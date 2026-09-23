package unit_tests

// Script-registry tests (Phase 4). Hermetic + SYNTHETIC: drive native calls
// directly through the VM-agnostic dispatch and assert they land in the worldstate
// overlay — no Lua VM, no game files. The 674-native manifest is the committed
// generated artifact; we assert auto-stub coverage + that the hot set mutates +
// reads through baseline⊕overlay + case-insensitive dispatch.

import "core:log"
import "core:testing"
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
	// Declared but no body yet -> known, not implemented. (EquipItem is a Phase-7 actor verb we
	// deliberately left stubbed — swap this if it ever gets a real body.)
	testing.expect(t, script.is_declared(&reg, "Actor", "EquipItem"), "EquipItem declared")
	testing.expect(t, !script.is_implemented(&reg, "Actor", "EquipItem"), "EquipItem not impl")
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
	testing.expect_value(t, pf, script.PLAYER)
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
	// Over-removal clamps at 0 (drops the entry, never negative).
	script.call(&reg, "ObjectReference", "RemoveItem", &c, {item, i32(100)})
	testing.expect_value(t, count(&reg, &c, item), i32(0))

	// Gold amount reads the Gold001 count; RemoveAllItems wipes everything.
	script.call(&reg, "ObjectReference", "AddItem", &c, {script.GOLD, i32(250)})
	testing.expect_value(t, script.call(&reg, "Actor", "GetGoldAmount", &c, nil).(i32), i32(250))
	script.call(&reg, "ObjectReference", "RemoveAllItems", &c, nil)
	testing.expect_value(t, script.call(&reg, "Actor", "GetGoldAmount", &c, nil).(i32), i32(0))
}

// Actor-value store: set/get (case-insensitive), mod/damage, base==current, percentage placeholder.
@(test)
test_registry_actor_value :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB

	actor := script.Form_ID(0x0006_0000)
	c := script.Call{self = actor, ws = &ws, db = &db}
	av :: proc(reg: ^script.Registry, c: ^script.Call, name: string) -> f32 {
		return script.call(reg, "Actor", "GetActorValue", c, {name}).(f32)
	}

	script.call(&reg, "Actor", "SetActorValue", &c, {"Health", f32(100)})
	testing.expect_value(t, av(&reg, &c, "Health"), f32(100))
	testing.expect_value(t, av(&reg, &c, "health"), f32(100)) // case-insensitive
	script.call(&reg, "Actor", "ModActorValue", &c, {"Health", f32(25)})
	testing.expect_value(t, av(&reg, &c, "Health"), f32(125))
	script.call(&reg, "Actor", "DamageActorValue", &c, {"Health", f32(50)})
	testing.expect_value(t, av(&reg, &c, "Health"), f32(75))
	// GetBaseActorValue reads the same store (no base/current split yet).
	testing.expect_value(t, script.call(&reg, "Actor", "GetBaseActorValue", &c, {"Health"}).(f32), f32(75))
	// Unset AV reads 0; percentage is 1.0 for a set AV, 0 for an unset one (placeholder, no max data).
	testing.expect_value(t, av(&reg, &c, "Stamina"), f32(0))
	testing.expect_value(t, script.call(&reg, "Actor", "GetActorValuePercentage", &c, {"Health"}).(f32), f32(1))
	testing.expect_value(t, script.call(&reg, "Actor", "GetActorValuePercentage", &c, {"Magicka"}).(f32), f32(0))
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
	stages := make(map[u16]bool)
	stages[10] = false
	stages[20] = true
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

	// Reaching a Complete-flagged stage marks the quest completed (baseline stage flag).
	testing.expect_value(t, script.call(&reg, "Quest", "SetCurrentStageID", &c, {i32(20)}).(bool), true)
	testing.expect_value(t, script.call(&reg, "Quest", "IsCompleted", &c, nil).(bool), true)

	// CompleteAllObjectives reaches the baseline (QOBJ) objectives even though none was individually set.
	script.call(&reg, "Quest", "CompleteAllObjectives", &c, nil)
	testing.expect_value(t, script.call(&reg, "Quest", "IsObjectiveCompleted", &c, {i32(5)}).(bool), true)
	testing.expect_value(t, script.call(&reg, "Quest", "IsObjectiveCompleted", &c, {i32(15)}).(bool), true)

	// Explicit Stop overrides the baseline SGE; a stopped quest ignores SetCurrentStageID.
	script.call(&reg, "Quest", "Stop", &c, nil)
	testing.expect_value(t, script.call(&reg, "Quest", "IsRunning", &c, nil).(bool), false)
	testing.expect_value(t, script.call(&reg, "Quest", "SetCurrentStageID", &c, {i32(10)}).(bool), false)
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

	// CompleteQuest sets the completed bit; Stop clears running.
	script.call(&reg, "Quest", "CompleteQuest", &c, nil)
	testing.expect_value(t, script.call(&reg, "Quest", "IsCompleted", &c, nil).(bool), true)
	script.call(&reg, "Quest", "Stop", &c, nil)
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

	testing.expect(t, activate(&reg, &c, {script.PLAYER}), "an unblocked ref will process")
	script.call(&reg, "ObjectReference", "BlockActivation", &c, nil)
	testing.expect(t, !activate(&reg, &c, {script.PLAYER}), "a blocked ref will not")
	testing.expect(t, activate(&reg, &c, {script.PLAYER, true}), "default-only ignores the block")

	testing.expect_value(t, len(ws.activations), 3)
	testing.expect_value(t, ws.activations[2], worldstate.Activation{target = lever, by = script.PLAYER, default_only = true})
}
