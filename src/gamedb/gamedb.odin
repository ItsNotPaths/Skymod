package gamedb

// Game database (ROADMAP Phase 1b / Iteration 1, Milestone C): the parsed ESM
// records held in memory and queryable — by FormID, by cell. Built in one walk of a
// plugin's bytes (src/formats/esm) and consumed by src/world to build a scene.
//
// Iteration-1 scope: index interior cells, their REFR placements, and the base-form
// model paths those REFRs resolve to (the static-world subset). FormID remapping
// across masters is single-file for now (Skyrim.esm has no masters); §note below.

import "base:runtime"
import "core:strings"
import "../formats/esm"

// Ref is one placed reference inside a cell: its base form, world transform, and (for
// doors) a teleport to a destination door.
Ref :: struct {
	form_id:      u32,
	cell_form_id: u32, // the interior cell this ref belongs to
	base:         u32,
	pos:          [3]f32,
	rot:          [3]f32,
	scale:        f32,
	teleport:     esm.Teleport,
	has_tp:       bool,
	disabled:     bool, // REFR "Initially Disabled" flag — not placed in the world
}

// REFR record-header flag: the ref starts disabled (an alternate-state placement).
REFR_INITIALLY_DISABLED :: 0x0000_0800

// Cell is one cell's identity. Exterior cells carry their worldspace + grid (each
// grid step is 4096 units); interior cells have world_form_id 0 and has_grid false.
Cell :: struct {
	form_id:       u32,
	editor_id:     string, // owned by the DB
	interior:      bool,
	world_form_id: u32, // owning WRLD (0 for interiors)
	gx, gy:        i32, // exterior grid coordinates
	has_grid:      bool, // false for interiors / the worldspace persistent cell
}

// DB is the in-memory record index. All strings / dynamic arrays are owned and freed
// by destroy.
DB :: struct {
	allocator:    runtime.Allocator,
	base_models:   map[u32]string, // base formID -> mesh path (owned)
	cells:         map[u32]Cell, // cell formID -> identity
	cell_by_edid:  map[string]u32, // lowercased editor id -> cell formID (key owned)
	cell_refs:     map[u32][dynamic]Ref, // cell formID -> placements
	ref_by_id:     map[u32]Ref, // REFR formID -> its placement (for XTEL door targets)
	worlds:        map[u32]string, // WRLD formID -> editor id (owned)
	world_by_edid: map[string]u32, // lowercased worldspace editor id -> formID (key owned)
	world_cells:   map[u32][dynamic]u32, // WRLD formID -> its exterior cell formIDs
}

// base-form record types that carry a MODL mesh — the static-world subset an
// interior is built from (architecture, furniture, clutter, doors, lights).
@(private)
is_base_type :: proc(s: string) -> bool {
	switch s {
	case "STAT", "MSTT", "FURN", "DOOR", "ACTI", "CONT", "FLOR", "TREE", "LIGT", "MISC":
		return true
	}
	return false
}

// build walks a plugin's bytes and returns the indexed DB. The DB borrows nothing
// from `data` (all kept strings are cloned), so `data` may be freed after.
build :: proc(data: []u8, allocator := context.allocator) -> DB {
	db := DB {
		allocator     = allocator,
		base_models   = make(map[u32]string, 4096, allocator),
		cells         = make(map[u32]Cell, 1024, allocator),
		cell_by_edid  = make(map[string]u32, 1024, allocator),
		cell_refs     = make(map[u32][dynamic]Ref, 1024, allocator),
		ref_by_id     = make(map[u32]Ref, 4096, allocator),
		worlds        = make(map[u32]string, 64, allocator),
		world_by_edid = make(map[string]u32, 64, allocator),
		world_cells   = make(map[u32][dynamic]u32, 64, allocator),
	}
	esm.walk(data, visit, &db)
	return db
}

destroy :: proc(db: ^DB) {
	context.allocator = db.allocator
	for _, m in db.base_models {
		delete(m)
	}
	delete(db.base_models)
	for _, c in db.cells {
		delete(c.editor_id)
	}
	delete(db.cells)
	for k, _ in db.cell_by_edid {
		delete(k)
	}
	delete(db.cell_by_edid)
	for _, refs in db.cell_refs {
		delete(refs)
	}
	delete(db.cell_refs)
	delete(db.ref_by_id)
	for _, e in db.worlds {
		delete(e)
	}
	delete(db.worlds)
	for k, _ in db.world_by_edid {
		delete(k)
	}
	delete(db.world_by_edid)
	for _, cells in db.world_cells {
		delete(cells)
	}
	delete(db.world_cells)
	db^ = {}
}

// find_cell looks up an interior cell by editor id (case-insensitive).
find_cell :: proc(db: ^DB, editor_id: string) -> (Cell, bool) {
	key := strings.to_lower(editor_id, context.temp_allocator)
	if fid, ok := db.cell_by_edid[key]; ok {
		return db.cells[fid], true
	}
	return {}, false
}

// find_world looks up a worldspace by editor id (case-insensitive), e.g.
// "WhiterunWorld" -> 0x0001A26F.
find_world :: proc(db: ^DB, editor_id: string) -> (form_id: u32, ok: bool) {
	key := strings.to_lower(editor_id, context.temp_allocator)
	fid, found := db.world_by_edid[key]
	return fid, found
}

// cells_of returns a worldspace's exterior cell formIDs (empty if none / unknown
// world). Order follows the file (exterior block/sub-block order).
cells_of :: proc(db: ^DB, world_form_id: u32) -> []u32 {
	if cells, ok := db.world_cells[world_form_id]; ok {
		return cells[:]
	}
	return nil
}

// refs_of returns a cell's placed references (empty if none / unknown cell).
refs_of :: proc(db: ^DB, cell_form_id: u32) -> []Ref {
	if refs, ok := db.cell_refs[cell_form_id]; ok {
		return refs[:]
	}
	return nil
}

// model_of resolves a base form's mesh path.
model_of :: proc(db: ^DB, base_form_id: u32) -> (string, bool) {
	m, ok := db.base_models[base_form_id]
	return m, ok
}

// ref_by_formid looks up a placed reference by its formID (e.g. an XTEL teleport's
// destination door). Only interior-cell refs are indexed.
ref_by_formid :: proc(db: ^DB, form_id: u32) -> (Ref, bool) {
	r, ok := db.ref_by_id[form_id]
	return r, ok
}

// cell_by_formid looks up a cell's identity by formID.
cell_by_formid :: proc(db: ^DB, form_id: u32) -> (Cell, bool) {
	c, ok := db.cells[form_id]
	return c, ok
}

// --- walk visitor ---

@(private)
visit :: proc(rec: esm.Record, ctx: esm.Walk_Context, user: rawptr) -> bool {
	db := (^DB)(user)
	s := esm.sig(rec)

	switch {
	case s == "WRLD":
		index_world(db, rec)
	case s == "CELL":
		index_cell(db, rec, ctx)
	case s == "REFR":
		// Keep refs whose owning cell is already indexed (the CELL record precedes its
		// children GRUP). Interiors and exterior worldspace cells both qualify — the
		// world loader gathers exterior cells by worldspace, the interior loader by cell.
		if _, ok := db.cells[ctx.cell_form_id]; ok {
			index_ref(db, rec, ctx.cell_form_id)
		}
	case is_base_type(s):
		index_base(db, rec)
	}
	return true
}

@(private)
index_world :: proc(db: ^DB, rec: esm.Record) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	edid := esm.editor_id(fl)
	db.worlds[rec.form_id] = strings.clone(edid, db.allocator)
	if edid != "" {
		key := strings.to_lower(edid, db.allocator)
		db.world_by_edid[key] = rec.form_id
	}
}

@(private)
index_cell :: proc(db: ^DB, rec: esm.Record, ctx: esm.Walk_Context) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below (one-pass build)
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	edid := esm.editor_id(fl)
	cell := Cell {
		form_id       = rec.form_id,
		editor_id     = strings.clone(edid, db.allocator),
		interior      = esm.cell_is_interior(fl),
		world_form_id = ctx.world_form_id,
	}
	if gx, gy, gok := esm.cell_grid(fl); gok {
		cell.gx, cell.gy, cell.has_grid = gx, gy, true
	}
	db.cells[rec.form_id] = cell
	if edid != "" {
		key := strings.to_lower(edid, db.allocator)
		db.cell_by_edid[key] = rec.form_id
	}
	// Group exterior cells under their worldspace so the world loader can gather them.
	if ctx.world_form_id != 0 {
		cells, found := &db.world_cells[ctx.world_form_id]
		if !found {
			db.world_cells[ctx.world_form_id] = make([dynamic]u32, 0, 64, db.allocator)
			cells = &db.world_cells[ctx.world_form_id]
		}
		append(cells, rec.form_id)
	}
}

@(private)
index_ref :: proc(db: ^DB, rec: esm.Record, cell_form_id: u32) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	p := esm.decode_refr(fl)
	ref := Ref {
		form_id      = rec.form_id,
		cell_form_id = cell_form_id,
		base         = p.base,
		pos          = p.pos,
		rot          = p.rot,
		scale        = p.scale,
		disabled     = rec.flags & REFR_INITIALLY_DISABLED != 0,
	}
	if tp, has := esm.refr_teleport(fl); has {
		ref.teleport = tp
		ref.has_tp = true
	}

	refs, found := &db.cell_refs[cell_form_id]
	if !found {
		db.cell_refs[cell_form_id] = make([dynamic]Ref, 0, 64, db.allocator)
		refs = &db.cell_refs[cell_form_id]
	}
	append(refs, ref)
	db.ref_by_id[rec.form_id] = ref
}

@(private)
index_base :: proc(db: ^DB, rec: esm.Record) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	model := esm.model_path(fl)
	if model != "" {
		db.base_models[rec.form_id] = strings.clone(model, db.allocator)
	}
}
