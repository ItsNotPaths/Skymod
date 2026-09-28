package main

// Door traversal, the sim's side (ws.md Workstream R): where the player is, the loaded interior's
// cells and physics world, and the load doors around the player. A crossing runs with the sim parked;
// main then shows the new place (show_place) and loads what it draws.
//
// A load door is symmetric (its XTEL names a partner door), so traversal is one op, go_through, that
// resolves the destination cell and moves the player's place there. The exterior's live cells stay
// while the player is inside, so a return is instant.

import "core:log"

import "../formid"
import "../gamedb"
import smath "../math"
import "../physics"
import "../world"
import "../worldstate"

// Door activation ranges. A manual door (real mesh) arms a "Go Through" prompt within DOOR_RANGE (press E). An auto-
// load door (an invisible AutoLoadMarker — cave/dungeon entrances) fires on PROXIMITY within
// the tighter AUTO_DOOR_RANGE, no key. After any transition, auto-firing is suppressed until
// the player walks AUTO_REARM away from the arrival spot — else the partner door (right where
// you land) would instantly teleport you back in a loop.
DOOR_RANGE :: f32(600)
AUTO_DOOR_RANGE :: f32(300)
AUTO_REARM :: f32(500)

// Door_Ref is one load door, indexed from gamedb (NOT from renderable instances — so it
// includes invisible AutoLoadMarker doors, which build_chunk skips as markers). `pos` is the
// door's world position (proximity prompt + range); the rest is its XTEL (destination door +
// the arrival marker on the far side). `auto` = an auto-load (proximity-entered) door.
Door_Ref :: struct {
	self:    Form_ID, // this door's own formID (arrival re-trigger guard)
	pos:     smath.Vec3,
	tp_door: Form_ID,
	tp_pos:  smath.Vec3,
	tp_rot:  smath.Vec3,
	auto:    bool,
}

// Door_Hit is the nearest activatable load door to the player this frame. ok=false when none
// is within DOOR_RANGE.
Door_Hit :: struct {
	door_pos: smath.Vec3, // for the prompt + range test
	tp_door:  Form_ID,
	tp_pos:   smath.Vec3,
	tp_rot:   smath.Vec3,
	auto:     bool,
	dist:     f32,
	ok:       bool,
}

// Place is where the player is. The sim owns it; main draws the one it last heard of (Evt_Place).
Place :: struct {
	world:    Form_ID, // the exterior worldspace, kept while inside
	interior: Form_ID, // the interior cell the player is in; 0 = outside
}

// Traversal is the sim's side of door crossings: the place, the interior's live cells and the doors.
Traversal :: struct {
	place:       Place,
	db:          ^gamedb.DB,
	ext:         ^world.Space, // the exterior's live cells (borrowed)
	int_phys:    physics.World, // the interior's collision world (reused across interiors)
	int_space:   world.Space, // the interior's live cells and bodies, in int_phys
	int_phys_ok: bool, // false if Jolt failed to make the interior world (interiors then have no collision)
	ext_doors:   [dynamic]Door_Ref, // the worldspace's load doors (rebuilt on retarget)
	int_doors:   [dynamic]Door_Ref, // the interior's load doors (rebuilt on entry)
	arrival_pos: smath.Vec3, // where the last transition landed (auto-fire suppression anchor)
	has_arrival: bool, // suppress auto-firing until the player walks AUTO_REARM from arrival_pos
}

// Traversal_Kind is what a transition did, so the caller knows which load screen it still needs.
Traversal_Kind :: enum {
	None,     // no transition (unresolved destination)
	Stay,     // already in the destination interior (instant)
	Interior, // entered an interior cell (load screen ran inside go_through)
	City,     // crossed to a different worldspace (caller runs the streamer load screen)
	Jump,     // moved far within the exterior (caller runs the streamer load screen)
	Exit,     // returned to the same-worldspace exterior (instant)
}

traversal_init :: proc(t: ^Traversal, ext: ^world.Space, db: ^gamedb.DB, ws: ^worldstate.World_State) {
	t^ = {place = {world = ext.window.world_fid}, db = db, ext = ext}
	t.int_phys, t.int_phys_ok = physics.world_create()
	if !t.int_phys_ok {log.warn("traversal: interior physics world creation failed — interiors will have no collision")}
	world.space_init(&t.int_space, &t.int_phys if t.int_phys_ok else nil, ext.collisions, ws, dynamic_clutter = true)
	rebuild_ext_doors(t)
}

traversal_destroy :: proc(t: ^Traversal) {
	world.space_destroy(&t.int_space) // the interior's bodies leave int_phys before it goes
	if t.int_phys_ok {physics.world_destroy(&t.int_phys)}
	delete(t.ext_doors)
	delete(t.int_doors)
	t^ = {}
}

inside :: proc(t: ^Traversal) -> bool {
	return t.place.interior != 0
}

// traversal_space is the sim's side of the place the player is in.
traversal_space :: proc(t: ^Traversal) -> ^world.Space {
	return &t.int_space if inside(t) else t.ext
}

// gather_doors fills `out` with every load door across `cells` (a worldspace's cell set, or a
// single interior cell). Built straight from gamedb refs — so invisible AutoLoadMarker doors
// (which build_chunk drops as markers) are included. auto = the door's mesh is a marker.
@(private = "file")
gather_doors :: proc(t: ^Traversal, cells: []Form_ID, out: ^[dynamic]Door_Ref) {
	clear(out)
	for cid in cells {
		for r in gamedb.refs_of(t.db, cid) {
			if !r.has_tp || r.disabled || r.base == formid.PRISON_MARKER {
				continue
			}
			model, _ := gamedb.model_of(t.db, r.base)
			append(
				out,
				Door_Ref {
					self = r.form_id,
					pos = r.pos,
					tp_door = r.teleport.door,
					tp_pos = r.teleport.pos,
					tp_rot = r.teleport.rot,
					auto = world.is_marker_path(model),
				},
			)
		}
	}
}

// rebuild_ext_doors indexes the worldspace's load doors (its persistent cell, among all its cells,
// carries the exterior doors). Called at init and on each cross-worldspace retarget.
@(private = "file")
rebuild_ext_doors :: proc(t: ^Traversal) {
	clear(&t.ext_doors)
	if t.place.world == 0 {return}
	gather_doors(t, gamedb.cells_of(t.db, t.place.world), &t.ext_doors)
	log.infof("traversal: indexed %d load doors in worldspace 0x%08X", len(t.ext_doors), t.place.world)
}

// traversal_arrival_update clears the auto-fire suppression once the player has walked clear
// of the last transition's landing spot (so re-approaching an auto door fires it again).
traversal_arrival_update :: proc(t: ^Traversal, cam_pos: smath.Vec3) {
	if t.has_arrival && smath.length3(cam_pos - t.arrival_pos) > AUTO_REARM {
		t.has_arrival = false
	}
}

// traversal_nearest_door finds the nearest activatable load door to `pos` — scanning the
// interior cell's doors when inside, the worldspace's doors otherwise (both gamedb-sourced, so
// invisible auto-load doors are found). ok is set only within DOOR_RANGE.
traversal_nearest_door :: proc(t: ^Traversal, pos: smath.Vec3) -> Door_Hit {
	doors := t.int_doors if inside(t) else t.ext_doors
	best := Door_Hit{dist = max(f32)}
	for d in doors {
		if dist := smath.length3(d.pos - pos); dist < best.dist {
			best = {
				door_pos = d.pos,
				tp_door  = d.tp_door,
				tp_pos   = d.tp_pos,
				tp_rot   = d.tp_rot,
				auto     = d.auto,
				dist     = dist,
			}
		}
	}
	best.ok = best.dist <= DOOR_RANGE
	return best
}

// door_dest_label resolves a load door's destination into a short prompt label, or "" when it
// can't be resolved. Cross-worldspace exteriors now show the destination worldspace's name.
door_dest_label :: proc(db: ^gamedb.DB, tp_door: Form_ID) -> string {
	dref, ok := gamedb.ref_by_formid(db, tp_door)
	if !ok {
		return ""
	}
	dcell, cok := gamedb.cell_by_formid(db, dref.cell_form_id)
	if !cok {
		return ""
	}
	// Prefer the cell's FULL display name ("Riverwood Trader", "Sleeping Giant Inn") — what the
	// activation prompt should read — over the editor id ("RiverwoodTraderInterior").
	if full := gamedb.name_of(db, dcell.form_id); full != "" {
		return full
	}
	if dcell.editor_id != "" {
		return dcell.editor_id
	}
	if dcell.interior {
		return "(interior)"
	}
	if w := gamedb.world_editor_id(db, dcell.world_form_id); w != "" {
		return w // exterior worldspace name (e.g. a city gate → "WhiterunWorld")
	}
	return "(exterior)"
}

// go_through follows the activated load door's XTEL to its destination cell and moves the player's
// place there, returning the player placement at the arrival marker. The door's
// teleport marker (designer-placed) is the landing spot+facing in the destination cell — far
// better than guessing from the dest door mesh. kind=.None (placement unused) only if the
// destination is unresolved.
go_through :: proc(t: ^Traversal, h: Door_Hit) -> (feet: smath.Vec3, yaw: f32, kind: Traversal_Kind) {
	if !h.ok {
		return {}, 0, .None
	}
	dref, dok := gamedb.ref_by_formid(t.db, h.tp_door)
	if !dok {
		log.warnf("traversal: door dest 0x%08X not found — staying put", h.tp_door)
		return {}, 0, .None
	}
	// The XTEL marker is in interior-local coords for an interior dest, world coords otherwise.
	feet, yaw = h.tp_pos, h.tp_rot.z
	kind = traversal_go_to(t, dref.cell_form_id, feet)
	if kind == .None {
		return {}, 0, .None
	}
	// Anchor auto-fire suppression at the landing spot so the partner door (right here) doesn't
	// immediately teleport us back; it re-arms once we walk AUTO_REARM away.
	t.arrival_pos = feet
	t.has_arrival = true
	log.infof("traversal: entered cell 0x%08X via door 0x%08X", dref.cell_form_id, h.tp_door)
	return feet, yaw, kind
}

// traversal_go_to moves the player's place to `cell` for a player arriving at `feet`: an interior
// becomes live (unless it is the one live), another worldspace replaces the exterior's live cells,
// and a same-worldspace exterior is left for the window. .None when the cell is unknown.
traversal_go_to :: proc(t: ^Traversal, cell: Form_ID, feet: smath.Vec3) -> Traversal_Kind {
	c, ok := gamedb.cell_by_formid(t.db, cell)
	if !ok {
		log.warnf("traversal: cell 0x%08X unknown — staying put", cell)
		return .None
	}
	switch {
	case c.interior && t.place.interior == c.form_id:
		return .Stay
	case c.interior:
		enter_interior(t, c.form_id)
		return .Interior
	case c.world_form_id != t.place.world:
		retarget_exterior(t, c.world_form_id)
		return .City
	case !inside(t) && !world.window_ready(t.ext, t.db, feet):
		return .Jump
	}
	leave_interior(t) // same-worldspace exterior (interior return / wilderness door)
	return .Exit
}

// traversal_reload rebuilds the current interior cell in place, so a just-loaded overlay (F9
// quickload) applies. No-op outside.
traversal_reload :: proc(t: ^Traversal) {
	if inside(t) {enter_interior(t, t.place.interior)}
}

// settle_interior builds every body of the interior's live cells, once main has loaded their models,
// so the player lands on a solid floor.
settle_interior :: proc(t: ^Traversal) {
	if !t.int_phys_ok {return}
	for world.sync_physics(&t.int_space, max(int)) > 0 {}
	physics.optimize_broadphase(&t.int_phys)
	n := 0
	for _, &c in t.int_space.cells {n += len(c.bodies)}
	log.infof("traversal: interior 0x%08X collision built — %d static bodies", t.place.interior, n)
}

// enter_interior makes an interior cell the live one and indexes its doors.
@(private = "file")
enter_interior :: proc(t: ^Traversal, cell: Form_ID) {
	world.space_clear(&t.int_space)
	world.place_cell(&t.int_space, t.db, cell)
	gather_doors(t, {cell}, &t.int_doors)
	t.place.interior = cell
}

// leave_interior retires the interior's live cells; the window moves to the arrival cell next tick.
@(private = "file")
leave_interior :: proc(t: ^Traversal) {
	world.space_clear(&t.int_space)
	clear(&t.int_doors)
	t.place.interior = 0
}

// retarget_exterior crosses to a DIFFERENT exterior worldspace (a city gate): a full swap, like
// Skyrim's city load screen. Every live cell of the old worldspace retires; the load screen then
// fills the arrival bubble.
@(private = "file")
retarget_exterior :: proc(t: ^Traversal, world_fid: Form_ID) {
	leave_interior(t)
	world.set_world(t.ext, t.db, world_fid, t.ext.window.radius)
	t.place.world = world_fid
	rebuild_ext_doors(t)
	log.infof("traversal: crossed to worldspace 0x%08X (%s)", world_fid, gamedb.world_editor_id(t.db, world_fid))
}
