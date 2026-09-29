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
// (hole vfx-events :tags (threading vfx unclaimed) :sev gap) no channel carries script and magic visuals to main (EffectShader, VisualEffect, PlayImpactEffect, image space modifiers, fades, camera shake, decals). Wanted: a sim-to-main effect queue stamped with tick time; natives must never call render (do not copy the c.audio pattern).
// (hole vfx-natives :tags (vfx unclaimed) :sev blocker :needs (particles)) EffectShader.Play (551), VisualEffect (551), ImageSpaceModifier (221) — no VFX.
// (hole anim-natives :tags (animation unclaimed) :sev blocker :needs (animation)) PlayAnimation (296) + PlayAnimationAndWait (309) — no animation system. An absent subsystem's completion predicate must answer DONE or rewrites poll forever.
// (hole anim-natives :tags (animation unclaimed) :sev blocker) the script side rides this subsystem — a guard needs a testable "is this clip done", and whether PlayAnimation completes in one tick is an animation decision. Rewrite those scripts here, not before.

// Stubbed writes that no native can read back, so no guard can test them. Each needs a paired
// read (docs/script-rewrite.md step 2 item 2; the `bucket` column of natives-classified.tsv).
// (hole combat-reads :tags combat :sev gap :needs (combat-damage)) no read for Start/EndDeferredKill, SetCriticalStage, AttachAshPile, SetActorCause, AllowBleedoutDialogue.
// (hole ai-reads :tags ai :sev gap) no read for SetNotShowOnStealthMeter, SetAllowFlyingMountLandingRequests.
// (hole physics-reads :tags physics :sev gap) no read for SetMotionType, StopTranslation (no IsTranslating), TetherToHorse, Add/RemoveHavokConstraints.
// (hole cell-reads :tags world :sev gap) no read for Cell.SetPublic.
// (hole camera-reads :tags (render unclaimed) :sev gap :needs (view-model)) no camera read for ForceFirstPerson/ForceThirdPerson, SetCameraTarget, ShowFirstPersonGeometry.
// (hole sit-rotation-read :tags (animation unclaimed) :sev gap :needs (animation)) no read for SetSittingRotation.
// (hole save-request-read :tags save :sev gap) no read for RequestSave/RequestAutoSave (queued; nothing says the save ran).
// (hole model-request-read :tags assets :sev gap) no read for RequestModel (queued; nothing says the model loaded).
// (hole ui-reads :tags ui :sev gap) no read for SetInChargen, AddAchievement, Quest.UpdateCurrentInstanceGlobal.
// (hole ini-reads :tags script :sev polish) no read for the four SetINI*; no vanilla or CC script calls them, so only mods notice.

import "../worldstate"
import "../formid"

register_builtins :: proc(reg: ^Registry) {
	// ObjectReference — the instance-method bulk of the corpus.
	register(reg, "ObjectReference", "Disable", n_disable)
	register(reg, "ObjectReference", "Enable", n_enable)
	register(reg, "ObjectReference", "IsDisabled", n_is_disabled)
	register(reg, "ObjectReference", "Is3DLoaded", n_is_3d_loaded)
	register(reg, "ObjectReference", "SetScale", n_set_scale)
	register(reg, "ObjectReference", "GetScale", n_get_scale)
	register(reg, "ObjectReference", "Delete", n_delete)
	register(reg, "ObjectReference", "DeleteWhenAble", n_delete_when_able)
	register(reg, "ObjectReference", "MoveToWhenUnloaded", n_move_to_when_unloaded)
	register(reg, "ObjectReference", "MoveTo", n_move_to)
	register(reg, "ObjectReference", "Lock", n_lock)
	register(reg, "ObjectReference", "IsLocked", n_is_locked)
	register(reg, "ObjectReference", "SetOpen", n_set_open)
	register(reg, "ObjectReference", "Activate", n_activate)
	register(reg, "Form", "RegisterForSingleUpdate", n_register_single_update)
	register(reg, "Form", "RegisterForUpdate", n_register_update)
	register(reg, "Form", "UnregisterForUpdate", n_unregister_for_update)
	register(reg, "Form", "RegisterForSingleUpdateGameTime", n_register_single_update_game_time)
	register(reg, "Form", "RegisterForUpdateGameTime", n_register_update_game_time)
	register(reg, "Form", "UnregisterForUpdateGameTime", n_unregister_for_update_game_time)
	register(reg, "Form", "RegisterForAnimationEvent", n_register_anim_event)
	register(reg, "Form", "UnregisterForAnimationEvent", n_unregister_anim_event)
	for class in ([?]string{"Form", "Alias", "ActiveMagicEffect"}) {
		register(reg, class, "RegisterForLOS", n_register_los)
		register(reg, class, "RegisterForSingleLOSGain", n_register_single_los_gain)
		register(reg, class, "RegisterForSingleLOSLost", n_register_single_los_lost)
		register(reg, class, "UnregisterForLOS", n_unregister_los)
	}
	register(reg, "ObjectReference", "BlockActivation", n_block_activation)
	register(reg, "ObjectReference", "IsActivationBlocked", n_is_activation_blocked)
	register(reg, "ObjectReference", "SetDestroyed", n_set_destroyed)
	register(reg, "ObjectReference", "ClearDestruction", n_clear_destruction)

	// Game / Debug — the top globals (callstatic), self is unused (0).
	register(reg, "Game", "GetPlayer", n_get_player)
	register(reg, "Game", "ForceFirstPerson", proc(c: ^Call, args: []Value) -> Value {c.ws.camera.dist = 0; return nil})
	register(reg, "Game", "ForceThirdPerson", proc(c: ^Call, args: []Value) -> Value {c.ws.camera.dist = max(c.ws.camera.dist, worldstate.THIRD_MIN); return nil})
	register(reg, "Game", "SetCameraTarget", n_set_camera_target)
	register(reg, "Game", "GetFormFromFile", n_get_form_from_file)
	register(reg, "Debug", "Trace", n_trace)
	register(reg, "Debug", "Notification", n_notification)

	register(reg, "Message", "Show", n_message_show)

	// No handler runs inside a menu: a world-pausing menu stops the ticks (docs/script-api.md section 7).
	register(reg, "Utility", "IsInMenuMode", n_is_in_menu_mode)

	// Skymod facts a rewritten script waits on (docs/script-api.md section 4); not Papyrus natives.
	register(reg, "ObjectReference", "IsAnimRunning", n_is_anim_running)
	register(reg, "Game", "IsVideoPlaying", n_is_video_playing)

	register_math(reg) // Math.* — pure callstatic leaves
	register_sound(reg) // Sound / SoundCategory — the audio device
	register_quest(reg) // Quest.* — the quest-state store
	register_story(reg) // Keyword.SendStoryEvent — the story manager
	register_dialogue(reg) // who talks to the player, a topic info's quest
	register_scene(reg) // Scene.Start — scenes
	register_alias(reg) // quest aliases
	register_stores(reg) // GlobalVariable / Actor life / PlaceAtMe (A-tier overlay)
	register_inventory(reg) // ObjectReference/Actor inventory store
	register_actor(reg) // Actor values + faction/relationship store
	register_crime(reg) // faction relations and bounties
	register_ai(reg)
	register_ref_reads(reg) // position, links, cell and location of a ref
	register_forms(reg) // FormList, Location, keywords, race, game time
	register_reset(reg) // cell and ref reset, cleared locations
	register_magic(reg) // spells start and end scripted magic effects
	register_projectiles(reg) // Weapon.Fire
	register_levels(reg) // encounter zone levels for mods
	register_equip(reg) // what actors wear and hold
	register_leveling(reg) // skill XP, levels, perk points
	register_query(reg) // reads over records and the stores their setters write
	register_find(reg) // Game.FindClosest* / FindRandom* over the loaded refs
}

// ── ObjectReference verbs (write through the overlay) ────────────────────────

n_disable :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_disabled(c.ws, c.self, worldstate.ref_cell(c.ws, c.db, c.self), true)
	worldstate.mark_scene_dirty(c.ws, c.self)
	return nil
}

n_enable :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_disabled(c.ws, c.self, worldstate.ref_cell(c.ws, c.db, c.self), false)
	worldstate.mark_scene_dirty(c.ws, c.self)
	return nil
}

n_is_disabled :: proc(c: ^Call, args: []Value) -> Value {
	return !worldstate.ref_enabled(c.ws, c.db, c.self)
}

// n_is_3d_loaded: an enabled ref whose cell is attached to the player's scene.
n_is_3d_loaded :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.ref_3d_loaded(c.ws, c.db, c.self)
}

n_register_single_update :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.register_update(&c.ws.updates, c.self, arg_f32(args, 0, 0), false)
	return nil
}

n_register_update :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.register_update(&c.ws.updates, c.self, arg_f32(args, 0, 0), true)
	return nil
}

n_unregister_for_update :: proc(c: ^Call, args: []Value) -> Value {
	delete_key(&c.ws.updates, c.self)
	return nil
}

n_register_single_update_game_time :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.register_update(&c.ws.game_updates, c.self, arg_f32(args, 0, 0), false)
	return nil
}

n_register_update_game_time :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.register_update(&c.ws.game_updates, c.self, arg_f32(args, 0, 0), true)
	return nil
}

n_unregister_for_update_game_time :: proc(c: ^Call, args: []Value) -> Value {
	delete_key(&c.ws.game_updates, c.self)
	return nil
}

// RegisterForAnimationEvent(akSender, asEventName): true, as nothing here can fail to register.
n_set_camera_target :: proc(c: ^Call, args: []Value) -> Value {
	c.ws.camera.target = arg_form(c, args, 0)
	return nil
}

n_register_anim_event :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.register_anim_event(c.ws, arg_form(c, args, 0), c.self, arg_str(args, 1))
	return true
}

n_unregister_anim_event :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.unregister_anim_event(c.ws, arg_form(c, args, 0), c.self, arg_str(args, 1))
	return nil
}

n_register_los :: proc(c: ^Call, args: []Value) -> Value {return register_los(c, args, .Both)}
n_register_single_los_gain :: proc(c: ^Call, args: []Value) -> Value {return register_los(c, args, .Gain)}
n_register_single_los_lost :: proc(c: ^Call, args: []Value) -> Value {return register_los(c, args, .Lost)}

register_los :: proc(c: ^Call, args: []Value, mode: worldstate.Los_Mode) -> Value {
	worldstate.register_los(c.ws, c.self, arg_form(c, args, 0), arg_form(c, args, 1), mode)
	return nil
}

n_unregister_los :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.unregister_los(c.ws, c.self, arg_form(c, args, 0), arg_form(c, args, 1))
	return nil
}

// n_activate queues the activation for the app's next tick. It returns whether default processing
// will run: false when blocked, unless abDefaultProcessingOnly ignores the block.
n_activate :: proc(c: ^Call, args: []Value) -> Value {
	default_only := arg_bool(args, 1, false)
	worldstate.request_activation(c.ws, c.self, arg_form(c, args, 0), default_only)
	return default_only || !worldstate.activation_blocked(c.ws, c.self)
}

n_block_activation :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_activation_blocked(c.ws, c.self, worldstate.ref_cell(c.ws, c.db, c.self), arg_bool(args, 0, true))
	return nil
}

n_is_activation_blocked :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.activation_blocked(c.ws, c.self)
}

n_set_destroyed :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_destroyed(c.ws, c.self, worldstate.ref_cell(c.ws, c.db, c.self), arg_bool(args, 0, true))
	return nil
}

n_clear_destruction :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_destroyed(c.ws, c.self, worldstate.ref_cell(c.ws, c.db, c.self), false)
	return nil
}

n_set_scale :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_scale(c.ws, c.self, worldstate.ref_cell(c.ws, c.db, c.self), arg_f32(args, 0, 1))
	worldstate.mark_scene_dirty(c.ws, c.self)
	return nil
}

n_get_scale :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.ref_scale(c.ws, c.db, c.self)
}

n_delete :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_deleted(c.ws, c.self, worldstate.ref_cell(c.ws, c.db, c.self))
	worldstate.mark_scene_dirty(c.ws, c.self)
	return nil
}

// DeleteWhenAble: at once when the ref's cell is not attached, else when it detaches (the converted
// ObjectReference.psc loop is replaced by objectreference.patch.lua, script-api.md section 5).
n_delete_when_able :: proc(c: ^Call, args: []Value) -> Value {
	cell := worldstate.ref_cell(c.ws, c.db, c.self)
	if cell in c.ws.attached {
		worldstate.set_delete_when_detached(c.ws, c.self, cell)
		return nil
	}
	return n_delete(c, args)
}

// MoveTo(akTarget, afXOffset, afYOffset, afZOffset, abMatchRotation).
n_move_to :: proc(c: ^Call, args: []Value) -> Value {
	move_to(c, c.self, arg_form(c, args, 0), move_offset(args), arg_bool(args, 4, true))
	return nil
}

// move_to puts `form` at `target` plus `offset`, facing the way the target faces (abMatchRotation)
// or keeping its own facing.
move_to :: proc(c: ^Call, form, target: Form_ID, offset: smath.Vec3, match_rotation := true) {
	dst := worldstate.ref_pos(c.ws, c.db, target) + offset
	rot := worldstate.ref_rot(c.ws, c.db, target if match_rotation else form)
	place(c, form, dst, rot, worldstate.ref_cell(c.ws, c.db, target))
}

// place moves `form` to `pos` facing `rot`, in `cell` (0 keeps its own).
place :: proc(c: ^Call, form: Form_ID, pos, rot: smath.Vec3, cell: Form_ID = 0) {
	worldstate.relocate(c.ws, form, cell if cell != 0 else worldstate.ref_cell(c.ws, c.db, form), pos, rot)
}

move_offset :: proc(args: []Value) -> smath.Vec3 {
	return {arg_f32(args, 1, 0), arg_f32(args, 2, 0), arg_f32(args, 3, 0)}
}

// MoveToWhenUnloaded: at once when neither the ref's location nor the target's is loaded, else
// when a cell detach unloads both (settle_moves; the converted Wait(5) loop is replaced by
// objectreference.patch.lua, script-api.md section 5).
n_move_to_when_unloaded :: proc(c: ^Call, args: []Value) -> Value {
	move := worldstate.Pending_Move{arg_form(c, args, 0), move_offset(args)}
	if both_unloaded(c, c.self, move.target) {
		move_to(c, c.self, move.target, move.offset)
	} else {
		c.ws.pending_moves[c.self] = move
	}
	return nil
}

// settle_moves runs the pending MoveToWhenUnloaded moves whose locations have both unloaded.
settle_moves :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State) {
	c := Call{ws = ws, db = db}
	done := make([dynamic]Form_ID, context.temp_allocator)
	for ref, move in ws.pending_moves {
		if !both_unloaded(&c, ref, move.target) {continue}
		move_to(&c, ref, move.target, move.offset)
		append(&done, ref)
	}
	for ref in done {delete_key(&ws.pending_moves, ref)}
}

both_unloaded :: proc(c: ^Call, a, b: Form_ID) -> bool {
	return !location_loaded(c, worldstate.ref_location(c.ws, c.db, a)) && !location_loaded(c, worldstate.ref_location(c.ws, c.db, b))
}

n_lock :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_locked(c.ws, c.self, worldstate.ref_cell(c.ws, c.db, c.self), arg_bool(args, 0, true))
	return nil
}

n_is_locked :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.is_locked(c.ws, c.db, c.self)
}

n_set_open :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_open(c.ws, c.self, worldstate.ref_cell(c.ws, c.db, c.self), arg_bool(args, 0, true))
	return nil
}

// ── Game / Debug globals ─────────────────────────────────────────────────────

n_get_form_from_file :: proc(c: ^Call, args: []Value) -> Value {
	form, ok := gamedb.form_from_file(c.db, u32(arg_i32(args, 0, 0)), arg_str(args, 1))
	if !ok {return nil}
	return form
}

n_get_player :: proc(c: ^Call, args: []Value) -> Value {
	return formid.PLAYER
}

n_is_in_menu_mode :: proc(c: ^Call, args: []Value) -> Value {
	return false
}

// (hole anim-natives :tags (animation unclaimed) :sev blocker) IsAnimRunning(asAnim) reads false; no behaviour graph plays, so a rewritten animation wait ends at once.
n_is_anim_running :: proc(c: ^Call, args: []Value) -> Value {
	return false
}

// (hole video-player :tags ui :sev gap :needs video-converter) IsVideoPlaying(asFile) reads false; there is no video player, so a wait on a Bink ends at once.
n_is_video_playing :: proc(c: ^Call, args: []Value) -> Value {
	return false
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
// (hole menu-mode :tags ui :sev gap :needs (message-box-screen)) no message box, so Show never pauses the world. The yield must end the script phase suspended and park the sim (sim_drain); main blocking in a join until the click would deadlock.
// When it lands, Show yields the handler's coroutine until the click, and ticks stop meanwhile
// (docs/script-rewrite.md "Menus that pause the world"). The messagebox menu does not exist yet
// (`docs/menus.md` lists `messagebox.swf` as P1), so there is nothing to pick a button WITH.
// Until it lands this logs the resolved text and returns 0 — the
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
arg_form :: proc(c: ^Call, args: []Value, i: int) -> Form_ID {
	if i >= len(args) {return 0}
	#partial switch v in args[i] {
	case Form_ID: return v
	case string: // a form named by editor id or "File.esm:012FCD" (ws.md Workstream M, Naming)
		f, _ := worldstate.form_by_name(c.ws, c.db, v)
		return f
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
