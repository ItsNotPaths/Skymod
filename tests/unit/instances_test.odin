package unit_tests

// Script instances at runtime (src/script/lua/instances.odin + rt.attach): plugin property values
// reach a script's members, OnInit fires on every instance, a runaway handler is stopped by the
// instruction budget without stopping the next one, placed refs start at the right time, and sent
// events run only when the queue drains, load/attach transitions follow the attached cells, and
// OnUpdate registrations fire on time.
// Hermetic: a temp scripts dir, no game files.

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"
import "../../src/formid"
import "../../src/formula"
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
  ["::via_alias_var"] = { type = "referencealias", default = nil },
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
    alias = v["::via_alias_var"] === ref(0x4000000000006000), -- alias 0 of quest 0x6000
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

@(private = "file")
WATCH_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Watch", nil)
__log = {}
for _, e in ipairs({ "OnCellAttach", "OnLoad", "OnCellLoad", "OnUnload", "OnCellDetach" }) do
  C.__fn[string.lower(e)] = function(self)
    __log[#__log] = (self.form === ref(0x201) and "a:" or "b:") .. e
  end
end
return C
`

@(private = "file")
SPAWNER_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Spawner", nil)
C.__fn["spawn"] = function(self)
  __placed = rt.call(self.form, "PlaceAtMe", ref(0xB))
  __inits_at_return = __inits or 0
end
return C
`

@(private = "file")
MADE_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Made", nil)
C.__vars = { TickRate = rt.float(0) }
C.__fn["oninit"] = function(self) __inits = (__inits or 0) + 1 end
C.__fn["onload"] = function(self) __loads = (__loads or 0) + 1 end
C.__fn["ontick"] = function(self) __ticks = (__ticks or 0) + 1 end
return C
`

@(private = "file")
GLOW_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Glow", nil)
C.__effect = { Health = { capacity = "m * (1 - t / d)" }, Stamina = { amount = "q", pace = "1" } }
__fx = {}
C.__fn["oneffectstart"] = function(self, target, caster)
  __fx[#__fx] = "start:" .. tostring(target === self:GetTargetActor())
end
C.__fn["oneffectfinish"] = function(self) __fx[#__fx] = "finish"; self.vars["::state"] = "fading" end
C.__states["fading"] = {}
C.__states["fading"]["ontick"] = function(self) __fx[#__fx] = "tick"; self.vars["::state"] = "" end
return C
`

@(private = "file")
TICK_A_LUA :: `local rt = require('skymod.rt')
local C = rt.class("TickA", nil)
C.__fn["onupdate"] = function(self) __a = (__a or 0) + 1 end
C.__fn["onupdategametime"] = function(self) __g = (__g or 0) + 1 end
C.__fn["oninit"] = function(self) __init = (__init or 0) + 1 end
C.__fn["onreset"] = function(self) __reset = (__reset or 0) + 1 end
return C
`

@(private = "file")
TICK_B_LUA :: `local rt = require('skymod.rt')
local C = rt.class("TickB", nil)
C.__fn["onupdate"] = function(self) __b = (__b or 0) + 1 end
return C
`

@(private = "file")
BAG_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Bag", nil)
local function log(s) __log = (__log or "") .. s .. ";" end
C.__fn["onitemadded"] = function(self, base, n, ref, src) log("add" .. n .. (src and "+src" or "")) end
C.__fn["onitemremoved"] = function(self, base, n, ref, dest) log("rem" .. n .. (dest and "+dest" or "")) end
C.__fn["oncontainerchanged"] = function(self, new, old) log("moved" .. (new and "+new" or "") .. (old and "+old" or "")) end
return C
`

@(private = "file")
GUARD_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Guard", nil)
local get = rt.native("ReferenceAlias", "GetReference", false)
C.__fn["onactivate"] = function(self, by) __guard = (__guard or "") .. tostring(get(self)) .. ";" end
C.__fn["onupdate"] = function(self) __guard = (__guard or "") .. "update;" end
return C
`

@(private = "file")
COUNTER_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Counter", nil)
C.__vars = {
  ["::count_var"] = { type = "Int", default = nil },
  ["::list_var"] = { type = "Int[]", default = nil },
  ["::seen"] = { type = "Bool", default = nil },
  ["::target"] = { type = "objectreference", default = nil },
  ["::untouched"] = { type = "Int", default = 4 },
}
C.__autoprop["count"] = "::count_var"
C.__autoprop["list"] = "::list_var"
C.__fn["oninit"] = function(self) __inits = (__inits or 0) + 1 end
return C
`

@(private = "file")
SEEDS_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Seeds", nil)
C.__fn["ongameloaded"] = function(self) rt.seed_spell(ref(0x500), ref(0x902)) end
return C
`

@(private = "file")
STATS_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Stats", nil)
C.__fn["ongameloaded"] = function(self)
  __order = (__order or "") .. "loaded;"
  rt.actor_value("Hunger", { default = -1 })
  if not __second then rt.actor_value("Old") end
end
C.__fn["oninit"] = function(self)
  __order = (__order or "") .. "init;"
  __outside = pcall(rt.actor_value, "Thirst")
end
return C
`

@(private = "file")
ZONES_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Zones", nil)
local listen = rt.native("Form", "RegisterForZoneLevelSet", false)
C.__fn["ongameloaded"] = function(self)
  rt.formula("ZoneLevel", "level + 3")
  listen(self)
end
C.__fn["onzonelevelset"] = function(self, zone, level) __zone = { zone, level } end
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

	testing.expect_value(t, slua.start_game(&f.vm, &f.db), 1)
	testing.expect_value(t, slua.attach_cell(&f.vm, &f.db, CELL), 2)
	testing.expect_value(t, slua.attach_cell(&f.vm, &f.db, CELL), 0)
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
	slua.send(&f.vm, LEVER, "OnActivate", formid.PLAYER)
	slua.send(&f.vm, script.Form_ID(0x999), "OnActivate", formid.PLAYER)
	testing.expect(t, slua.do_string(&f.vm, `assert(__acts == nil)`), "nothing runs before the drain")

	testing.expect_value(t, slua.drain(&f.vm), 1)
	testing.expect(t, slua.do_string(&f.vm, `assert(__acts == 1 and __who === ref(0x14) and not __again)`), "OnActivate ran by the player")
	testing.expect_value(t, slua.drain(&f.vm), 1)
	testing.expect(t, slua.do_string(&f.vm, `assert(__again)`), "a handler's event ran on the next drain")
}

// A cell attaching sends OnCellAttach to every scripted ref, OnLoad to the enabled ones, then
// OnCellLoad. Enabling a ref in an attached cell loads it; the cell detaching unloads, then
// detaches. Is3DLoaded follows the same state.
@(test)
test_transitions_follow_attached_cells :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_transitions", {{"watch.lua", WATCH_LUA}})
	defer fixture_destroy(&f)
	trans: slua.Transitions
	defer slua.transitions_destroy(&trans)

	CELL :: gamedb.Form_ID(0x100)
	SCRIPTED :: gamedb.Form_ID(0xB)
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	f.db.form_scripts[SCRIPTED] = {scripts = []esm.Script_Attach{{name = "Watch"}}}
	refs := []gamedb.Ref {
		{form_id = 0x201, cell_form_id = CELL, base = SCRIPTED},
		{form_id = 0x202, cell_form_id = CELL, base = SCRIPTED, disabled = true},
		{form_id = 0x204, cell_form_id = CELL, base = 0xC},
	}
	f.db.cell_refs = make(map[gamedb.Form_ID][dynamic]gamedb.Ref, context.temp_allocator)
	f.db.cell_refs[CELL] = make([dynamic]gamedb.Ref, context.temp_allocator)
	f.db.ref_by_id = make(map[gamedb.Form_ID]gamedb.Ref, context.temp_allocator)
	for r in refs {
		append(&f.db.cell_refs[CELL], r)
		f.db.ref_by_id[r.form_id] = r
	}
	slua.attach_cell(&f.vm, &f.db, CELL)

	loaded :: proc(f: ^Fixture, form: script.Form_ID) -> bool {
		c := script.Call{self = form, ws = &f.ws, db = &f.db}
		b, _ := script.call(&f.reg, "ObjectReference", "Is3DLoaded", &c, nil).(bool)
		return b
	}
	step :: proc(t: ^testing.T, f: ^Fixture, trans: ^slua.Transitions, now: []script.Form_ID, want: string) {
		slua.tick_transitions(&f.vm, &f.db, &f.ws, trans, now)
		slua.drain(&f.vm)
		check := strings.concatenate({`local got = table.concat(__log, ","); __log = {}; assert(got == "`, want, `", got)`}, context.temp_allocator)
		ok := slua.do_string(&f.vm, check)
		testing.expectf(t, ok, "events after attached = %v", now)
	}

	step(t, &f, &trans, {CELL}, "a:OnCellAttach,b:OnCellAttach,a:OnLoad,a:OnCellLoad,b:OnCellLoad")
	testing.expect(t, loaded(&f, 0x201) && !loaded(&f, 0x202), "Is3DLoaded: enabled yes, disabled no")
	step(t, &f, &trans, {CELL}, "")
	worldstate.set_disabled(&f.ws, 0x202, CELL, false)
	step(t, &f, &trans, {CELL}, "b:OnLoad")
	step(t, &f, &trans, {}, "a:OnUnload,a:OnCellDetach,b:OnUnload,b:OnCellDetach")
	testing.expect(t, !loaded(&f, 0x201), "Is3DLoaded: no once detached")
}

// OnUpdate timers (the scheduler): a registration belongs to the form, so both scripts on it get
// OnUpdate; registering again replaces the pending one; a repeating one keeps firing until
// UnregisterForUpdate; a due timer on a form with no scripts yet waits for them.
@(test)
test_updates_fire_on_time :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_updates", {{"ticka.lua", TICK_A_LUA}, {"tickb.lua", TICK_B_LUA}})
	defer fixture_destroy(&f)

	FORM :: script.Form_ID(0x700)
	LATE :: script.Form_ID(0x701)
	both := []esm.Script_Attach{{name = "TickA"}, {name = "TickB"}}
	slua.attach(&f.vm, FORM, both, false)
	native :: proc(f: ^Fixture, form: script.Form_ID, fn: string, args: ..script.Value) {
		c := script.Call{self = form, ws = &f.ws, db = &f.db}
		script.call(&f.reg, "Form", fn, &c, args)
	}
	ticks :: proc(f: ^Fixture, n: int) {
		for _ in 0 ..< n {
			slua.tick_updates(&f.vm, &f.ws, 1.0 / 60, 0)
			slua.drain(&f.vm)
		}
	}
	seen :: proc(f: ^Fixture, a, b: int) -> bool {
		return slua.do_string(&f.vm, strings.concatenate({`assert((__a or 0) == `, fmt_int(a), ` and (__b or 0) == `, fmt_int(b), `, tostring(__a) .. " " .. tostring(__b))`}, context.temp_allocator))
	}

	native(&f, FORM, "RegisterForSingleUpdate", f32(1))
	native(&f, FORM, "RegisterForSingleUpdate", f32(0.5)) // replaces the 1 s one
	ticks(&f, 28)
	testing.expect(t, seen(&f, 0, 0), "nothing before 0.5 s")
	ticks(&f, 4)
	testing.expect(t, seen(&f, 1, 1), "both scripts at 0.5 s")
	ticks(&f, 60)
	testing.expect(t, seen(&f, 1, 1), "a single update fires once")
	testing.expect(t, FORM not_in f.ws.updates, "a fired single update is gone")

	native(&f, FORM, "RegisterForUpdate", f32(0.5))
	ticks(&f, 62) // ~1.03 s: fires at 0.5 and 1.0
	testing.expect(t, seen(&f, 3, 3), "a repeating update fires every 0.5 s")
	native(&f, FORM, "UnregisterForUpdate")
	ticks(&f, 60)
	testing.expect(t, seen(&f, 3, 3), "UnregisterForUpdate stops it")

	native(&f, LATE, "RegisterForSingleUpdate", f32(0.1))
	ticks(&f, 30)
	testing.expect(t, LATE in f.ws.updates, "due with no scripts yet: still waiting")
	slua.attach(&f.vm, LATE, both, false)
	ticks(&f, 1)
	testing.expect(t, seen(&f, 4, 4), "delivered once the form has scripts")
}

// OnUpdateGameTime timers count game hours. After a skip a repeating one fires once, not once for
// each interval it passed, then starts a full interval again (CK wiki, OnUpdateGameTime).
@(test)
test_game_time_updates :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_game_updates", {{"ticka.lua", TICK_A_LUA}})
	defer fixture_destroy(&f)

	FORM :: script.Form_ID(0x700)
	slua.attach(&f.vm, FORM, []esm.Script_Attach{{name = "TickA"}}, false)
	c := script.Call{self = FORM, ws = &f.ws, db = &f.db}
	hours :: proc(f: ^Fixture, h: f64) {
		slua.tick_updates(&f.vm, &f.ws, 0, h)
		slua.drain(&f.vm)
	}
	seen :: proc(f: ^Fixture, n: int) -> bool {
		return slua.do_string(&f.vm, strings.concatenate({`assert((__g or 0) == `, fmt_int(n), `, tostring(__g))`}, context.temp_allocator))
	}

	script.call(&f.reg, "Form", "RegisterForUpdateGameTime", &c, {f32(1)})
	hours(&f, 0.5)
	testing.expect(t, seen(&f, 0), "nothing before an hour")
	hours(&f, 0.5)
	testing.expect(t, seen(&f, 1), "fires at an hour")
	hours(&f, 24)
	testing.expect(t, seen(&f, 2), "a 24-hour skip fires once")
	hours(&f, 0.5)
	testing.expect(t, seen(&f, 2), "a full interval after the skip")
	hours(&f, 0.5)
	testing.expect(t, seen(&f, 3), "then on time again")

	script.call(&f.reg, "Form", "RegisterForSingleUpdate", &c, {f32(10)})
	script.call(&f.reg, "Form", "UnregisterForUpdateGameTime", &c, nil)
	testing.expect(t, FORM not_in f.ws.game_updates, "UnregisterForUpdateGameTime stops game time")
	testing.expect(t, FORM in f.ws.updates, "and leaves OnUpdate alone")
}

@(private = "file")
fmt_int :: proc(n: int) -> string {
	buf := make([]u8, 20, context.temp_allocator)
	return strconv.itoa(buf, n)
}

// AddItem/RemoveItem queue OnItemAdded/OnItemRemoved for the next tick, only for items the
// container's filters let through; a transfer tells both containers; a moved ref hears
// OnContainerChanged.
@(test)
test_item_events :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_items", {{"bag.lua", BAG_LUA}})
	defer fixture_destroy(&f)

	CHEST :: script.Form_ID(0x800)
	OTHER :: script.Form_ID(0x801)
	GOLD :: script.Form_ID(0xF)
	ARROW :: script.Form_ID(0x10)
	bag := []esm.Script_Attach{{name = "Bag"}}
	ring := worldstate.create_ref(&f.ws, 0x20, 0, {}, {}, 1)
	for form in ([]script.Form_ID{CHEST, OTHER, ring}) {slua.attach(&f.vm, form, bag, false)}
	native :: proc(f: ^Fixture, form: script.Form_ID, fn: string, args: ..script.Value) {
		c := script.Call{self = form, ws = &f.ws, db = &f.db}
		script.call(&f.reg, "ObjectReference", fn, &c, args)
	}
	logged :: proc(f: ^Fixture, want: string) -> bool {
		slua.tick_items(&f.vm, &f.db, &f.ws)
		slua.drain(&f.vm)
		return slua.do_string(&f.vm, strings.concatenate({`assert((__log or "") == "`, want, `", __log); __log = nil`}, context.temp_allocator))
	}

	native(&f, CHEST, "RemoveAllItems") // an empty container
	testing.expect(t, logged(&f, ""), "nothing to remove")
	native(&f, CHEST, "AddItem", ARROW, i32(5))
	testing.expect(t, logged(&f, "add5;"), "no filter: every item")

	native(&f, CHEST, "AddInventoryEventFilter", GOLD)
	native(&f, CHEST, "AddItem", ARROW, i32(5))
	native(&f, CHEST, "AddItem", GOLD, i32(3))
	testing.expect(t, logged(&f, "add3;"), "a filter drops other items")

	alias, _ := formid.alias_handle(0x900, 0)
	slua.attach(&f.vm, alias, bag, false)
	worldstate.fill_alias(&f.ws, alias, CHEST)
	native(&f, CHEST, "AddItem", ARROW, i32(1))
	testing.expect(t, logged(&f, "add1;"), "an alias holding the chest filters by its own filters, not the chest's")
	worldstate.clear_alias(&f.ws, alias)

	native(&f, CHEST, "RemoveItem", GOLD, i32(2), false, OTHER)
	testing.expect(t, logged(&f, "rem2+dest;add2+src;"), "a transfer tells both containers")
	testing.expect_value(t, worldstate.inv_delta(&f.ws, CHEST, GOLD), 1)
	testing.expect_value(t, worldstate.inv_delta(&f.ws, OTHER, GOLD), 2)
	testing.expect_value(t, worldstate.inv_delta(&f.ws, CHEST, ARROW), 11)

	native(&f, OTHER, "AddItem", ring)
	testing.expect(t, logged(&f, "add1;moved+new;"), "a ref moving hears OnContainerChanged")
	testing.expect_value(t, worldstate.inv_delta(&f.ws, OTHER, 0x20), 1)

	native(&f, CHEST, "RemoveAllInventoryEventFilters")
	native(&f, CHEST, "RemoveAllItems")
	testing.expect(t, logged(&f, "rem1;rem11;"), "RemoveAllItems: one event per item type")
}

// A starting quest fills its Forced alias, then its External one from it; the alias's scripts get
// the events of the ref it holds (not the ref's OnUpdate); a stopped quest empties both.
@(test)
test_alias_fills_and_events :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_aliases", {{"guard.lua", GUARD_LUA}})
	defer fixture_destroy(&f)

	QUEST :: script.Form_ID(0x900)
	DOOR :: script.Form_ID(0x901)
	aliases := []gamedb.Quest_Alias{{id = 0, fill = .Forced, target = DOOR}, {id = 1, fill = .External, target = QUEST, extra = 0}}
	f.db.quest_baseline = make(map[gamedb.Form_ID]gamedb.Quest_Baseline)
	defer delete(f.db.quest_baseline)
	f.db.quest_baseline[QUEST] = {aliases = aliases}
	forced, _ := formid.alias_handle(QUEST, 0)
	external, _ := formid.alias_handle(QUEST, 1)
	slua.attach(&f.vm, forced, []esm.Script_Attach{{name = "Guard"}}, false)
	quest :: proc(f: ^Fixture, fn: string) {
		c := script.Call{self = QUEST, ws = &f.ws, db = &f.db}
		script.call(&f.reg, "Quest", fn, &c, nil)
	}
	guard_saw :: proc(f: ^Fixture, want: string) -> bool {
		slua.drain(&f.vm)
		return slua.do_string(&f.vm, strings.concatenate({`assert((__guard or "") == "`, want, `", __guard); __guard = nil`}, context.temp_allocator))
	}

	quest(&f, "Start")
	testing.expect_value(t, f.ws.aliases[forced], DOOR)
	testing.expect_value(t, f.ws.aliases[external], DOOR)
	slua.send(&f.vm, DOOR, "OnActivate", formid.PLAYER)
	testing.expect(t, guard_saw(&f, "[ObjectReference 0x00000901];"), "the alias hears its ref's OnActivate")

	worldstate.register_update(&f.ws.updates, DOOR, 0, false)
	slua.tick_updates(&f.vm, &f.ws, 1.0 / 60, 0)
	testing.expect(t, guard_saw(&f, ""), "the ref's own OnUpdate is not the alias's")

	quest(&f, "Stop")
	testing.expect_value(t, len(f.ws.aliases), 0)
	slua.send(&f.vm, DOOR, "OnActivate", formid.PLAYER)
	testing.expect(t, guard_saw(&f, ""), "an empty alias hears nothing")

	f.db.quest_baseline[QUEST] = {start_game_enabled = true, aliases = aliases}
	slua.start_game(&f.vm, &f.db)
	testing.expect_value(t, len(f.ws.aliases), 0)
	slua.new_game(&f.vm, &f.db)
	testing.expect_value(t, f.ws.aliases[forced], DOOR)
}

// A save keeps the members that differ from a fresh instance, autoprops included, and which forms
// ran OnInit. Loading puts the values back on rebuilt instances without re-running OnInit; a form
// the save does not know still runs it.
@(test)
test_script_members_survive_a_save :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_saves", {{"counter.lua", COUNTER_LUA}})
	defer fixture_destroy(&f)

	FORM :: script.Form_ID(0xA00)
	LATER :: script.Form_ID(0xA01)
	counter := []esm.Script_Attach{{name = "Counter", props = {
		{name = "Count", kind = .Int, status = 1, value = i32(5)},
		{name = "List", kind = .Int_Array, status = 1, value = []i32{1, 2, 3}},
	}}}
	testing.expect_value(t, slua.attach_known(&f.vm, FORM, counter), 1)
	testing.expect(t, slua.do_string(&f.vm, `
    local rt = require('skymod.rt')
    local v = rt.instances_of(ref(0xA00))["counter"].vars
    v["::count_var"] = 6
    rt.aset(v["::list_var"], 1, 9)
    v["::seen"] = true
    v["::target"] = ref(0x14)`), "change members")

	slua.save_scripts(&f.vm)
	testing.expect_value(t, len(f.ws.script_state[FORM]), 4)
	path := "/tmp/skymod_script_members.skysave"
	defer os.remove(path)
	testing.expect(t, worldstate.save_to_file(&f.ws, path, {save_number = 1}), "save")
	_, loaded := worldstate.load_from_file(&f.ws, path)
	testing.expect(t, loaded, "load")

	slua.reload_scripts(&f.vm, &f.db)
	testing.expect_value(t, slua.attach_known(&f.vm, FORM, counter), 1)
	testing.expect_value(t, slua.attach_known(&f.vm, LATER, counter), 1)
	testing.expect(t, slua.do_string(&f.vm, `
    local rt = require('skymod.rt')
    local v = rt.instances_of(ref(0xA00))["counter"].vars
    assert(v["::count_var"] === 6 and rt.aget(v["::list_var"], 1) === 9 and rt.aget(v["::list_var"], 2) === 3)
    assert(v["::seen"] === true and v["::target"] === ref(0x14) and v["::untouched"] === 4)
    assert(__inits == 2, "OnInit ran for the new form only: " .. tostring(__inits))`), "members restored")
}

// A placed ref of a scripted base gets its scripts inside PlaceAtMe (OnInit has run when it
// returns), joins its attached cell (OnLoad on the next tick), and ticks. Deleted, it stops ticking
// and its saved state goes.
@(test)
test_created_refs_run_scripts :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_created", {{"spawner.lua", SPAWNER_LUA}, {"made.lua", MADE_LUA}})
	defer fixture_destroy(&f)
	trans: slua.Transitions
	defer slua.transitions_destroy(&trans)

	CELL :: gamedb.Form_ID(0x100)
	SPAWNER :: script.Form_ID(0x600)
	f.db.cells = make(map[gamedb.Form_ID]gamedb.Cell, context.temp_allocator)
	f.db.cells[CELL] = {form_id = CELL, interior = true}
	f.db.ref_by_id = make(map[gamedb.Form_ID]gamedb.Ref, context.temp_allocator)
	f.db.ref_by_id[SPAWNER] = {form_id = SPAWNER, cell_form_id = CELL}
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	f.db.form_scripts[0xB] = {scripts = []esm.Script_Attach{{name = "Made"}}}
	slua.attach(&f.vm, SPAWNER, []esm.Script_Attach{{name = "Spawner"}}, false)
	slua.tick_transitions(&f.vm, &f.db, &f.ws, &trans, {CELL})

	ok := slua.do_string(&f.vm, `rt = require('skymod.rt'); rt.call(ref(0x600), "Spawn")
assert(__inits_at_return == 1, "OnInit ran inside PlaceAtMe")`)
	testing.expect(t, ok, "OnInit inside the call")
	slua.tick_transitions(&f.vm, &f.db, &f.ws, &trans, {CELL})
	slua.tick_end(&f.vm, 1.0 / 60)
	testing.expect(t, slua.do_string(&f.vm, `assert(__loads == 1 and __ticks == 1, tostring(__loads) .. "/" .. tostring(__ticks))`), "joins its cell and ticks")

	slua.save_scripts(&f.vm)
	testing.expect(t, slua.do_string(&f.vm, `__placed:Delete()`), "delete")
	slua.tick_end(&f.vm, 1.0 / 60)
	testing.expect(t, slua.do_string(&f.vm, `assert(__ticks == 1)`), "a deleted ref stops ticking")
	for id in f.ws.created {testing.expect(t, id not_in f.ws.script_state, "its saved state goes")}
}

// A spell's scripted effect gets an instance on its target: OnEffectStart, its duration, then
// OnEffectFinish. The instance stays while its state ticks, then leaves.
@(test)
test_effect_lifecycle :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_effects", {{"glow.lua", GLOW_LUA}})
	defer fixture_destroy(&f)

	SPELL, MGEF :: gamedb.Form_ID(0x900), gamedb.Form_ID(0x901)
	f.db.spells = make(map[gamedb.Form_ID]gamedb.Spell, context.temp_allocator)
	f.db.spells[SPELL] = {info = {cast_type = .Fire_And_Forget}, effects = []gamedb.Magic_Effect_Ref{{effect = MGEF, duration = 2}}}
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	f.db.form_scripts[MGEF] = {scripts = []esm.Script_Attach{{name = "Glow"}}}

	f.db.form_kinds = make(map[gamedb.Form_ID]gamedb.Form_Kind, context.temp_allocator)
	f.db.form_kinds[SPELL] = .Spell
	testing.expect(t, slua.do_string(&f.vm, `rt = require('skymod.rt'); rt.call(ref(0x900), "Cast", ref(0x700))`), "Cast")
	testing.expect_value(t, len(f.ws.effects), 1)
	slua.tick_effects(&f.vm, &f.ws, 1)
	slua.tick_end(&f.vm, 1)
	slua.tick_effects(&f.vm, &f.ws, 1)
	slua.tick_end(&f.vm, 1)
	testing.expect_value(t, len(f.ws.effects), 1)
	slua.tick_effects(&f.vm, &f.ws, 1)
	testing.expect_value(t, len(f.ws.effects), 0)
	testing.expect(t, slua.do_string(&f.vm, `local got = table.concat(__fx, ","); assert(got == "start:true,finish,tick", got)`), "start, finish, one tick, gone")

	terms := f.ws.effect_terms["glow"]
	testing.expect_value(t, len(terms), 1) // a bad formula and an unknown knob drop their terms
	testing.expect(t, terms[0].av == "Health" && terms[0].knob == .Capacity, "__effect read when the class loads")
	testing.expect_value(t, formula.eval(terms[0].f, {1, 10, 2}), 5)
}

// An effect whose conditions fail at start does not start; they run on the target.
@(test)
test_effect_start_conditions :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_effect_ctda", {{"glow.lua", GLOW_LUA}})
	defer fixture_destroy(&f)

	SPELL, MGEF, PERK :: gamedb.Form_ID(0x900), gamedb.Form_ID(0x901), gamedb.Form_ID(0x902)
	PERKED :: gamedb.Form_ID(0x701)
	has_perk := []gamedb.Condition{{function = 448, op = .Equal, value = 1, param1 = u64(PERK)}}
	f.db.spells = make(map[gamedb.Form_ID]gamedb.Spell, context.temp_allocator)
	f.db.spells[SPELL] = {info = {cast_type = .Fire_And_Forget}, effects = []gamedb.Magic_Effect_Ref{{effect = MGEF, duration = 2, conditions = has_perk}, {effect = MGEF, duration = 2}}}
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	f.db.form_scripts[MGEF] = {scripts = []esm.Script_Attach{{name = "Glow"}}}

	f.db.form_kinds = make(map[gamedb.Form_ID]gamedb.Form_Kind, context.temp_allocator)
	f.db.form_kinds[SPELL] = .Spell
	testing.expect(t, slua.do_string(&f.vm, `rt = require('skymod.rt'); rt.call(ref(0x900), "Cast", ref(0x700))`), "Cast")
	testing.expect_value(t, len(f.ws.effects), 1)
	f.ws.perks[PERKED] = make(map[gamedb.Form_ID]bool)
	(&f.ws.perks[PERKED])[PERK] = true
	testing.expect(t, slua.do_string(&f.vm, `rt.call(ref(0x900), "Cast", ref(0x701))`), "Cast on the perked")
	testing.expect_value(t, len(f.ws.effects), 3)
}

// EquipItem on a potion drinks one: it leaves the pack, OnObjectEquipped is queued and its effects
// start on the drinker. A poison is not drunk.
@(test)
test_potion_equip :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_potion", {{"glow.lua", GLOW_LUA}})
	defer fixture_destroy(&f)

	POTION, POISON, MGEF :: gamedb.Form_ID(0x910), gamedb.Form_ID(0x911), gamedb.Form_ID(0x901)
	DRINKER :: gamedb.Form_ID(0x700)
	effects := []gamedb.Magic_Effect_Ref{{effect = MGEF, duration = 2}}
	f.db.potions = make(map[gamedb.Form_ID]gamedb.Potion, context.temp_allocator)
	f.db.potions[POTION] = {effects = effects}
	f.db.potions[POISON] = {effects = effects, poison = true}
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	f.db.form_scripts[MGEF] = {scripts = []esm.Script_Attach{{name = "Glow"}}}
	worldstate.inv_add(&f.ws, DRINKER, POTION, 2)
	worldstate.inv_add(&f.ws, DRINKER, POISON, 1)

	testing.expect(t, slua.do_string(&f.vm, `rt = require('skymod.rt'); rt.call(ref(0x700), "EquipItem", ref(0x910)); rt.call(ref(0x700), "EquipItem", ref(0x911))`), "EquipItem")
	testing.expect_value(t, worldstate.inv_count(&f.ws, &f.db, DRINKER, POTION), 1)
	testing.expect_value(t, worldstate.inv_count(&f.ws, &f.db, DRINKER, POISON), 1)
	testing.expect_value(t, len(f.ws.effects), 1)
	testing.expect(t, len(f.ws.equip_changes) == 1 && f.ws.equip_changes[0].item == POTION, "OnObjectEquipped for the potion only")
}

// AddSpell teaches; only an ability starts. DispelSpell ends effects and keeps the spell; RemoveSpell
// forgets it. sync_abilities catches an actor up when a mod update changes its records' list.
@(test)
test_spell_natives :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_spells", {{"glow.lua", GLOW_LUA}})
	defer fixture_destroy(&f)

	FIREBALL, ABILITY, RACIAL, MGEF :: gamedb.Form_ID(0x900), gamedb.Form_ID(0x902), gamedb.Form_ID(0x903), gamedb.Form_ID(0x901)
	ACTOR :: gamedb.Form_ID(0x700)
	glow := []gamedb.Magic_Effect_Ref{{effect = MGEF}}
	f.db.spells = make(map[gamedb.Form_ID]gamedb.Spell, context.temp_allocator)
	f.db.spells[FIREBALL] = {effects = glow}
	f.db.spells[ABILITY] = {info = {type = .Ability}, effects = glow}
	f.db.spells[RACIAL] = {info = {type = .Ability}, effects = glow}
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	f.db.form_scripts[MGEF] = {scripts = []esm.Script_Attach{{name = "Glow"}}}
	f.db.actors = make(map[gamedb.Form_ID]gamedb.Actor_Base, context.temp_allocator)
	f.db.actors[ACTOR] = {}

	testing.expect(t, slua.do_string(&f.vm, `rt = require('skymod.rt'); local a = ref(0x700)
assert(rt.call(a, "AddSpell", ref(0x900)) and rt.call(a, "AddSpell", ref(0x902)))
assert(not rt.call(a, "AddSpell", ref(0x902)), "known")`), "AddSpell")
	testing.expect_value(t, len(f.ws.effects), 1)
	testing.expect(t, slua.do_string(&f.vm, `local a = ref(0x700)
assert(rt.call(a, "DispelSpell", ref(0x902)) and rt.call(a, "HasSpell", ref(0x902)), "dispelled, still known")
assert(rt.call(a, "RemoveSpell", ref(0x900)) and not rt.call(a, "HasSpell", ref(0x900)), "forgotten")`), "DispelSpell, RemoveSpell")

	c := script.Call{ws = &f.ws, db = &f.db}
	f.db.actors[ACTOR] = {spells = {RACIAL}} // a mod update
	script.sync_abilities(&c, ACTOR)
	testing.expect_value(t, len(script.spell_effects(&f.ws, ACTOR, RACIAL)), 1)
	f.db.actors[ACTOR] = {}
	script.sync_abilities(&c, ACTOR)
	testing.expect_value(t, len(script.spell_effects(&f.ws, ACTOR, RACIAL)), 0)
}

// rt.seed_spell from OnGameLoaded gives a race an ability; game start starts it on its actors.
@(test)
test_seed_spell :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_seeds", {{"seeds.lua", SEEDS_LUA}, {"glow.lua", GLOW_LUA}})
	defer fixture_destroy(&f)

	QUEST, RACE, NPC, ACTOR, CELL :: gamedb.Form_ID(0x800), gamedb.Form_ID(0x500), gamedb.Form_ID(0x501), gamedb.Form_ID(0x700), gamedb.Form_ID(0x100)
	ABILITY, MGEF :: gamedb.Form_ID(0x902), gamedb.Form_ID(0x901)
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	f.db.form_scripts[QUEST] = {scripts = []esm.Script_Attach{{name = "Seeds"}}}
	f.db.form_scripts[MGEF] = {scripts = []esm.Script_Attach{{name = "Glow"}}}
	f.db.quest_baseline = make(map[gamedb.Form_ID]gamedb.Quest_Baseline, context.temp_allocator)
	f.db.quest_baseline[QUEST] = {}
	f.db.spells = make(map[gamedb.Form_ID]gamedb.Spell, context.temp_allocator)
	f.db.spells[ABILITY] = {info = {type = .Ability}, effects = []gamedb.Magic_Effect_Ref{{effect = MGEF}}}
	f.db.actors = make(map[gamedb.Form_ID]gamedb.Actor_Base, context.temp_allocator)
	f.db.actors[NPC] = {race = RACE}
	actor := gamedb.Ref{form_id = ACTOR, base = NPC, cell_form_id = CELL, persistent = true}
	f.db.ref_by_id = make(map[gamedb.Form_ID]gamedb.Ref, context.temp_allocator)
	f.db.ref_by_id[ACTOR] = actor
	f.db.actor_refs = make(map[gamedb.Form_ID][dynamic]gamedb.Ref, context.temp_allocator)
	f.db.actor_refs[CELL] = make([dynamic]gamedb.Ref, context.temp_allocator)
	append(&f.db.actor_refs[CELL], actor)

	slua.start_game(&f.vm, &f.db)
	testing.expect_value(t, len(script.spell_effects(&f.ws, ACTOR, ABILITY)), 1)
	testing.expect(t, slua.do_string(&f.vm, `assert(not pcall(require('skymod.rt').seed_spell, ref(0x500), ref(0x902)))`), "only inside OnGameLoaded")
}

// A reset restarts a ref's scripts: its instances go, new ones run OnInit, then OnReset. A ref with
// no instances (its cell never loaded) gets none.
@(test)
test_reset_restarts_scripts :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_reset", {{"ticka.lua", TICK_A_LUA}})
	defer fixture_destroy(&f)

	FORM :: script.Form_ID(0x700)
	LATE :: script.Form_ID(0x701)
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	f.db.form_scripts[FORM] = {scripts = []esm.Script_Attach{{name = "TickA"}}}
	f.db.ref_by_id = make(map[gamedb.Form_ID]gamedb.Ref, context.temp_allocator)
	f.db.ref_by_id[FORM] = {form_id = FORM, base = 0x702}
	slua.attach(&f.vm, FORM, []esm.Script_Attach{{name = "TickA"}}, true)
	slua.drain(&f.vm)
	worldstate.restart_scripts(&f.ws, FORM)
	worldstate.restart_scripts(&f.ws, LATE)
	slua.sync_refs(&f.vm)
	slua.drain(&f.vm)
	testing.expect(t, slua.do_string(&f.vm, `assert(__init == 2 and __reset == 1, tostring(__init) .. " " .. tostring(__reset))`), "OnInit again, then OnReset, once")
}

// OnGameLoaded runs before OnInit, on a new game and on every load; only it creates actor values.
// A mod AV's base is its default. A load binds the saved values of the names created again and
// drops the rest.
@(test)
test_mod_actor_values :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_modav", {{"stats.lua", STATS_LUA}})
	defer fixture_destroy(&f)

	QUEST :: script.Form_ID(0x800)
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	f.db.form_scripts[QUEST] = {scripts = []esm.Script_Attach{{name = "Stats"}}}
	f.db.quest_baseline = make(map[gamedb.Form_ID]gamedb.Quest_Baseline, context.temp_allocator)
	f.db.quest_baseline[QUEST] = {}

	slua.start_game(&f.vm, &f.db)
	testing.expect(t, slua.do_string(&f.vm, `assert(__order == "loaded;init;" and __outside == false, __order)`), "OnGameLoaded first; rt.actor_value only there")
	hunger, ok := worldstate.av_name(&f.ws, "HUNGER")
	testing.expect(t, ok && hunger == "Hunger", "a mod AV resolves in any case")
	_, thirst := worldstate.av_name(&f.ws, "Thirst")
	testing.expect(t, !thirst, "no AV outside OnGameLoaded")
	testing.expect_value(t, worldstate.av_base(&f.ws, &f.db, formid.PLAYER, hunger), -1)

	old, _ := worldstate.av_name(&f.ws, "Old")
	worldstate.av_mod(&f.ws, formid.PLAYER, hunger, 5)
	worldstate.av_mod(&f.ws, formid.PLAYER, old, 2)
	slua.save_scripts(&f.vm)
	path := "/tmp/skymod_mod_avs.skysave"
	defer os.remove(path)
	testing.expect(t, worldstate.save_to_file(&f.ws, path, {save_number = 1}), "save")
	_, loaded := worldstate.load_from_file(&f.ws, path)
	testing.expect(t, loaded, "load")

	slua.do_string(&f.vm, `__second = true`)
	slua.reload_scripts(&f.vm, &f.db)
	testing.expect(t, slua.do_string(&f.vm, `assert(__order == "loaded;init;loaded;", __order)`), "a load runs OnGameLoaded, not OnInit")
	hunger, _ = worldstate.av_name(&f.ws, "hunger")
	testing.expect_value(t, worldstate.av_current(&f.ws, &f.db, formid.PLAYER, hunger), 4)
	_, kept := worldstate.av_name(&f.ws, "Old")
	testing.expect(t, !kept && len(f.ws.pending_avs) == 0, "an AV nobody created again is gone")
}

// A mod's zone formula sets a zone's first level, and registered forms hear OnZoneLevelSet.
@(test)
test_zone_level_hooks :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_zones", {{"zones.lua", ZONES_LUA}})
	defer fixture_destroy(&f)

	QUEST :: script.Form_ID(0x900)
	ZONE :: script.Form_ID(0x901)
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	f.db.form_scripts[QUEST] = {scripts = []esm.Script_Attach{{name = "Zones"}}}
	f.db.quest_baseline = make(map[gamedb.Form_ID]gamedb.Quest_Baseline, context.temp_allocator)
	f.db.quest_baseline[QUEST] = {}
	f.db.zones = make(map[gamedb.Form_ID]gamedb.Zone, context.temp_allocator)
	f.db.zones[ZONE] = {min_level = 5}

	slua.start_game(&f.vm, &f.db)
	testing.expect_value(t, worldstate.zone_level(&f.ws, &f.db, ZONE), 8) // min 5, plus the formula's 3
	slua.tick_zone_levels(&f.vm, &f.ws)
	slua.drain(&f.vm)
	testing.expect(t, slua.do_string(&f.vm, `assert(__zone[0] === ref(0x901) and __zone[1] == 8)`), "OnZoneLevelSet heard")
}
