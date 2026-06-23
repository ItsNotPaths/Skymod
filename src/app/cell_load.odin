package main

// Cell-load setup (ROADMAP Iteration 1, Milestone C): mount the install's archives
// into a VFS and build the gamedb from Skyrim.esm, so run_game can place a real
// interior cell. Thin glue — no SDL; the VFS/gamedb/world packages do the work.

import "core:log"
import "core:math"
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

// enter_door performs an interior→interior cell transition (ROADMAP Iteration 1,
// Milestone D): given a load door's XTEL destination door formID, reload the scene
// with the destination cell and return the camera placement at that door (eye height
// above the marker, facing into the room). ok=false if the destination isn't an
// indexed interior (e.g. a door out to an exterior worldspace — Phase 2).
enter_door :: proc(
	scene: ^world.Scene,
	db: ^gamedb.DB,
	r: ^render.Renderer,
	v: ^vfs.VFS,
	dest_door: u32,
) -> (pos: smath.Vec3, yaw: f32, ok: bool) {
	dref, dok := gamedb.ref_by_formid(db, dest_door)
	if !dok {
		log.warnf("door dest 0x%08X not found (exterior?) — staying put", dest_door)
		return {}, 0, false
	}
	dcell, cok := gamedb.cell_by_formid(db, dref.cell_form_id)
	if !cok || !dcell.interior {
		log.warnf("door dest cell 0x%08X not an indexed interior", dref.cell_form_id)
		return {}, 0, false
	}

	world.scene_destroy(scene)
	scene^ = world.scene_init(r, v)
	world.load_cell(scene, db, dcell.form_id)
	log.infof("entered %s via door 0x%08X", dcell.editor_id, dest_door)

	pos = {dref.pos.x, dref.pos.y, dref.pos.z + 128} // eye height above the door marker
	yaw = dref.rot.z + math.PI // face away from the door, into the room
	return pos, yaw, true
}
