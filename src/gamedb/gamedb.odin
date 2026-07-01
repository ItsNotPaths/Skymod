package gamedb

// Game database (ROADMAP Phase 1b / Iteration 1, Milestone C): the parsed ESM
// records held in memory and queryable — by FormID, by cell. Built in one walk of a
// plugin's bytes (src/formats/esm) and consumed by src/world to build a scene.
//
// Iteration-1 scope: index interior cells, their REFR placements, and the base-form
// model paths those REFRs resolve to (the static-world subset). Multi-master: build_plugins
// merges a resolved load order (loadorder.odin), remapping every plugin's local FormIDs into
// global load-order space so a later plugin overrides an earlier one (last write wins).

import "base:runtime"
import "core:log"
import "core:strings"
import "../formats/esm"

// Form_ID is the global form handle (esm.Form_ID = u64): (slot<<32)|local. All gamedb
// keys/handles are global — every plugin's FormIDs are remapped into this space at build.
Form_ID :: esm.Form_ID

// Ref is one placed reference inside a cell: its base form, world transform, and (for
// doors) a teleport to a destination door.
Ref :: struct {
	form_id:      Form_ID,
	cell_form_id: Form_ID, // the interior cell this ref belongs to
	base:         Form_ID,
	pos:          [3]f32,
	rot:          [3]f32,
	scale:        f32,
	teleport:     esm.Teleport,
	has_tp:       bool,
	disabled:     bool, // REFR "Initially Disabled" flag — not placed in the world
}

// REFR record-header flag: the ref starts disabled (an alternate-state placement).
REFR_INITIALLY_DISABLED :: 0x0000_0800
// Record-header DELETED flag — an override that removes a master's record (TESForm bit 5).
REFR_DELETED :: 0x0000_0020

// Cell is one cell's identity. Exterior cells carry their worldspace + grid (each
// grid step is 4096 units); interior cells have world_form_id 0 and has_grid false.
Cell :: struct {
	form_id:       Form_ID,
	editor_id:     string, // owned by the DB
	interior:      bool,
	world_form_id: Form_ID, // owning WRLD (0 for interiors)
	gx, gy:        i32, // exterior grid coordinates
	has_grid:      bool, // false for interiors / the worldspace persistent cell
	water_height:  f32, // flat water-plane Z (esm.WATER_NONE = no water; sentinel already resolved to the worldspace default at index time)
	water_type:    Form_ID, // XCWT water-type WATR formID (0 = none/default; reserved for appearance)
}

// DB is the in-memory record index. All strings / dynamic arrays are owned and freed
// by destroy.
DB :: struct {
	allocator:    runtime.Allocator,
	base_models:   map[Form_ID]string, // base formID -> mesh path (owned)
	base_lod:      map[Form_ID][esm.LOD_MODELS]string, // base formID -> MNAM distant-LOD meshes (owned; "" = absent)
	base_radius:   map[Form_ID]f32, // base formID -> OBND bounding radius (size cull, no mesh load)
	doors:         map[Form_ID]bool, // base formID -> true if it's a DOOR record (door-panel cull)
	trees:         map[Form_ID]bool, // base formID -> true if it's a TREE record (distant billboard LOD)
	cells:         map[Form_ID]Cell, // cell formID -> identity
	cell_by_edid:  map[string]Form_ID, // lowercased editor id -> cell formID (key owned)
	cell_refs:     map[Form_ID][dynamic]Ref, // cell formID -> placements
	ref_by_id:     map[Form_ID]Ref, // REFR formID -> its placement (for XTEL door targets)
	worlds:        map[Form_ID]string, // WRLD formID -> editor id (owned)
	world_by_edid: map[string]Form_ID, // lowercased worldspace editor id -> formID (key owned)
	world_cells:   map[Form_ID][dynamic]Form_ID, // WRLD formID -> its exterior cell formIDs
	world_persist: map[Form_ID]Form_ID, // WRLD formID -> its PERSISTENT cell formID (worldspace-wide refs)
	world_water:   map[Form_ID]f32, // WRLD formID -> default water height (a cell's XCLW sentinel resolves here)
	cell_at_grid:  map[Grid_Key]Form_ID, // (world, gx, gy) -> exterior cell formID (streaming)
	cell_heights:  map[Form_ID][]f32, // cell formID -> LAND_GRID² cumulative heightmap (owned)
	cell_base_tex: map[Form_ID][4]Form_ID, // cell formID -> per-quadrant base LTEX formID (0=none)
	cell_dominant: map[Form_ID][]Form_ID, // cell formID -> LAND_GRID² dominant LTEX per vertex (owned)
	ltex_txst:     map[Form_ID]Form_ID, // LTEX formID -> its TXST texture-set formID
	txst_diffuse:  map[Form_ID]string, // TXST formID -> TX00 diffuse path (owned)
	ltex_grass:    map[Form_ID]Form_ID, // LTEX formID -> its GRAS grass-type formID (GNAM)
	grasses:       map[Form_ID]Grass, // GRAS formID -> grass type (model owned)
	ref_index:     map[Form_ID]Ref_Loc, // build-time only: REFR formID -> its slot in cell_refs (override dedup); emptied after build
}

// Ref_Loc locates a placed ref within cell_refs so a later plugin overriding the same
// REFR formID replaces it in place instead of appending a duplicate. Build-time scaffolding.
@(private)
Ref_Loc :: struct {
	cell: Form_ID,
	idx:  int,
}

// Grass is one scatterable grass type (a GRAS record): the cluster mesh the engine
// instances over terrain and how densely (clusters per unit area).
Grass :: struct {
	model:   string, // owned (MODL grass-cluster mesh, e.g. "Plants\\Grass...")
	density: u8,
}

// Grid_Key identifies an exterior cell by its worldspace + grid coordinate — the
// streamer's lookup key as it windows cells around the player.
Grid_Key :: struct {
	world:  Form_ID,
	gx, gy: i32,
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

// build walks a single plugin's bytes and returns the indexed DB — the convenience for a
// no-master file (Skyrim.esm standalone, tools, synthetic tests). FormIDs pass through
// unremapped (identity). For the real game load it onto build_plugins via resolve_load_order.
// The DB borrows nothing from `data` (all kept strings are cloned), so `data` may be freed.
build :: proc(data: []u8, allocator := context.allocator) -> DB {
	return build_plugins({{data = data}}, allocator)
}

// build_plugins merges a resolved load order into one DB, walking each plugin in order with
// its Form_Map so every FormID lands in global space and a later plugin overrides an earlier
// one (last write wins). `plugins` comes from resolve_load_order; the DB clones what it keeps
// so the plugin bytes may be freed after. A single identity-mapped plugin == build().
build_plugins :: proc(plugins: []Loaded_Plugin, allocator := context.allocator, progress: ^int = nil) -> DB {
	db := DB {
		allocator     = allocator,
		base_models   = make(map[Form_ID]string, 4096, allocator),
		base_lod      = make(map[Form_ID][esm.LOD_MODELS]string, 2048, allocator),
		base_radius   = make(map[Form_ID]f32, 4096, allocator),
		doors         = make(map[Form_ID]bool, 512, allocator),
		trees         = make(map[Form_ID]bool, 512, allocator),
		cells         = make(map[Form_ID]Cell, 1024, allocator),
		cell_by_edid  = make(map[string]Form_ID, 1024, allocator),
		cell_refs     = make(map[Form_ID][dynamic]Ref, 1024, allocator),
		ref_by_id     = make(map[Form_ID]Ref, 4096, allocator),
		worlds        = make(map[Form_ID]string, 64, allocator),
		world_by_edid = make(map[string]Form_ID, 64, allocator),
		world_cells   = make(map[Form_ID][dynamic]Form_ID, 64, allocator),
		world_persist = make(map[Form_ID]Form_ID, 64, allocator),
		world_water   = make(map[Form_ID]f32, 64, allocator),
		cell_at_grid  = make(map[Grid_Key]Form_ID, 16384, allocator),
		cell_heights  = make(map[Form_ID][]f32, 1024, allocator),
		cell_base_tex = make(map[Form_ID][4]Form_ID, 1024, allocator),
		cell_dominant = make(map[Form_ID][]Form_ID, 1024, allocator),
		ltex_txst     = make(map[Form_ID]Form_ID, 128, allocator),
		txst_diffuse  = make(map[Form_ID]string, 1024, allocator),
		ltex_grass    = make(map[Form_ID]Form_ID, 128, allocator),
		grasses       = make(map[Form_ID]Grass, 64, allocator),
		ref_index     = make(map[Form_ID]Ref_Loc, 4096, allocator),
	}
	done_bytes := 0
	for &p in plugins {
		esm.walk(p.data, visit, &db, &p.fm, progress, done_bytes) // progress = cumulative bytes (for the load bar)
		done_bytes += len(p.data)
	}
	delete(db.ref_index) // build-time scaffolding — done once every plugin is walked
	db.ref_index = nil
	log.infof(
		"gamedb: %d base meshes, %d with prebaked LOD (%.0f%%)",
		len(db.base_models),
		len(db.base_lod),
		100 * f32(len(db.base_lod)) / f32(max(len(db.base_models), 1)),
	)
	// Sample a few LOD-mesh paths so we can eyeball the format (verify they resolve like MODL).
	shown := 0
	for fid, arr in db.base_lod {
		log.infof("  LOD sample 0x%08X: [0]=%q [3]=%q", fid, arr[0], arr[3])
		shown += 1
		if shown >= 4 {
			break
		}
	}
	return db
}

destroy :: proc(db: ^DB) {
	context.allocator = db.allocator
	for _, arr in db.base_lod {
		for s in arr {
			if s != "" {
				delete(s, db.allocator)
			}
		}
	}
	delete(db.base_lod)
	for _, m in db.base_models {
		delete(m)
	}
	delete(db.base_models)
	delete(db.base_radius)
	delete(db.doors)
	delete(db.trees)
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
	delete(db.world_persist)
	delete(db.world_water)
	delete(db.cell_at_grid)
	for _, h in db.cell_heights {
		delete(h)
	}
	delete(db.cell_heights)
	delete(db.cell_base_tex)
	for _, d in db.cell_dominant {
		delete(d)
	}
	delete(db.cell_dominant)
	delete(db.ltex_txst)
	for _, p in db.txst_diffuse {
		delete(p)
	}
	delete(db.txst_diffuse)
	delete(db.ltex_grass)
	for _, g in db.grasses {
		delete(g.model)
	}
	delete(db.grasses)
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
find_world :: proc(db: ^DB, editor_id: string) -> (form_id: Form_ID, ok: bool) {
	key := strings.to_lower(editor_id, context.temp_allocator)
	fid, found := db.world_by_edid[key]
	return fid, found
}

// world_persistent_cell returns a worldspace's persistent cell formID — the cell holding its
// worldspace-wide refs (load doors, bridges, city gates) at absolute coords. ok=false if none.
world_persistent_cell :: proc(db: ^DB, world_form_id: Form_ID) -> (cell_form_id: Form_ID, ok: bool) {
	c, found := db.world_persist[world_form_id]
	return c, found
}

// world_editor_id returns a worldspace's editor id by formID ("" if unknown).
world_editor_id :: proc(db: ^DB, world_form_id: Form_ID) -> string {
	if e, ok := db.worlds[world_form_id]; ok {
		return e
	}
	return ""
}

// cells_of returns a worldspace's exterior cell formIDs (empty if none / unknown
// world). Order follows the file (exterior block/sub-block order).
cells_of :: proc(db: ^DB, world_form_id: Form_ID) -> []Form_ID {
	if cells, ok := db.world_cells[world_form_id]; ok {
		return cells[:]
	}
	return nil
}

// cell_at resolves an exterior cell by its worldspace + grid coordinate (the
// streamer's per-cell lookup). ok=false where the grid has no cell (worldspace holes
// — common at the edges of Tamriel).
cell_at :: proc(db: ^DB, world_form_id: Form_ID, gx, gy: i32) -> (cell_form_id: Form_ID, ok: bool) {
	fid, found := db.cell_at_grid[Grid_Key{world_form_id, gx, gy}]
	return fid, found
}

// refs_of returns a cell's placed references (empty if none / unknown cell).
refs_of :: proc(db: ^DB, cell_form_id: Form_ID) -> []Ref {
	if refs, ok := db.cell_refs[cell_form_id]; ok {
		return refs[:]
	}
	return nil
}

// model_of resolves a base form's mesh path.
model_of :: proc(db: ^DB, base_form_id: Form_ID) -> (string, bool) {
	m, ok := db.base_models[base_form_id]
	return m, ok
}

// lod_model_of resolves a base form's prebaked distant-LOD mesh for detail slot `idx` (0 = highest
// detail/LOD4 … 3 = lowest/LOD32). Clamps to the populated range — a request beyond the last filled
// slot returns the coarsest available, so an object always has *some* LOD mesh once it has any.
// ok=false when the form carries no MNAM LOD models at all (e.g. small clutter — drop at distance).
lod_model_of :: proc(db: ^DB, base_form_id: Form_ID, idx: int) -> (string, bool) {
	arr, ok := db.base_lod[base_form_id]
	if !ok {
		return "", false
	}
	i := clamp(idx, 0, esm.LOD_MODELS - 1)
	for i >= 0 && arr[i] == "" {
		i -= 1
	}
	if i < 0 {
		return "", false
	}
	return arr[i], true
}

// has_lod_models reports whether a base form carries any prebaked distant-LOD meshes.
has_lod_models :: proc(db: ^DB, base_form_id: Form_ID) -> bool {
	return base_form_id in db.base_lod
}

// base_size returns a base form's OBND bounding radius (world units), or 0 if unknown —
// a cheap size proxy for distance/LOD culling without loading the mesh.
base_size :: proc(db: ^DB, base_form_id: Form_ID) -> f32 {
	return db.base_radius[base_form_id] if base_form_id in db.base_radius else 0
}

// ref_by_formid looks up a placed reference by its formID (e.g. an XTEL teleport's
// destination door). Every ref in an indexed cell (interior and exterior) is included.
ref_by_formid :: proc(db: ^DB, form_id: Form_ID) -> (Ref, bool) {
	r, ok := db.ref_by_id[form_id]
	return r, ok
}

// cell_terrain returns a cell's LAND heightmap (a row-major esm.LAND_GRID² grid of
// cumulative heights — world Z = value × the terrain height scale). ok=false for
// cells without a LAND record (interiors, and exterior cells that have none).
cell_terrain :: proc(db: ^DB, cell_form_id: Form_ID) -> ([]f32, bool) {
	h, ok := db.cell_heights[cell_form_id]
	return h, ok
}

// cell_water returns a cell's resolved flat-water-plane height (sentinel + worldspace
// default already folded in at index time). ok=false when the cell has no water.
cell_water :: proc(db: ^DB, cell_form_id: Form_ID) -> (height: f32, ok: bool) {
	c, found := db.cells[cell_form_id]
	if !found || c.water_height == esm.WATER_NONE {
		return 0, false
	}
	return c.water_height, true
}

// cell_base_textures returns a cell's per-quadrant base landscape texture formIDs
// (0=SW,1=SE,2=NW,3=NE; 0 where a quadrant has none). ok=false for cells with no LAND
// texture data. Resolve each formID to a diffuse path with landscape_diffuse.
cell_base_textures :: proc(db: ^DB, cell_form_id: Form_ID) -> ([4]Form_ID, bool) {
	bt, ok := db.cell_base_tex[cell_form_id]
	return bt, ok
}

// cell_dominant_texture returns a cell's per-vertex dominant-texture grid (row-major
// esm.LAND_GRID², each the LTEX formID most opaque at that vertex). Drives per-point
// grass type/presence. ok=false for cells without LAND texture layers.
cell_dominant_texture :: proc(db: ^DB, cell_form_id: Form_ID) -> ([]Form_ID, bool) {
	d, ok := db.cell_dominant[cell_form_id]
	return d, ok
}

// grass_for_texture resolves the grass type scattered over terrain painted with an LTEX
// (LTEX → GNAM → GRAS), returning the grass cluster model + density. ok=false if the
// texture has no grass (no GNAM) or the GRAS is unknown.
grass_for_texture :: proc(db: ^DB, ltex_form_id: Form_ID) -> (Grass, bool) {
	gras, ok := db.ltex_grass[ltex_form_id]
	if !ok {
		return {}, false
	}
	g, gok := db.grasses[gras]
	return g, gok
}

// landscape_diffuse resolves an LTEX formID to its diffuse texture path, following
// LTEX → TNAM → TXST → TX00. ok=false if any link is missing.
landscape_diffuse :: proc(db: ^DB, ltex_form_id: Form_ID) -> (string, bool) {
	txst, ok := db.ltex_txst[ltex_form_id]
	if !ok {
		return "", false
	}
	path, pok := db.txst_diffuse[txst]
	return path, pok
}

// cell_by_formid looks up a cell's identity by formID.
cell_by_formid :: proc(db: ^DB, form_id: Form_ID) -> (Cell, bool) {
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
			index_ref(db, rec, ctx)
			// An exterior ref under a cell's PERSISTENT children GRUP (ctx.temporary=false)
			// marks that cell as the worldspace's persistent cell — it holds worldspace-wide
			// refs (load doors, bridges, gates) at absolute coords, NOT confined to a grid
			// cell. Recorded once (the persistent cell precedes grid cells in world-children).
			if ctx.world_form_id != 0 && !ctx.temporary {
				if _, seen := db.world_persist[ctx.world_form_id]; !seen {
					db.world_persist[ctx.world_form_id] = ctx.cell_form_id
				}
			}
		}
	case s == "LAND":
		// Exterior terrain heightmap. LAND lives in its cell's children GRUP, so
		// ctx.cell_form_id names the owning cell (set before this record is reached).
		if ctx.cell_form_id != 0 {
			index_land(db, rec, ctx.cell_form_id, ctx.fm)
		}
	case s == "LTEX":
		index_ltex(db, rec, ctx.fm)
	case s == "TXST":
		index_txst(db, rec)
	case s == "GRAS":
		index_gras(db, rec)
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
	if old, ok := db.worlds[rec.form_id]; ok {
		delete(old, db.allocator) // override: free the previous clone
	}
	db.worlds[rec.form_id] = strings.clone(edid, db.allocator)
	if edid != "" {
		key := strings.to_lower(edid, context.temp_allocator)
		if _, seen := db.world_by_edid[key]; !seen {
			db.world_by_edid[strings.clone(key, db.allocator)] = rec.form_id
		}
	}
	// Default water height — the level a child cell's XCLW sentinel resolves to. WRLD
	// precedes its CELL children in the walk, so it's recorded before any cell reads it.
	if wh, ok := esm.world_water_height(fl); ok && abs(wh) <= esm.WATER_MAX_PLAUSIBLE {
		db.world_water[rec.form_id] = wh
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
		water_height  = esm.WATER_NONE,
	}
	// Resolve the cell's water height once, here: a real XCLW wins; the WATER_NONE
	// sentinel (FLT_MAX) falls back to the worldspace default (the ocean at sea level —
	// most exterior cells use this); no XCLW at all (interiors, border cells) = no water.
	if h, ok := esm.cell_water_height(fl); ok {
		if h == esm.WATER_NONE {
			if def, dok := db.world_water[ctx.world_form_id]; dok {
				cell.water_height = def
			}
		} else if abs(h) <= esm.WATER_MAX_PLAUSIBLE {
			cell.water_height = h
		}
		// else: a non-FLT_MAX "no water" marker (e.g. 0xCF000000) → leave WATER_NONE.
	}
	if wt, ok := esm.cell_water_type(fl); ok {
		cell.water_type = esm.remap_form(ctx.fm, wt) // XCWT references a WATR form
	}
	if gx, gy, gok := esm.cell_grid(fl); gok {
		cell.gx, cell.gy, cell.has_grid = gx, gy, true
		if ctx.world_form_id != 0 {
			db.cell_at_grid[Grid_Key{ctx.world_form_id, gx, gy}] = rec.form_id
		}
	}
	old, existed := db.cells[rec.form_id]
	if existed {
		delete(old.editor_id, db.allocator) // override: free the previous clone
	}
	db.cells[rec.form_id] = cell
	if edid != "" {
		key := strings.to_lower(edid, context.temp_allocator)
		if _, seen := db.cell_by_edid[key]; !seen {
			db.cell_by_edid[strings.clone(key, db.allocator)] = rec.form_id
		}
	}
	// Group exterior cells under their worldspace so the world loader can gather them —
	// only on first sighting, so an override doesn't list the same cell twice.
	if ctx.world_form_id != 0 && !existed {
		cells, found := &db.world_cells[ctx.world_form_id]
		if !found {
			db.world_cells[ctx.world_form_id] = make([dynamic]Form_ID, 0, 64, db.allocator)
			cells = &db.world_cells[ctx.world_form_id]
		}
		append(cells, rec.form_id)
	}
}

@(private)
index_ref :: proc(db: ^DB, rec: esm.Record, ctx: esm.Walk_Context) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	cell_form_id := ctx.cell_form_id
	p := esm.decode_refr(fl)
	ref := Ref {
		form_id      = rec.form_id,
		cell_form_id = cell_form_id,
		base         = esm.remap_form(ctx.fm, p.base), // NAME references a base form
		pos          = p.pos,
		rot          = p.rot,
		scale        = p.scale,
		// "Initially Disabled" OR a DELETED override (a plugin removing a master's ref):
		// either way the ref isn't placed. Treating delete as disable keeps the slot so the
		// override replaces in place rather than leaving a hole.
		disabled     = rec.flags & (REFR_INITIALLY_DISABLED | REFR_DELETED) != 0,
	}
	if tp, has := esm.refr_teleport(fl); has {
		tp.door = esm.remap_form(ctx.fm, u32(tp.door)) // XTEL references the destination door
		ref.teleport = tp
		ref.has_tp = true
	}

	// Override: a later plugin re-declaring this REFR formID replaces it in place (preserves
	// cell-array order). Otherwise append and remember where it landed. (A relocation to a
	// different cell — vanishingly rare in the official masters — replaces the old slot.)
	if loc, seen := db.ref_index[rec.form_id]; seen {
		db.cell_refs[loc.cell][loc.idx] = ref
	} else {
		refs, found := &db.cell_refs[cell_form_id]
		if !found {
			db.cell_refs[cell_form_id] = make([dynamic]Ref, 0, 64, db.allocator)
			refs = &db.cell_refs[cell_form_id]
		}
		append(refs, ref)
		db.ref_index[rec.form_id] = Ref_Loc{cell_form_id, len(refs) - 1}
	}
	db.ref_by_id[rec.form_id] = ref
}

@(private)
index_land :: proc(db: ^DB, rec: esm.Record, cell_form_id: Form_ID, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	if h, hok := esm.land_heights(fl, db.allocator); hok {
		if old, exists := db.cell_heights[cell_form_id]; exists {
			delete(old, db.allocator) // override: free the previous heightmap
		}
		db.cell_heights[cell_form_id] = h
	}
	if raw := esm.land_base_textures(fl); raw != {} {
		bt: [4]Form_ID
		for q, i in raw {
			bt[i] = esm.remap_form(fm, q) // each quadrant base is an LTEX form
		}
		db.cell_base_tex[cell_form_id] = bt
	}

	// Build the per-vertex dominant-texture grid (esm.LAND_GRID²): start each quadrant at
	// its base texture, then let any ATXT layer with higher opacity at a vertex win. Drives
	// per-point grass type + presence (so grass follows the painted texture, not a coarse
	// per-quadrant base). Layers come base-first per quadrant.
	if layers, lok := esm.land_layers(fl, context.allocator); lok && len(layers) > 0 {
		defer esm.free_land_layers(layers, context.allocator)
		G :: esm.LAND_GRID
		Q :: G / 2 // 16: a quadrant is 17×17 sharing the centre line at index 16
		dom := make([]Form_ID, G * G, db.allocator)
		opac := make([]f32, G * G) // heap scratch; freed below (walk has no temp reset)
		defer delete(opac)
		for layer in layers {
			ltex := esm.remap_form(fm, layer.ltex) // the painted LTEX, in global space
			x0 := int(layer.quadrant & 1) * Q
			y0 := int((layer.quadrant >> 1) & 1) * Q
			if layer.base {
				for ly in 0 ..= Q {
					for lx in 0 ..= Q {
						gi := (y0 + ly) * G + (x0 + lx)
						if opac[gi] <= 0 {
							dom[gi] = ltex
							opac[gi] = 0.0001 // baseline so any painted layer wins
						}
					}
				}
			} else {
				for a in layer.alpha {
					lx, ly := int(a.point % (Q + 1)), int(a.point / (Q + 1))
					if lx > Q || ly > Q {
						continue
					}
					gi := (y0 + ly) * G + (x0 + lx)
					if a.opacity >= opac[gi] {
						opac[gi] = a.opacity
						dom[gi] = ltex
					}
				}
			}
		}
		if old, exists := db.cell_dominant[cell_form_id]; exists {
			delete(old, db.allocator) // override: free the previous dominant grid
		}
		db.cell_dominant[cell_form_id] = dom
	}
}

@(private)
index_ltex :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	if txst, has := esm.landscape_txst(fl); has {
		db.ltex_txst[rec.form_id] = esm.remap_form(fm, txst) // TNAM references a TXST form
	}
	if gras, has := esm.landscape_grass(fl); has {
		db.ltex_grass[rec.form_id] = esm.remap_form(fm, gras) // GNAM references a GRAS form
	}
}

@(private)
index_gras :: proc(db: ^DB, rec: esm.Record) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	model := esm.model_path(fl)
	if model == "" {
		return
	}
	density, _ := esm.grass_density(fl)
	if old, ok := db.grasses[rec.form_id]; ok {
		delete(old.model, db.allocator) // override: free the previous model clone
	}
	db.grasses[rec.form_id] = Grass{model = strings.clone(model, db.allocator), density = density}
}

@(private)
index_txst :: proc(db: ^DB, rec: esm.Record) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	if path := esm.texture_set_diffuse(fl); path != "" {
		if old, ok := db.txst_diffuse[rec.form_id]; ok {
			delete(old, db.allocator) // override: free the previous path clone
		}
		db.txst_diffuse[rec.form_id] = strings.clone(path, db.allocator)
	}
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
		if old, ok := db.base_models[rec.form_id]; ok {
			delete(old, db.allocator) // override: free the previous clone
		}
		db.base_models[rec.form_id] = strings.clone(model, db.allocator)
	}
	// Prebaked distant-LOD meshes (STAT MNAM): clone the populated slots so the LOD rings load
	// Skyrim's own low-poly meshes instead of decimating at runtime.
	if lods, n := esm.lod_model_paths(fl); n > 0 {
		if old, ok := db.base_lod[rec.form_id]; ok {
			for s in old {
				if s != "" {
					delete(s, db.allocator) // override: free the previous LOD clones
				}
			}
		}
		arr: [esm.LOD_MODELS]string
		for i in 0 ..< esm.LOD_MODELS {
			if lods[i] != "" {
				arr[i] = strings.clone(lods[i], db.allocator)
			}
		}
		db.base_lod[rec.form_id] = arr
	}
	if radius, ok := esm.object_bounds(fl); ok {
		db.base_radius[rec.form_id] = radius
	}
	if rec.type == "DOOR" {
		db.doors[rec.form_id] = true // door-panel base (open-interiors portal cull)
	}
	if rec.type == "TREE" {
		db.trees[rec.form_id] = true // tree base → distant billboard (the _lod_flat.nif beside the mesh)
	}
}

// is_tree reports whether a base formID is a TREE record. TREEs carry no MNAM, so the distant-LOD
// path falls back to Skyrim's prebaked billboard (the _lod_flat.nif beside the full mesh) — see
// world.tree_billboard_for.
is_tree :: proc(db: ^DB, base_form_id: Form_ID) -> bool {
	return base_form_id in db.trees
}

// is_door reports whether a base formID is a DOOR record — the reliable door-panel signal
// (record type), independent of whether the placement is a teleport/load door. Used by the
// open-interiors portal cull to hide the door panel filling the doorway opening.
is_door :: proc(db: ^DB, base: Form_ID) -> bool {
	return base in db.doors
}
