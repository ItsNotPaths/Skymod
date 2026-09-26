package unit_tests

// Script-registry tests (Phase 4). Hermetic + SYNTHETIC: drive native calls
// directly through the VM-agnostic dispatch and assert they land in the worldstate
// overlay — no Lua VM, no game files. The 674-native manifest is the committed
// generated artifact; we assert auto-stub coverage + that the hot set mutates +
// reads through baseline⊕overlay + case-insensitive dispatch.

import "core:log"
import "core:os"
import "core:math"
import "core:testing"
import "../../src/conditions"
import "../../src/formats/esm"
import "../../src/formid"
import "../../src/gamedb"
import "../../src/script"
import "../../src/worldstate"

@(test)
test_registry_manifest_and_stubs :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)

	// The whole declared surface is auto-stubbed (674 from the corpus).
	testing.expect(t, len(reg.declared) >= 600, "manifest auto-stubbed")
	testing.expect(t, script.is_declared(&reg, "ObjectReference", "Disable"), "Disable declared")
	testing.expect(t, script.is_implemented(&reg, "ObjectReference", "Disable"), "Disable implemented")
	// Declared but no body yet -> known, not implemented. (GetWarmthRating has no body yet; swap this
	// if it ever gets one.)
	testing.expect(t, script.is_declared(&reg, "Actor", "GetWarmthRating"), "GetWarmthRating declared")
	testing.expect(t, !script.is_implemented(&reg, "Actor", "GetWarmthRating"), "GetWarmthRating not impl")
}

@(test)
test_registry_disable_enable :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB // empty baseline; read-through falls back to defaults

	form := script.Form_ID(0x0001_2345)
	c := script.Call{self = form, ws = &ws, db = &db}

	script.call(&reg, "ObjectReference", "Disable", &c, nil)
	d, ok := worldstate.get(&ws, form)
	testing.expect(t, ok, "delta exists after Disable")
	testing.expect(t, .Disabled in d.live, "Disabled field live")
	testing.expect(t, d.disabled, "disabled = true")

	// case-insensitive dispatch (Papyrus is case-insensitive).
	script.call(&reg, "objectreference", "enable", &c, nil)
	d2, _ := worldstate.get(&ws, form)
	testing.expect(t, !d2.disabled, "Enable cleared disabled")

	// read-through getter reflects the overlay.
	res := script.call(&reg, "ObjectReference", "IsDisabled", &c, nil)
	b, isb := res.(bool)
	testing.expect(t, isb && !b, "IsDisabled reads overlay = false")
}

@(test)
test_registry_scale_and_player :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB

	form := script.Form_ID(0x0002_2222)
	c := script.Call{self = form, ws = &ws, db = &db}

	script.call(&reg, "ObjectReference", "SetScale", &c, []script.Value{f32(2.5)})
	gs := script.call(&reg, "ObjectReference", "GetScale", &c, nil)
	sv, oks := gs.(f32)
	testing.expect(t, oks, "GetScale returns a float")
	testing.expect_value(t, sv, f32(2.5))

	// Game.GetPlayer is a global (self unused) returning the player form 0x14.
	gp := script.call(&reg, "Game", "GetPlayer", &c, nil)
	pf, okf := gp.(script.Form_ID)
	testing.expect(t, okf, "GetPlayer returns a form")
	testing.expect_value(t, pf, formid.PLAYER)
}

@(test)
test_registry_unimplemented_and_unknown :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB
	c := script.Call{self = script.Form_ID(1), ws = &ws, db = &db}

	// Declared-but-unimplemented returns its declared type's zero; None only for objects.
	r1 := script.call(&reg, "Actor", "GetActorValue", &c, []script.Value{"Health"})
	testing.expect_value(t, r1.(f32), f32(0))
	testing.expect_value(t, script.call(&reg, "Actor", "CanFlyHere", &c, nil).(bool), false)
	testing.expect(t, script.call(&reg, "Actor", "GetCombatTarget", &c, nil) == nil, "object stub -> None")
	testing.expect(t, reg.declared["utility.wait"].latent, "Wait is latent")
	testing.expect(t, !reg.declared["actor.canflyhere"].latent, "CanFlyHere is not latent")

	// Unknown native (not in the manifest) also returns None. It logs an ERROR by design, which the
	// runner would count, so only that call runs silenced: expect reports through the same logger.
	old := context.logger
	context.logger = log.nil_logger()
	r2 := script.call(&reg, "TotallyNotAClass", "Nope", &c, nil)
	context.logger = old
	testing.expect(t, r2 == nil, "unknown -> None")
	testing.expect(t, !script.is_declared(&reg, "TotallyNotAClass", "Nope"), "unknown not declared")
}

// Math.* — pure callstatic leaves (degrees convention: sin(90)=1). Spot-checks each shape.
@(test)
test_registry_math :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	c := script.Call{}

	f :: proc(v: script.Value) -> f32 {return v.(f32)}
	i :: proc(v: script.Value) -> i32 {return v.(i32)}

	testing.expect(t, script.is_implemented(&reg, "Math", "sqrt"), "sqrt implemented")
	testing.expectf(t, abs(f(script.call(&reg, "Math", "sqrt", &c, {f32(16)})) - 4) < 1e-4, "sqrt(16)=4")
	testing.expectf(t, abs(f(script.call(&reg, "Math", "abs", &c, {f32(-3.5)})) - 3.5) < 1e-4, "abs(-3.5)")
	testing.expectf(t, abs(f(script.call(&reg, "Math", "pow", &c, {f32(2), f32(10)})) - 1024) < 1e-2, "pow(2,10)")
	testing.expectf(t, abs(f(script.call(&reg, "Math", "sin", &c, {f32(90)})) - 1) < 1e-4, "sin(90 deg)=1")
	testing.expectf(t, abs(f(script.call(&reg, "Math", "cos", &c, {f32(0)})) - 1) < 1e-4, "cos(0)=1")
	// Ceiling/Floor return int, case-insensitive dispatch ("math"/"ceiling").
	testing.expect_value(t, i(script.call(&reg, "math", "ceiling", &c, {f32(2.1)})), i32(3))
	testing.expect_value(t, i(script.call(&reg, "Math", "Floor", &c, {f32(2.9)})), i32(2))
	// DegreesToRadians(180) = pi.
	testing.expectf(t, abs(f(script.call(&reg, "Math", "DegreesToRadians", &c, {f32(180)})) - 3.14159) < 1e-3, "deg2rad(180)")
}

// Inventory store: AddItem/RemoveItem/GetItemCount clamp at 0, RemoveAllItems clears, GetGoldAmount.
@(test)
test_registry_inventory :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB

	owner := script.Form_ID(0x0005_0000)
	item := script.Form_ID(0x0000_0A11)
	c := script.Call{self = owner, ws = &ws, db = &db}
	count :: proc(reg: ^script.Registry, c: ^script.Call, item: script.Form_ID) -> i32 {
		return script.call(reg, "ObjectReference", "GetItemCount", c, {item}).(i32)
	}

	testing.expect_value(t, count(&reg, &c, item), i32(0))
	script.call(&reg, "ObjectReference", "AddItem", &c, {item, i32(5)})
	script.call(&reg, "ObjectReference", "AddItem", &c, {item, i32(3)})
	testing.expect_value(t, count(&reg, &c, item), i32(8))
	script.call(&reg, "ObjectReference", "RemoveItem", &c, {item, i32(2)})
	testing.expect_value(t, count(&reg, &c, item), i32(6))
	// Over-removal clamps at 0.
	script.call(&reg, "ObjectReference", "RemoveItem", &c, {item, i32(100)})
	testing.expect_value(t, count(&reg, &c, item), i32(0))

	// Gold amount reads the Gold001 count; RemoveAllItems wipes everything.
	script.call(&reg, "ObjectReference", "AddItem", &c, {formid.GOLD, i32(250)})
	testing.expect_value(t, script.call(&reg, "Actor", "GetGoldAmount", &c, nil).(i32), i32(250))
	script.call(&reg, "ObjectReference", "RemoveAllItems", &c, nil)
	testing.expect_value(t, script.call(&reg, "Actor", "GetGoldAmount", &c, nil).(i32), i32(0))
}

// Counts start from the base's contents: a container's CNTO, an NPC_'s through its inventory
// template. Leveled entries count as nothing, and a source gives at most what it holds.
@(test)
test_registry_starting_contents :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	F :: script.Form_ID
	CHEST, CHEST_BASE, GUARD, GUARD_BASE, TEMPLATE, BAG :: F(0x100), F(0x101), F(0x200), F(0x201), F(0x202), F(0x300)
	ITEM, LEVELED :: F(0xA00), F(0xA01)
	db: gamedb.DB
	defer {delete(db.ref_by_id);delete(db.containers);delete(db.actors);delete(db.leveled_lists)}
	chest_items := []gamedb.Content_Entry{{ITEM, 4}, {LEVELED, 1}}
	guard_items := []gamedb.Content_Entry{{ITEM, 2}}
	db.ref_by_id[CHEST] = {form_id = CHEST, base = CHEST_BASE}
	db.ref_by_id[GUARD] = {form_id = GUARD, base = GUARD_BASE}
	db.containers[CHEST_BASE] = chest_items
	db.leveled_lists[LEVELED] = {}
	db.actors[GUARD_BASE] = {template = TEMPLATE, template_flags = esm.ACBS_TEMPLATE_INVENTORY}
	db.actors[TEMPLATE] = {inventory = guard_items}

	chest := script.Call{self = CHEST, ws = &ws, db = &db}
	guard := script.Call{self = GUARD, ws = &ws, db = &db}
	count :: proc(reg: ^script.Registry, c: ^script.Call, item: script.Form_ID) -> i32 {
		return script.call(reg, "ObjectReference", "GetItemCount", c, {item}).(i32)
	}
	testing.expect_value(t, count(&reg, &chest, ITEM), i32(4))
	testing.expect_value(t, count(&reg, &chest, LEVELED), i32(0))
	testing.expect_value(t, count(&reg, &guard, ITEM), i32(2))

	script.call(&reg, "ObjectReference", "RemoveItem", &chest, {ITEM, i32(10), false, BAG})
	testing.expect_value(t, count(&reg, &chest, ITEM), i32(0))
	testing.expect_value(t, worldstate.inv_delta(&ws, BAG, ITEM), i32(4))

	script.call(&reg, "ObjectReference", "RemoveAllItems", &guard, {BAG})
	testing.expect_value(t, count(&reg, &guard, ITEM), i32(0))
	testing.expect_value(t, worldstate.inv_delta(&ws, BAG, ITEM), i32(6))
}

// Actor values follow the CK wiki's model: Set moves the base, Mod the max, Damage and Restore only
// the current value, and Force sets the permanent modifier to reach its value.
@(test)
test_registry_actor_value :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB

	c := script.Call{self = script.Form_ID(0x0006_0000), ws = &ws, db = &db}
	get :: proc(reg: ^script.Registry, c: ^script.Call, fn, name: string) -> f32 {
		return script.call(reg, "Actor", fn, c, {name}).(f32)
	}
	act :: proc(reg: ^script.Registry, c: ^script.Call, fn, name: string, v: f32) {
		script.call(reg, "Actor", fn, c, {name, v})
	}

	act(&reg, &c, "SetActorValue", "Health", 100)
	act(&reg, &c, "DamageActorValue", "health", 10) // case-insensitive
	testing.expect_value(t, get(&reg, &c, "GetActorValue", "Health"), f32(90)) // "90/100 Health"
	act(&reg, &c, "ModActorValue", "Health", -10)
	testing.expect_value(t, get(&reg, &c, "GetActorValueMax", "Health"), f32(90))
	testing.expect_value(t, get(&reg, &c, "GetBaseActorValue", "Health"), f32(100))
	testing.expect_value(t, get(&reg, &c, "GetActorValuePercentage", "Health"), f32(80) / 90)
	act(&reg, &c, "DamageActorValue", "Health", -20) // a negative amount damages too
	act(&reg, &c, "RestoreActorValue", "Health", 1000) // never past the max
	testing.expect_value(t, get(&reg, &c, "GetActorValue", "Health"), f32(90))

	act(&reg, &c, "SetActorValue", "Health", 125)
	act(&reg, &c, "ForceActorValue", "Health", 0) // "force their health to 0"
	act(&reg, &c, "SetActorValue", "Health", 150) // "their current health will instantly become 25"
	testing.expect_value(t, get(&reg, &c, "GetActorValue", "Health"), f32(25))

	testing.expect_value(t, get(&reg, &c, "GetActorValuePercentage", "Stamina"), f32(1)) // max 0
	act(&reg, &c, "SetActorValue", "CarryWeight", 300)
	act(&reg, &c, "DamageActorValue", "CarryWeight", 100)
	testing.expect_value(t, get(&reg, &c, "GetActorValuePercentage", "CarryWeight"), f32(1))

	act(&reg, &c, "SetActorValue", "NotAnActorValue", 5)
	testing.expect_value(t, get(&reg, &c, "GetActorValue", "NotAnActorValue"), f32(0))
}

// Faction + relationship store: SetFactionRank adds, Mod adjusts, Remove(All), relationship rank.
@(test)
test_registry_faction :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB

	actor := script.Form_ID(0x0007_0000)
	faction := script.Form_ID(0x0000_00AB)
	c := script.Call{self = actor, ws = &ws, db = &db}
	in_faction :: proc(reg: ^script.Registry, c: ^script.Call, f: script.Form_ID) -> bool {
		return script.call(reg, "Actor", "IsInFaction", c, {f}).(bool)
	}
	rank :: proc(reg: ^script.Registry, c: ^script.Call, f: script.Form_ID) -> i32 {
		return script.call(reg, "Actor", "GetFactionRank", c, {f}).(i32)
	}

	testing.expect_value(t, in_faction(&reg, &c, faction), false)
	testing.expect_value(t, rank(&reg, &c, faction), i32(-1)) // non-member
	script.call(&reg, "Actor", "SetFactionRank", &c, {faction, i32(3)})
	testing.expect_value(t, in_faction(&reg, &c, faction), true)
	testing.expect_value(t, rank(&reg, &c, faction), i32(3))
	script.call(&reg, "Actor", "ModFactionRank", &c, {faction, i32(2)})
	testing.expect_value(t, rank(&reg, &c, faction), i32(5))
	script.call(&reg, "Actor", "RemoveFromFaction", &c, {faction})
	testing.expect_value(t, in_faction(&reg, &c, faction), false)

	// RemoveFromAllFactions drops every membership.
	script.call(&reg, "Actor", "SetFactionRank", &c, {faction, i32(1)})
	script.call(&reg, "Actor", "SetFactionRank", &c, {script.Form_ID(0xCD), i32(1)})
	script.call(&reg, "Actor", "RemoveFromAllFactions", &c, nil)
	testing.expect_value(t, in_faction(&reg, &c, faction), false)
	testing.expect_value(t, in_faction(&reg, &c, script.Form_ID(0xCD)), false)

	// Relationship rank: default 0 (neutral), then set.
	other := script.Form_ID(0x0008_0000)
	testing.expect_value(t, script.call(&reg, "Actor", "GetRelationshipRank", &c, {other}).(i32), i32(0))
	script.call(&reg, "Actor", "SetRelationshipRank", &c, {other, i32(4)})
	testing.expect_value(t, script.call(&reg, "Actor", "GetRelationshipRank", &c, {other}).(i32), i32(4))
}

// Quest baseline ⊕ overlay: an untouched Start-Game-Enabled quest reads running; SetCurrentStageID
// validates the stage against the baseline + requires the quest running; a stage flagged Complete
// completes the quest; an explicit Stop overrides the baseline.
@(test)
test_registry_quest_baseline :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	// A baseline: SGE=true, stages {10: not-complete, 20: completes}. (form_kinds not needed — the
	// natives dispatch by explicit class; this exercises the baseline merge, not method resolution.)
	q := script.Form_ID(0x000C_0DE0)
	db: gamedb.DB
	db.quest_baseline = make(map[gamedb.Form_ID]gamedb.Quest_Baseline)
	complete := []gamedb.Stage_Item{{flags = gamedb.ITEM_COMPLETE_QUEST}}
	stages := make(map[u16]gamedb.Quest_Stage)
	stages[10] = {}
	stages[20] = {items = complete}
	stages[30] = {}
	objectives := make(map[u16]bool)
	objectives[5] = true
	objectives[15] = true
	db.quest_baseline[q] = gamedb.Quest_Baseline{start_game_enabled = true, stages = stages, objectives = objectives}
	defer {delete(stages);delete(objectives);delete(db.quest_baseline)}

	c := script.Call{self = q, ws = &ws, db = &db}

	// Untouched SGE quest defers to the baseline → running.
	testing.expect_value(t, script.call(&reg, "Quest", "IsRunning", &c, nil).(bool), true)
	testing.expect_value(t, script.call(&reg, "Quest", "IsStopped", &c, nil).(bool), false)

	// SetCurrentStageID: undefined stage 99 → false (no-op); defined stage 10 → true.
	testing.expect_value(t, script.call(&reg, "Quest", "SetCurrentStageID", &c, {i32(99)}).(bool), false)
	testing.expect_value(t, script.call(&reg, "Quest", "SetCurrentStageID", &c, {i32(10)}).(bool), true)
	testing.expect_value(t, script.call(&reg, "Quest", "GetCurrentStageID", &c, nil).(i32), i32(10))
	testing.expect_value(t, script.call(&reg, "Quest", "IsCompleted", &c, nil).(bool), false)
	testing.expect_value(t, script.call(&reg, "Quest", "SetCurrentStageID", &c, {i32(10)}).(bool), false) // done: runs once

	// Reaching a Complete-flagged stage marks the quest completed (baseline stage flag).
	testing.expect_value(t, script.call(&reg, "Quest", "SetCurrentStageID", &c, {i32(20)}).(bool), true)
	testing.expect_value(t, script.call(&reg, "Quest", "IsCompleted", &c, nil).(bool), true)

	// CompleteAllObjectives reaches the baseline (QOBJ) objectives even though none was individually set.
	script.call(&reg, "Quest", "CompleteAllObjectives", &c, nil)
	testing.expect_value(t, script.call(&reg, "Quest", "IsObjectiveCompleted", &c, {i32(5)}).(bool), true)
	testing.expect_value(t, script.call(&reg, "Quest", "IsObjectiveCompleted", &c, {i32(15)}).(bool), true)

	// Explicit Stop overrides the baseline SGE once the VM runs the queued stop; SetCurrentStageID
	// starts a stopped quest again.
	script.call(&reg, "Quest", "Stop", &c, nil)
	testing.expect_value(t, len(ws.quest_steps) > 0 && ws.quest_steps[len(ws.quest_steps) - 1].stop, true)
	script.stop_quest(&c, q)
	testing.expect_value(t, script.call(&reg, "Quest", "IsRunning", &c, nil).(bool), false)
	testing.expect_value(t, script.call(&reg, "Quest", "SetCurrentStageID", &c, {i32(30)}).(bool), true)
	testing.expect_value(t, script.call(&reg, "Quest", "IsRunning", &c, nil).(bool), true)
}

// Form-kind method dispatch: a Quest/GlobalVariable/Faction handle resolves methods up its own
// class chain, not the object-ref chain. (The gamedb form→kind indexing is covered in esm_test.)
@(test)
test_method_class_dispatch :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)

	// Quest methods resolve under .Quest (they're invisible to the object-ref chain).
	c, ok := script.method_class(&reg, "SetCurrentStageID", .Quest)
	testing.expect(t, ok, "Quest.SetCurrentStageID resolves")
	testing.expect_value(t, c, "Quest")
	// A skymod extension (implemented-but-not-declared) still resolves under its class.
	c2, ok2 := script.method_class(&reg, "GetRecentStageID", .Quest)
	testing.expect(t, ok2 && c2 == "Quest", "GetRecentStageID -> Quest")
	// GlobalVariable.GetValue would miss the object-ref chain; resolves under .Global.
	cg, okg := script.method_class(&reg, "GetValue", .Global)
	testing.expect(t, okg && cg == "GlobalVariable", "GetValue -> GlobalVariable")
	// A base-object handle (a WEAP form) dispatches up its own class: ActorBase.GetSex is invisible
	// to the object-ref chain but resolves under .ActorBase; the display class is the class itself.
	cn, okn := script.method_class(&reg, "GetSex", .ActorBase)
	testing.expect(t, okn && cn == "ActorBase", "GetSex -> ActorBase")
	testing.expect_value(t, script.class_display(.Weapon), "Weapon")
	testing.expect_value(t, script.class_display(.Unknown), "ObjectReference") // object refs, not "Actor"
	// Default (Unknown / object-ref) chain unchanged: Disable -> ObjectReference.
	cd, _ := script.method_class(&reg, "Disable")
	testing.expect_value(t, cd, "ObjectReference")
	// A miss on a typed chain falls back to the form's own class, not ObjectReference.
	cm, okm := script.method_class(&reg, "NotARealMethod", .Quest)
	testing.expect(t, !okm, "unknown method misses")
	testing.expect_value(t, cm, "Quest")
}

// A-tier stores: globals, actor Kill/IsDead, PlaceAtMe.
@(test)
test_registry_stores :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB

	glob := script.Form_ID(0x0001_0000)
	gc := script.Call{self = glob, ws = &ws, db = &db}
	// Unset global reads 0; SetValue then GetValue reflects it.
	testing.expect_value(t, script.call(&reg, "GlobalVariable", "GetValue", &gc, nil).(f32), f32(0))
	script.call(&reg, "GlobalVariable", "SetValue", &gc, {f32(12.5)})
	testing.expect_value(t, script.call(&reg, "GlobalVariable", "GetValue", &gc, nil).(f32), f32(12.5))

	// Actor Kill flips Dead; IsDead reads through the overlay (default false before).
	actor := script.Form_ID(0x0002_0000)
	ac := script.Call{self = actor, ws = &ws, db = &db}
	testing.expect_value(t, script.call(&reg, "Actor", "IsDead", &ac, nil).(bool), false)
	script.call(&reg, "Actor", "Kill", &ac, {script.Form_ID(0)})
	testing.expect_value(t, script.call(&reg, "Actor", "IsDead", &ac, nil).(bool), true)

	// PlaceAtMe mints a created ref of the base form and returns its (0xFF-space) FormID.
	placer := script.Form_ID(0x0003_0000)
	pc := script.Call{self = placer, ws = &ws, db = &db}
	base := script.Form_ID(0x0000_00CF)
	res := script.call(&reg, "ObjectReference", "PlaceAtMe", &pc, {base, i32(2), false, false})
	newid, isform := res.(script.Form_ID)
	testing.expect(t, isform, "PlaceAtMe returns a form")
	testing.expect(t, newid >= formid.CREATED_FORM_BASE, "created ref in the 0xFF space")
	cr, crok := worldstate.get_created(&ws, newid)
	testing.expect(t, crok, "created ref stored")
	testing.expect_value(t, cr.base, base)
	// aiCount=2 spawned two refs; the returned one is the last.
	testing.expect_value(t, newid, formid.CREATED_FORM_BASE + 1)
}

// Quest.* — the store natives end to end through the VM-agnostic dispatch.
@(test)
test_registry_quest :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB

	quest := script.Form_ID(0x000C_0DE0)
	c := script.Call{self = quest, ws = &ws, db = &db}

	// Untouched quest: stage 0, not running, IsStopped true.
	testing.expect_value(t, script.call(&reg, "Quest", "GetCurrentStageID", &c, nil).(i32), i32(0))
	testing.expect_value(t, script.call(&reg, "Quest", "IsRunning", &c, nil).(bool), false)
	testing.expect_value(t, script.call(&reg, "Quest", "IsStopped", &c, nil).(bool), true)

	// Start, then advance a stage → running, stage set + marked done.
	testing.expect_value(t, script.call(&reg, "Quest", "Start", &c, nil).(bool), true)
	testing.expect_value(t, script.call(&reg, "Quest", "Start", &c, nil).(bool), false) // already running
	script.call(&reg, "Quest", "SetCurrentStageID", &c, {i32(30)})
	testing.expect_value(t, script.call(&reg, "Quest", "GetCurrentStageID", &c, nil).(i32), i32(30))
	testing.expect_value(t, script.call(&reg, "Quest", "IsStageDone", &c, {i32(30)}).(bool), true)
	testing.expect_value(t, script.call(&reg, "Quest", "IsStageDone", &c, {i32(31)}).(bool), false)
	// GetCurrentStageID = HIGHEST completed stage, not last set: 30 then a lower 20 still reads 30.
	// GetRecentStageID (skymod extension) = the raw last-set stage → 20.
	script.call(&reg, "Quest", "SetCurrentStageID", &c, {i32(20)})
	testing.expect_value(t, script.call(&reg, "Quest", "GetCurrentStageID", &c, nil).(i32), i32(30))
	testing.expect_value(t, script.call(&reg, "Quest", "GetRecentStageID", &c, nil).(i32), i32(20))
	testing.expect_value(t, script.call(&reg, "Quest", "IsStageDone", &c, {i32(20)}).(bool), true)

	// Objectives: set displayed + completed on obj 5; IsObjective* reflects it.
	script.call(&reg, "Quest", "SetObjectiveDisplayed", &c, {i32(5), true, false})
	script.call(&reg, "Quest", "SetObjectiveCompleted", &c, {i32(5), true})
	testing.expect_value(t, script.call(&reg, "Quest", "IsObjectiveDisplayed", &c, {i32(5)}).(bool), true)
	testing.expect_value(t, script.call(&reg, "Quest", "IsObjectiveCompleted", &c, {i32(5)}).(bool), true)
	testing.expect_value(t, script.call(&reg, "Quest", "IsObjectiveFailed", &c, {i32(5)}).(bool), false)

	// FailAllObjectives reaches the touched objective (adds Failed alongside).
	script.call(&reg, "Quest", "FailAllObjectives", &c, nil)
	testing.expect_value(t, script.call(&reg, "Quest", "IsObjectiveFailed", &c, {i32(5)}).(bool), true)

	// CompleteQuest sets the completed bit; Stop clears running once the VM runs the stop.
	script.call(&reg, "Quest", "CompleteQuest", &c, nil)
	testing.expect_value(t, script.call(&reg, "Quest", "IsCompleted", &c, nil).(bool), true)
	script.call(&reg, "Quest", "Stop", &c, nil)
	script.stop_quest(&c, c.self)
	testing.expect_value(t, script.call(&reg, "Quest", "IsRunning", &c, nil).(bool), false)

	// Reset wipes state back to baseline.
	script.call(&reg, "Quest", "Reset", &c, nil)
	testing.expect_value(t, script.call(&reg, "Quest", "GetCurrentStageID", &c, nil).(i32), i32(0))
	testing.expect_value(t, script.call(&reg, "Quest", "IsStageDone", &c, {i32(30)}).(bool), false)
	testing.expect_value(t, script.call(&reg, "Quest", "IsCompleted", &c, nil).(bool), false)
}

// BlockActivation sets the flag the engine reads before its default action; unblocking clears it,
// and the read-back native sees both.
@(test)
test_registry_block_activation :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB

	form := script.Form_ID(0x0001_2345)
	c := script.Call{self = form, ws = &ws, db = &db}
	is_blocked :: proc(reg: ^script.Registry, c: ^script.Call) -> bool {
		b, _ := script.call(reg, "ObjectReference", "IsActivationBlocked", c, nil).(bool)
		return b
	}

	testing.expect(t, !is_blocked(&reg, &c), "a baseline ref is not blocked")
	script.call(&reg, "ObjectReference", "BlockActivation", &c, nil) // abBlocked defaults to true
	testing.expect(t, worldstate.activation_blocked(&ws, form), "BlockActivation() blocks")
	testing.expect(t, is_blocked(&reg, &c), "IsActivationBlocked reads it")
	script.call(&reg, "ObjectReference", "BlockActivation", &c, []script.Value{false})
	testing.expect(t, !is_blocked(&reg, &c), "BlockActivation(false) unblocks")
}

// Activate queues the request for the app's next tick. It returns whether default processing will
// run: false on a blocked ref, true again when abDefaultProcessingOnly ignores the block.
@(test)
test_registry_activate_queues :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB

	lever := script.Form_ID(0x0001_2345)
	c := script.Call{self = lever, ws = &ws, db = &db}
	activate :: proc(reg: ^script.Registry, c: ^script.Call, args: []script.Value) -> bool {
		b, _ := script.call(reg, "ObjectReference", "Activate", c, args).(bool)
		return b
	}

	testing.expect(t, activate(&reg, &c, {formid.PLAYER}), "an unblocked ref will process")
	script.call(&reg, "ObjectReference", "BlockActivation", &c, nil)
	testing.expect(t, !activate(&reg, &c, {formid.PLAYER}), "a blocked ref will not")
	testing.expect(t, activate(&reg, &c, {formid.PLAYER, true}), "default-only ignores the block")

	testing.expect_value(t, len(ws.activations), 3)
	testing.expect_value(t, ws.activations[2], worldstate.Activation{target = lever, by = formid.PLAYER, default_only = true})
}

// A stub answers its fallback: Papyrus's value where the zero would be wrong, else the zero.
@(test)
test_registry_fallbacks :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB
	c := script.Call{self = script.Form_ID(1), ws = &ws, db = &db}

	testing.expect_value(t, script.call(&reg, "Actor", "GetLightLevel", &c, nil).(f32), f32(100))
	testing.expect_value(t, script.call(&reg, "Actor", "IsInCombat", &c, nil).(bool), false)
}

// Ref reads over a small world: an interior with a linked chain, and a worldspace whose persistent
// cell holds a ref standing over one grid cell.
@(test)
test_registry_ref_reads :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	F :: script.Form_ID
	INT, WORLD, PERSIST, GRID :: F(0x100), F(0x200), F(0x201), F(0x202)
	LOC, WORLD_LOC, KW, DOOR :: F(0x300), F(0x301), F(0x400), F(0x401)
	A, B, C, OUT :: F(0x500), F(0x501), F(0x502), F(0x503)

	db: gamedb.DB
	defer {
		delete(db.cells);delete(db.cell_at_grid);delete(db.world_location)
		delete(db.ref_by_id);delete(db.linked_refs);delete(db.doors)
	}
	db.cells[INT] = {form_id = INT, interior = true, location = LOC}
	db.cells[PERSIST] = {form_id = PERSIST, world_form_id = WORLD}
	db.cells[GRID] = {form_id = GRID, world_form_id = WORLD, has_grid = true}
	db.cell_at_grid[{WORLD, 0, 0}] = GRID
	db.world_location[WORLD] = WORLD_LOC
	db.ref_by_id[A] = {form_id = A, cell_form_id = INT, base = DOOR, rot = {0, 0, math.PI / 2}}
	db.ref_by_id[B] = {form_id = B, cell_form_id = INT, pos = {3, 4, 0}}
	db.ref_by_id[OUT] = {form_id = OUT, cell_form_id = PERSIST, pos = {100, 100, 0}}
	a_links := []gamedb.Linked_Ref{{0, B}, {KW, OUT}}
	b_links := []gamedb.Linked_Ref{{0, C}}
	db.linked_refs[A] = a_links
	db.linked_refs[B] = b_links
	db.doors[DOOR] = true

	a := script.Call{self = A, ws = &ws, db = &db}
	b := script.Call{self = B, ws = &ws, db = &db}
	out := script.Call{self = OUT, ws = &ws, db = &db}
	call :: proc(reg: ^script.Registry, c: ^script.Call, fn: string, args: ..script.Value) -> script.Value {
		return script.call(reg, "ObjectReference", fn, c, args)
	}

	testing.expect_value(t, call(&reg, &a, "GetDistance", B).(f32), f32(5))
	testing.expect_value(t, call(&reg, &a, "GetDistance", OUT).(f32), worldstate.FAR_DISTANCE)
	testing.expect_value(t, call(&reg, &a, "GetDistance", formid.PLAYER).(f32), worldstate.FAR_DISTANCE)
	worldstate.set_moved(&ws, formid.PLAYER, INT, {}, {0, 0, 10})
	testing.expect_value(t, call(&reg, &a, "GetDistance", formid.PLAYER).(f32), f32(10))

	testing.expect_value(t, call(&reg, &a, "GetLinkedRef").(F), B)
	testing.expect_value(t, call(&reg, &a, "GetLinkedRef", KW).(F), OUT)
	testing.expect_value(t, call(&reg, &a, "GetNthLinkedRef", i32(2)).(F), C)
	testing.expect(t, call(&reg, &a, "GetNthLinkedRef", i32(3)) == nil, "chain ends in None")

	testing.expect(t, abs(call(&reg, &a, "GetAngleZ").(f32) - 90) < 1e-4, "angle in degrees")
	call(&reg, &b, "SetPosition", f32(7), f32(8), f32(9))
	testing.expect_value(t, call(&reg, &b, "GetPositionY").(f32), f32(8))
	call(&reg, &a, "SetAngle", f32(10), f32(-20), f32(45))
	call(&reg, &a, "SetPosition", f32(1), f32(2), f32(3))
	testing.expect(t, abs(call(&reg, &a, "GetAngleY").(f32) + 20) < 1e-3 && abs(call(&reg, &a, "GetAngleZ").(f32) - 45) < 1e-3, "SetPosition keeps SetAngle's facing")
	call(&reg, &b, "MoveTo", A, f32(0), f32(0), f32(0), true)
	testing.expect(t, abs(call(&reg, &b, "GetAngleX").(f32) - 10) < 1e-3, "MoveTo matches the target's facing")

	testing.expect(t, call(&reg, &a, "GetWorldSpace") == nil, "an interior has no worldspace")
	testing.expect_value(t, call(&reg, &out, "GetWorldSpace").(F), WORLD)
	testing.expect_value(t, call(&reg, &a, "GetCurrentLocation").(F), LOC)
	testing.expect_value(t, call(&reg, &out, "GetCurrentLocation").(F), WORLD_LOC)
	testing.expect(t, call(&reg, &out, "GetParentCell") == nil, "an unattached exterior reads None")
	ws.attached[GRID] = make([dynamic]F)
	testing.expect_value(t, call(&reg, &out, "GetParentCell").(F), GRID)
	testing.expect_value(t, call(&reg, &out, "Is3DLoaded").(bool), true)

	testing.expect_value(t, call(&reg, &a, "GetBaseObject").(F), DOOR)
	testing.expect_value(t, call(&reg, &a, "GetOpenState").(i32), i32(3))
	call(&reg, &a, "SetOpen", true)
	testing.expect_value(t, call(&reg, &a, "GetOpenState").(i32), i32(1))
	testing.expect_value(t, call(&reg, &b, "GetOpenState").(i32), i32(0))
}

// Base-form reads: keywords through a ref's base, form lists with added forms, the location tree
// and its keyword data, race, and the game time from its global.
@(test)
test_registry_form_reads :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	F :: script.Form_ID
	REF, BASE, KW, LIST, X, Y, Z :: F(0x500), F(0x501), F(0x400), F(0x600), F(0x601), F(0x602), F(0x603)
	HOLD, CITY, ACTOR, NPC, RACE :: F(0x700), F(0x701), F(0x800), F(0x801), F(0x802)

	db: gamedb.DB
	defer {
		delete(db.ref_by_id);delete(db.keywords);delete(db.form_lists)
		delete(db.locations);delete(db.actors);delete(db.global_values)
	}
	kws := []F{KW}
	members := []F{X, Y}
	db.ref_by_id[REF] = {form_id = REF, base = BASE}
	db.ref_by_id[ACTOR] = {form_id = ACTOR, base = NPC}
	db.keywords[BASE] = kws
	db.form_lists[LIST] = members
	db.locations[CITY] = {parent = HOLD}
	db.actors[NPC] = {race = RACE}
	db.global_values[formid.GAME_DAYS_PASSED] = 3.5

	c := script.Call{self = REF, ws = &ws, db = &db}
	testing.expect_value(t, script.call(&reg, "Form", "HasKeyword", &c, {KW}).(bool), true)
	c.self = ACTOR
	testing.expect_value(t, script.call(&reg, "Actor", "GetRace", &c, nil).(F), RACE)

	c.self = LIST
	script.call(&reg, "FormList", "AddForm", &c, {Z})
	testing.expect_value(t, script.call(&reg, "FormList", "GetSize", &c, nil).(i32), i32(3))
	testing.expect_value(t, script.call(&reg, "FormList", "GetAt", &c, {i32(2)}).(F), Z)
	testing.expect_value(t, script.call(&reg, "FormList", "HasForm", &c, {Y}).(bool), true)
	script.call(&reg, "FormList", "Revert", &c, nil)
	testing.expect_value(t, script.call(&reg, "FormList", "HasForm", &c, {Z}).(bool), false)

	c.self = CITY
	testing.expect_value(t, script.call(&reg, "Location", "IsChild", &c, {HOLD}).(bool), true)
	script.call(&reg, "Location", "SetKeywordData", &c, {KW, f32(2)})
	testing.expect_value(t, script.call(&reg, "Location", "GetKeywordData", &c, {KW}).(f32), f32(2))

	testing.expect_value(t, script.call(&reg, "Utility", "GetCurrentGameTime", &c, nil).(f32), f32(3.5))
}

// MoveToWhenUnloaded waits while either location is loaded (an attached cell in it or in a child
// of it), and moves when the cell detaches.
@(test)
test_move_to_when_unloaded :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	F :: script.Form_ID
	HERE, THERE, HOLD, CITY, FAR, REF, TARGET :: F(0x100), F(0x101), F(0x300), F(0x301), F(0x302), F(0x500), F(0x501)

	db: gamedb.DB
	defer {delete(db.cells);delete(db.locations);delete(db.ref_by_id)}
	db.cells[HERE] = {form_id = HERE, interior = true, location = CITY}
	db.cells[THERE] = {form_id = THERE, interior = true, location = FAR}
	db.locations[CITY] = {parent = HOLD}
	db.ref_by_id[REF] = {form_id = REF, cell_form_id = HERE}
	db.ref_by_id[TARGET] = {form_id = TARGET, cell_form_id = THERE, pos = {1, 2, 3}}

	c := script.Call{self = HOLD, ws = &ws, db = &db}
	testing.expect_value(t, script.call(&reg, "Location", "IsLoaded", &c, nil).(bool), false)
	ws.attached[HERE] = make([dynamic]F)
	testing.expect_value(t, script.call(&reg, "Location", "IsLoaded", &c, nil).(bool), true)

	c.self = REF
	script.call(&reg, "ObjectReference", "MoveToWhenUnloaded", &c, {TARGET, f32(0), f32(0), f32(10)})
	testing.expect(t, REF in ws.pending_moves, "waits while its location is loaded")
	script.settle_moves(&db, &ws)
	testing.expect(t, REF in ws.pending_moves, "still attached, still waiting")

	delete(ws.attached[HERE])
	delete_key(&ws.attached, HERE)
	script.settle_moves(&db, &ws)
	testing.expect(t, REF not_in ws.pending_moves, "moved once both unloaded")
	d, _ := worldstate.get(&ws, REF)
	testing.expect_value(t, d.cell, THERE)
	testing.expect_value(t, d.pos, [3]f32{1, 2, 13})
}

// Game.GetFormFromFile puts a plugin-local id in the plugin's slot, whatever the case of its name;
// a plugin that is not loaded gives None.
@(test)
test_registry_get_form_from_file :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	db: gamedb.DB
	db.plugin_slots = make(map[string]u32)
	defer delete(db.plugin_slots)
	db.plugin_slots["dawnguard.esm"] = 2

	c := script.Call{db = &db}
	got := script.call(&reg, "Game", "GetFormFromFile", &c, {i32(0x016691), "Dawnguard.esm"})
	testing.expect_value(t, got.(script.Form_ID), script.Form_ID(0x2_0001_6691))
	testing.expect_value(t, script.call(&reg, "Game", "GetFormFromFile", &c, {i32(0x016691), "Nope.esp"}), nil)
}

// Words of power: taught is not unlocked. Beast form and the vampire and werewolf states are kept,
// and all of it saves.
@(test)
test_registry_magic_state :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB
	WORD, NPC :: script.Form_ID(0x602), script.Form_ID(0x700)
	c := script.Call{ws = &ws, db = &db}

	script.call(&reg, "Game", "TeachWord", &c, {WORD})
	testing.expect(t, worldstate.word_taught(&ws, formid.PLAYER, WORD), "taught")
	testing.expect_value(t, script.call(&reg, "Game", "IsWordUnlocked", &c, {WORD}).(bool), false)
	script.call(&reg, "Game", "UnlockWord", &c, {WORD})
	script.call(&reg, "Game", "SetBeastForm", &c, {true})
	c.self = NPC
	script.call(&reg, "Actor", "SendVampirismStateChanged", &c, {true})
	script.call(&reg, "Actor", "SendLycanthropyStateChanged", &c, {true})
	script.call(&reg, "Actor", "SendLycanthropyStateChanged", &c, {false})

	path := "test_magic_state.skysave"
	defer os.remove(path)
	testing.expect(t, worldstate.save_to_file(&ws, path, {save_number = 1}), "save")
	_, ok := worldstate.load_from_file(&ws, path)
	testing.expect(t, ok, "load")
	testing.expect_value(t, script.call(&reg, "Game", "IsWordUnlocked", &c, {WORD}).(bool), true)
	testing.expect(t, ws.beast_form && NPC in ws.vampires && NPC not_in ws.werewolves, "beast form, vampire, not a werewolf")
}

// Casting (the scaffold): the spell in a hand costs its magicka and lands at once, a Self spell on
// the caster; a caster that cannot pay casts nothing.
@(test)
test_cast_hand :: proc(t: ^testing.T) {
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB
	CASTER, HEAL, MGEF :: script.Form_ID(0x700), script.Form_ID(0x800), script.Form_ID(0x900)
	db.equip_slots = make(map[gamedb.Form_ID]gamedb.Equip_Slot, context.temp_allocator)
	db.equip_slots[HEAL] = {kind = .Spell, etyp = gamedb.EQUP_LEFT_HAND}
	db.spells = make(map[gamedb.Form_ID]gamedb.Spell, context.temp_allocator)
	db.spells[HEAL] = {info = {cost = 30, cast_type = .Fire_And_Forget, delivery = .Self}, effects = []gamedb.Magic_Effect_Ref{{effect = MGEF, duration = 1}}}
	worldstate.av_set_base(&ws, CASTER, "Magicka", 50)
	worldstate.equip(&ws, &db, CASTER, HEAL)
	c := script.Call{ws = &ws, db = &db}

	testing.expect(t, script.cast_hand(&c, CASTER, .LeftHand, 0), "cast")
	testing.expect_value(t, worldstate.av_current(&ws, &db, CASTER, "Magicka"), 20)
	testing.expect_value(t, len(worldstate.effects_on(&ws, CASTER)), 1)
	testing.expect(t, !script.cast_hand(&c, CASTER, .LeftHand, 0), "cannot pay")
}

// A location is cleared once every one of its Boss refs is dead (CK IsCleared).
@(test)
test_boss_death_clears_location :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	LOC, BOSS_A, BOSS_B :: script.Form_ID(0xB00), script.Form_ID(0xB01), script.Form_ID(0xB02)
	db: gamedb.DB
	db.locations = make(map[gamedb.Form_ID]gamedb.Location)
	defer delete(db.locations)
	specials := []gamedb.Special_Ref{{formid.LOC_REF_BOSS, BOSS_A}, {formid.LOC_REF_BOSS, BOSS_B}}
	db.locations[LOC] = {special_refs = specials}

	loc := script.Call{self = LOC, ws = &ws, db = &db}
	a := script.Call{self = BOSS_A, ws = &ws, db = &db}
	b := script.Call{self = BOSS_B, ws = &ws, db = &db}
	script.call(&reg, "Actor", "Kill", &a, nil)
	testing.expect_value(t, script.call(&reg, "Location", "IsCleared", &loc, nil).(bool), false)
	script.call(&reg, "Actor", "Kill", &b, nil)
	testing.expect_value(t, script.call(&reg, "Location", "IsCleared", &loc, nil).(bool), true)
	e := ws.story_events[len(ws.story_events) - 1]
	testing.expect(t, e.type == worldstate.STORY_KILL && e.ref1 == BOSS_B, "a death is a KILL story event")
}

// Courier.RemoveRef waits while the courier talks to the player, then gives the item.
@(test)
test_courier_waits_for_dialogue :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB
	COURIER, BAG, LETTER :: script.Form_ID(0xC01), script.Form_ID(0xC02), script.Form_ID(0xC03)
	c := script.Call{ws = &ws, db = &db}
	script.move_items(&c, {base = LETTER, to = BAG, count = 1})
	ws.talking = COURIER
	script.call(&reg, "Courier", "RemoveRef", &c, {COURIER, BAG, LETTER, true, script.Form_ID(0)})
	script.tick_courier(&c)
	testing.expect_value(t, worldstate.inv_count(&ws, &db, formid.PLAYER, LETTER), i32(0))
	ws.talking = 0
	script.tick_courier(&c)
	testing.expect_value(t, worldstate.inv_count(&ws, &db, formid.PLAYER, LETTER), i32(1))
	e := ws.story_events[len(ws.story_events) - 1]
	testing.expect(t, e.type == worldstate.STORY_ADD_ITEM && e.value1 == 0 && e.ref2 == BAG, "a script's give is AIPL, acquire type none")
	script.move_items(&c, {base = LETTER, to = formid.PLAYER, count = 1, via = .World})
	e = ws.story_events[len(ws.story_events) - 1]
	testing.expect_value(t, e.value1, i32(4)) // picked up from the world
}

// A placed actor is in its NPC_'s factions (the ref, not only the base, answers).
@(test)
test_placed_actor_factions :: proc(t: ^testing.T) {
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	REF, NPC, SHOP :: gamedb.Form_ID(0xD01), gamedb.Form_ID(0xD02), gamedb.Form_ID(0xD03)
	db: gamedb.DB
	db.ref_by_id = make(map[gamedb.Form_ID]gamedb.Ref)
	db.actors = make(map[gamedb.Form_ID]gamedb.Actor_Base)
	defer {delete(db.ref_by_id);delete(db.actors)}
	db.ref_by_id[REF] = {form_id = REF, base = NPC}
	db.actors[NPC] = {factions = []gamedb.Faction_Membership{{SHOP, 0}}}
	testing.expect(t, worldstate.in_faction(&ws, &db, REF, SHOP), "the ref is in its base's faction")
	testing.expect_value(t, len(worldstate.actor_factions_now(&ws, &db, REF)), 1)
}

// Query natives read the stores their setters write, and a condition reads the same one.
@(test)
test_registry_queries :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB
	NPC :: script.Form_ID(0x0001_0000)
	LIST :: script.Form_ID(0x0001_0001)
	FACTION :: script.Form_ID(0x0001_0002)
	db.actors = make(map[gamedb.Form_ID]gamedb.Actor_Base)
	db.factions = make(map[gamedb.Form_ID]gamedb.Faction)
	defer {delete(db.actors);delete(db.factions)}
	db.actors[NPC] = {flags = esm.ACBS_ESSENTIAL}
	db.factions[FACTION] = {}

	c := script.Call{self = LIST, ws = &ws, db = &db}
	testing.expect_value(t, script.call(&reg, "FormList", "Find", &c, {NPC}), script.Value(i32(-1)))
	worldstate.add_to_list(&ws, LIST, NPC)
	testing.expect_value(t, script.call(&reg, "FormList", "Find", &c, {NPC}), script.Value(i32(0)))

	actor := worldstate.create_ref(&ws, NPC, 0, {}, {}, 1)
	a := script.Call{self = actor, ws = &ws, db = &db}
	base := script.Call{self = NPC, ws = &ws, db = &db}
	testing.expect_value(t, script.call(&reg, "Actor", "IsEssential", &a, nil), script.Value(bool(true)))
	script.call(&reg, "ActorBase", "SetEssential", &base, {false})
	testing.expect_value(t, script.call(&reg, "Actor", "IsEssential", &a, nil), script.Value(bool(false)))
	script.call(&reg, "Actor", "SetGhost", &a, {true})
	testing.expect_value(t, script.call(&reg, "Actor", "IsGhost", &a, nil), script.Value(bool(true)))
	testing.expect_value(t, script.call(&reg, "ActorBase", "IsInvulnerable", &base, nil), script.Value(bool(false)))
	ctx := conditions.Context{db = &db, ws = &ws, subject = actor}
	ghost := []gamedb.Condition{{function = 237, op = .Equal, value = 1}}
	testing.expect(t, conditions.all(&ctx, ghost), "GetIsGhost reads SetGhost")

	thing := script.Call{self = script.Form_ID(0x0001_0003), ws = &ws, db = &db}
	script.call(&reg, "ObjectReference", "SetFactionOwner", &thing, {FACTION})
	testing.expect_value(t, script.call(&reg, "ObjectReference", "GetFactionOwner", &thing, nil), script.Value(FACTION))
	testing.expect_value(t, script.call(&reg, "ObjectReference", "GetActorOwner", &thing, nil), script.Value(nil))

	worldstate.advance_clock(&ws, 2, 20)
	testing.expect_value(t, script.call(&reg, "Utility", "GetCurrentRealTime", &c, nil), script.Value(f32(2)))

	CHILD :: script.Form_ID(0x0001_0004)
	db.relationships = make(map[[2]gamedb.Form_ID]gamedb.Relationship)
	defer delete(db.relationships)
	db.relationships[{NPC, CHILD}] = {association = formid.ASSOC_PARENT_CHILD, parent = NPC}
	child := script.Call{self = CHILD, ws = &ws, db = &db}
	testing.expect_value(t, script.call(&reg, "Actor", "HasParentRelationship", &base, {CHILD}), script.Value(bool(true)))
	testing.expect_value(t, script.call(&reg, "Actor", "HasParentRelationship", &child, {NPC}), script.Value(bool(false)))
}
