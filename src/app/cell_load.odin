package main

// Cell-load setup (ROADMAP Iteration 1, Milestone C): mount the install's archives
// into a VFS and build the gamedb from Skyrim.esm, so run_game can place a real
// interior cell. Thin glue — no SDL; the VFS/gamedb/world packages do the work.

import "core:log"
import "core:os"
import "core:path/filepath"

import "../gamedb"
import smath "../math"
import "../render"
import "../vfs"
import "../world"

// Archives that carry the static-world assets an interior needs (meshes + diffuse
// textures). Mounted in load order; loose Data/ (added first) overrides all.
GAME_ARCHIVES := []string{"Skyrim - Meshes.bsa", "Skyrim - Textures.bsa"}

// mount_game builds a VFS over <src>/Data: the loose folder (highest precedence) plus
// the static-asset archives. Caller frees with vfs.destroy.
mount_game :: proc(src: string) -> vfs.VFS {
	v: vfs.VFS
	data_dir, _ := filepath.join({src, "Data"}, context.temp_allocator)
	vfs.mount_loose(&v, data_dir)
	for name in GAME_ARCHIVES {
		p, _ := filepath.join({data_dir, name}, context.temp_allocator)
		if !vfs.mount_archive(&v, p) {
			log.warnf("could not mount %s", p)
		}
	}
	return v
}

// load_gamedb reads <src>/Data/Skyrim.esm and builds the in-memory record DB. The
// file bytes are freed after the build (the DB clones everything it keeps).
load_gamedb :: proc(src: string) -> (gamedb.DB, bool) {
	esm_path, _ := filepath.join({src, "Data", "Skyrim.esm"}, context.temp_allocator)
	data, rerr := os.read_entire_file(esm_path, context.allocator)
	if rerr != nil {
		log.errorf("could not read %s", esm_path)
		return {}, false
	}
	defer delete(data)
	log.infof("loading gamedb from %s (%d bytes)…", esm_path, len(data))
	return gamedb.build(data), true
}

// stream_spawn picks a camera start over an exterior grid cell: centred on the cell
// in XY, raised above its statics' mean height. Used to drop the player into a
// streamed worldspace (e.g. Riverwood in Tamriel) before terrain exists to stand on.
stream_spawn :: proc(db: ^gamedb.DB, world_fid: u32, gx, gy: i32) -> (pos: smath.Vec3, ok: bool) {
	cid, cok := gamedb.cell_at(db, world_fid, gx, gy)
	if !cok {
		return {}, false
	}
	sum_z, n := f32(0), 0
	for r in gamedb.refs_of(db, cid) {
		if !r.disabled {
			sum_z += r.pos.z
			n += 1
		}
	}
	ground := sum_z / f32(max(n, 1))
	return {(f32(gx) + 0.5) * 4096, (f32(gy) + 0.5) * 4096, ground + 900}, true
}

// --- Inter-cell traversal (base game locomotion via NORMAL load doors) ---
//
// One reusable, mode-aware core for full game traversal: walk the streamed exterior,
// cross a load door → its interior (the exterior stays loaded but shrinks to a small
// fixed window), interior→interior, and return → the exterior at the correct spot.
// This is plain Skyrim door traversal — NOT the open-interiors portal experiment.
//
// A load door is symmetric (its XTEL names a partner door), so traversal collapses to
// ONE op — go_through — that resolves the destination cell and swaps the active scene
// to match, branching on interior vs exterior. The streamer is the one piece that must
// be managed: its worker thread holds the exterior ^Scene, so scene_destroy would fight
// it. We never destroy the exterior scene; we PAUSE the streamer (+ collapse its window)
// on interior entry and resume it on return.

// Camera height above the XTEL landing marker on arrival, and door activation ranges. A
// manual door (real mesh) arms a "Go Through" prompt within DOOR_RANGE (press F). An auto-
// load door (an invisible AutoLoadMarker — cave/dungeon entrances) fires on PROXIMITY within
// the tighter AUTO_DOOR_RANGE, no key. After any transition, auto-firing is suppressed until
// the player walks AUTO_REARM away from the arrival spot — else the partner door (right where
// you land) would instantly teleport you back in a loop.
TRAVERSAL_EYE :: f32(96)
DOOR_RANGE :: f32(600)
AUTO_DOOR_RANGE :: f32(300)
AUTO_REARM :: f32(500)

Traversal_Mode :: enum {
	Exterior, // living in the streamed exterior scene
	Interior, // living in a synchronously-loaded interior cell
}

// Door_Ref is one load door, indexed from gamedb (NOT from renderable instances — so it
// includes invisible AutoLoadMarker doors, which build_chunk skips as markers). `pos` is the
// door's world position (proximity prompt + range); the rest is its XTEL (destination door +
// the arrival marker on the far side). `auto` = an auto-load (proximity-entered) door.
Door_Ref :: struct {
	self:    u32, // this door's own formID (arrival re-trigger guard)
	pos:     smath.Vec3,
	tp_door: u32,
	tp_pos:  smath.Vec3,
	tp_rot:  smath.Vec3,
	auto:    bool,
}

// Door_Hit is the nearest activatable load door to the player this frame. ok=false when none
// is within DOOR_RANGE.
Door_Hit :: struct {
	door_pos: smath.Vec3, // for the prompt + range test
	tp_door:  u32,
	tp_pos:   smath.Vec3,
	tp_rot:   smath.Vec3,
	auto:     bool,
	dist:     f32,
	ok:       bool,
}

// Traversal owns which scene the player currently inhabits and manages the exterior
// streamer's lifecycle across door transitions (interior load, interior↔interior, return to
// the exterior, and cross-worldspace city gates). It borrows the exterior scene + streamer
// (always alive) and holds the interior scene when one is loaded.
Traversal :: struct {
	mode:        Traversal_Mode,
	ext_scene:   ^world.Scene, // streamed exterior (borrowed; never destroyed here)
	st:          ^world.Streamer, // exterior streamer (borrowed)
	db:          ^gamedb.DB,
	v:           ^vfs.VFS,
	r:           ^render.Renderer,
	interior:    world.Scene, // valid only while mode == .Interior
	ext_doors:   [dynamic]Door_Ref, // current exterior worldspace's load doors (rebuilt on retarget)
	int_doors:   [dynamic]Door_Ref, // current interior cell's load doors (rebuilt on entry)
	arrival_pos: smath.Vec3, // where the last transition landed (auto-fire suppression anchor)
	has_arrival: bool, // suppress auto-firing until the player walks AUTO_REARM from arrival_pos
}

traversal_init :: proc(
	t: ^Traversal,
	ext_scene: ^world.Scene,
	st: ^world.Streamer,
	db: ^gamedb.DB,
	v: ^vfs.VFS,
	r: ^render.Renderer,
) {
	t^ = Traversal {
		mode      = .Exterior,
		ext_scene = ext_scene,
		st        = st,
		db        = db,
		v         = v,
		r         = r,
		ext_doors = make([dynamic]Door_Ref),
		int_doors = make([dynamic]Door_Ref),
	}
	rebuild_ext_doors(t)
}

traversal_destroy :: proc(t: ^Traversal) {
	if t.mode == .Interior {
		world.scene_destroy(&t.interior)
	}
	delete(t.ext_doors)
	delete(t.int_doors)
	t^ = {}
}

// gather_doors fills `out` with every load door across `cells` (a worldspace's cell set, or a
// single interior cell). Built straight from gamedb refs — so invisible AutoLoadMarker doors
// (which build_chunk drops as markers) are included. auto = the door's mesh is a marker.
@(private = "file")
gather_doors :: proc(t: ^Traversal, cells: []u32, out: ^[dynamic]Door_Ref) {
	clear(out)
	for cid in cells {
		for r in gamedb.refs_of(t.db, cid) {
			if !r.has_tp || r.disabled {
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

// rebuild_ext_doors indexes the streamer's CURRENT worldspace's load doors (the persistent
// cell — among all its cells — carries the exterior doors, absent from the streamed grid
// chunks). Called at init and on each cross-worldspace retarget.
@(private = "file")
rebuild_ext_doors :: proc(t: ^Traversal) {
	clear(&t.ext_doors)
	if t.st.world_fid == 0 {
		return // no streamed worldspace (e.g. worldspace not found)
	}
	gather_doors(t, gamedb.cells_of(t.db, t.st.world_fid), &t.ext_doors)
	log.infof("traversal: indexed %d load doors in worldspace 0x%08X", len(t.ext_doors), t.st.world_fid)
}

// traversal_scene returns the scene the camera + picker currently operate in: the loaded
// interior cell when inside, the streamed exterior otherwise.
traversal_scene :: proc(t: ^Traversal) -> ^world.Scene {
	if t.mode == .Interior {
		return &t.interior
	}
	return t.ext_scene
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
	doors := t.int_doors if t.mode == .Interior else t.ext_doors
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
door_dest_label :: proc(t: ^Traversal, tp_door: u32) -> string {
	dref, ok := gamedb.ref_by_formid(t.db, tp_door)
	if !ok {
		return ""
	}
	dcell, cok := gamedb.cell_by_formid(t.db, dref.cell_form_id)
	if !cok {
		return ""
	}
	if dcell.editor_id != "" {
		return dcell.editor_id
	}
	if dcell.interior {
		return "(interior)"
	}
	if w := gamedb.world_editor_id(t.db, dcell.world_form_id); w != "" {
		return w // exterior worldspace name (e.g. a city gate → "WhiterunWorld")
	}
	return "(exterior)"
}

// go_through follows the activated load door's XTEL to its destination cell and swaps the
// active scene to match, returning the camera placement at the arrival marker. The door's
// teleport marker (designer-placed) is the landing spot+facing in the destination cell — far
// better than guessing from the dest door mesh. Branches: interior dest → load it; exterior
// in the SAME worldspace → resume streaming there; exterior in a DIFFERENT worldspace (a city
// gate) → retarget the streamer. ok=false (camera unchanged) only if the destination is
// unresolved.
go_through :: proc(t: ^Traversal, h: Door_Hit) -> (pos: smath.Vec3, yaw: f32, ok: bool) {
	if !h.ok {
		return {}, 0, false
	}
	dref, dok := gamedb.ref_by_formid(t.db, h.tp_door)
	if !dok {
		log.warnf("traversal: door dest 0x%08X not found — staying put", h.tp_door)
		return {}, 0, false
	}
	dcell, cok := gamedb.cell_by_formid(t.db, dref.cell_form_id)
	if !cok {
		log.warnf("traversal: door dest cell 0x%08X unknown — staying put", dref.cell_form_id)
		return {}, 0, false
	}

	// Arrival placement from the door's XTEL marker (interior-local coords for an interior
	// dest, absolute world coords for an exterior dest — matches the target scene).
	pos = h.tp_pos + smath.Vec3{0, 0, TRAVERSAL_EYE}
	yaw = h.tp_rot.z

	switch {
	case dcell.interior:
		enter_interior(t, dcell.form_id)
	case dcell.world_form_id != t.st.world_fid:
		retarget_exterior(t, dcell.world_form_id, pos) // cross-worldspace city gate
	case:
		exit_to_exterior(t, pos) // same-worldspace exterior (interior return / wilderness door)
	}

	// Anchor auto-fire suppression at the landing spot so the partner door (right here) doesn't
	// immediately teleport us back; it re-arms once we walk AUTO_REARM away.
	t.arrival_pos = pos
	t.has_arrival = true
	log.infof("traversal: entered cell 0x%08X (%s) via door 0x%08X", dcell.form_id, dcell.editor_id, h.tp_door)
	return pos, yaw, true
}

// enter_interior swaps to a freshly-loaded interior cell. The exterior streamer is paused
// (and its window collapsed to a small fixed footprint) the first time we leave it, so the
// immediate surroundings stay warm for an instant return while the far LOD/terrain rings —
// the costly resident set — are freed. The new cell's own doors are indexed for proximity.
@(private = "file")
enter_interior :: proc(t: ^Traversal, cell_id: u32) {
	if t.mode == .Interior {
		world.scene_destroy(&t.interior) // interior → interior swap
	} else {
		world.stream_pause(t.st, true)
		world.stream_collapse(t.st, t.st.full_radius) // keep only the inner full-detail window
	}
	t.interior = world.scene_init(t.r, t.v)
	world.load_cell(&t.interior, t.db, cell_id)
	gather_doors(t, {cell_id}, &t.int_doors)
	t.mode = .Interior
}

// exit_to_exterior tears down the interior and resumes the exterior streamer, re-windowing
// at the arrival cell (the kept inner window pops in instantly; the outer rings re-stream
// progressively via build-before-release, no hitch).
@(private = "file")
exit_to_exterior :: proc(t: ^Traversal, pos: smath.Vec3) {
	if t.mode == .Interior {
		world.scene_destroy(&t.interior)
		t.interior = {}
	}
	world.stream_pause(t.st, false)
	world.stream_update(t.st, pos)
	t.mode = .Exterior
}

// retarget_exterior crosses to a DIFFERENT exterior worldspace (a city gate). Unlike an
// interior visit, there's no "keep the old world warm" — this is a full swap (like Skyrim's
// city load screen): the streamer drops the old worldspace's chunks and re-windows the new
// one, and the per-worldspace far-terrain backdrop + door index are rebuilt. Models stay
// cached (shared meshes carry over). pos is the arrival spot in the new world's coords.
@(private = "file")
retarget_exterior :: proc(t: ^Traversal, world_fid: u32, pos: smath.Vec3) {
	if t.mode == .Interior {
		world.scene_destroy(&t.interior)
		t.interior = {}
	}
	world.stream_retarget(t.st, world_fid)
	world.release_far_terrain(t.ext_scene)
	world.build_far_terrain(t.ext_scene, t.db, world_fid)
	rebuild_ext_doors(t)
	world.stream_update(t.st, pos) // prime the new worldspace's window at the arrival cell
	t.mode = .Exterior
	log.infof("traversal: crossed to worldspace 0x%08X (%s)", world_fid, gamedb.world_editor_id(t.db, world_fid))
}
