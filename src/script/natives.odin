package script

// The implemented native hot set — the call-frequency leaders from the validated
// corpus histogram (see pex-reader-built memory), the ones that map cleanly onto
// the existing worldstate overlay. The long tail stays auto-stubbed (registry.odin)
// until a real script needs it; verbs that need a store we don't have yet
// (inventory, quest stages, actor values, quest aliases) are intentionally absent
// so they log as "unimplemented" rather than silently no-op.

import "core:log"
import "../gamedb"
import smath "../math"
// HOLE(audio, blocker): Sound.Play/PlayAndWait, SoundCategory — no audio subsystem. 587 closure sites.
// HOLE(audio, blocker): the script side rides this subsystem — whether a sound's completion is OBSERVABLE (can a guard test it?) and whether Play finishes inside one tick are answerable only once audio exists. Rewriting the scripts that use it waits on the same landing. See docs/script-rewrite.md step 2.
// HOLE(vfx, blocker): EffectShader.Play (551), VisualEffect (551), ImageSpaceModifier (221) — no VFX.
// HOLE(animation, blocker): PlayAnimation (296) + PlayAnimationAndWait (309) — no animation system. An absent subsystem's completion predicate must answer DONE or rewrites poll forever.
// HOLE(animation, blocker): the script side rides this subsystem — a guard needs a testable "is this clip done", and whether PlayAnimation completes in one tick is an animation decision. Rewrite those scripts here, not before.
// HOLE(ai, blocker): Actor.EvaluatePackage (165), package and combat natives — await the actor phase.
// HOLE(ai, blocker): the script side rides this subsystem — PathToReference needs an observable arrival fact, and pathing is the one native class whose completion time is genuinely not ours to choose.
// HOLE(magic, blocker): Cast/AddSpell/RemoveSpell — MGEF records indexed, the subsystem that applies them is not.

// Stubbed writes that no native can read back, so no guard can test them. Each needs a paired
// read (docs/script-rewrite.md step 2 item 2; the `bucket` column of natives-classified.tsv).
// HOLE(combat): no read for Start/EndDeferredKill, SetCriticalStage, AttachAshPile, SetActorCause, Faction.SetPlayerEnemy, SetPlayerResistingArrest, ClearPrison, SetPlayerReportCrime.
// HOLE(ai): no read for SetDontMove, SetRestrained, SetNotShowOnStealthMeter, ActorBase.SetOutfit, SetAllowFlyingMountLandingRequests.
// HOLE(dialogue): no read for AllowPCDialogue, AllowBleedoutDialogue, SetNoFavorAllowed.
// HOLE(magic): no read for SetBeastForm, TeachWord (taught is not unlocked), SendLycanthropy/VampirismStateChanged.
// HOLE(physics): no read for SetMotionType, StopTranslation (no IsTranslating), TetherToHorse, Add/RemoveHavokConstraints.
// HOLE(world): no read for Cell.SetPublic, Cell.Reset.
// HOLE(render): no camera read for ForceFirstPerson/ForceThirdPerson, SetCameraTarget, ShowFirstPersonGeometry.
// HOLE(animation): no read for SetSittingRotation.
// HOLE(save): no read for RequestSave/RequestAutoSave (queued; nothing says the save ran).
// HOLE(assets): no read for RequestModel (queued; nothing says the model loaded).
// HOLE(ui): no read for SetInChargen, AddAchievement, Quest.UpdateCurrentInstanceGlobal.
// HOLE(script): no read for AdvanceSkill (skill XP), AddPerkPoints, the four SetINI*.

import "../worldstate"

register_builtins :: proc(reg: ^Registry) {
	// ObjectReference — the instance-method bulk of the corpus.
	register(reg, "ObjectReference", "Disable", n_disable)
	register(reg, "ObjectReference", "Enable", n_enable)
	register(reg, "ObjectReference", "IsDisabled", n_is_disabled)
	register(reg, "ObjectReference", "Is3DLoaded", n_is_3d_loaded)
	register(reg, "ObjectReference", "SetScale", n_set_scale)
	register(reg, "ObjectReference", "GetScale", n_get_scale)
	register(reg, "ObjectReference", "Delete", n_delete)
	// HOLE(world): DeleteWhenAble deletes at once and the converted MoveToWhenUnloaded polls; both become
	// engine facts, "delete when detached" and "move when both unloaded" (docs/script-rewrite.md).
	register(reg, "ObjectReference", "DeleteWhenAble", n_delete)
	register(reg, "ObjectReference", "MoveTo", n_move_to)
	register(reg, "ObjectReference", "Lock", n_lock)
	register(reg, "ObjectReference", "IsLocked", n_is_locked)
	register(reg, "ObjectReference", "SetOpen", n_set_open)
	register(reg, "ObjectReference", "Activate", n_activate)
	register(reg, "Form", "RegisterForSingleUpdate", n_register_single_update)
	register(reg, "Form", "RegisterForUpdate", n_register_update)
	register(reg, "Form", "UnregisterForUpdate", n_unregister_for_update)
	register(reg, "ObjectReference", "BlockActivation", n_block_activation)
	register(reg, "ObjectReference", "IsActivationBlocked", n_is_activation_blocked)

	// Game / Debug — the top globals (callstatic), self is unused (0).
	register(reg, "Game", "GetPlayer", n_get_player)
	register(reg, "Debug", "Trace", n_trace)
	register(reg, "Debug", "Notification", n_notification)

	register(reg, "Message", "Show", n_message_show)

	register_math(reg) // Math.* — pure callstatic leaves
	register_quest(reg) // Quest.* — the quest-state store
	register_alias(reg) // quest aliases
	register_stores(reg) // GlobalVariable / Actor life / PlaceAtMe (A-tier overlay)
	register_inventory(reg) // ObjectReference/Actor inventory store
	register_actor(reg) // Actor values + faction/relationship store
}

// ── ObjectReference verbs (write through the overlay) ────────────────────────

n_disable :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_disabled(c.ws, c.self, ref_cell(c, c.self), true)
	worldstate.mark_scene_dirty(c.ws, c.self)
	return nil
}

n_enable :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_disabled(c.ws, c.self, ref_cell(c, c.self), false)
	worldstate.mark_scene_dirty(c.ws, c.self)
	return nil
}

n_is_disabled :: proc(c: ^Call, args: []Value) -> Value {
	return !ref_enabled(c.ws, c.db, c.self)
}

// n_is_3d_loaded: an enabled ref whose cell is attached to the player's scene.
n_is_3d_loaded :: proc(c: ^Call, args: []Value) -> Value {
	r, ok := gamedb.ref_by_formid(c.db, c.self)
	return ok && gamedb.ref_attach_cell(c.db, r) in c.ws.attached && ref_enabled(c.ws, c.db, c.self)
}

// ref_enabled is a ref's current enable state: a script's Enable/Disable wins, else the baseline
// (the REFR flag, a deletion, or its enable parent).
ref_enabled :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, form: Form_ID) -> bool {
	if d, ok := worldstate.get(ws, form); ok && .Disabled in d.live {
		return !d.disabled
	}
	r, ok := gamedb.ref_by_formid(db, form)
	return !ok || !gamedb.ref_effective_disabled(db, r) // a ref with no baseline (created) is enabled
}

// HOLE(script, gap): RegisterForSingleUpdateGameTime / RegisterForUpdateGameTime are stubs; game-hour timers wait on the game clock (HOLE(world)).

n_register_single_update :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.register_update(c.ws, c.self, arg_f32(args, 0, 0), false)
	return nil
}

n_register_update :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.register_update(c.ws, c.self, arg_f32(args, 0, 0), true)
	return nil
}

n_unregister_for_update :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.unregister_updates(c.ws, c.self)
	return nil
}

// n_activate queues the activation for the app's next tick. It returns whether default processing
// will run: false when blocked, unless abDefaultProcessingOnly ignores the block.
n_activate :: proc(c: ^Call, args: []Value) -> Value {
	default_only := arg_bool(args, 1, false)
	worldstate.request_activation(c.ws, c.self, arg_form(args, 0), default_only)
	return default_only || !worldstate.activation_blocked(c.ws, c.self)
}

n_block_activation :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_activation_blocked(c.ws, c.self, ref_cell(c, c.self), arg_bool(args, 0, true))
	return nil
}

n_is_activation_blocked :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.activation_blocked(c.ws, c.self)
}

n_set_scale :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_scale(c.ws, c.self, ref_cell(c, c.self), arg_f32(args, 0, 1))
	worldstate.mark_scene_dirty(c.ws, c.self)
	return nil
}

n_get_scale :: proc(c: ^Call, args: []Value) -> Value {
	if d, ok := worldstate.get(c.ws, c.self); ok && .Scaled in d.live {
		return d.scale
	}
	if r, ok := gamedb.ref_by_formid(c.db, c.self); ok {
		return r.scale
	}
	return f32(1)
}

n_delete :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_deleted(c.ws, c.self, ref_cell(c, c.self))
	worldstate.mark_scene_dirty(c.ws, c.self)
	return nil
}

// MoveTo(akTarget, afXOffset, afYOffset, afZOffset, abMatchRotation). First slice:
// teleport self to the target ref's (overlay⊕baseline) position + offsets; self
// lands in the target's cell. Rotation-match is deferred (identity orientation).
n_move_to :: proc(c: ^Call, args: []Value) -> Value {
	target := arg_form(args, 0)
	dst := ref_pos(c, target)
	dst += smath.Vec3{arg_f32(args, 1, 0), arg_f32(args, 2, 0), arg_f32(args, 3, 0)}
	worldstate.set_moved(c.ws, c.self, ref_cell(c, target), smath.translate(dst), dst)
	worldstate.mark_scene_dirty(c.ws, c.self)
	return nil
}

n_lock :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_locked(c.ws, c.self, ref_cell(c, c.self), arg_bool(args, 0, true))
	return nil
}

n_is_locked :: proc(c: ^Call, args: []Value) -> Value {
	if d, ok := worldstate.get(c.ws, c.self); ok && .Locked in d.live {
		return d.locked
	}
	return false // no baseline lock-state surfaced yet
}

n_set_open :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_open(c.ws, c.self, ref_cell(c, c.self), arg_bool(args, 0, true))
	return nil
}

// ── Game / Debug globals ─────────────────────────────────────────────────────

n_get_player :: proc(c: ^Call, args: []Value) -> Value {
	return PLAYER
}

n_trace :: proc(c: ^Call, args: []Value) -> Value {
	log.infof("[papyrus] %s", arg_str(args, 0))
	return nil
}

n_notification :: proc(c: ^Call, args: []Value) -> Value {
	log.infof("[notification] %s", arg_str(args, 0))
	return nil
}

// ── Message ──────────────────────────────────────────────────────────────────

// n_message_show resolves the receiving MESG and puts it on screen. Papyrus returns the index of
// the button the player picked, so a script branches on it.
//
// HOLE(ui): no message box, so Show never pauses the world. When it lands, Show yields the handler's
// coroutine until the click, and ticks stop meanwhile (docs/script-rewrite.md "Menus that pause the
// world"). The messagebox menu does not exist yet (`docs/menus.md` lists `messagebox.swf` as P1), so there
// is nothing to pick a button WITH. Until it lands this logs the resolved text and returns 0 — the
// first button, which the base game authors as the "carry on" choice on the records that matter
// (OghmaInfinium button 0 is "(Do not read)"). Point this at the menu when it exists: show
// `m.buttons` and return the chosen index.
n_message_show :: proc(c: ^Call, args: []Value) -> Value {
	m, ok := gamedb.message_of(c.db, c.self)
	if !ok {
		log.warnf("[message] Show on 0x%X: not an indexed MESG", c.self)
		return i32(0)
	}
	if m.message_box {
		log.infof("[message] box %q: %s  buttons=%v", m.title, m.body, m.buttons)
	} else {
		log.infof("[message] %s", m.body)
	}
	return i32(0) // the first button, until the menu can return a real choice
}

// ── read-through helpers (baseline ⊕ overlay) ────────────────────────────────

// ref_cell resolves a ref's CURRENT owning cell — the overlay (if it moved) wins
// over the gamedb baseline. The setters need it for the per-cell patch index.
@(private)
ref_cell :: proc(c: ^Call, form: Form_ID) -> Form_ID {
	if d, ok := worldstate.get(c.ws, form); ok && d.cell != 0 {
		return d.cell
	}
	if r, ok := gamedb.ref_by_formid(c.db, form); ok {
		return r.cell_form_id
	}
	return 0
}

// ref_pos resolves a ref's CURRENT position (overlay Moved wins over baseline).
@(private)
ref_pos :: proc(c: ^Call, form: Form_ID) -> smath.Vec3 {
	if d, ok := worldstate.get(c.ws, form); ok && .Moved in d.live {
		return d.pos
	}
	if r, ok := gamedb.ref_by_formid(c.db, form); ok {
		return r.pos
	}
	return {}
}

// ── arg coercion (Value union → concrete, with defaults) ─────────────────────

@(private)
arg_f32 :: proc(args: []Value, i: int, fallback: f32) -> f32 {
	if i < len(args) {
		#partial switch v in args[i] {
		case f32:
			return v
		case i32:
			return f32(v)
		}
	}
	return fallback
}

@(private)
arg_i32 :: proc(args: []Value, i: int, fallback: i32) -> i32 {
	if i < len(args) {
		#partial switch v in args[i] {
		case i32:
			return v
		case f32:
			return i32(v)
		}
	}
	return fallback
}

@(private)
arg_form :: proc(args: []Value, i: int) -> Form_ID {
	if i < len(args) {
		if f, ok := args[i].(Form_ID); ok {
			return f
		}
	}
	return 0
}

@(private)
arg_bool :: proc(args: []Value, i: int, fallback: bool) -> bool {
	if i < len(args) {
		if b, ok := args[i].(bool); ok {
			return b
		}
	}
	return fallback
}

@(private)
arg_str :: proc(args: []Value, i: int) -> string {
	if i < len(args) {
		if s, ok := args[i].(string); ok {
			return s
		}
	}
	return ""
}
