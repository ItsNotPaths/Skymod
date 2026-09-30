package unit_tests

// Script instances at runtime (src/script/lua/instances.odin + rt.attach): plugin property values
// reach a script's members, OnInit fires on every instance, a runaway handler is stopped by the
// instruction budget without stopping the next one, placed refs start at the right time, and sent
// events run only when the queue drains, load/attach transitions follow the attached cells, and
// OnUpdate registrations fire on time.
// Hermetic: a temp scripts dir, no game files.

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"
import "../../src/combat"
import "../../src/conditions"
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
MORTAL_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Mortal", nil)
local function log(s) __log = (__log or "") .. s .. ";" end
C.__fn["onlocationchange"] = function(self, old, new) log("loc"); __old, __new = old, new end
C.__fn["ondying"] = function(self, killer) log("dying"); __killer = killer end
C.__fn["ondeath"] = function(self, killer) log("death"); assert(killer === __killer) end
C.__fn["ontriggerenter"] = function(self, who) log("enter"); __who = who end
C.__fn["ontriggerleave"] = function(self, who) log("leave"); __who = who end
return C
`

@(private = "file")
WATCH_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Watch", nil)
__log = {}
for _, e in ipairs({ "OnCellAttach", "OnLoad", "OnCellLoad", "OnUnload", "OnCellDetach", "OnAttachedToCell", "OnDetachedFromCell" }) do
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
C.__fn["onmagiceffectapply"] = function(self, caster, effect) __fx[#__fx] = "apply" end
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
TOME_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Tome", nil)
local function log(s) __log = (__log or "") .. s .. ";" end
C.__fn["oninit"] = function(self) log("init") end
C.__fn["oncontainerchanged"] = function(self, new, old) log("moved") end
C.__fn["onequipped"] = function(self, actor) log("equipped") end
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
STAGES_LUA :: `local rt = require('skymod.rt')
local C = rt.class("QF_Test", nil)
local set_stage = rt.native("Quest", "SetCurrentStageID", false)
local running = rt.native("Quest", "IsRunning", false)
C.__fn["fragment_0"] = function(self) __stages = (__stages or "") .. "start;" end
C.__fn["fragment_1"] = function(self)
  __stages = (__stages or "") .. "10a;"
  set_stage(self, 20)
  __stages = __stages .. "10a after 20;"
end
C.__fn["fragment_2"] = function(self) __stages = (__stages or "") .. "10b;" end
C.__fn["fragment_3"] = function(self) __stages = (__stages or "") .. "20;" end
C.__fn["fragment_4"] = function(self) __stages = (__stages or "") .. "stop, running " .. tostring(running(self)) .. ";" end
return C
`

@(private = "file")
RESET_LUA :: `local rt = require('skymod.rt')
local C = rt.class("QReset", nil)
C.__vars = { ["::count_var"] = { type = "Int", default = nil } }
C.__fn["oninit"] = function(self)
  __inits = (__inits or 0) + 1
  __count_at_init = self.vars["::count_var"]
end
C.__fn["bump"] = function(self) self.vars["::count_var"] = self.vars["::count_var"] + 1 end
C.__fn["count"] = function(self) return self.vars["::count_var"] end
return C
`

@(private = "file")
TIF_LUA :: `local rt = require('skymod.rt')
local C = rt.class("TIF_Test", nil)
local owner = rt.native("TopicInfo", "GetOwningQuest", false)
local set_stage = rt.native("Quest", "SetCurrentStageID", false)
C.__fn["fragment_0"] = function(self, akSpeakerRef) __said = tostring(akSpeakerRef); set_stage(owner(self), 10) end
C.__fn["fragment_1"] = function(self, akSpeakerRef) __said = __said .. " done" end
return C
`

@(private = "file")
SCENE_LUA :: `local rt = require('skymod.rt')
local C = rt.class("SF_Test", nil)
local done = rt.native("Scene", "IsActionComplete", false)
local function log(s) __scene = (__scene or "") .. s .. ";" end
C.__fn["fragment_0"] = function(self) log("begin") end
C.__fn["fragment_1"] = function(self) log("end") end
C.__fn["fragment_2"] = function(self) log("phase 0") end
C.__fn["fragment_3"] = function(self) log("phase 2 done, line done " .. tostring(done(self, 1))) end
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
FORTIFY_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Fortify", nil)
C.__effect = { Health = { capacity = "m", amount = "5 * t" } }
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

// PlayerRef finds the scripts on the actor the player controls, equals their instance, and rt.key
// makes it and that actor one table key.
@(test)
test_playerref_lookups :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_playerref", {{"lever.lua", LEVER_LUA}})
	defer fixture_destroy(&f)

	testing.expect_value(t, slua.attach(&f.vm, f.ws.player, []esm.Script_Attach{{name = "Lever"}}, false), 1)
	testing.expect(t, slua.do_string(&f.vm, `rt = require('skymod.rt')
local inst = rt.cast(ref(0x14), "lever")
assert(type(inst) == "table" and inst == ref(0x14), "cast by PlayerRef")`), "cast by PlayerRef")
	src := fmt.tprintf("local n = {{}}; n[rt.key(ref(0x14))] = 1; local body = rt.key(ref(0x%X)); n[body] = n[body] + 1; assert(n[rt.key(ref(0x14))] == 2)", f.ws.player)
	testing.expect(t, slua.do_string(&f.vm, src), "one table key")
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
	slua.send(&f.vm, LEVER, "OnActivate", f.ws.player)
	slua.send(&f.vm, script.Form_ID(0x999), "OnActivate", f.ws.player)
	testing.expect(t, slua.do_string(&f.vm, `assert(__acts == nil)`), "nothing runs before the drain")

	testing.expect_value(t, slua.drain(&f.vm), 1)
	testing.expect(t, slua.do_string(&f.vm, `assert(__acts == 1 and __who == ref(0x14) and not __again)`), "OnActivate ran by the player")
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

// A scripted ref moved out of the attached cells unloads and detaches; moved back it attaches and
// loads; moved between attached cells it hears nothing. A cell that attaches lists the refs moved
// into it. An alias that takes a ref where it stands hears its later events, starting loaded.
@(test)
test_transitions_follow_moves_and_aliases :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_moves", {{"watch.lua", WATCH_LUA}})
	defer fixture_destroy(&f)
	trans: slua.Transitions
	defer slua.transitions_destroy(&trans)

	CELL :: gamedb.Form_ID(0x100)
	OTHER :: gamedb.Form_ID(0x101)
	SCRIPTED :: gamedb.Form_ID(0xB)
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	f.db.form_scripts[SCRIPTED] = {scripts = []esm.Script_Attach{{name = "Watch"}}}
	refs := []gamedb.Ref{{form_id = 0x201, cell_form_id = CELL, base = SCRIPTED}, {form_id = 0x204, cell_form_id = CELL, base = 0xC}}
	f.db.cell_refs = make(map[gamedb.Form_ID][dynamic]gamedb.Ref, context.temp_allocator)
	f.db.cell_refs[CELL] = make([dynamic]gamedb.Ref, context.temp_allocator)
	f.db.ref_by_id = make(map[gamedb.Form_ID]gamedb.Ref, context.temp_allocator)
	for r in refs {
		append(&f.db.cell_refs[CELL], r)
		f.db.ref_by_id[r.form_id] = r
	}
	slua.attach_cell(&f.vm, &f.db, CELL)
	alias, _ := formid.alias_handle(0x900, 0)
	slua.attach(&f.vm, alias, []esm.Script_Attach{{name = "Watch"}}, false)

	step :: proc(t: ^testing.T, f: ^Fixture, trans: ^slua.Transitions, now: []script.Form_ID, want: string, loc := #caller_location) {
		slua.tick_transitions(&f.vm, &f.db, &f.ws, trans, now)
		slua.drain(&f.vm)
		check := strings.concatenate({`local got = table.concat(__log, ","); __log = {}; assert(got == "`, want, `", got)`}, context.temp_allocator)
		testing.expect(t, slua.do_string(&f.vm, check), "events", loc = loc)
	}
	move :: proc(f: ^Fixture, cell: gamedb.Form_ID) {worldstate.relocate(&f.ws, 0x201, cell, {}, {})}

	step(t, &f, &trans, {CELL}, "a:OnCellAttach,a:OnLoad,a:OnCellLoad")
	move(&f, OTHER)
	step(t, &f, &trans, {CELL}, "a:OnUnload,a:OnDetachedFromCell")
	move(&f, CELL)
	step(t, &f, &trans, {CELL}, "a:OnAttachedToCell,a:OnLoad")
	move(&f, OTHER)
	step(t, &f, &trans, {CELL, OTHER}, "a:OnCellAttach,a:OnCellLoad")
	move(&f, CELL)
	step(t, &f, &trans, {CELL, OTHER}, "")

	worldstate.fill_alias(&f.ws, alias, 0x204)
	step(t, &f, &trans, {CELL}, "")
	step(t, &f, &trans, {}, "a:OnUnload,a:OnCellDetach,b:OnUnload,b:OnCellDetach")
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
	f.db.base_value = make(map[gamedb.Form_ID]i32, context.temp_allocator)
	f.db.base_value[0x20] = 50
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	f.db.form_scripts[0x20] = {scripts = bag} // the ring's scripts make it a unit
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
	testing.expect_value(t, f.ws.units[ring].holder, OTHER)
	native(&f, CHEST, "AddItem", ring)
	testing.expect(t, logged(&f, "rem1+dest;moved+new+old;"), "AddItem of a held unit takes it from its container (the chest filters for gold)")
	testing.expect_value(t, worldstate.inv_count(&f.ws, &f.db, OTHER, 0x20), 0)
	native(&f, OTHER, "AddItem", ring)
	testing.expect(t, logged(&f, "add1+src;moved+new+old;"), "and back")
	c := script.Call{ws = &f.ws, db = &f.db}
	script.move_items(&c, {base = 0x20, from = OTHER, to = f.ws.player, count = 1, via = .Dead_Body}) // the container menu's Take
	testing.expect(t, logged(&f, "rem1+dest;moved+new+old;"), "a unit taken by base hears OnContainerChanged")

	native(&f, CHEST, "RemoveAllInventoryEventFilters")
	native(&f, CHEST, "RemoveAllItems")
	testing.expect(t, logged(&f, "rem1;rem11;"), "RemoveAllItems: one event per item type")
}

// Scripts are data, so each scripted item is a unit with its own instance: it keeps its ID when it
// moves or drops. A scripted item held as a count (starting contents) gets identity when an event
// needs its ref.
@(test)
test_scripted_item_units :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_stacks", {{"tome.lua", TOME_LUA}})
	defer fixture_destroy(&f)

	CHEST, OTHER, TOME :: script.Form_ID(0x800), script.Form_ID(0x801), script.Form_ID(0x30)
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	f.db.form_scripts[TOME] = {scripts = []esm.Script_Attach{{name = "Tome"}}}
	native :: proc(f: ^Fixture, form: script.Form_ID, fn: string, args: ..script.Value) -> script.Value {
		c := script.Call{self = form, ws = &f.ws, db = &f.db}
		v := script.call(&f.reg, "ObjectReference", fn, &c, args)
		slua.sync_refs(&f.vm)
		return v
	}
	logged :: proc(f: ^Fixture, want: string) -> bool {
		slua.tick_items(&f.vm, &f.db, &f.ws)
		slua.drain(&f.vm)
		return slua.do_string(&f.vm, strings.concatenate({`assert((__log or "") == "`, want, `", __log); __log = nil`}, context.temp_allocator))
	}

	native(&f, CHEST, "AddItem", TOME, i32(3))
	testing.expect(t, logged(&f, "init;init;init;moved;moved;moved;"), "one instance each")
	testing.expect_value(t, len(worldstate.held_units(&f.ws, CHEST, TOME)), 3)
	first := worldstate.held_units(&f.ws, CHEST, TOME)[0]
	native(&f, CHEST, "RemoveItem", TOME, i32(1), false, OTHER)
	testing.expect(t, logged(&f, "moved;") && worldstate.held_units(&f.ws, OTHER, TOME)[0] == first, "it moves as itself")
	dropped := native(&f, OTHER, "DropObject", TOME, i32(1))
	testing.expect(t, dropped.(script.Form_ID) == first && f.ws.units[first].holder == 0, "it drops as itself")
	slua.drain(&f.vm)
	slua.do_string(&f.vm, `__log = nil`)

	worldstate.inv_add(&f.ws, OTHER, 0x31, 2) // starting contents: counts, no ref
	f.db.form_scripts[0x31] = f.db.form_scripts[TOME]
	append(&f.ws.equip_changes, worldstate.Equip_Change{OTHER, 0x31, true})
	slua.tick_equips(&f.vm, &f.ws)
	slua.drain(&f.vm)
	testing.expect(t, slua.do_string(&f.vm, `assert(__log == "init;equipped;", __log)`), "an item with no ref gets one, then hears its own OnEquipped")
	testing.expect_value(t, worldstate.plain_count(&f.ws, &f.db, OTHER, 0x31), 1)
}

// A stage runs the fragment of each item whose conditions pass, inside SetStage: a fragment that sets
// another stage waits for that stage's fragments. Start runs the start-up stage first; Stop runs the
// shut-down stage while the quest still runs.
@(test)
test_stage_fragments :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_stages", {{"qf_test.lua", STAGES_LUA}})
	defer fixture_destroy(&f)

	QUEST :: script.Form_ID(0x900)
	never := []gamedb.Condition{{function = 74, op = .Equal, value = 1, param1 = 0xDEAD}} // GetGlobalValue: an unset global reads 0
	f.db.quest_baseline = make(map[gamedb.Form_ID]gamedb.Quest_Baseline)
	defer delete(f.db.quest_baseline)
	stages := make(map[u16]gamedb.Quest_Stage)
	defer delete(stages)
	stages[0] = {flags = gamedb.STAGE_START_UP, items = []gamedb.Stage_Item{{}}}
	stages[10] = {items = []gamedb.Stage_Item{{}, {}, {conditions = never}}}
	stages[20] = {items = []gamedb.Stage_Item{{}}}
	stages[255] = {flags = gamedb.STAGE_SHUT_DOWN, items = []gamedb.Stage_Item{{}}}
	f.db.quest_baseline[QUEST] = {stages = stages}
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts)
	defer delete(f.db.form_scripts)
	f.db.form_scripts[QUEST] = {
		scripts   = []esm.Script_Attach{{name = "QF_Test"}},
		frag_file = "QF_Test",
		fragments = []esm.Script_Fragment {
			{index = 0, function = "Fragment_0"},
			{index = 10, item = 0, function = "Fragment_1"},
			{index = 10, item = 1, function = "Fragment_2"},
			{index = 10, item = 2, function = "Fragment_2"},
			{index = 20, function = "Fragment_3"},
			{index = 255, function = "Fragment_4"},
		},
	}
	slua.attach(&f.vm, QUEST, f.db.form_scripts[QUEST].scripts, false)
	quest :: proc(f: ^Fixture, fn: string, args: ..script.Value) {
		c := script.Call{self = QUEST, ws = &f.ws, db = &f.db}
		script.call(&f.reg, "Quest", fn, &c, args)
		slua.sync_refs(&f.vm) // as rt_native does after every native
	}
	stages_were :: proc(f: ^Fixture, want: string) -> bool {
		return slua.do_string(&f.vm, strings.concatenate({`assert((__stages or "") == "`, want, `", __stages); __stages = nil`}, context.temp_allocator))
	}

	quest(&f, "SetCurrentStageID", i32(10))
	testing.expect(t, stages_were(&f, "start;10a;20;10a after 20;10b;"), "start-up stage, then 10's items in order, 20 inside 10a")
	quest(&f, "SetCurrentStageID", i32(10))
	testing.expect(t, stages_were(&f, ""), "a done stage runs once")
	quest(&f, "Stop")
	testing.expect(t, stages_were(&f, "stop, running true;"), "the shut-down stage runs before the stop")
	testing.expect(t, !worldstate.quest_running(&f.ws, &f.db, QUEST), "then the quest stops")
}

// A quest that starts resets: its scripts start from their start values and run OnInit again, and
// its done stages can run again. A Run Once quest keeps its state.
@(test)
test_quest_resets_on_start :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_quest_reset", {{"qreset.lua", RESET_LUA}})
	defer fixture_destroy(&f)

	QUEST, ONCE :: script.Form_ID(0x900), script.Form_ID(0x901)
	f.db.quest_baseline = make(map[gamedb.Form_ID]gamedb.Quest_Baseline)
	defer delete(f.db.quest_baseline)
	f.db.quest_baseline[QUEST] = {}
	f.db.quest_baseline[ONCE] = {run_once = true}
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts)
	defer delete(f.db.form_scripts)
	for q in ([]script.Form_ID{QUEST, ONCE}) {f.db.form_scripts[q] = {scripts = []esm.Script_Attach{{name = "QReset"}}}}
	slua.start_game(&f.vm, &f.db)
	testing.expect(t, slua.do_string(&f.vm, `assert(__inits == 2); __inits = 0`), "OnInit at game start")

	quest :: proc(f: ^Fixture, q: script.Form_ID, fn: string) {
		c := script.Call{self = q, ws = &f.ws, db = &f.db}
		script.call(&f.reg, "Quest", fn, &c, nil)
		slua.sync_refs(&f.vm)
	}
	testing.expect(t, slua.do_string(&f.vm, `local rt = require('skymod.rt'); rt.call(ref(0x900), "Bump"); rt.call(ref(0x901), "Bump")`), "bump")
	worldstate.quest_set_stage(&f.ws, QUEST, 10)
	quest(&f, QUEST, "Start")
	quest(&f, ONCE, "Start")
	testing.expect(t, slua.do_string(&f.vm, `assert(__inits == 1 and __count_at_init == 0, tostring(__inits) .. " " .. tostring(__count_at_init))`), "only the quest that resets runs OnInit, from its start values")
	testing.expect(t, !worldstate.quest_is_stage_done(&f.ws, QUEST, 10), "its done stages cleared")
	testing.expect(t, worldstate.quest_running(&f.ws, &f.db, QUEST) && worldstate.quest_running(&f.ws, &f.db, ONCE), "both run")
	testing.expect(t, slua.do_string(&f.vm, `local rt = require('skymod.rt'); assert(rt.call(ref(0x900), "Count") == 0 and rt.call(ref(0x901), "Count") == 1)`), "run once keeps its fields")
}

// A topic info's begin fragment runs at the tick after its line starts, on its own script, with
// the speaker; it reaches its quest through GetOwningQuest. The end fragment follows the line.
@(test)
test_info_fragments :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_tif", {{"tif_test.lua", TIF_LUA}, {"qf_test.lua", STAGES_LUA}})
	defer fixture_destroy(&f)

	QUEST, TOPIC, INFO, SPEAKER :: script.Form_ID(0x900), script.Form_ID(0x910), script.Form_ID(0x911), script.Form_ID(0x920)
	f.db.topics = make(map[gamedb.Form_ID]gamedb.Topic)
	f.db.infos = make(map[gamedb.Form_ID]gamedb.Info)
	f.db.quest_baseline = make(map[gamedb.Form_ID]gamedb.Quest_Baseline)
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts)
	defer {delete(f.db.topics);delete(f.db.infos);delete(f.db.quest_baseline);delete(f.db.form_scripts)}
	f.db.topics[TOPIC] = {quest = QUEST}
	f.db.infos[INFO] = {topic = TOPIC}
	stages := make(map[u16]gamedb.Quest_Stage)
	defer delete(stages)
	stages[10] = {}
	f.db.quest_baseline[QUEST] = {start_game_enabled = true, stages = stages}
	f.db.form_scripts[INFO] = {
		scripts   = []esm.Script_Attach{{name = "TIF_Test"}},
		frag_file = "TIF_Test",
		fragments = []esm.Script_Fragment{{index = 0, function = "Fragment_0"}, {index = 1, function = "Fragment_1"}},
	}

	append(&f.ws.info_runs, worldstate.Info_Run{info = INFO, speaker = SPEAKER})
	append(&f.ws.info_runs, worldstate.Info_Run{info = INFO, speaker = SPEAKER, end = true})
	slua.tick_info_fragments(&f.vm)
	testing.expect(t, slua.do_string(&f.vm, `assert(__said == "[ObjectReference 0x00000920] done", __said)`), "begin, then end, with the speaker")
	testing.expect(t, worldstate.quest_is_stage_done(&f.ws, QUEST, 10), "GetOwningQuest reaches the topic's quest")
}

// A scene waits for nothing here, runs Begin, then phase 0 with its line (a line lasts its text
// length, at least two seconds), skips phase 1 whose start conditions fail, runs phase 2's timer,
// then its completion fragment, End, and stops its quest.
@(test)
test_scene_phases :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_scene", {{"sf_test.lua", SCENE_LUA}})
	defer fixture_destroy(&f)

	QUEST, SCENE, TOPIC, INFO, ACTOR :: script.Form_ID(0x900), script.Form_ID(0x930), script.Form_ID(0x910), script.Form_ID(0x911), script.Form_ID(0x920)
	never := []gamedb.Condition{{function = 74, op = .Equal, value = 1, param1 = 0xDEAD}}
	f.db.quest_baseline = make(map[gamedb.Form_ID]gamedb.Quest_Baseline)
	f.db.topics = make(map[gamedb.Form_ID]gamedb.Topic)
	f.db.infos = make(map[gamedb.Form_ID]gamedb.Info)
	f.db.scenes = make(map[gamedb.Form_ID]gamedb.Scene)
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts)
	defer {delete(f.db.quest_baseline);delete(f.db.topics);delete(f.db.infos);delete(f.db.scenes);delete(f.db.form_scripts)}
	f.db.quest_baseline[QUEST] = {start_game_enabled = true}
	infos := []gamedb.Form_ID{INFO}
	f.db.topics[TOPIC] = {quest = QUEST, infos = infos}
	f.db.infos[INFO] = {topic = TOPIC, responses = []gamedb.Response{{text = "Hi."}}}
	f.db.scenes[SCENE] = {
		quest   = QUEST,
		flags   = gamedb.SCENE_STOP_QUEST_ON_END,
		phases  = []gamedb.Scene_Phase{{}, {start = never}, {}},
		actors  = []gamedb.Scene_Actor{{alias = 0}},
		actions = []gamedb.Scene_Action{{kind = .Dialogue, index = 1, topic = TOPIC}, {kind = .Timer, index = 2, start = 2, end = 2, seconds = 0.5}},
	}
	f.db.form_scripts[SCENE] = {
		scripts   = []esm.Script_Attach{{name = "SF_Test"}},
		frag_file = "SF_Test",
		fragments = []esm.Script_Fragment {
			{index = 0, function = "Fragment_0"},
			{index = 1, function = "Fragment_1"},
			{index = 0, item = esm.PHASE_ON_START, function = "Fragment_2"},
			{index = 2, item = esm.PHASE_ON_COMPLETION, function = "Fragment_3"},
		},
	}
	alias, _ := formid.alias_handle(QUEST, 0)
	f.ws.aliases[alias] = ACTOR

	c := script.Call{self = SCENE, ws = &f.ws, db = &f.db}
	script.call(&f.reg, "Scene", "Start", &c, nil)
	scene_was :: proc(f: ^Fixture, want: string) -> bool {
		return slua.do_string(&f.vm, strings.concatenate({`assert((__scene or "") == "`, want, `", __scene); __scene = nil`}, context.temp_allocator))
	}
	slua.tick_scenes(&f.vm, 0.1)
	testing.expect(t, scene_was(&f, "begin;phase 0;"), "Begin, then phase 0's start fragment")
	testing.expect(t, worldstate.scene_playing(&f.ws, SCENE) && worldstate.scene_of_actor(&f.ws, &f.db, ACTOR) == SCENE, "playing, with its actor")
	testing.expect(t, len(f.ws.info_runs) == 1 && f.ws.info_runs[0].speaker == ACTOR, "the line's begin fragment is queued")
	for _ in 0 ..< 19 {slua.tick_scenes(&f.vm, 0.1)}
	testing.expect_value(t, f.ws.scenes[SCENE].phase, 0) // the line lasts two seconds
	slua.tick_scenes(&f.vm, 0.2)
	testing.expect_value(t, f.ws.scenes[SCENE].phase, 2) // phase 1 skipped
	for _ in 0 ..< 6 {slua.tick_scenes(&f.vm, 0.1)}
	testing.expect(t, scene_was(&f, "phase 2 done, line done true;end;"), "completion, then End")
	testing.expect(t, SCENE not_in f.ws.scenes, "the scene ended")
	testing.expect(t, len(f.ws.quest_steps) > 0 && f.ws.quest_steps[len(f.ws.quest_steps) - 1].stop, "Stop Quest on End")
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
	aliases := []gamedb.Quest_Alias{{id = 0, fill = .Specific, target = DOOR, alias = -1}, {id = 1, fill = .External, target = QUEST, alias = 0}}
	f.db.quest_baseline = make(map[gamedb.Form_ID]gamedb.Quest_Baseline)
	defer delete(f.db.quest_baseline)
	f.db.quest_baseline[QUEST] = {aliases = aliases}
	forced, _ := formid.alias_handle(QUEST, 0)
	external, _ := formid.alias_handle(QUEST, 1)
	slua.attach(&f.vm, forced, []esm.Script_Attach{{name = "Guard"}}, false)
	quest :: proc(f: ^Fixture, fn: string) {
		c := script.Call{self = QUEST, ws = &f.ws, db = &f.db}
		script.call(&f.reg, "Quest", fn, &c, nil)
		slua.sync_refs(&f.vm) // as rt_native does after every native
	}
	guard_saw :: proc(f: ^Fixture, want: string) -> bool {
		slua.drain(&f.vm)
		return slua.do_string(&f.vm, strings.concatenate({`assert((__guard or "") == "`, want, `", __guard); __guard = nil`}, context.temp_allocator))
	}

	quest(&f, "Start")
	testing.expect_value(t, f.ws.aliases[forced], DOOR)
	testing.expect_value(t, f.ws.aliases[external], DOOR)
	slua.send(&f.vm, DOOR, "OnActivate", f.ws.player)
	testing.expect(t, guard_saw(&f, "[ObjectReference 0x00000901];"), "the alias hears its ref's OnActivate")

	worldstate.register_update(&f.ws.updates, DOOR, 0, false)
	slua.tick_updates(&f.vm, &f.ws, 1.0 / 60, 0)
	testing.expect(t, guard_saw(&f, ""), "the ref's own OnUpdate is not the alias's")

	quest(&f, "Stop")
	testing.expect_value(t, len(f.ws.aliases), 0)
	slua.send(&f.vm, DOOR, "OnActivate", f.ws.player)
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

// A spell's scripted effect gets an instance on its target, which hears OnMagicEffectApply, then
// OnEffectStart, its duration, then OnEffectFinish. The instance stays while its state ticks, then leaves.
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
	testing.expect(t, slua.do_string(&f.vm, `local got = table.concat(__fx, ","); assert(got == "apply,start:true,finish,tick", got)`), "apply, start, finish, one tick, gone")

	terms := f.ws.effect_classes["glow"].terms
	testing.expect_value(t, len(terms), 1) // a bad formula and an unknown knob drop their terms
	testing.expect(t, terms[0].av == "Health" && terms[0].knob == .Capacity, "__effect read when the class loads")
	testing.expect_value(t, formula.eval(terms[0].f, {1, 10, 2, 0, 1, 0, 0, 0, 0}), 5)
}

// An effect whose MGEF's conditions fail does not start. One whose spell-side conditions fail starts
// inactive, and the recheck each second turns it on once they pass. They run on the target.
@(test)
test_effect_start_conditions :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_effect_ctda", {{"glow.lua", GLOW_LUA}})
	defer fixture_destroy(&f)

	SPELL, MGEF, GATED, PERK :: gamedb.Form_ID(0x900), gamedb.Form_ID(0x901), gamedb.Form_ID(0x903), gamedb.Form_ID(0x902)
	TARGET :: gamedb.Form_ID(0x700)
	has_perk := []gamedb.Condition{{function = 448, op = .Equal, value = 1, param1 = u64(PERK)}}
	f.db.spells = make(map[gamedb.Form_ID]gamedb.Spell, context.temp_allocator)
	f.db.spells[SPELL] = {info = {cast_type = .Fire_And_Forget}, effects = []gamedb.Magic_Effect_Ref{{effect = MGEF, duration = 5, conditions = has_perk}, {effect = GATED, duration = 5}}}
	f.db.magic_effects = make(map[gamedb.Form_ID]gamedb.Magic_Effect, context.temp_allocator)
	f.db.magic_effects[GATED] = {conditions = has_perk}
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	f.db.form_scripts[MGEF] = {scripts = []esm.Script_Attach{{name = "Glow"}}}
	f.db.form_kinds = make(map[gamedb.Form_ID]gamedb.Form_Kind, context.temp_allocator)
	f.db.form_kinds[SPELL] = .Spell

	testing.expect(t, slua.do_string(&f.vm, `rt = require('skymod.rt'); rt.call(ref(0x900), "Cast", ref(0x700))`), "Cast")
	testing.expect_value(t, len(f.ws.effects), 1)
	h := script.spell_effects(&f.ws, TARGET, SPELL)[0]
	testing.expect(t, f.ws.effects[h].inactive, "spell-side conditions fail: inactive")
	worldstate.perk_add(&f.ws, TARGET, PERK)
	slua.tick_effects(&f.vm, &f.ws, 1)
	testing.expect(t, !f.ws.effects[h].inactive, "the recheck turns it on")
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
// forgets it. sync_constant_effects catches an actor up when a mod update changes its records' list.
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
	script.sync_constant_effects(&c, ACTOR)
	testing.expect_value(t, len(script.spell_effects(&f.ws, ACTOR, RACIAL)), 1)
	f.db.actors[ACTOR] = {}
	script.sync_constant_effects(&c, ACTOR)
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

// An effect's capacity term holds while it runs and leaves with it; its amount term's gains stay.
@(test)
test_effect_ledger :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_ledger", {{"fortify.lua", FORTIFY_LUA}})
	defer fixture_destroy(&f)

	SPELL, MGEF, ACTOR :: gamedb.Form_ID(0x900), gamedb.Form_ID(0x901), gamedb.Form_ID(0x700)
	f.db.spells = make(map[gamedb.Form_ID]gamedb.Spell, context.temp_allocator)
	f.db.spells[SPELL] = {info = {cast_type = .Fire_And_Forget}, effects = []gamedb.Magic_Effect_Ref{{effect = MGEF, magnitude = 10, duration = 2}}}
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	f.db.form_scripts[MGEF] = {scripts = []esm.Script_Attach{{name = "Fortify"}}}
	f.db.form_kinds = make(map[gamedb.Form_ID]gamedb.Form_Kind, context.temp_allocator)
	f.db.form_kinds[SPELL] = .Spell
	worldstate.av_set_base(&f.ws, ACTOR, "Health", 100)
	worldstate.av_damage(&f.ws, &f.db, ACTOR, "Health", 50)

	testing.expect(t, slua.do_string(&f.vm, `require('skymod.rt').call(ref(0x900), "Cast", ref(0x700))`), "Cast")
	testing.expect_value(t, worldstate.av_max(&f.ws, &f.db, ACTOR, "Health"), 110)
	slua.tick_effects(&f.vm, &f.ws, 1)
	testing.expect_value(t, worldstate.av_current(&f.ws, &f.db, ACTOR, "Health"), 65)
	slua.tick_effects(&f.vm, &f.ws, 1.5) // runs past its end: t stops at 2
	testing.expect_value(t, worldstate.av_max(&f.ws, &f.db, ACTOR, "Health"), 100)
	testing.expect_value(t, worldstate.av_current(&f.ws, &f.db, ACTOR, "Health"), 60)
}

// The archetypes are the shipped pure-formula classes: a Recover fortify holds capacity while it
// runs, fire's taper adds its linger, a dual modifier moves the second AV by its weight, Absorb moves
// health to the caster, and an unrecovered timed modifier adds its magnitude each second. A class
// with its own __effect claims its MGEF; __claims_archetype = false runs both.
@(test)
test_effect_archetypes :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_archetypes", {
		{"archetypevaluemodifier.lua", #load("../../src/script/effects/archetypevaluemodifier.lua", string)},
		{"archetypepeakvaluemodifier.lua", #load("../../src/script/effects/archetypepeakvaluemodifier.lua", string)},
		{"archetypedualvaluemodifier.lua", #load("../../src/script/effects/archetypedualvaluemodifier.lua", string)},
		{"archetypeabsorb.lua", #load("../../src/script/effects/archetypeabsorb.lua", string)},
		{"fortify.lua", FORTIFY_LUA},
		{"both.lua", `local rt = require('skymod.rt')
local C = rt.class("Both", nil)
C.__effect = { Magicka = { capacity = "m" } }
C.__claims_archetype = false
return C
`},
	})
	defer fixture_destroy(&f)

	TARGET, CASTER :: gamedb.Form_ID(0x700), gamedb.Form_ID(0x701)
	FORTIFY, FIRE, SHOCK, ABSORB, RESTORE, CLAIMED, BOTH :: gamedb.Form_ID(0x901), gamedb.Form_ID(0x902), gamedb.Form_ID(0x903), gamedb.Form_ID(0x904), gamedb.Form_ID(0x905), gamedb.Form_ID(0x906), gamedb.Form_ID(0x907)
	HEALTH, MAGICKA :: i32(24), i32(25)
	harm :: esm.MGEF_DETRIMENTAL
	f.db.magic_effects = make(map[gamedb.Form_ID]gamedb.Magic_Effect, context.temp_allocator)
	f.db.magic_effects[FORTIFY] = {info = {archetype = .Peak_Value_Modifier, flags = esm.MGEF_RECOVER, primary_av = HEALTH}}
	f.db.magic_effects[FIRE] = {info = {archetype = .Value_Modifier, flags = harm, primary_av = HEALTH, taper_weight = 0.3, taper_curve = 2, taper_duration = 1}}
	f.db.magic_effects[SHOCK] = {info = {archetype = .Dual_Value_Modifier, flags = harm, primary_av = HEALTH, second_av = MAGICKA, second_av_weight = 0.5}}
	f.db.magic_effects[ABSORB] = {info = {archetype = .Absorb, flags = harm, primary_av = HEALTH}}
	f.db.magic_effects[RESTORE] = {info = {archetype = .Value_Modifier, primary_av = MAGICKA}}
	f.db.magic_effects[CLAIMED] = {info = {archetype = .Peak_Value_Modifier, flags = esm.MGEF_RECOVER, primary_av = MAGICKA}}
	f.db.magic_effects[BOTH] = {info = {archetype = .Peak_Value_Modifier, flags = esm.MGEF_RECOVER, primary_av = HEALTH}}
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	f.db.form_scripts[CLAIMED] = {scripts = []esm.Script_Attach{{name = "Fortify"}}}
	f.db.form_scripts[BOTH] = {scripts = []esm.Script_Attach{{name = "Both"}}}
	for a in ([]gamedb.Form_ID{TARGET, CASTER}) {
		worldstate.av_set_base(&f.ws, a, "Health", 100)
		worldstate.av_set_base(&f.ws, a, "Magicka", 100)
	}
	start :: proc(f: ^Fixture, e: worldstate.Active_Effect) -> gamedb.Form_ID {
		h := worldstate.start_effect(&f.ws, e)
		slua.sync_refs(&f.vm)
		return h
	}
	run :: proc(f: ^Fixture, h: gamedb.Form_ID, seconds: int) {
		for _ in 0 ..< seconds * 4 {worldstate.advance_effect(&f.ws, &f.db, h, 0.25)}
	}
	current :: proc(f: ^Fixture, a: gamedb.Form_ID, av: string) -> f32 {return worldstate.av_current(&f.ws, &f.db, a, av)}

	fort := start(&f, {effect = FORTIFY, target = TARGET, caster = TARGET, duration = 2, magnitude = 50})
	run(&f, fort, 1)
	testing.expect_value(t, worldstate.av_max(&f.ws, &f.db, TARGET, "Health"), 150)
	run(&f, fort, 2)
	testing.expect_value(t, worldstate.av_max(&f.ws, &f.db, TARGET, "Health"), 100)
	testing.expect(t, f.ws.effect_classes["archetypepeakvaluemodifier"].pure, "an archetype class is pure")

	fire := start(&f, {effect = FIRE, target = TARGET, caster = CASTER, taper = 1, magnitude = 30})
	run(&f, fire, 2)
	testing.expect(t, abs(current(&f, TARGET, "Health") - 67) < 0.01, "30 at once, then 30 * 0.3 * 1 / 3 over the linger")

	worldstate.av_restore(&f.ws, TARGET, "Health", 100)
	shock := start(&f, {effect = SHOCK, target = TARGET, caster = CASTER, magnitude = 20})
	run(&f, shock, 1)
	testing.expect(t, current(&f, TARGET, "Health") == 80 && current(&f, TARGET, "Magicka") == 90, "shock: health, then half on magicka")

	worldstate.av_damage(&f.ws, &f.db, CASTER, "Health", 40)
	absorb := start(&f, {effect = ABSORB, target = TARGET, caster = CASTER, magnitude = 15})
	run(&f, absorb, 1)
	testing.expect(t, current(&f, TARGET, "Health") == 65 && current(&f, CASTER, "Health") == 75, "absorb moves health to the caster")

	restore := start(&f, {effect = RESTORE, target = TARGET, caster = TARGET, duration = 2, magnitude = 3})
	run(&f, restore, 3)
	testing.expect_value(t, current(&f, TARGET, "Magicka"), 96)

	start(&f, {effect = CLAIMED, target = CASTER, caster = CASTER, lasts = true, magnitude = 10})
	testing.expect_value(t, worldstate.av_max(&f.ws, &f.db, CASTER, "Magicka"), 100) // Fortify's Health terms replace the archetype
	start(&f, {effect = BOTH, target = CASTER, caster = CASTER, lasts = true, magnitude = 10})
	testing.expect(t, worldstate.av_max(&f.ws, &f.db, CASTER, "Magicka") == 110 && worldstate.av_max(&f.ws, &f.db, CASTER, "Health") == 120, "both run")
}

// Worn gear's constant-effect enchantment runs while it is worn.
@(test)
test_worn_enchantment :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_worn", {{"fortify.lua", FORTIFY_LUA}})
	defer fixture_destroy(&f)

	ACTOR, ARMOR, ENCH, MGEF :: gamedb.Form_ID(0x700), gamedb.Form_ID(0x910), gamedb.Form_ID(0x920), gamedb.Form_ID(0x901)
	f.db.equip_slots = make(map[gamedb.Form_ID]gamedb.Equip_Slot, context.temp_allocator)
	f.db.equip_slots[ARMOR] = {kind = .Armor, biped = 0x04, enchantment = ENCH}
	f.db.enchantments = make(map[gamedb.Form_ID]gamedb.Enchantment, context.temp_allocator)
	f.db.enchantments[ENCH] = {info = {cast_type = .Constant_Effect}, effects = []gamedb.Magic_Effect_Ref{{effect = MGEF, magnitude = 20}}}
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	f.db.form_scripts[MGEF] = {scripts = []esm.Script_Attach{{name = "Fortify"}}}
	worldstate.av_set_base(&f.ws, ACTOR, "Health", 100)

	worldstate.equip(&f.ws, &f.db, ACTOR, ARMOR)
	slua.tick_equips(&f.vm, &f.ws)
	slua.sync_refs(&f.vm)
	testing.expect_value(t, worldstate.av_max(&f.ws, &f.db, ACTOR, "Health"), 120)
	worldstate.unequip(&f.ws, &f.db, ACTOR, ARMOR)
	slua.tick_equips(&f.vm, &f.ws)
	testing.expect_value(t, worldstate.av_max(&f.ws, &f.db, ACTOR, "Health"), 100)
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
	testing.expect_value(t, worldstate.av_base(&f.ws, &f.db, f.ws.player, hunger), -1)

	old, _ := worldstate.av_name(&f.ws, "Old")
	worldstate.av_mod(&f.ws, f.ws.player, hunger, 5)
	worldstate.av_mod(&f.ws, f.ws.player, old, 2)
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
	testing.expect_value(t, worldstate.av_current(&f.ws, &f.db, f.ws.player, hunger), 4)
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

// GetVMQuestVariable reads a quest script member through the VM's condition hook.
@(test)
test_condition_reads_quest_member :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_quest_var", {{"counter.lua", COUNTER_LUA}})
	defer fixture_destroy(&f)

	QUEST :: script.Form_ID(0xA00)
	counter := []esm.Script_Attach{{name = "Counter", props = {{name = "Count", kind = .Int, status = 1, value = i32(5)}}}}
	testing.expect_value(t, slua.attach_known(&f.vm, QUEST, counter), 1)

	ctx := script.condition_context(&f.vm.ctx, f.ws.player, 0)
	is :: proc(ctx: ^conditions.Context, name: string, v: f32) -> bool {
		c := [1]gamedb.Condition{{function = 629, op = .Equal, value = v, param1 = u64(QUEST), text = name}}
		return conditions.all(ctx, c[:])
	}
	testing.expect(t, is(&ctx, "::count_var", 5), "Count is 5")
	testing.expect(t, !is(&ctx, "::count_var", 6), "Count is not 6")
	testing.expect(t, is(&ctx, "::Count_var", 5), "the record's casing (Papyrus names fold case)")
	testing.expect(t, !is(&ctx, "::Count_var", 6), "the record's casing reads the member, not a pass")
	testing.expect(t, is(&ctx, "::untouched", 4), "a declared default")
	testing.expect(t, is(&ctx, "::missing_var", 6), "no such member passes")
}

// The player's location change sends OnLocationChange and queues a CLOC story event; the first tick
// after a load only records where the player is.
@(test)
test_change_location_event :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_location", {{"mortal.lua", MORTAL_LUA}})
	defer fixture_destroy(&f)
	trans: slua.Transitions
	defer slua.transitions_destroy(&trans)
	A, B :: script.Form_ID(0xA01), script.Form_ID(0xA02)
	slua.attach(&f.vm, f.ws.player, []esm.Script_Attach{{name = "Mortal"}}, false)

	slua.tick_location(&f.vm, &f.ws, &trans, A)
	slua.tick_location(&f.vm, &f.ws, &trans, A)
	testing.expect_value(t, len(f.ws.story_events), 0)
	slua.tick_location(&f.vm, &f.ws, &trans, B)
	if testing.expect_value(t, len(f.ws.story_events), 1) {
		e := f.ws.story_events[0]
		testing.expect(t, e.type == worldstate.STORY_CHANGE_LOCATION && e.ref1 == f.ws.player, "CLOC by the player")
		testing.expect(t, e.location1 == A && e.location2 == B, "old then new")
	}
	slua.drain(&f.vm)
	testing.expect(t, slua.do_string(&f.vm, `assert(__log == "loc;" and __old === ref(0xA01) and __new === ref(0xA02), __log); __log = nil`), "OnLocationChange(old, new)")
	trans.location = nil // a load
	slua.tick_location(&f.vm, &f.ws, &trans, A)
	testing.expect_value(t, len(f.ws.story_events), 1)
}

// Kill sends OnDying, then OnDeath, each with the killer, once: a dead actor does not die again.
@(test)
test_kill_events :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_kill", {{"mortal.lua", MORTAL_LUA}})
	defer fixture_destroy(&f)
	VICTIM :: script.Form_ID(0x600)
	slua.attach(&f.vm, VICTIM, []esm.Script_Attach{{name = "Mortal"}}, false)

	testing.expect(t, slua.do_string(&f.vm, `ref(0x600):Kill(ref(0x14)); ref(0x600):Kill(ref(0x14))`), "Kill twice")
	slua.tick_deaths(&f.vm, &f.ws)
	slua.drain(&f.vm)
	testing.expect(t, slua.do_string(&f.vm, `assert(__log == "dying;death;" and __killer == ref(0x14), __log)`), "OnDying then OnDeath, once")
	testing.expect(t, worldstate.is_dead(&f.ws, &f.db, VICTIM), "dead")
}

// A trigger box turned 90 degrees hears the player come in, then go out; a disabled one forgets;
// a loaded NPC walks in too.
@(test)
test_trigger_events :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_trigger", {{"mortal.lua", MORTAL_LUA}})
	defer fixture_destroy(&f)
	f.ws.ai.loaded[f.ws.player] = true // the app lists the player's capsule with the others
	CELL, TRIG :: script.Form_ID(0x100), script.Form_ID(0x700)
	f.db.ref_by_id = make(map[gamedb.Form_ID]gamedb.Ref, context.temp_allocator)
	f.db.ref_by_id[TRIG] = {form_id = TRIG, cell_form_id = CELL, pos = {1000, 0, 0}, rot = {0, 0, math.PI / 2}, scale = 1}
	f.db.triggers = make(map[gamedb.Form_ID]esm.Primitive, context.temp_allocator)
	f.db.triggers[TRIG] = {half = {300, 50, 100}, kind = .Box}
	f.ws.attached[CELL] = make([dynamic]script.Form_ID)
	append(&f.ws.attached[CELL], TRIG)
	slua.attach(&f.vm, TRIG, []esm.Script_Attach{{name = "Mortal"}}, false)

	at :: proc(f: ^Fixture, pos: [3]f32) {
		worldstate.set_moved(&f.ws, f.ws.player, 0x100, {}, pos)
		slua.tick_triggers(&f.vm, &f.db, &f.ws, 1.0 / 60)
		slua.drain(&f.vm)
	}
	at(&f, {1000, 400, 0})
	at(&f, {1000, 200, 0}) // inside only if the box is turned: its long side runs along y
	at(&f, {1000, 250, 0})
	testing.expect_value(t, len(f.ws.in_triggers), 1)
	at(&f, {1000, 400, 0})
	testing.expect(t, slua.do_string(&f.vm, `assert(__log == "enter;leave;", __log); assert(__who == ref(0x14)); __log = nil`), "enter once, then leave")
	at(&f, {1000, 200, 0})
	worldstate.set_disabled(&f.ws, TRIG, CELL, true)
	at(&f, {1000, 400, 0})
	testing.expect(t, slua.do_string(&f.vm, `assert(__log == "enter;", __log); __log = nil`), "a disabled trigger sends no leave")
	testing.expect_value(t, len(f.ws.in_triggers), 0)

	NPC :: script.Form_ID(0x800)
	worldstate.set_disabled(&f.ws, TRIG, CELL, false)
	f.ws.ai.loaded[NPC] = true
	worldstate.set_moved(&f.ws, NPC, CELL, {}, {1000, 200, 0})
	at(&f, {1000, 400, 0})
	testing.expect(t, slua.do_string(&f.vm, `assert(__log == "enter;", __log); assert(__who === ref(0x800))`), "a loaded NPC enters too")
}

// rt.zone makes a sphere that casts its spell on each actor inside, on entry and then every
// second, until its lifetime runs out. A once zone fires at the first actor in, on each within its
// burst, and goes. A caster's zone hits only actors hostile to it.
@(test)
test_runtime_zones :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_runtime_zones", {})
	defer fixture_destroy(&f)
	CELL, MARK, NPC :: script.Form_ID(0x100), script.Form_ID(0x700), script.Form_ID(0x800)
	SPELL, MGEF :: gamedb.Form_ID(0x900), gamedb.Form_ID(0x901)
	f.db.spells = make(map[gamedb.Form_ID]gamedb.Spell, context.temp_allocator)
	f.db.spells[SPELL] = {info = {cast_type = .Fire_And_Forget}, effects = []gamedb.Magic_Effect_Ref{{effect = MGEF, duration = 60}}}
	f.db.form_kinds = make(map[gamedb.Form_ID]gamedb.Form_Kind, context.temp_allocator)
	f.db.form_kinds[SPELL] = .Spell
	f.db.ref_by_id = make(map[gamedb.Form_ID]gamedb.Ref, context.temp_allocator)
	f.db.ref_by_id[MARK] = {form_id = MARK, cell_form_id = CELL, scale = 1}
	f.ws.attached[CELL] = make([dynamic]script.Form_ID)
	f.ws.ai.loaded[f.ws.player] = true
	f.ws.ai.loaded[NPC] = true
	worldstate.set_moved(&f.ws, f.ws.player, CELL, {}, {50, 0, 0})
	worldstate.set_moved(&f.ws, NPC, CELL, {}, {300, 0, 0})
	started_on :: proc(f: ^Fixture) -> []script.Form_ID { // who the effects started since the last look are on
		out := make([dynamic]script.Form_ID, context.temp_allocator)
		for h in f.ws.new_effects {append(&out, f.ws.effects[h].target)}
		clear(&f.ws.new_effects)
		return out[:]
	}

	testing.expect(t, slua.do_string(&f.vm, `rt = require('skymod.rt')
rt.zone { at = ref(0x700), shape = { sphere = 100 }, lifetime = 2.5, spell = ref(0x900), every = 1 }`), "rt.zone")
	testing.expect_value(t, len(f.ws.zones), 1)
	for _ in 0 ..< 4 {slua.tick_triggers(&f.vm, &f.db, &f.ws, 0.5)}
	testing.expect(t, slice.equal(started_on(&f), []script.Form_ID{f.ws.player, f.ws.player}), "on entry and a second later; the NPC is outside")
	slua.tick_triggers(&f.vm, &f.db, &f.ws, 1)
	testing.expect_value(t, len(f.ws.zones), 0)

	testing.expect(t, slua.do_string(&f.vm, `rt.zone { at = ref(0x700), shape = { box = { 200, 200, 200 } }, spell = ref(0x900), burst = 400, caster = ref(0x801) }`), "a caster's rune")
	slua.tick_triggers(&f.vm, &f.db, &f.ws, 0.5)
	testing.expect_value(t, len(started_on(&f)), 0) // nobody inside is hostile to the caster
	testing.expect_value(t, len(f.ws.zones), 1)
	testing.expect(t, slua.do_string(&f.vm, `rt.zone { at = ref(0x700), shape = { box = { 200, 200, 200 } }, spell = ref(0x900), burst = 400 }`), "a rune")
	slua.tick_triggers(&f.vm, &f.db, &f.ws, 0.5)
	testing.expect_value(t, len(f.ws.zones), 1)
	burst := started_on(&f)
	testing.expect(t, len(burst) == 2 && slice.contains(burst, f.ws.player) && slice.contains(burst, NPC), "the NPC is outside the box, inside the burst")
}

// Hazards are zones from their HAZD: PlaceAtMe by a trap makes one that hits everyone, up to its
// limit; a placed PHZD casts in an attached cell; a Spawn Hazard effect makes its hazard at its
// target with the effect's duration when the hazard inherits it.
@(test)
test_hazards :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_hazards", {})
	defer fixture_destroy(&f)
	CELL, TRAP, PLACED :: script.Form_ID(0x100), script.Form_ID(0x700), script.Form_ID(0x701)
	SPELL, HAZ, INHERITS, MGEF :: gamedb.Form_ID(0x900), gamedb.Form_ID(0x910), gamedb.Form_ID(0x911), gamedb.Form_ID(0x920)
	f.db.spells = make(map[gamedb.Form_ID]gamedb.Spell, context.temp_allocator)
	f.db.spells[SPELL] = {info = {cast_type = .Fire_And_Forget}, effects = []gamedb.Magic_Effect_Ref{{effect = 0x901, duration = 60}}}
	f.db.form_kinds = make(map[gamedb.Form_ID]gamedb.Form_Kind, context.temp_allocator)
	f.db.form_kinds[SPELL] = .Spell
	f.db.hazards = make(map[gamedb.Form_ID]esm.Hazard, context.temp_allocator)
	f.db.hazards[HAZ] = {limit = 2, radius = 3, lifetime = 30, interval = 0.5, spell = SPELL}
	f.db.hazards[INHERITS] = {radius = 20, lifetime = 40, interval = 0.5, flags = esm.HAZD_INHERIT_DURATION, spell = SPELL}
	f.db.magic_effects = make(map[gamedb.Form_ID]gamedb.Magic_Effect, context.temp_allocator)
	f.db.magic_effects[MGEF] = {related = INHERITS}
	f.db.ref_by_id = make(map[gamedb.Form_ID]gamedb.Ref, context.temp_allocator)
	f.db.ref_by_id[TRAP] = {form_id = TRAP, cell_form_id = CELL, scale = 1}
	f.db.ref_by_id[PLACED] = {form_id = PLACED, base = HAZ, cell_form_id = CELL, pos = {0, 0, 0}, scale = 1}

	c := f.vm.ctx
	c.self = TRAP
	for _ in 0 ..< 3 {script.place_at_me(&c, HAZ)}
	testing.expect_value(t, len(f.ws.zones), 2)
	for _, z in f.ws.zones {testing.expect(t, z.caster == 0 && z.left == 30 && abs(z.shape.half.x - 64) < 0.01, "a trap's hazard, 3 feet")}

	f.ws.zones = {} // a fresh start for the placed hazard
	f.db.placed_hazards = make([dynamic]gamedb.Form_ID, context.temp_allocator)
	append(&f.db.placed_hazards, PLACED)
	f.ws.attached[CELL] = make([dynamic]script.Form_ID)
	f.ws.ai.loaded[f.ws.player] = true
	worldstate.set_moved(&f.ws, f.ws.player, CELL, {}, {10, 0, 0})
	slua.tick_triggers(&f.vm, &f.db, &f.ws, 0.1)
	testing.expect(t, len(f.ws.new_effects) == 1 && f.ws.effects[f.ws.new_effects[0]].target == f.ws.player, "a placed hazard burns")

	h := worldstate.start_effect(&f.ws, {effect = MGEF, spell = SPELL, target = f.ws.player, caster = 0x800, duration = 12})
	zone := worldstate.effect_hazard(&f.ws, &f.db, h)
	testing.expect(t, zone != 0 && f.ws.zones[zone].left == 12 && f.ws.zones[zone].caster == 0x800, "the effect's duration and caster")
}

// A script makes factions at runtime: rt.faction gets or creates by name, the faction reads like a
// record's through worldstate.faction, its relations are relation deltas (mutual by default), and a
// save keeps it whole.
@(test)
test_script_factions :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_factions", {})
	defer fixture_destroy(&f)
	testing.expect(t, slua.do_string(&f.vm, `local rt = require('skymod.rt')
		local red = rt.faction("Red Hand", {flags = {"track_crime"}, crime = {assault = 40, murder = 1000, arrest = true}, ranks = {"Thug", "Boss"}})
		local blue = rt.faction("Blue", {relations = {{faction = red, reaction = "enemy", modifier = -20}}})
		assert(rt.faction("red hand") == red, "get by name")
		assert(red ~= blue)`), "rt.faction")
	find :: proc(ws: ^worldstate.World_State, name: string) -> gamedb.Form_ID {
		for id, s in ws.script_factions {if s.name == name {return id}}
		return 0
	}
	red, blue := find(&f.ws, "Red Hand"), find(&f.ws, "Blue")
	testing.expect_value(t, len(f.ws.script_factions), 2)
	testing.expect_value(t, gamedb.form_kind(&f.db, red), gamedb.Form_Kind.Faction)

	check :: proc(t: ^testing.T, ws: ^worldstate.World_State, db: ^gamedb.DB, red, blue: gamedb.Form_ID) {
		rf, ok := worldstate.faction(ws, db, red)
		testing.expect(t, ok && rf.flags == esm.FACT_TRACK_CRIME && rf.crime.assault == 40 && rf.crime.murder == 1000 && rf.crime.arrest, "crime data")
		testing.expect(t, len(rf.ranks) == 2 && rf.ranks[1].male_title == "Boss", "ranks")
		r, _ := worldstate.relation(ws, db, blue, red)
		testing.expect(t, r.combat == .Enemy && r.modifier == -20, "blue hates red")
		back, _ := worldstate.relation(ws, db, red, blue)
		testing.expect_value(t, back.combat, esm.Combat_Reaction.Enemy)
	}
	check(t, &f.ws, &f.db, red, blue)

	path := "/tmp/skymod_script_factions.skysave"
	defer os.remove(path)
	testing.expect(t, worldstate.save_to_file(&f.ws, path, {save_number = 1}), "save")
	_, loaded := worldstate.load_from_file(&f.ws, path)
	testing.expect(t, loaded, "load")
	check(t, &f.ws, &f.db, red, blue)
}

MOMENT_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Moment", nil)
C.__vars = { ["::label_var"] = { type = "String", default = nil } }
C.__autoprop["label"] = "::label_var"
C.__fn["oneffectstart"] = function(self)
  local t = self:GetTargetActor()
  __moment = self.vars["::label_var"]
  __read = { hp = t.av.Health.capacity, perk = t:HasPerk("MomentPerk") }
end
function C:OnTick() self:SetActive(__on ~= false) end
return C
`

BURN_LUA :: `local rt = require('skymod.rt')
return rt.effect {
  tags = { "magic.fire" },
  av = { Health = { amount = "-taken * min(t, d) / d" } },
  land = function(e)
    if e.target.av.Health.value <= 0 then return false end
    e.d = e.m
    e.taken = e.target.av.Health.value * 0.5
  end,
  script = { "Moment", label = "hi" },
}
`

// An rt.effect file defines an effect by name: a Lua form, its land (d from m, a tunable taken as it
// lands), its AV formula and its moment script with properties. A patched land keeps
// another from starting. The moment script switches it off (SetActive).
@(test)
test_rt_effect :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_rt_effect", {{"moment.lua", MOMENT_LUA}})
	defer fixture_destroy(&f)
	effects, _ := filepath.join({f.dir, "effects"}, context.temp_allocator)
	os.make_directory_all(effects)
	for file in ([][2]string{{"burn.lua", BURN_LUA}, {"gated.lua", BURN_LUA}, {"gated.patch.lua", `return function(def) def.land = function(e) return e.target.av.Health.value > 1000 end end`}}) {
		p, _ := filepath.join({effects, file[0]}, context.temp_allocator)
		testing.expect(t, os.write_entire_file(p, transmute([]u8)file[1]) == nil, "write effect")
	}
	slua.set_script_dirs(&f.vm, {f.dir})
	testing.expect(t, slua.do_string(&f.vm, `require('skymod.rt').load_effects()`), "load_effects")

	SPELL, TARGET, CASTER :: gamedb.Form_ID(0x900), gamedb.Form_ID(0x700), gamedb.Form_ID(0x701)
	BURN, GATED := formid.lua_form("effect", "Burn"), formid.lua_form("effect", "gated")
	testing.expect(t, worldstate.has_tag(&f.ws, &f.db, BURN, "magic"), "tags")
	f.db.spells = make(map[gamedb.Form_ID]gamedb.Spell, context.temp_allocator)
	f.db.spells[SPELL] = {info = {cast_type = .Fire_And_Forget}, effects = []gamedb.Magic_Effect_Ref{{effect = BURN, magnitude = 4, duration = 99}, {effect = GATED, magnitude = 4, duration = 99}}}
	f.db.form_kinds = make(map[gamedb.Form_ID]gamedb.Form_Kind, context.temp_allocator)
	f.db.form_kinds[SPELL] = .Spell
	worldstate.av_set_base(&f.ws, TARGET, "Health", 100)
	PERK :: gamedb.Form_ID(0x950)
	f.db.form_by_edid = make(map[string]gamedb.Form_ID, context.temp_allocator)
	f.db.form_by_edid["momentperk"] = PERK
	worldstate.perk_add(&f.ws, TARGET, PERK)

	testing.expect(t, slua.do_string(&f.vm, `rt = require('skymod.rt'); rt.call(ref(0x900), "Cast", ref(0x701), ref(0x700))`), "Cast")
	testing.expect_value(t, len(f.ws.effects), 1)
	h := script.spell_effects(&f.ws, TARGET, SPELL)[0]
	e := f.ws.effects[h]
	testing.expect(t, e.effect == BURN && e.duration == 4 && e.tunables[0] == 50, "d = m, taken once as it lands")
	for i in 0 ..< 4 {
		if i == 2 {testing.expect(t, slua.do_string(&f.vm, `__on = false`), "switch")}
		slua.tick_effects(&f.vm, &f.ws, 1)
		slua.tick_end(&f.vm, 1)
	}
	testing.expect(t, slua.do_string(&f.vm, `assert(__moment == "hi", tostring(__moment))`), "the moment script got its property")
	testing.expect(t, slua.do_string(&f.vm, `assert(__read.hp == 100 and __read.perk == true, tostring(__read.hp))`), ".av read, and a perk named by editor id")
	testing.expect_value(t, worldstate.av_current(&f.ws, &f.db, TARGET, "Health"), 62.5) // off from the tick after the switch: 3 s of 4
	testing.expect(t, f.ws.effects[h].inactive, "its script switched it off")
}

// A translated effect keeps its record's form, runs on for its taper, and hands its list of scripts
// to the engine with their properties, a form one through rt.ref.
@(test)
test_rt_effect_translated :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_rt_effect_translated", {})
	defer fixture_destroy(&f)
	effects, _ := filepath.join({f.dir, "effects"}, context.temp_allocator)
	os.make_directory_all(effects)
	p, _ := filepath.join({effects, "MGTimeFreezeEffect.lua"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(p, transmute([]u8)string(`local rt = require('skymod.rt')
return rt.effect {
  form = "Skyrim.esm:012F03",
  taper = "1.5s",
  av = { Health = { amount = "-m" } },
  script = {
    "magicimodbeginloopend",
    { "shaderparticlegeometryscript", FadeInTime = 0.1, PSGD = rt.ref("Skyrim.esm:0486F3") },
  },
}
`)) == nil, "write effect")
	f.db.plugin_slots = make(map[string]u32, context.temp_allocator)
	f.db.plugin_slots["skyrim.esm"] = 0
	f.db.form_kinds = make(map[gamedb.Form_ID]gamedb.Form_Kind, context.temp_allocator)
	slua.set_script_dirs(&f.vm, {f.dir})
	testing.expect(t, slua.do_string(&f.vm, `require('skymod.rt').load_effects()`), "load_effects")
	d, ok := f.ws.effect_defs[0x012F03]
	testing.expect(t, ok, "defined at its record's form")
	testing.expect_value(t, d.taper, 1.5)
	testing.expect_value(t, len(d.scripts), 2)
	if len(d.scripts) < 2 {return}
	testing.expect_value(t, d.scripts[0].name, "magicimodbeginloopend")
	testing.expect_value(t, len(d.scripts[1].props), 2)
	for prop in d.scripts[1].props {
		if prop.name == "PSGD" {testing.expect(t, prop.value.(esm.Prop_Object).form == 0x0486F3, "rt.ref gives the form")}
	}
}

// A ref reaches a condition function by name when no native implements it, a declared stub
// included: Is/Has ones answer booleans, the rest numbers, and a number parameter takes an AV name.
@(test)
test_ref_condition_functions :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_ref_conditions", {})
	defer fixture_destroy(&f)
	worldstate.av_set_base(&f.ws, 0x700, "Health", 100)
	testing.expect(t, slua.do_string(&f.vm, `
require('skymod.rt')
local a = ref(0x700)
assert(a:IsUndead() == false, "IsUndead is a boolean")
assert(a:IsHostileToActor(ref(0x701)) == false, "a condition beats the declared stub")
assert(a:GetActorValuePercent("Health") == 1, tostring(a:GetActorValuePercent("Health")))
local ok, err = pcall(function() return a:GetActorValuePercent("NoSuchAV") end)
assert(not ok and err:find("GetActorValuePercent: expected a number or an actor value name", 1, true), tostring(err))
`), "condition calls")
}

// A translated ability is one effect at the ability's form: AddSpell starts it at m = 1, lasting,
// and RemoveSpell ends it, both by the spell's identity.
@(test)
test_ability_effect :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_ability_effect", {})
	defer fixture_destroy(&f)
	effects, _ := filepath.join({f.dir, "effects"}, context.temp_allocator)
	os.make_directory_all(effects)
	p, _ := filepath.join({effects, "AbWerewolf.lua"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(p, transmute([]u8)string(`local rt = require('skymod.rt')
return rt.effect { form = "Skyrim.esm:000900", av = { Health = { capacity = "50 * m" } } }
`)) == nil, "write effect")
	ABILITY, ACTOR :: gamedb.Form_ID(0x900), gamedb.Form_ID(0x700)
	f.db.plugin_slots = make(map[string]u32, context.temp_allocator)
	f.db.plugin_slots["skyrim.esm"] = 0
	f.db.spells = make(map[gamedb.Form_ID]gamedb.Spell, context.temp_allocator)
	f.db.spells[ABILITY] = {info = {type = .Ability}}
	f.db.form_kinds = make(map[gamedb.Form_ID]gamedb.Form_Kind, context.temp_allocator)
	f.db.form_kinds[ABILITY] = .Spell
	worldstate.av_set_base(&f.ws, ACTOR, "Health", 100)
	slua.set_script_dirs(&f.vm, {f.dir})
	testing.expect(t, slua.do_string(&f.vm, `require('skymod.rt').load_effects()`), "load_effects")
	testing.expect(t, f.db.form_kinds[ABILITY] == .Spell, "the ability stays a Spell")

	testing.expect(t, slua.do_string(&f.vm, `rt = require('skymod.rt'); assert(rt.call(ref(0x700), "AddSpell", ref(0x900)))`), "AddSpell")
	running := script.spell_effects(&f.ws, ACTOR, ABILITY)
	testing.expect_value(t, len(running), 1)
	if len(running) == 1 {
		e := f.ws.effects[running[0]]
		testing.expect(t, e.effect == ABILITY && e.lasts && e.magnitude == 1, "one lasting effect at m = 1")
	}
	testing.expect_value(t, worldstate.av_max(&f.ws, &f.db, ACTOR, "Health"), 150)
	testing.expect(t, slua.do_string(&f.vm, `assert(rt.call(ref(0x700), "RemoveSpell", ref(0x900)))`), "RemoveSpell")
	testing.expect_value(t, len(script.spell_effects(&f.ws, ACTOR, ABILITY)), 0)
}

// An rt.spell file names every effect it applies; Spell.Cast reaches it by its Lua form. Each effect
// gates itself in its land (here by the hour, through e.global), and a duration may be in ticks.
@(test)
test_rt_spell :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_rt_spell", {})
	defer fixture_destroy(&f)
	NIGHT :: `land = function(e) return e.global.GameHour >= 20 end`
	files := [][2]string {
		{"effects/scorch.lua", `return require('skymod.rt').effect { av = { Health = { amount = "-m" } }, tags = { "school.destruction" }, ` + NIGHT + ` }`},
		{"effects/dread.lua", `return require('skymod.rt').effect { av = { Confidence = { capacity = "-m" } }, ` + NIGHT + ` }`},
		{"spells/nightfire.lua", `return require('skymod.rt').spell { name = "Nightfire", use = "charged", shape = "missile", cost = 10, applies = { { "Scorch", m = 5 }, { "Dread", m = 2, d = "20tk" }, { "Nothing", m = 1 } } }`},
	}
	for file in files {
		p, _ := filepath.join({f.dir, file[0]}, context.temp_allocator)
		os.make_directory_all(filepath.dir(p))
		testing.expect(t, os.write_entire_file(p, transmute([]u8)file[1]) == nil, "write content")
	}
	f.db.form_kinds = make(map[gamedb.Form_ID]gamedb.Form_Kind, context.temp_allocator)
	f.db.global_by_edid = make(map[string]gamedb.Form_ID, context.temp_allocator)
	f.db.global_by_edid["gamehour"] = formid.GAME_HOUR
	f.ws.globals[formid.GAME_HOUR] = 22
	slua.set_script_dirs(&f.vm, {f.dir})
	testing.expect(t, slua.do_string(&f.vm, `require('skymod.rt').load_effects()`), "load") // warns: no effect "Nothing"

	TARGET, CASTER :: gamedb.Form_ID(0x700), gamedb.Form_ID(0x701)
	SPELL := formid.lua_form("spell", "Nightfire")
	testing.expect_value(t, len(f.ws.spell_defs[SPELL].entries), 2)
	testing.expect_value(t, f.db.form_kinds[SPELL], gamedb.Form_Kind.Spell)
	worldstate.av_set_base(&f.ws, TARGET, "Health", 100)
	cast_it := fmt.tprintf("rt.call(ref(0x%X), \"Cast\", ref(0x701), ref(0x700))", SPELL)
	testing.expect(t, slua.do_string(&f.vm, strings.concatenate({"rt = require('skymod.rt'); ", cast_it}, context.temp_allocator)), "Cast at night")
	testing.expect_value(t, len(f.ws.effects), 2)
	for h in worldstate.effects_on(&f.ws, TARGET) {
		if e := f.ws.effects[h]; e.effect == formid.lua_form("effect", "Dread") {testing.expect(t, abs(e.duration - 20.0 / 60) < 1e-6, "20 ticks")}
	}
	slua.tick_effects(&f.vm, &f.ws, 1)
	testing.expect_value(t, worldstate.av_current(&f.ws, &f.db, TARGET, "Health"), 95)

	f.ws.globals[formid.GAME_HOUR] = 12
	before := len(f.ws.effects)
	testing.expect(t, slua.do_string(&f.vm, cast_it), "Cast by day")
	testing.expect_value(t, len(f.ws.effects), before) // both effects gate themselves out
	s, ok := script.spell_school(&f.ws, &f.db, SPELL)
	testing.expect(t, ok && s == "Destruction", "a defined spell trains its first effect's school")
	testing.expect(t, slua.do_string(&f.vm, `rt.call(ref(0x701), "AddSpell", "Nightfire"); assert(rt.call(ref(0x701), "HasSpell", "nightfire") == true)`), "a spell named by its name, like an editor id")
}

// An rt.power's words are its variants; each sets its cooldown on a timer AV: a shout's on the
// shared Voice in real seconds times ShoutRecoveryMult, a power's own in game hours, a lesser
// power none. Cooling down, it cannot be used.
@(test)
test_rt_power :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_rt_power", {})
	defer fixture_destroy(&f)
	files := [][2]string {
		{"effects/push.lua", `return require('skymod.rt').effect { av = { Stamina = { amount = "-m" } } }`},
		{"powers/force.lua", `return require('skymod.rt').power { shape = "cone", cooldown_av = "Voice", cooldown_mult = "ShoutRecoveryMult",
			words = { { applies = { { "Push", m = 1 } }, cooldown = "5s" }, { applies = { { "Push", m = 2 } }, cooldown = "10s" } } }`},
		{"powers/blessing.lua", `return require('skymod.rt').power { shape = "self", applies = { { "Push", m = 3 } }, cooldown = "24h" }`},
		{"powers/whisper.lua", `return require('skymod.rt').power { shape = "self", applies = { { "Push", m = 4 } } }`},
	}
	for file in files {
		p, _ := filepath.join({f.dir, file[0]}, context.temp_allocator)
		os.make_directory_all(filepath.dir(p))
		testing.expect(t, os.write_entire_file(p, transmute([]u8)file[1]) == nil, "write content")
	}
	slua.set_script_dirs(&f.vm, {f.dir})
	testing.expect(t, slua.do_string(&f.vm, `require('skymod.rt').load_effects()`), "load")

	TARGET, CASTER :: gamedb.Form_ID(0x700), gamedb.Form_ID(0x701)
	FORCE, BLESSING, WHISPER := formid.lua_form("power", "force"), formid.lua_form("power", "blessing"), formid.lua_form("power", "whisper")
	c := &f.vm.ctx
	worldstate.av_set_base(&f.ws, CASTER, "ShoutRecoveryMult", 0.5)

	testing.expect(t, script.use_power(c, CASTER, FORCE, 5, TARGET), "a shout, more words than it has: its last")
	testing.expect(t, len(f.ws.casts) == 1 && f.ws.casts[0] == {CASTER, FORCE}, "OnSpellCast names the power")
	testing.expect_value(t, worldstate.av_current(&f.ws, &f.db, CASTER, "Voice"), 5) // 10 s x 0.5
	testing.expect(t, !script.use_power(c, CASTER, FORCE, 1, TARGET), "cooling down")
	f.ws.clock.played += 5
	testing.expect(t, script.use_power(c, CASTER, FORCE, 1, TARGET), "cooled down")

	testing.expect(t, script.use_power(c, CASTER, BLESSING, 1, 0), "a power")
	f.ws.clock.played += 1000
	testing.expect(t, !script.use_power(c, CASTER, BLESSING, 1, 0), "real time does not reach a game-hours cooldown")
	f.ws.clock.hours += 24
	testing.expect(t, script.use_power(c, CASTER, BLESSING, 1, 0), "a day later")
	testing.expect(t, script.use_power(c, CASTER, WHISPER, 1, 0) && script.use_power(c, CASTER, WHISPER, 1, 0), "a lesser power has no cooldown")
	testing.expect_value(t, len(f.ws.effects), 6)
}

// rt.item: a mug used from the inventory is used up and its effect's land gives random gold; a
// scroll held in a hand casts its spell with no Magicka, one per cast, and leaves the hand when the
// last is gone.
@(test)
test_rt_item :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_rt_item", {})
	defer fixture_destroy(&f)
	files := [][2]string {
		{"effects/luckygold.lua", `local rt = require('skymod.rt')
return rt.effect { land = function(e) e.target:AddItem("Gold001", rt.static("Utility", "RandomInt", 10, 50)) end }`},
		{"effects/burn.lua", `return require('skymod.rt').effect { av = { Health = { amount = "-m" } } }`},
		{"spells/firebolt.lua", `return require('skymod.rt').spell { use = "charged", shape = "missile", cost = 50, applies = { { "Burn", m = 10 } } }`},
		{"items/luckymug.lua", `return require('skymod.rt').item { form = "LuckyMug", use = "inventory", applies = { { "LuckyGold" } } }`},
		{"items/firescroll.lua", `return require('skymod.rt').item { form = "FireScroll", use = "hand", casts = "Firebolt" }`},
	}
	for file in files {
		p, _ := filepath.join({f.dir, file[0]}, context.temp_allocator)
		os.make_directory_all(filepath.dir(p))
		testing.expect(t, os.write_entire_file(p, transmute([]u8)file[1]) == nil, "write content")
	}
	MUG, SCROLL :: gamedb.Form_ID(0x5000), gamedb.Form_ID(0x5001)
	ACTOR, TARGET :: gamedb.Form_ID(0x700), gamedb.Form_ID(0x701)
	f.db.form_by_edid = make(map[string]gamedb.Form_ID, context.temp_allocator)
	f.db.form_by_edid["luckymug"] = MUG
	f.db.form_by_edid["firescroll"] = SCROLL
	f.db.form_by_edid["gold001"] = formid.GOLD
	slua.set_script_dirs(&f.vm, {f.dir})
	testing.expect(t, slua.do_string(&f.vm, `require('skymod.rt').load_effects()`), "load")

	worldstate.inv_add(&f.ws, ACTOR, MUG, 2)
	testing.expect(t, slua.do_string(&f.vm, `rt = require('skymod.rt'); rt.call(ref(0x700), "EquipItem", ref(0x5000))`), "use the mug")
	testing.expect_value(t, worldstate.inv_count(&f.ws, &f.db, ACTOR, MUG), 1)
	gold := worldstate.inv_count(&f.ws, &f.db, ACTOR, formid.GOLD)
	testing.expectf(t, gold >= 10 && gold <= 50, "gold %d", gold)

	worldstate.inv_add(&f.ws, ACTOR, SCROLL, 1)
	worldstate.av_set_base(&f.ws, TARGET, "Health", 100)
	testing.expect(t, worldstate.equip(&f.ws, &f.db, ACTOR, SCROLL, gamedb.Slot.RightHand), "a hand item equips")
	c := &f.vm.ctx
	testing.expect(t, script.cast_hand(c, ACTOR, .RightHand, TARGET), "the scroll casts with no Magicka")
	testing.expect(t, len(f.ws.casts) == 1 && f.ws.casts[0] == {ACTOR, SCROLL}, "OnSpellCast names the scroll")
	slua.tick_effects(&f.vm, &f.ws, 1)
	testing.expect_value(t, worldstate.av_current(&f.ws, &f.db, TARGET, "Health"), 90)
	testing.expect_value(t, worldstate.inv_count(&f.ws, &f.db, ACTOR, SCROLL), 0)
	testing.expect_value(t, worldstate.in_slot(&f.ws, &f.db, ACTOR, .RightHand), 0)
	testing.expect(t, !script.cast_hand(c, ACTOR, .RightHand, TARGET), "nothing left to cast")
}

// A passive is an effect applied straight to an actor with its own m, lasting until dispelled: the
// vampire stage goes up by dispelling and applying again with the new m.
@(test)
test_apply_effect :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_apply_effect", {})
	defer fixture_destroy(&f)
	p, _ := filepath.join({f.dir, "effects", "vampirism.lua"}, context.temp_allocator)
	os.make_directory_all(filepath.dir(p))
	testing.expect(t, os.write_entire_file(p, transmute([]u8)string(`return require('skymod.rt').effect { av = { FrostResist = { capacity = "10 + 10 * m" } } }`)) == nil, "write")
	p2, _ := filepath.join({f.dir, "effects", "broken.lua"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(p2, transmute([]u8)string(`return require('skymod.rt').effect { av = { FrostResist = { capacity = "5" } }, land = function(e) e.d = e.m / 0 end }`)) == nil, "write")
	slua.set_script_dirs(&f.vm, {f.dir})
	testing.expect(t, slua.do_string(&f.vm, `rt = require('skymod.rt'); rt.load_effects()`), "load")

	ACTOR :: gamedb.Form_ID(0x700)
	testing.expect(t, slua.do_string(&f.vm, `rt.call(ref(0x700), "ApplyEffect", "Vampirism", 2)`), "apply")
	for _ in 0 ..< 3 {slua.tick_effects(&f.vm, &f.ws, 10)}
	testing.expect_value(t, worldstate.av_current(&f.ws, &f.db, ACTOR, "FrostResist"), 30) // it lasts
	testing.expect(t, slua.do_string(&f.vm, `assert(rt.call(ref(0x700), "DispelEffect", "Vampirism") == true); rt.call(ref(0x700), "ApplyEffect", "Vampirism", 3)`), "next stage")
	testing.expect_value(t, worldstate.av_current(&f.ws, &f.db, ACTOR, "FrostResist"), 40)

	testing.expect(t, slua.do_string(&f.vm, `rt.call(ref(0x700), "DispelEffect", "Vampirism"); rt.call(ref(0x700), "ApplyEffect", "Vampirism", 1, -1)`), "a time that ran out, even exactly -1")
	slua.tick_effects(&f.vm, &f.ws, 1)
	testing.expect_value(t, worldstate.av_current(&f.ws, &f.db, ACTOR, "FrostResist"), 0) // ended, did not last

	testing.expect(t, slua.do_string(&f.vm, `rt.call(ref(0x700), "ApplyEffect", "Broken", 1, 5)`), "a land that divides by zero")
	slua.tick_effects(&f.vm, &f.ws, 1)
	testing.expect_value(t, worldstate.av_current(&f.ws, &f.db, ACTOR, "FrostResist"), 0) // d inf -> 0: ended
}

@(private = "file")
HOOKS_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Hooks", nil)
C.__fn["ongameloaded"] = function(self)
  rt.hook("Double", { land = function(e) if e.spell:HasTag("magic.fire") then e.m = e.m * 2 end end })
  rt.hook("Plus", { land = function(e) e.m = e.m + 10 end })
  rt.hook("Broken", { land = function(e) error("broken hook") end })
  rt.hook("Gone", { land = function(e) return false end })
  rt.hook("Gone", nil)
  rt.hook("Huge", { land = function(e) if e.m > 1000 then return false end end })
  rt.hook("Cost", { cost = function(c)
    if c.spell:HasTag("forbidden") then return false end
    c.cost = c.cost / 2
  end })
  rt.hook("Silver", { hit = function(h) if h.weapon then h.damage.add = h.damage.add + 20 end end })
  rt.hook("Armsman", { hit = function(h) h.damage.mult = h.damage.mult * 2 end })
  rt.hook("Unseen", { hit = function(h) if not h.attacker then return false end end })
  rt.hook("AssassinsBlade", { hit = function(h) if h.sneak then h.sneak_mult.mult = h.sneak_mult.mult * 2.5 end end })
  rt.hook("Juggernaut", { armor = function(a) a.rating.mult = a.rating.mult * 1.2 end })
  rt.hook("Dragonhide", { armor = function(a) if a.item then a.rating.set = 0 end end })
end
return C
`

// rt.hook adds landing, cost and hit hooks at game load. Landing hooks run on every effect from any
// source, defined or not, in the order they were added, and see a spell's tags through its effects;
// a broken one is passed over, one may stop an effect, a cost hook may refuse a cast, and a hit hook
// may change a hit's parts or stop it; an armor hook changes a piece's rating part.
@(test)
test_landing_hooks :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_hooks", {{"hooks.lua", HOOKS_LUA}})
	defer fixture_destroy(&f)
	files := [][2]string {
		{"effects/scorch.lua", `return require('skymod.rt').effect { tags = { "magic.fire" }, av = { Health = { amount = "-m" } } }`},
		{"spells/firebolt.lua", `return require('skymod.rt').spell { cost = 20, applies = { { "Scorch", m = 5 } } }`},
		{"spells/doom.lua", `return require('skymod.rt').spell { tags = { "forbidden" }, cost = 20, applies = { { "Scorch", m = 2000 } } }`},
	}
	for file in files {
		p, _ := filepath.join({f.dir, file[0]}, context.temp_allocator)
		os.make_directory_all(filepath.dir(p))
		testing.expect(t, os.write_entire_file(p, transmute([]u8)file[1]) == nil, "write content")
	}
	QUEST, TARGET, CASTER :: gamedb.Form_ID(0x900), gamedb.Form_ID(0x700), gamedb.Form_ID(0x701)
	PLAIN, BARE :: gamedb.Form_ID(0x910), gamedb.Form_ID(0x950) // a record spell, and an effect with no definition
	f.db.form_kinds = make(map[gamedb.Form_ID]gamedb.Form_Kind, context.temp_allocator)
	f.db.form_kinds[PLAIN] = .Spell
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	f.db.form_scripts[QUEST] = {scripts = []esm.Script_Attach{{name = "Hooks"}}}
	f.db.quest_baseline = make(map[gamedb.Form_ID]gamedb.Quest_Baseline, context.temp_allocator)
	f.db.quest_baseline[QUEST] = {}
	f.db.spells = make(map[gamedb.Form_ID]gamedb.Spell, context.temp_allocator)
	f.db.spells[PLAIN] = {info = {cast_type = .Fire_And_Forget}, effects = []gamedb.Magic_Effect_Ref{{effect = BARE, magnitude = 3, duration = 5}}}
	slua.set_script_dirs(&f.vm, {f.dir})
	slua.start_game(&f.vm, &f.db)

	FIREBOLT, DOOM := formid.lua_form("spell", "Firebolt"), formid.lua_form("spell", "Doom")
	testing.expect(t, worldstate.has_tag(&f.ws, &f.db, FIREBOLT, "magic"), "a spell has its effects' tags")
	cast_at :: proc(t: ^testing.T, f: ^Fixture, spell: gamedb.Form_ID) {
		src := fmt.tprintf("rt = require('skymod.rt'); rt.call(ref(0x%X), \"Cast\", ref(0x701), ref(0x700))", spell)
		testing.expect(t, slua.do_string(&f.vm, src), "Cast")
	}
	cast_at(t, &f, FIREBOLT)
	cast_at(t, &f, PLAIN)
	cast_at(t, &f, DOOM) // 2000 * 2 + 10: Huge stops it
	testing.expect_value(t, len(f.ws.effects), 2)
	for h in worldstate.effects_on(&f.ws, TARGET) {
		e := f.ws.effects[h]
		switch e.effect {
		case BARE: testing.expect_value(t, e.magnitude, 13) // not fire: Plus only
		case:      testing.expect_value(t, e.magnitude, 20) // 5 * 2, then + 10
		}
	}

	cost, ok := worldstate.cast_cost(&f.ws, CASTER, FIREBOLT, 20)
	testing.expect(t, ok && cost == 10, "the cost hook halves it")
	_, ok = worldstate.cast_cost(&f.ws, CASTER, DOOM, 20)
	testing.expect(t, !ok, "the cost hook refuses it")

	h := f.ws.hooks
	a := combat.attack(CASTER, TARGET, PLAIN, {.Sneak})
	testing.expect(t, h.hit(h.data, &a), "the hit goes on")
	testing.expect_value(t, a.damage, combat.Part{add = 20, mult = 2})
	testing.expect_value(t, a.armor_pen, combat.KEEP)
	testing.expect_value(t, a.sneak_mult, combat.Part{mult = 2.5})
	a = combat.attack(0, TARGET, 0)
	testing.expect(t, !h.hit(h.data, &a), "a hit hook stops the hit")
	rating := combat.KEEP
	h.armor(h.data, TARGET, PLAIN, &rating)
	testing.expect_value(t, rating, combat.Part{mult = 1.2, set = 0, has_set = true})
}

@(private = "file")
PLUS_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Plus", nil)
C.__fn["ongameloaded"] = function(self) rt.hook("Plus", { land = function(e) e.m = e.m + 10 end }) end
return C
`

// The core Resist hook runs after every mod's hook and cuts a hostile effect's m by Resist Magic
// and its own resistance, each capped at ResistCap (the player's is fPlayerMaxResistance); a
// poison by PoisonResist alone, an ignore_resist spell not at all.
@(test)
test_resist_hook :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_resist", {{"plus.lua", PLUS_LUA}})
	defer fixture_destroy(&f)
	CHILL :: `return require('skymod.rt').effect { tags = { "hostile" }, resist = "FrostResist", av = { Health = { amount = "-m" } } }`
	files := [][2]string {
		{"effects/chill.lua", CHILL},
		{"spells/frostbite.lua", `return require('skymod.rt').spell { applies = { { "Chill", m = 30 } } }`},
		{"spells/pierce.lua", `return require('skymod.rt').spell { tags = { "ignore_resist" }, applies = { { "Chill", m = 30 } } }`},
		{"spells/venom.lua", `return require('skymod.rt').spell { tags = { "poison" }, applies = { { "Chill", m = 30 } } }`},
	}
	for file in files {
		p, _ := filepath.join({f.dir, file[0]}, context.temp_allocator)
		os.make_directory_all(filepath.dir(p))
		testing.expect(t, os.write_entire_file(p, transmute([]u8)file[1]) == nil, "write content")
	}
	QUEST, NPC, STURDY, CASTER :: gamedb.Form_ID(0x900), gamedb.Form_ID(0x700), gamedb.Form_ID(0x702), gamedb.Form_ID(0x701)
	f.ws.player = formid.PLAYER
	f.db.form_kinds = make(map[gamedb.Form_ID]gamedb.Form_Kind, context.temp_allocator)
	f.db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	f.db.form_scripts[QUEST] = {scripts = []esm.Script_Attach{{name = "Plus"}}}
	f.db.quest_baseline = make(map[gamedb.Form_ID]gamedb.Quest_Baseline, context.temp_allocator)
	f.db.quest_baseline[QUEST] = {}
	for a in ([]gamedb.Form_ID{NPC, STURDY, formid.PLAYER}) {worldstate.av_set_base(&f.ws, a, "Health", 1000)}
	worldstate.av_set_base(&f.ws, NPC, "FrostResist", 50)
	worldstate.av_set_base(&f.ws, NPC, "MagicResist", 50)
	worldstate.av_set_base(&f.ws, NPC, "PoisonResist", 20)
	worldstate.av_set_base(&f.ws, STURDY, "FrostResist", 100)
	worldstate.av_set_base(&f.ws, formid.PLAYER, "FrostResist", 100)
	slua.set_script_dirs(&f.vm, {f.dir})
	slua.start_game(&f.vm, &f.db)

	landed :: proc(t: ^testing.T, f: ^Fixture, spell: string, target: gamedb.Form_ID) -> f32 {
		form := formid.lua_form("spell", spell)
		src := fmt.tprintf("rt = require('skymod.rt'); rt.call(ref(0x%X), \"Cast\", ref(0x701), ref(0x%X))", form, target)
		testing.expect(t, slua.do_string(&f.vm, src), "Cast")
		hs := script.spell_effects(&f.ws, target, form)
		if len(hs) == 0 {return -1}
		return f.ws.effects[hs[0]].magnitude
	}
	testing.expect_value(t, landed(t, &f, "Frostbite", NPC), 10) // (30 + 10) * 0.5 * 0.5: the mod's hook first
	testing.expect_value(t, landed(t, &f, "Pierce", NPC), 40)
	testing.expect_value(t, landed(t, &f, "Venom", NPC), 32) // 40 * 0.8, no Resist Magic
	testing.expect_value(t, landed(t, &f, "Frostbite", STURDY), 0) // 100: immune
	player := landed(t, &f, "Frostbite", formid.PLAYER)
	testing.expect(t, abs(player - 6) < 1e-4, "the player's 100 counts as 85") // 40 * 0.15
}

// A defined effect landed again by the same caster from the same source restarts, adds or keeps
// the running copy by its `stack`; other casters and sources add. In a nostack group only the
// strongest runs, across AVs. A land may dispel by tag.
@(test)
test_rt_stacking :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(t, &f, "skymod_instances_stacking", {})
	defer fixture_destroy(&f)
	RT :: `return require('skymod.rt').`
	files := [][2]string {
		{"effects/burn.lua", RT + `effect { av = { Health = { amount = "-m" } } }`},
		{"effects/venom.lua", RT + `effect { stack = "add", av = { Health = { amount = "-m" } } }`},
		{"effects/hex.lua", RT + `effect { stack = "keep", av = { Magicka = { amount = "-m" } } }`},
		{"effects/rot.lua", RT + `effect { tags = { "disease.rattles" }, av = { Stamina = { capacity = "-m" } } }`},
		{"effects/cure.lua", RT + `effect { land = function(e) e.target:DispelTagged("disease") end }`},
		{"effects/blessingarkay.lua", RT + `effect { nostack = "Blessing", av = { Health = { capacity = "m" } } }`},
		{"effects/blessingkyne.lua", RT + `effect { nostack = "Blessing", av = { Stamina = { capacity = "m" } } }`},
		{"spells/flames.lua", RT + `spell { applies = { { "Burn", m = 1, d = "9s" } } }`},
		{"spells/firebolt.lua", RT + `spell { applies = { { "Burn", m = 1, d = "9s" } } }`},
		{"spells/sting.lua", RT + `spell { applies = { { "Venom", m = 1, d = "9s" } } }`},
		{"spells/curse.lua", RT + `spell { applies = { { "Hex", m = 1, d = "9s" } } }`},
		{"spells/rattles.lua", RT + `spell { applies = { { "Rot", m = 1, d = "90s" } } }`},
		{"spells/curedisease.lua", RT + `spell { applies = { { "Cure" } } }`},
	}
	for file in files {
		p, _ := filepath.join({f.dir, file[0]}, context.temp_allocator)
		os.make_directory_all(filepath.dir(p))
		testing.expect(t, os.write_entire_file(p, transmute([]u8)file[1]) == nil, "write content")
	}
	f.db.form_kinds = make(map[gamedb.Form_ID]gamedb.Form_Kind, context.temp_allocator)
	slua.set_script_dirs(&f.vm, {f.dir})
	testing.expect(t, slua.do_string(&f.vm, `require('skymod.rt').load_effects()`), "load")
	TARGET :: gamedb.Form_ID(0x700)
	worldstate.av_set_base(&f.ws, TARGET, "Health", 1000)

	cast_by :: proc(t: ^testing.T, f: ^Fixture, spell: string, caster: gamedb.Form_ID) {
		src := fmt.tprintf("rt = require('skymod.rt'); rt.call(ref(0x%X), \"Cast\", ref(0x%X), ref(0x700))", formid.lua_form("spell", spell), caster)
		testing.expect(t, slua.do_string(&f.vm, src), "Cast")
	}
	running :: proc(f: ^Fixture, effect: string) -> (n: int) {
		for h in worldstate.effects_on(&f.ws, TARGET) {
			if e := f.ws.effects[h]; !e.ended && e.effect == formid.lua_form("effect", effect) {n += 1}
		}
		return
	}
	cast_by(t, &f, "Flames", 0x701)
	cast_by(t, &f, "Flames", 0x701)
	testing.expect_value(t, running(&f, "Burn"), 1) // the same caster and spell: restarted
	cast_by(t, &f, "Flames", 0x702)
	cast_by(t, &f, "Firebolt", 0x701)
	testing.expect_value(t, running(&f, "Burn"), 3) // another caster, another spell: they add
	cast_by(t, &f, "Sting", 0x701)
	cast_by(t, &f, "Sting", 0x701)
	testing.expect_value(t, running(&f, "Venom"), 2)
	cast_by(t, &f, "Curse", 0x701)
	first := worldstate.effects_on(&f.ws, TARGET)[len(worldstate.effects_on(&f.ws, TARGET)) - 1]
	cast_by(t, &f, "Curse", 0x701)
	testing.expect(t, running(&f, "Hex") == 1 && !f.ws.effects[first].ended, "keep: the running copy stays")

	bless :: proc(t: ^testing.T, f: ^Fixture, effect: string, m: int) {
		testing.expect(t, slua.do_string(&f.vm, fmt.tprintf(`rt.call(ref(0x700), "ApplyEffect", "%s", %d)`, effect, m)), "ApplyEffect")
	}
	bless(t, &f, "BlessingArkay", 10)
	bless(t, &f, "BlessingKyne", 5)
	testing.expect(t, running(&f, "BlessingArkay") == 1 && running(&f, "BlessingKyne") == 0, "a weaker blessing does not land")
	bless(t, &f, "BlessingKyne", 20)
	testing.expect(t, running(&f, "BlessingArkay") == 0 && running(&f, "BlessingKyne") == 1, "a stronger one replaces it, across AVs")

	cast_by(t, &f, "Rattles", 0x701)
	testing.expect_value(t, running(&f, "Rot"), 1)
	cast_by(t, &f, "CureDisease", 0x700)
	testing.expect_value(t, running(&f, "Rot"), 0)
}
