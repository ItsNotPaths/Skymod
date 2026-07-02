package unit_tests

// Console REPL (Phase 4) — the native-testing loop itself, tested headless. Proves:
// bare-expression echo, print capture, ref identity + method dispatch through the
// overlay, None absorption, selection-defaulted commands, and the CE preprocessor.
// Synthetic: empty baseline DB, no game files, no imgui.

import "core:strings"
import "core:testing"
import "../../src/gamedb"
import "../../src/script"
import slua "../../src/script/lua"
import "../../src/worldstate"

@(private = "file")
setup :: proc(repl: ^slua.Repl, ws: ^worldstate.World_State, db: ^gamedb.DB, reg: ^script.Registry) -> bool {
	script.init(reg)
	worldstate.init(ws)
	return slua.repl_init(repl, reg, script.Call{ws = ws, db = db})
}

// joined concatenates the captured output lines with '\n' (temp) for easy asserts.
@(private = "file")
joined :: proc(lines: []string) -> string {
	return strings.join(lines, "\n", context.temp_allocator)
}

@(test)
test_repl_expression_echo :: proc(t: ^testing.T) {
	repl: slua.Repl
	ws: worldstate.World_State
	db: gamedb.DB
	reg: script.Registry
	testing.expect(t, setup(&repl, &ws, &db, &reg), "repl init")
	defer {slua.repl_destroy(&repl);worldstate.destroy(&ws);script.destroy(&reg)}

	testing.expect_value(t, joined(slua.repl_eval(&repl, "1 + 2")), "3")
	testing.expect_value(t, joined(slua.repl_eval(&repl, `print("hi")`)), "hi")
	// An error is captured, not thrown.
	out := joined(slua.repl_eval(&repl, "nope("))
	testing.expect(t, strings.has_prefix(out, "!"), "syntax error captured")
}

@(test)
test_repl_ref_identity_and_dispatch :: proc(t: ^testing.T) {
	repl: slua.Repl
	ws: worldstate.World_State
	db: gamedb.DB
	reg: script.Registry
	testing.expect(t, setup(&repl, &ws, &db, &reg), "repl init")
	defer {slua.repl_destroy(&repl);worldstate.destroy(&ws);script.destroy(&reg)}

	// The player global and Game.GetPlayer() are the SAME cached userdata → == holds.
	testing.expect_value(t, joined(slua.repl_eval(&repl, "player == Game.GetPlayer()")), "true")

	// Method dispatch through a ref writes the overlay (player:Disable()).
	slua.repl_eval(&repl, "player:Disable()")
	d, found := worldstate.get(&ws, script.PLAYER)
	testing.expect(t, found && .Disabled in d.live && d.disabled, "player:Disable() wrote overlay")
}

@(test)
test_repl_none_absorption :: proc(t: ^testing.T) {
	repl: slua.Repl
	ws: worldstate.World_State
	db: gamedb.DB
	reg: script.Registry
	testing.expect(t, setup(&repl, &ws, &db, &reg), "repl init")
	defer {slua.repl_destroy(&repl);worldstate.destroy(&ws);script.destroy(&reg)}

	// None prints as None, absorbs method calls (returning None), and == None.
	testing.expect_value(t, joined(slua.repl_eval(&repl, "None")), "None")
	testing.expect_value(t, joined(slua.repl_eval(&repl, "tostring(None:Whatever())")), "None")
	testing.expect_value(t, joined(slua.repl_eval(&repl, "None == None")), "true")
	// ref(0) is None (a null form reads as None everywhere).
	testing.expect_value(t, joined(slua.repl_eval(&repl, "ref(0) == None")), "true")
}

@(test)
test_repl_selection_default :: proc(t: ^testing.T) {
	repl: slua.Repl
	ws: worldstate.World_State
	db: gamedb.DB
	reg: script.Registry
	testing.expect(t, setup(&repl, &ws, &db, &reg), "repl init")
	defer {slua.repl_destroy(&repl);worldstate.destroy(&ws);script.destroy(&reg)}

	// cmd.disable() with no arg acts on the current selection (CE semantics).
	form := script.Form_ID(0x0004_4444)
	slua.repl_set_selection(&repl, form)
	slua.repl_eval(&repl, "cmd.disable()")
	d, found := worldstate.get(&ws, form)
	testing.expect(t, found && .Disabled in d.live, "cmd.disable() targeted the selection")

	// The native ALSO enqueues the form for deferred live-apply (decision #3): the overlay write
	// alone is invisible; this is what makes the app's per-frame drain hide the resident instance.
	pending := worldstate.pending_scene(&ws)
	found_pending := false
	for f in pending {
		if f == form {found_pending = true}
	}
	testing.expect(t, found_pending, "disable enqueued the form for deferred scene-apply")

	// A ref echoes as [Class 0xFORMID …]; the selection's id shows up in tostring.
	out := joined(slua.repl_eval(&repl, "sel"))
	testing.expect(t, strings.contains(out, "00044444"), "sel prints its form id")

	// End-to-end CE wiring: a BARE `enable` (no parens) preprocesses to cmd.enable() → sel:Enable()
	// → overlay, flipping the Disabled delta off.
	slua.repl_eval(&repl, "enable")
	d2, _ := worldstate.get(&ws, form)
	testing.expect(t, .Disabled in d2.live && !d2.disabled, "bare CE `enable` re-enabled the selection")

	// `prid <id>` selects a ref by form id (the preprocessor wraps the hex in ref()).
	slua.repl_eval(&repl, "prid 0x000539a8")
	sout := joined(slua.repl_eval(&repl, "sel"))
	testing.expect(t, strings.contains(sout, "000539A8"), "prid selected the ref by id")
}

// End-to-end quest dispatch: a bare form handle whose gamedb kind is Quest resolves methods up the
// {Quest, Form} chain — the console path for save debugging. Proves gamedb.form_kind → method_class →
// call() all connect for a NON-object-ref class. (Without the form-kind map, GetCurrentStageID would
// miss the object-ref chain and error as an unknown native.)
@(test)
test_repl_quest_dispatch :: proc(t: ^testing.T) {
	repl: slua.Repl
	ws: worldstate.World_State
	reg: script.Registry
	// A DB that classifies one form as a Quest (form_kinds is a plain field — no full ESM build needed).
	quest := gamedb.Form_ID(0x000C_0DE0)
	db: gamedb.DB
	db.form_kinds = make(map[gamedb.Form_ID]gamedb.Form_Kind)
	db.form_kinds[quest] = .Quest
	defer delete(db.form_kinds)

	testing.expect(t, setup(&repl, &ws, &db, &reg), "repl init")
	defer {slua.repl_destroy(&repl);worldstate.destroy(&ws);script.destroy(&reg)}

	// Set a stage through a bare quest handle, then read it back — routes to Quest.*, not ObjectReference.
	// Start() first: SetCurrentStageID only advances a running quest (this DB has no baseline SGE flag).
	slua.repl_eval(&repl, "q = ref(0x000C0DE0)")
	slua.repl_eval(&repl, "q:Start()")
	slua.repl_eval(&repl, "q:SetCurrentStageID(30)")
	testing.expect_value(t, worldstate.quest_stage(&ws, quest), u16(30))
	testing.expect_value(t, joined(slua.repl_eval(&repl, "q:GetCurrentStageID()")), "30")
	// The skymod extension is reachable the same way.
	slua.repl_eval(&repl, "q:SetCurrentStageID(20)")
	testing.expect_value(t, joined(slua.repl_eval(&repl, "q:GetCurrentStageID()")), "30") // highest
	testing.expect_value(t, joined(slua.repl_eval(&repl, "q:GetRecentStageID()")), "20") // last-set
}

@(test)
test_preprocess_ce_shapes :: proc(t: ^testing.T) {
	tmp := context.temp_allocator
	// No-arg toggles + help.
	testing.expect_value(t, slua.preprocess("tcl", tmp), "cmd.noclip()")
	testing.expect_value(t, slua.preprocess("TGM", tmp), "cmd.god()")
	testing.expect_value(t, slua.preprocess("help", tmp), "cmd.help()")
	// Bare CE selection verbs → cmd.* (act on sel).
	testing.expect_value(t, slua.preprocess("disable", tmp), "cmd.disable()")
	testing.expect_value(t, slua.preprocess("markfordelete", tmp), "cmd.delete()")
	testing.expect_value(t, slua.preprocess("setscale 2", tmp), "cmd.scale(2)")
	// Ref-arg CE commands: bare hex args wrap in ref(); decimals pass through.
	testing.expect_value(t, slua.preprocess("moveto 0x14", tmp), "cmd.moveto(ref(0x14))")
	testing.expect_value(t, slua.preprocess("prid 0x1a26f", tmp), "cmd.prid(ref(0x1a26f))")
	// Bare hex alone echoes a ref.
	testing.expect_value(t, slua.preprocess("0x1a26f", tmp), "ref(0x1a26f)")
	// Dotted obj.method with a hex form arg + a decimal count.
	testing.expect_value(t, slua.preprocess("player.additem 0xf 100", tmp), "player:additem(ref(0xf), 100)")
	testing.expect_value(t, slua.preprocess("sel.setscale 2", tmp), "sel:setscale(2)")
	testing.expect_value(t, slua.preprocess("0x1a26f.disable", tmp), "ref(0x1a26f):disable()")
	// Anything Lua-shaped ('(' or '=') passes through untouched — never mangled.
	testing.expect_value(t, slua.preprocess("print(1+2)", tmp), "print(1+2)")
	testing.expect_value(t, slua.preprocess("sel:Disable()", tmp), "sel:Disable()")
	testing.expect_value(t, slua.preprocess("x = 5", tmp), "x = 5")
}
