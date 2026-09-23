package unit_tests

// Script instances at runtime (src/script/lua/instances.odin + rt.attach): plugin property values
// reach a script's members, OnInit fires on every instance, a runaway handler is stopped by the
// instruction budget without stopping the next one, placed refs start at the right time, and sent
// events run only when the queue drains.
// Hermetic: a temp scripts dir, no game files.

import "core:os"
import "core:path/filepath"
import "core:testing"
import "../../src/formats/esm"
import "../../src/gamedb"
import "../../src/script"
import slua "../../src/script/lua"
import "../../src/worldstate"

@(private = "file")
PROPS_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Props", nil)
C.__vars = {
  ["::target_var"] = { type = "objectreference", default = nil },
  ["::via_alias_var"] = { type = "objectreference", default = nil },
  ["::count_var"] = { type = "Int", default = nil },
  ["::speed_var"] = { type = "Float", default = nil },
  ["::on_var"] = { type = "Bool", default = nil },
  ["::label_var"] = { type = "String", default = nil },
  ["::list_var"] = { type = "Int[]", default = nil },
  ["::unset_var"] = { type = "Int", default = nil },
}
for _, p in ipairs({ "target", "via_alias", "count", "speed", "on", "label", "list", "unset" }) do
  C.__autoprop[p] = "::" .. p .. "_var"
end
C.__fn["oninit"] = function(self)
  local v = self.vars
  __seen = {
    target = v["::target_var"] === ref(0x5000),
    alias_none = v["::via_alias_var"] == nil and not v["::via_alias_var"],
    count = v["::count_var"] === 7,
    speed = v["::speed_var"] == 1.5,
    on = v["::on_var"] === true,
    label = v["::label_var"] === "Hello",
    list = rt.alen(v["::list_var"]) == 3 and rt.aget(v["::list_var"], 2) == 30,
    unset = v["::unset_var"] === 0,
  }
end
return C
`

@(private = "file")
SPIN_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Spin", nil)
C.__fn["oninit"] = function(self) while true do end end
return C
`

@(private = "file")
AFTER_LUA :: `local rt = require('skymod.rt')
local C = rt.class("After", nil)
C.__fn["oninit"] = function(self) __after = true end
return C
`

@(private = "file")
COUNT_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Count", nil)
C.__fn["oninit"] = function(self) __inits = (__inits or 0) + 1 end
return C
`

@(private = "file")
LEVER_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Lever", nil)
C.__fn["onactivate"] = function(self, who)
  __acts = (__acts or 0) + 1
  __who = who
  rt.send(self.form, "Again")
end
C.__fn["again"] = function(self) __again = true end
return C
`

// Fixture is a VM over a temp scripts dir. Its fields are pointed into, so it never moves.
@(private = "file")
Fixture :: struct {
	dir: string,
	reg: script.Registry,
	ws:  worldstate.World_State,
	db:  gamedb.DB,
	vm:  slua.VM,
}

@(private = "file")
fixture_init :: proc(t: ^testing.T, f: ^Fixture, name: string, files: [][2]string) {
	tmp, _ := os.temp_dir(context.temp_allocator)
	f.dir, _ = filepath.join({tmp, name}, context.temp_allocator)
	os.remove_all(f.dir)
	_ = os.make_directory_all(f.dir)
	for file in files {
		p, _ := filepath.join({f.dir, file[0]}, context.temp_allocator)
		testing.expect(t, os.write_entire_file(p, transmute([]u8)file[1]) == nil, "write fixture")
	}
	script.init(&f.reg)
	worldstate.init(&f.ws)
	testing.expect(t, slua.init(&f.vm, &f.reg, script.Call{ws = &f.ws, db = &f.db}), "VM init")
	slua.set_script_dirs(&f.vm, {f.dir})
}

@(private = "file")
fixture_destroy :: proc(f: ^Fixture) {
	slua.destroy(&f.vm)
	worldstate.destroy(&f.ws)
	script.destroy(&f.reg)
	os.remove_all(f.dir)
}

@(test)
test_attach_props_and_oninit :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_props", {{"props.lua", PROPS_LUA}, {"spin.lua", SPIN_LUA}, {"after.lua", AFTER_LUA}})
	defer fixture_destroy(&f)

	props := []esm.Script_Prop {
		{name = "Target", kind = .Object, status = 1, value = esm.Prop_Object{form = 0x5000, alias = -1}},
		{name = "Via_Alias", kind = .Object, status = 1, value = esm.Prop_Object{form = 0x6000, alias = 0}},
		{name = "Count", kind = .Int, status = 1, value = i32(7)},
		{name = "Speed", kind = .Float, status = 1, value = f32(1.5)},
		{name = "On", kind = .Bool, status = 1, value = true},
		{name = "Label", kind = .String, status = 1, value = "Hello"},
		{name = "List", kind = .Int_Array, status = 1, value = []i32{10, 20, 30}},
		{name = "Unset", kind = .Int, status = 3, value = i32(99)}, // removed: stays at the type's zero
	}
	scripts := []esm.Script_Attach{{name = "Props", props = props}, {name = "Spin"}, {name = "After"}}
	// The spin handler exceeds the budget by design and warns; that is not a test failure.
	made := slua.attach(&f.vm, script.Form_ID(0x1234), scripts, true)
	testing.expect_value(t, made, 3)

	ok := slua.do_string(&f.vm, `
		for k, v in pairs(__seen) do assert(v, "property " .. k) end
		assert(__after, "OnInit after a runaway handler still ran")`)
	testing.expect(t, ok, "OnInit saw every property value, and the budget stopped only the runaway")
}

// A persistent ref starts at game start; the cell's other refs and actors start when it loads, once.
// A deleted ref and a ref whose base has no scripts get nothing.
@(test)
test_refs_start_at_game_start_or_cell_load :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_refs", {{"count.lua", COUNT_LUA}})
	defer fixture_destroy(&f)

	CELL :: gamedb.Form_ID(0x100)
	SCRIPTED :: gamedb.Form_ID(0xB)
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	f.db.form_scripts[SCRIPTED] = {scripts = []esm.Script_Attach{{name = "Count"}}}
	f.db.cell_refs = make(map[gamedb.Form_ID][dynamic]gamedb.Ref, context.temp_allocator)
	f.db.cell_refs[CELL] = make([dynamic]gamedb.Ref, context.temp_allocator)
	append(
		&f.db.cell_refs[CELL],
		gamedb.Ref{form_id = 0x201, base = SCRIPTED, persistent = true},
		gamedb.Ref{form_id = 0x202, base = SCRIPTED},
		gamedb.Ref{form_id = 0x203, base = SCRIPTED, deleted = true, disabled = true},
		gamedb.Ref{form_id = 0x204, base = 0xC},
	)
	f.db.actor_refs = make(map[gamedb.Form_ID][dynamic]gamedb.Ref, context.temp_allocator)
	f.db.actor_refs[CELL] = make([dynamic]gamedb.Ref, context.temp_allocator)
	append(&f.db.actor_refs[CELL], gamedb.Ref{form_id = 0x301, base = SCRIPTED})

	testing.expect_value(t, slua.start_game(&f.vm, &f.db, true), 1)
	testing.expect_value(t, slua.attach_cell(&f.vm, &f.db, CELL, true), 2)
	testing.expect_value(t, slua.attach_cell(&f.vm, &f.db, CELL, true), 0)
	testing.expect(t, slua.do_string(&f.vm, `assert(__inits == 3, tostring(__inits))`), "OnInit ran once per ref")
}

// A sent event waits for the drain, reaches the handler with its args, and an event a handler sends
// runs on the next drain. An event for a form with no scripts is dropped.
@(test)
test_send_runs_on_drain :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_events", {{"lever.lua", LEVER_LUA}})
	defer fixture_destroy(&f)

	LEVER :: script.Form_ID(0x500)
	testing.expect_value(t, slua.attach(&f.vm, LEVER, []esm.Script_Attach{{name = "Lever"}}, false), 1)
	slua.send(&f.vm, LEVER, "OnActivate", script.PLAYER)
	slua.send(&f.vm, script.Form_ID(0x999), "OnActivate", script.PLAYER)
	testing.expect(t, slua.do_string(&f.vm, `assert(__acts == nil)`), "nothing runs before the drain")

	testing.expect_value(t, slua.drain(&f.vm), 1)
	testing.expect(t, slua.do_string(&f.vm, `assert(__acts == 1 and __who === ref(0x14) and not __again)`), "OnActivate ran by the player")
	testing.expect_value(t, slua.drain(&f.vm), 1)
	testing.expect(t, slua.do_string(&f.vm, `assert(__again)`), "a handler's event ran on the next drain")
}
