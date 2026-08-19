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
import "../worldstate"

register_builtins :: proc(reg: ^Registry) {
	// ObjectReference — the instance-method bulk of the corpus.
	register(reg, "ObjectReference", "Disable", n_disable)
	register(reg, "ObjectReference", "Enable", n_enable)
	register(reg, "ObjectReference", "IsDisabled", n_is_disabled)
	register(reg, "ObjectReference", "SetScale", n_set_scale)
	register(reg, "ObjectReference", "GetScale", n_get_scale)
	register(reg, "ObjectReference", "Delete", n_delete)
	register(reg, "ObjectReference", "DeleteWhenAble", n_delete) // we have no defer; act now
	register(reg, "ObjectReference", "MoveTo", n_move_to)
	register(reg, "ObjectReference", "Lock", n_lock)
	register(reg, "ObjectReference", "IsLocked", n_is_locked)
	register(reg, "ObjectReference", "SetOpen", n_set_open)

	// Game / Debug — the top globals (callstatic), self is unused (0).
	register(reg, "Game", "GetPlayer", n_get_player)
	register(reg, "Debug", "Trace", n_trace)
	register(reg, "Debug", "Notification", n_notification)

	register(reg, "Message", "Show", n_message_show)

	register_math(reg) // Math.* — pure callstatic leaves
	register_quest(reg) // Quest.* — the quest-state store
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
	if d, ok := worldstate.get(c.ws, c.self); ok && .Disabled in d.live {
		return d.disabled
	}
	if r, ok := gamedb.ref_by_formid(c.db, c.self); ok {
		return r.disabled // baseline REFR "Initially Disabled"
	}
	return false
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
// The messagebox menu does not exist yet (`docs/menus.md` lists `messagebox.swf` as P1), so there
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
