package world

// World / cell scene (ROADMAP Iteration 1 Milestone C; Section E exteriors; Section F
// streaming). Turns gamedb REFR placements into drawable instances at native Skyrim
// units. Lighting, water and collision have since landed; navmesh and actors have not
// (see the HOLEs below). Markers and disabled refs are skipped.
//
// (hole ai-agent :tags ai :sev blocker :needs (package-records navmesh spatial-queries)) actors are capsules that stand where they were placed — no agent, no packages, no schedules, no perception. Every NPC in the world stands still.
// (hole story-actor-dialogue :tags (quest ai) :sev gap :needs (ai-agent scene-system)) no NPC starts a conversation with another: no ADIA story event (163 SMQN, NPC-to-NPC scene quests).
// (hole story-dead-body :tags (quest ai) :sev polish :needs (ai-agent)) finding a body queues no DEAD story event (DA02DeadBody, WIDeadBody01).
// (hole navmesh :tags ai :sev blocker) NAVM is never decoded, so there is no navigable surface and nothing can path even once an agent exists.
//
// A Scene is a MAP of CHUNKS keyed by cell formID, one per loaded cell. An interior is
// a single chunk; a bounded exterior (WhiterunWorld) loads them all up front; the
// open world (Tamriel) streams them in/out around the player (see stream.odin). The
// chunk is the streaming unit and the frustum-culling unit.
//
// Instances reference their model by PATH (borrowed from gamedb, stable for the
// session) and hold a `model` pointer that is nil until the asset is uploaded —
// resolved lazily at draw. The synchronous loaders resolve it immediately (get_model);
// the streamer leaves it nil and the model pops in as the worker delivers it.

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:strings"

import "../physics"

import "../assetdb"
import "../gamedb"
import smath "../math"
import "../render"
import "../vfs"
import "../worldstate"

// Hardcoded marker base forms (invisible editor helpers): XMarker / XMarkerHeading.
XMARKER :: 0x0000_003B
XMARKER_HEADING :: 0x0000_0034

// Scene lighting (sun, ambient, fog, material response) now lives in the per-frame lighting
// UBO, set via render.set_lighting from the active lighting profile (see src/lighting + the
// app's frame loop) — NOT a hardcoded direction here. The draw paths below pass no light.

// Vegetation wind tuning, by "weight". Displacement in the shaders is amplitude×height,
// so SHORT foliage needs a much bigger amplitude than a tree to move a visible amount —
// otherwise small plants look frozen next to swaying trees. Frequency varies too: heavy
// trees sway slowly, light foliage flutters fast. (Grass has its own amplitude on its
// dedicated path.) Visual tuning knobs — amplitude (per world-unit of height) + a
// multiplier on the global wind speed.
TREE_WIND :: f32(0.006) // heavy: small lean
TREE_SPEED :: f32(0.7) // …and slow
PLANT_WIND :: f32(0.13) // light: large amplitude (so short flora still moves visibly)
PLANT_SPEED :: f32(1.5) // …and quick flutter
// …but cap the height that feeds the amplitude, so TALL foliage (shrubs, ferns, vine
// maple) doesn't wave wildly — only short flora scale up to it. World units.
PLANT_HEIGHT_CAP :: f32(45)

// Veg_Kind is a placement's vegetation class, classified ONCE from its model path at
// build time (the string match is the expensive part) and cached on the Instance / batch.
// veg_wind_for then derives the per-frame wind cheaply from it + the global wind.
Veg_Kind :: enum u8 {
	Rigid, // architecture, rocks, clutter — no sway
	Tree,  // `...\Trees\` — heavy, small slow lean
	Plant, // `...\Plants\` — light, large fast flutter
}

// Veg_Shadow_Mode is how vegetation casts sun shadows (the `veg_shadows` setting). Opaque
// geometry (buildings, rocks, tree TRUNKS, terrain) always casts regardless. Off = foliage casts
// nothing; Proxy = trees cast a cheap canopy-hull proxy (plants skip; blacklisted trees cast full);
// Full = trees + plants cast their real alpha-tested geometry (accurate, expensive).
Veg_Shadow_Mode :: enum u8 {
	Off,
	Proxy,
	Full,
}

// veg_classify maps a model path to its vegetation class. The one string lowercase +
// substring scan; call at build/load time, NOT per frame. Trees live under `...\Trees\`,
// other foliage under `...\Plants\`; everything else is rigid.
veg_classify :: proc(path: string) -> Veg_Kind {
	p := strings.to_lower(path, context.temp_allocator)
	switch {
	case strings.contains(p, "trees\\"):
		return .Tree
	case strings.contains(p, "plants\\"):
		return .Plant
	}
	return .Rigid
}

// veg_wind_for returns a class's per-type wind (amplitude, oscillation speed, height cap),
// preserving the global wind DIRECTION. Cheap (a switch) — safe to call per frame.
veg_wind_for :: proc(kind: Veg_Kind, base: render.Wind) -> render.Wind {
	switch kind {
	case .Tree:
		return {dir = base.dir, strength = TREE_WIND, speed = base.speed * TREE_SPEED}
	case .Plant:
		return {dir = base.dir, strength = PLANT_WIND, speed = base.speed * PLANT_SPEED, height_cap = PLANT_HEIGHT_CAP}
	case .Rigid:
		return {dir = base.dir, speed = base.speed} // rigid (strength 0)
	}
	return {dir = base.dir, speed = base.speed}
}

// shape_mat flattens a shape's authored material (specular/glossiness/emissive) into the
// renderer's per-draw material block. The global remap (spec_scale etc.) is applied in-shader
// from the lighting env. Shared by every lit draw path so materials are uniform across them.
shape_mat :: proc(sh: assetdb.Shape) -> render.Material_Params {
	m := sh.material
	return render.Material_Params {
		spec     = {m.spec_color[0], m.spec_color[1], m.spec_color[2], m.spec_strength},
		emissive = {m.emissive_color[0], m.emissive_color[1], m.emissive_color[2], m.emissive_mult},
		params   = {m.glossiness, 0, 0, 0},
	}
}

// veg_phase derives a per-placement wind phase from world position so neighbouring plants
// sway out of sync — while all share the one global wind DIRECTION (no random directions).
veg_phase :: proc(pos: smath.Vec3) -> f32 {
	return pos.x * 0.013 + pos.y * 0.017
}

// is_marker_path reports whether a model is an invisible editor helper (dragon-landing,
// critter/bird-path, link/civil-war markers, etc.) that shouldn't render in-game. Skyrim
// names all such meshes with "marker" in the path; "market" doesn't contain "marker", so
// this is safe. (XMarker/XMarkerHeading base forms are also skipped by formID.)
is_marker_path :: proc(modl: string) -> bool {
	return strings.contains(strings.to_lower(modl, context.temp_allocator), "marker")
}

// is_nonworld_path reports whether a model belongs to a SPECIAL-render system, not static
// world geometry: `Sky\` (the sky dome / clouds — managed by the sky system, would otherwise
// draw as giant opaque quads) and `Water\` (water planes — need a water shader we don't have).
// Both appear as persistent-cell refs; skip them so the persistent statics layer stays clean.
// Folder-prefixed (`sky\`/`water\`) so names like `WRStairsWater01River01` (real geometry,
// not in a Water\ folder) are kept.
is_nonworld_path :: proc(modl: string) -> bool {
	low := strings.to_lower(modl, context.temp_allocator)
	return strings.contains(low, "sky\\") || strings.contains(low, "water\\")
}

// pretty_hidden reports whether --pretty should suppress this WHOLE instance (color, effects,
// shadows, picking): every shape fell back to the white texture, so the entire mesh is CK debug
// geometry (e.g. a pure-marker NIF). Mixed meshes — a real textured effect bundled with an
// untextured debug ring/arrow/route — are NOT caught here; those shed their debug shapes per-shape
// at draw (sh.tex.tex == nil) so the textured part survives. A no-op until s.pretty + model resolve.
pretty_hidden :: proc(s: ^Scene, inst: ^Instance) -> bool {
	return s.pretty && inst.model != nil && inst.model.untextured
}

// instance_world returns the instance's live render transform: its baked static placement, or —
// for a movable-clutter instance carried by a dynamic body (Phase 3b) — that placement moved by
// the body's pose. Derivation: a model vertex's world position is world·v; after the body moves
// to (p, R) we want R·(world·v − pos) + p, which as a matrix is body_transform·translate(−pos)·world
// (translate(−pos) re-bases the rotation on the REFR origin the hull verts were centred relative to).
instance_world :: proc(s: ^Scene, inst: ^Instance) -> smath.Mat4 {
	if inst.dyn_body == 0 || s.phys == nil {
		return inst.world
	}
	return physics.body_transform(s.phys, inst.dyn_body) * smath.translate(-inst.pos) * inst.world
}

// instance_shape_world returns the render transform for ONE shape (index `si`) of an instance. For an
// ARTICULATED item (Phase C) whose shape maps to a movable body, it poses that shape by the body's live
// transform (the board swings, the wheel rolls) using the same follow math as a single dynamic body but
// per-shape. Everything else — ordinary instances, and the static parts of an articulated one — falls
// back to `iworld * sh_local` (the whole-instance pose), so this is a no-op for the common case.
instance_shape_world :: proc(s: ^Scene, inst: ^Instance, iworld, sh_local: smath.Mat4, si: int) -> smath.Mat4 {
	m := inst.model
	if inst.dyn_bodies != nil && m.shape_body != nil && si < len(m.shape_body) && m.shape_body[si] >= 0 {
		if b := inst.dyn_bodies[m.shape_body[si]]; b != 0 {
			return physics.body_transform(s.phys, b) * smath.translate(-inst.pos) * inst.world * sh_local
		}
	}
	return iworld * sh_local
}

CELL_SIZE :: gamedb.CELL_SIZE

// Conservative half-extent added to a chunk's instance-position bounds so culling
// never clips a tall/wide mesh whose origin sits near a cell edge.
CHUNK_MARGIN :: f32(4096)

// Instance_Vis is a placement's render visibility. Show is the default (zero) value.
// Hidden / ShadowOnly are set by the open-interiors experiment to suppress an exterior
// building's shell while the player is inside the inlined interior — the color passes skip
// both. ShadowOnly is reserved: a future shadow/depth pass will still render it, so the
// hidden building keeps casting shadows. Today it behaves like Hidden (no shadow pass yet).
Instance_Vis :: enum u8 {
	Show,
	ShadowOnly,
	Hidden,
}

// Form_ID is the global form handle (= gamedb.Form_ID = u64): (slot<<32)|local.
Form_ID :: gamedb.Form_ID

// Instance is one placed reference: its model (shared, nil until uploaded) referenced
// by path, the raw REFR placement, and a door teleport if this is a load door.
Instance :: struct {
	model_path: string, // borrowed from gamedb (valid for the DB's lifetime)
	model:      ^assetdb.Model, // nil until the asset is uploaded; resolved lazily
	base:       Form_ID,
	form_id:    Form_ID, // this REFR's formID (overlay key — worldstate deltas + settle capture, Phase 3)
	pos:        smath.Vec3,
	rot:        smath.Vec3, // XYZ euler radians (REFR DATA)
	scale:      f32,
	has_tp:     bool,
	tp_door:    Form_ID, // destination door formID (XTEL)
	tp_pos:     smath.Vec3, // XTEL landing position in the DEST cell (arrival placement)
	tp_rot:     smath.Vec3, // XTEL landing rotation (arrival facing)
	vis:        Instance_Vis, // render visibility (Show by default; see Instance_Vis)
	world:      smath.Mat4, // cached trs(pos,rot,scale) — placement is static, so computed once at build
	veg:        Veg_Kind, // cached vegetation class (path match done once, not per frame)
	phys_built: bool, // collision bodies created for this instance (sync_physics, Phase 2e)
	dyn_body:   physics.Body, // movable-clutter dynamic body (0 = none/static); render follows it (Phase 3b)
	dyn_active: bool, // last frame's body-active state — settle (active→asleep) edge → overlay delta (Phase 3c)
	disabled:   bool, // overlay Disabled/Deleted: hidden + no collision (set by apply_overlay / disable_ref)
	// This instance's collision bodies occupy chunk.bodies[body_first : body_first+body_count] and its
	// hinge constraints chunk.constraints[con_first : con_first+con_count] — contiguous slices recorded
	// at build. Lets disable_ref remove just this ref's bodies/constraints live without a per-instance
	// allocation. (Constraints must be removed before the bodies they link — Jolt asserts otherwise.)
	body_first: int,
	body_count: int,
	con_first:  int,
	con_count:  int,
	// dyn_bodies maps a Collision_Body index → its Jolt body, for ARTICULATED instances (>1 movable body
	// linked by hinges — Phase B). nil for the common single-body item (which uses dyn_body). Owned;
	// freed on unload. The debug/collision view reads it to draw each linked body at its live pose.
	dyn_bodies: []physics.Body,
}

// Chunk is one loaded cell's instances + a culling AABB. Exterior cells carry their
// grid coordinate and detail level (lod 0 = full; higher reserved for Section-F LOD).
Chunk :: struct {
	cell_form_id: Form_ID,
	gx, gy:       i32,
	has_grid:     bool,
	lod:          int,
	instances:    [dynamic]Instance,
	actors:       [dynamic]Form_ID, // the actor refs placed here, disabled ones included (app/actors.odin gives them bodies)
	terrain:      [dynamic]Terrain_Patch, // exterior LAND heightmap patches (one per quadrant)
	grass:        [dynamic]Grass_Batch, // scattered grass (one batch per grass type)
	objects:      [dynamic]Obj_Batch, // distant instanced statics (lod ≥ 1; one batch per model)
	water:        render.Mesh, // flat per-cell water plane (zero mesh = none); see water.odin
	has_water:    bool,
	bodies:       [dynamic]physics.Body, // static collision bodies for this chunk's instances (Phase 2e)
	constraints:  [dynamic]physics.Constraint, // hinge joints linking this chunk's articulated bodies (Phase B)
	phys_done:    bool, // every instance's collision bodies are built (skip in sync_physics)
	debug_mesh:   render.Mesh, // collision-hitbox wireframe geometry (world-space); built on demand
	has_debug:    bool,
	lo, hi:       smath.Vec3, // world-space culling bounds (incl. terrain footprint)
}

// Vis_Chunk is one entry in the per-frame flat draw list: the chunk's cull AABB INLINE (so the
// frustum test reads a tight contiguous array, not the scattered big Chunk structs) plus a pointer
// dereferenced only once the chunk passes the test. See cull_begin.
Vis_Chunk :: struct {
	lo, hi: smath.Vec3,
	c:      ^Chunk,
}

// Scene is the loaded world: chunks keyed by cell formID + the asset cache.
Scene :: struct {
	cache:    assetdb.Cache,
	chunks:   map[Form_ID]Chunk,
	// Exterior PERSISTENT-cell refs (load doors, bridges, gates, quest set-dressing) bucketed by the
	// grid cell each one's world position falls in. The ESM groups them logically in one persistent
	// cell at scattered coords, so we spatially re-bucket them once at worldspace load and merge each
	// bucket into its grid chunk as it streams (merge_persistent) — they then load/unload/collide with
	// the grid exactly like normal cell refs, instead of being one always-resident, fully-cooked chunk.
	persistent_by_grid: map[[2]i32][dynamic]gamedb.Ref,
	// frame_chunks is a flat snapshot of the resident chunks (pointers + cull bounds), rebuilt
	// once per frame by cull_begin and iterated by EVERY draw/shadow pass. Walking the chunk MAP
	// directly streams its big inline Chunk values through cache on each of ~9 passes/frame; a
	// flat array of 40-byte entries is the cache-friendly alternative. Pointers stay valid for the
	// frame (no chunk insert/remove happens between cull_begin and end_frame).
	frame_chunks: [dynamic]Vis_Chunk,
	// Baked distant-object LOD: the whole worldspace's distant objects merged per quad into static
	// buffers at load (object_lod.odin), drawn instead of per-cell — keyed by packed quad coord.
	lod_quads: map[u64]Lod_Quad,
	// Baked distant water: per-cell water planes (at their varying heights) merged per quad into one
	// mesh at load (water_lod.odin), so distant lakes/rivers survive the streamer shrink cheaply.
	water_quads: map[u64]Water_Quad,
	lo, hi:   smath.Vec3, // overall AABB of placed refs (spawn framing)
	sel_cell: Form_ID, // selected instance's chunk (0 = none)
	sel_inst: int,
	has_sel:  bool,
	hover_cell: Form_ID, // instance under the cursor this frame (inspect mode)
	hover_inst: int,
	has_hover:  bool,
	last_land_tex: render.Texture, // most recently resolved ground texture (terrain fallback)
	tfield:   Terrain_Field, // CDLOD whole-world height-texture terrain (terrain pivot)
	tree_billboards: map[Form_ID]string, // tree base formID -> resolved _lod_flat.nif path ("" = none); scene-owned
	pretty:   bool, // --pretty: hide untextured white placeholders (effect/bird-route/X markers) in the color + caster passes
	phys:     ^physics.World, // borrowed static-collision world (Phase 2e); nil = physics off for this scene
	dyn_debug: render.Mesh, // per-frame collision-wireframe of DYNAMIC bodies at their live pose (K overlay); rebuilt each draw
	has_dyn_debug: bool,
	dynamic_clutter: bool, // build movable clutter (CLUTTER/PROPS layer + mass>0) as DYNAMIC bodies (Phase 3b/A). Now ON for exteriors too: double precision (RVec3 == f64) makes far-from-origin dynamic bodies safe, and add_dynamic_body keeps each body's shapes LOCAL with the world placement in the f64 body position. Architecture/rocks (static layers) stay static regardless.
	ws:       ^worldstate.World_State, // borrowed world-state overlay (Phase 3c); nil = no persistence layer for this scene
	// resident maps a ref's formID -> where its live Instance currently sits, so a runtime mutation
	// (a Layer-1 verb) can find a loaded ref without scanning every chunk. It's a SELF-HEALING CACHE:
	// find_resident validates each hit against the chunk map and falls back to a scan on a stale/missing
	// entry, so correctness never depends on perfect upkeep at the (duplicated) chunk load/unload sites.
	resident: map[Form_ID]Resident_Ref,
	// Borrowed list the scene appends each cell to when it becomes resident at full detail, so the
	// app can give its refs their scripts (world never touches the script VM). Owned outside every
	// scene, so a scene destroyed before the app drains it loses nothing. nil = nobody listens.
	loaded_cells: ^[dynamic]Form_ID,
}

// Resident_Ref locates a resident instance: its owning cell + index into that chunk's `instances`.
// Resolved (and validated) to a ^Instance on demand — never stored as a pointer, so a chunk map
// rehash or instances-array churn can't dangle it.
Resident_Ref :: struct {
	cell: Form_ID,
	idx:  int,
}

scene_init :: proc(r: ^render.Renderer, v: ^vfs.VFS) -> Scene {
	return Scene {
		cache = assetdb.cache_init(r, v),
		chunks = make(map[Form_ID]Chunk),
		lod_quads = make(map[u64]Lod_Quad),
		water_quads = make(map[u64]Water_Quad),
		resident = make(map[Form_ID]Resident_Ref),
		lo = {max(f32), max(f32), max(f32)},
		hi = {min(f32), min(f32), min(f32)},
	}
}

// cull_begin rebuilds the per-frame flat chunk list (s.frame_chunks) from the chunk map — one
// map walk that every subsequent draw/shadow pass reuses instead of walking the map itself. Call
// ONCE per frame for a scene, AFTER all streaming/loading mutations and BEFORE its first draw
// pass; the captured ^Chunk pointers + AABBs stay valid until the next chunk insert/remove.
cull_begin :: proc(s: ^Scene) {
	clear(&s.frame_chunks)
	for _, &chunk in s.chunks {
		append(&s.frame_chunks, Vis_Chunk{lo = chunk.lo, hi = chunk.hi, c = &chunk})
	}
}

// cache_counts exposes the asset cache's resident model + texture counts and approximate
// payload bytes (memory-growth probe: what D1 eviction bounds).
cache_counts :: proc(
	s: ^Scene,
) -> (models, textures, model_bytes, tex_bytes, cold, cold_bytes, tex_cold, tex_cold_bytes: int) {
	return assetdb.cache_counts(&s.cache)
}

// debug_check_model_refs (verification aid) independently recounts the model refs this scene's live
// holders imply — every resident chunk's instances + grass batches, plus every baked LOD draw — and
// compares to the asset cache's actual refcounts (assetdb.debug_compare_refs). A mismatch is an
// acquire/release imbalance (the classic being the rebuild_resident_overlay F9 trap leaking the old
// instances' refs). ok=true when balanced; otherwise msg names the offending path + want/got. Temp-
// allocated (freed at frame end). Meant for a DEVTOOLS periodic assert while D1 ships dark.
debug_check_model_refs :: proc(s: ^Scene) -> (ok: bool, msg: string) {
	expected := make(map[string]int, 2048, context.temp_allocator)
	bump :: proc(exp: ^map[string]int, path: string) {
		if path == "" {
			return
		}
		exp[strings.to_lower(path, context.temp_allocator)] += 1
	}
	for _, &chunk in s.chunks {
		for inst in chunk.instances {
			bump(&expected, inst.model_path)
		}
		for b in chunk.grass {
			bump(&expected, b.model_path)
		}
	}
	for _, &q in s.lod_quads {
		for d in q.draws {
			bump(&expected, d.model_path)
		}
	}
	bal, path, want, got := assetdb.debug_compare_refs(&s.cache, expected)
	if bal {
		return true, ""
	}
	return false, fmt.tprintf("model-ref imbalance: %q want=%d got=%d", path, want, got)
}

// debug_check_texture_refs (verification aid, D1 slice 2) checks the cache's texture refcounts
// against the resident models (assetdb recounts internally — texture refs derive purely from model
// shapes). Mismatch = a tex_acquire/tex_release imbalance. ok=true when balanced.
debug_check_texture_refs :: proc(s: ^Scene) -> (ok: bool, msg: string) {
	bal, key, want, got := assetdb.debug_check_texture_refs(&s.cache)
	if bal {
		return true, ""
	}
	return false, fmt.tprintf("texture-ref imbalance: %q want=%d got=%d", key, want, got)
}

scene_destroy :: proc(s: ^Scene) {
	release_terrain_field(s)
	for _, &chunk in s.chunks {
		release_chunk_assets(s, &chunk, deindex = false) // resident map is deleted below
	}
	delete(s.chunks)
	if s.has_dyn_debug {render.release_mesh(s.cache.r, s.dyn_debug)}
	free_persistent_grid(s)
	delete(s.persistent_by_grid)
	delete(s.frame_chunks)
	clear_object_lod(s) // release the baked distant-object LOD buffers
	delete(s.lod_quads)
	clear_water_lod(s) // release the baked distant-water meshes
	delete(s.water_quads)
	delete(s.resident)
	assetdb.cache_destroy(&s.cache)
	s^ = {}
}

// release_chunk_assets frees everything a chunk owns — terrain/grass/object buffers, water,
// collision bodies+constraints, the on-demand hitbox wireframe, the instance array — as THE
// one chunk-unload path (rewindow / collapse / retarget / LOD swap / scene teardown all used
// to repeat this block; D1's eviction refcount-release hooks in here once). Also fixes a
// long-standing leak: the hitbox debug_mesh was only ever freed by clear_collision_debug,
// never on chunk unload. `deindex` drops the chunk's refs from the resident index — pass
// false when the whole map is cleared right after (retarget / scene_destroy).
release_chunk_assets :: proc(s: ^Scene, chunk: ^Chunk, deindex := true) {
	// D1 eviction: drop this chunk's model refs (instances + grass batches). Symmetric with
	// acquire_chunk_assets — every path that built the chunk acquired these, so releasing over the
	// CURRENT instance/grass sets rebalances exactly (runtime instance removals — delete_ref,
	// apply_overlay_ref Deleted — release their one instance as they remove it). At zero refs a model
	// becomes cold, then eviction-eligible under the budget.
	for inst in chunk.instances {
		assetdb.model_release(&s.cache, inst.model_path)
	}
	for b in chunk.grass {
		assetdb.model_release(&s.cache, b.model_path)
	}
	release_terrain(s, chunk)
	release_grass(s, chunk)
	release_objects(s, chunk)
	release_chunk_physics(s, chunk)
	release_water(s, chunk)
	if chunk.has_debug {
		render.release_mesh(s.cache.r, chunk.debug_mesh)
		chunk.debug_mesh = {}
		chunk.has_debug = false
	}
	if deindex {
		deindex_instances(s, chunk)
	}
	delete(chunk.instances)
	chunk.instances = nil
	delete(chunk.actors)
	chunk.actors = nil
}

// acquire_chunk_assets records one model ref per instance + grass batch this chunk holds — the
// symmetric counterpart to release_chunk_assets' release loop (D1 eviction). Call once a chunk's
// instance + grass layers are final (after apply_overlay + load_grass), so every model a resident
// chunk draws is pinned against eviction until the chunk unloads. Path-keyed and residency-
// independent, so it's fine to acquire before the async decode finishes (the ref precedes upload).
acquire_chunk_assets :: proc(s: ^Scene, chunk: ^Chunk) {
	for inst in chunk.instances {
		assetdb.model_acquire(&s.cache, inst.model_path)
	}
	for b in chunk.grass {
		assetdb.model_acquire(&s.cache, b.model_path)
	}
}

// chunk_meta makes an empty chunk carrying just a cell's identity + grid (no instances,
// no terrain). Used directly for distant terrain-only LOD chunks; the base of build_chunk.
chunk_meta :: proc(db: ^gamedb.DB, cell_form_id: Form_ID) -> Chunk {
	chunk := Chunk {
		cell_form_id = cell_form_id,
	}
	if c, ok := gamedb.cell_by_formid(db, cell_form_id); ok {
		chunk.gx, chunk.gy, chunk.has_grid = c.gx, c.gy, c.has_grid
	}
	return chunk
}

// build_chunk gathers a cell's placeable refs into a chunk (instances + culling
// bounds), WITHOUT resolving/uploading models (model stays nil). Cheap, main-thread:
// no IO, no GPU. Shared by the sync loaders and the streamer.
build_chunk :: proc(db: ^gamedb.DB, cell_form_id: Form_ID) -> Chunk {
	chunk := chunk_meta(db, cell_form_id)
	append_refs(&chunk, db, gamedb.refs_of(db, cell_form_id))
	append_refs(&chunk, db, gamedb.actors_of(db, cell_form_id))
	return chunk
}

// append_refs turns a slice of ESM refs into renderable/collidable Instances on `chunk`, skipping
// disabled refs, marker base forms, and marker/sky/water meshes, and expanding the chunk's cull
// bounds (CHUNK_MARGIN folded in per-ref so repeated calls accumulate correctly). Shared by
// build_chunk (a cell's own refs) and merge_persistent (the persistent bucket for that grid cell).
append_refs :: proc(chunk: ^Chunk, db: ^gamedb.DB, refs: []gamedb.Ref) {
	m := smath.Vec3{CHUNK_MARGIN, CHUNK_MARGIN, CHUNK_MARGIN}
	lo, hi := chunk.lo, chunk.hi
	if len(chunk.instances) == 0 {
		lo = {max(f32), max(f32), max(f32)}
		hi = {min(f32), min(f32), min(f32)}
	}
	n0 := len(chunk.instances)
	for r in refs {
		if gamedb.is_actor(db, r.base) {
			append(&chunk.actors, r.form_id)
			continue
		}
		if gamedb.ref_effective_disabled(db, r) || r.base == XMARKER || r.base == XMARKER_HEADING {
			continue
		}
		modl, ok := gamedb.model_of(db, r.base)
		if !ok || modl == "" || is_marker_path(modl) || is_nonworld_path(modl) {
			continue
		}
		append(
			&chunk.instances,
			Instance {
				model_path = modl,
				base = r.base,
				form_id = r.form_id,
				pos = r.pos,
				rot = r.rot,
				scale = r.scale,
				has_tp = r.has_tp,
				tp_door = r.teleport.door,
				tp_pos = r.teleport.pos,
				tp_rot = r.teleport.rot,
				world = smath.trs(r.pos, r.rot, r.scale), // static placement — cached for the draw paths
				veg = veg_classify(modl),
			},
		)
		lo = {min(lo.x, r.pos.x - m.x), min(lo.y, r.pos.y - m.y), min(lo.z, r.pos.z - m.z)}
		hi = {max(hi.x, r.pos.x + m.x), max(hi.y, r.pos.y + m.y), max(hi.z, r.pos.z + m.z)}
	}
	if len(chunk.instances) > n0 {
		chunk.lo, chunk.hi = lo, hi
	}
}

// merge_persistent appends the persistent-cell refs that spatially belong to this grid chunk (see
// Scene.persistent_by_grid) as normal Instances — so persistent bridges/gates/quest set-dressing
// load, collide, and unload with the grid cell instead of living in one always-resident chunk.
// No-op for interior/non-grid chunks and grids with no persistent refs.
merge_persistent :: proc(s: ^Scene, db: ^gamedb.DB, chunk: ^Chunk) {
	if !chunk.has_grid {
		return
	}
	if bucket, ok := s.persistent_by_grid[{chunk.gx, chunk.gy}]; ok {
		append_refs(chunk, db, bucket[:])
	}
}

// free_persistent_grid releases the per-grid persistent-ref buckets (each a dynamic array) and the
// map. Called on worldspace retarget (before re-indexing) and at scene teardown.
free_persistent_grid :: proc(s: ^Scene) {
	for _, &bucket in s.persistent_by_grid {
		delete(bucket)
	}
	clear(&s.persistent_by_grid)
}

// Cell_Load_Progress reports interior-load progress (0..1) to a UI callback during the synchronous
// per-instance decode. `user` is an opaque app pointer (the app package can't be imported here). nil =
// no reporting (headless / the streamer path). The model decode+upload loop is the bulk of the load,
// so i/N is an honest fraction.
Cell_Load_Progress :: #type proc "odin" (user: rawptr, frac: f32)

// load_cell loads one cell synchronously (build + resolve every model via get_model)
// and inserts it as a chunk. Returns the instance count. Used for interiors and the
// bounded Whiterun load — NOT the streamer (which decodes off-thread). An optional `progress`
// callback (throttled) reports the per-instance decode fraction so a load screen can show real
// progress instead of a blocking freeze.
load_cell :: proc(s: ^Scene, db: ^gamedb.DB, cell_form_id: Form_ID, progress: Cell_Load_Progress = nil, user: rawptr = nil) -> int {
	chunk := build_overlaid_chunk(s, db, cell_form_id) // ESM baseline ⊕ created refs
	ninst := len(chunk.instances)
	for &inst, i in chunk.instances {
		if m, ok := assetdb.get_model(&s.cache, inst.model_path); ok {
			inst.model = m
		}
		// Report progress every 16 instances (a present per model would dominate the load).
		if progress != nil && ninst > 0 && i % 16 == 0 {
			progress(user, f32(i) / f32(ninst))
		}
	}
	apply_overlay(s, &chunk) // baseline ⊕ overlay: patch moved refs before collision is built (3c)
	expand_scene_bounds(s, chunk)
	load_terrain(s, db, &chunk)
	load_water(s, db, &chunk)
	load_grass(s, db, &chunk)
	acquire_chunk_assets(s, &chunk) // D1: pin instance + grass models (grass now built)
	build_chunk_physics(s, db, &chunk) // static collision (terrain; objects via sync_physics)
	n := len(chunk.instances)
	s.chunks[cell_form_id] = chunk
	index_instances(s, &s.chunks[cell_form_id]) // resident index for runtime mutation lookup
	note_loaded(s, cell_form_id)
	return n
}

// load_worldspace loads every cell of a bounded exterior worldspace (e.g.
// WhiterunWorld) synchronously, as chunks. Returns the total instance count.
load_worldspace :: proc(s: ^Scene, db: ^gamedb.DB, world_form_id: Form_ID) -> int {
	cells := gamedb.cells_of(db, world_form_id)
	total := 0
	for cid in cells {
		total += load_cell(s, db, cid)
	}
	log.infof("world: worldspace 0x%08X → %d cells, %d instances", world_form_id, len(cells), total)
	return total
}

// note_loaded tells whoever listens that a cell is now resident at full detail.
@(private)
note_loaded :: proc(s: ^Scene, cell: Form_ID) {
	if s.loaded_cells != nil {append(s.loaded_cells, cell)}
}

@(private)
expand_scene_bounds :: proc(s: ^Scene, chunk: Chunk) {
	if len(chunk.instances) == 0 {
		return
	}
	for inst in chunk.instances {
		s.lo = {min(s.lo.x, inst.pos.x), min(s.lo.y, inst.pos.y), min(s.lo.z, inst.pos.z)}
		s.hi = {max(s.hi.x, inst.pos.x), max(s.hi.y, inst.pos.y), max(s.hi.z, inst.pos.z)}
	}
}

// spawn returns a sensible camera start: the AABB centre raised toward the top.
// ok=false if nothing was placed.
spawn :: proc(s: ^Scene) -> (pos: smath.Vec3, ok: bool) {
	if len(s.chunks) == 0 || s.hi.z < s.lo.z {
		return {}, false
	}
	c := smath.scale3(s.lo + s.hi, 0.5)
	c.z = s.lo.z + (s.hi.z - s.lo.z) * 0.6
	return c, true
}

// draw renders every visible instance with the camera view-projection `vp`. Culls
// whole chunks against the frustum, then individual instances by bounding sphere.
// Resolves each instance's model lazily (skips ones not yet uploaded by the streamer).
// `wind`/`time` drive the vegetation sway (trees + foliage); rigid statics pass strength 0.
draw :: proc(s: ^Scene, r: ^render.Renderer, vp: smath.Mat4, wind: render.Wind = {}, time: f32 = 0) {
	f := smath.frustum_from_vp(vp)
	// Near terrain is textured through the SHARED blended ground (terrain.frag) — the same array +
	// per-cell index + noise blend as the distant CDLOD tier — so it blends seamlessly instead of
	// showing per-quadrant texture seams. Verts are already world-space (real Z + normals).
	tuni := render.Terrain_Uniforms {
		vp    = vp,
		field = s.tfield.uni_field,
		texel = s.tfield.uni_texel,
	}
	for vc in s.frame_chunks {
		if !smath.aabb_in_frustum(f, vc.lo, vc.hi) {
			continue
		}
		chunk := vc.c
		for p in chunk.terrain {
			render.draw_terrain_near(r, p.mesh, s.tfield.ground, s.tfield.index, tuni)
		}
		for &inst in chunk.instances {
			if inst.vis != .Show {
				continue // hidden / shadow-only (open-interiors shell clip) — no color draw
			}
			if inst.model == nil {
				inst.model = assetdb.model_ptr(&s.cache, inst.model_path)
				if inst.model == nil {
					continue // not streamed in yet
				}
			}
			if pretty_hidden(s, &inst) {
				continue // --pretty: blank-white untextured placeholder — hidden
			}
			// Live render transform (a movable clutter body's pose, or the static placement).
			// Frustum-cull at the LIVE centre so a settled/shoved body is tested where it actually is —
			// culling at the baked origin popped moved clutter out while it was still on screen.
			iworld := instance_world(s, &inst)
			cw := iworld * [4]f32{inst.model.center.x, inst.model.center.y, inst.model.center.z, 1}
			ccenter := [3]f32{cw.x, cw.y, cw.z}
			crad := inst.model.radius * inst.scale
			// Articulated item (dyn_body=0): its parts move with their own bodies, so the baked centre is
			// stale (a rolling cart drove off it, vanishing). Track a live body + widen the sphere to
			// cover the swing/roll.
			if inst.dyn_bodies != nil {
				for b in inst.dyn_bodies {
					if b != 0 {ccenter = physics.body_position(s.phys, b);break}
				}
				crad *= 2
			}
			if !smath.sphere_in_frustum(f, ccenter, crad) {
				continue
			}
			// One global wind direction; per-vegetation amplitude+speed+cap, per-placement phase.
			iw := veg_wind_for(inst.veg, wind)
			phase := veg_phase(inst.pos)
			for sh, si in inst.model.shapes {
				if sh.is_effect {
					continue // ghosted in the translucent draw_effects pass
				}
				if s.pretty && sh.tex.tex == nil {
					continue // --pretty: untextured CK debug shape (bounding ring/arrow baked into the mesh) — hidden
				}
				model := instance_shape_world(s, &inst, iworld, sh.local, si) // Phase C: articulated parts follow their body
				render.draw_mesh(
					r,
					sh.mesh,
					vp,
					model,
					sh.tex,
					sh.alpha_cutoff,
					wind = iw,
					time = time,
					phase = phase,
					normal = sh.normal,
					mat = shape_mat(sh),
				)
			}
		}
	}
}

// draw_casters renders the shadow casters for one cascade: opaque statics + terrain, depth-only,
// culled by the cascade's LIGHT frustum `f` (reuses aabb_in_frustum against the light view-proj).
// Skips effect shapes and alpha-tested foliage (D1 casts opaque only — foliage cutout shadows
// need the alpha-test caster path in D2, else leaves cast solid rectangles). Call between
// render.shadow_cascade and shadow_cascade_end, once per cascade.
draw_casters :: proc(
	s: ^Scene,
	r: ^render.Renderer,
	light_vp: smath.Mat4,
	f: smath.Frustum,
	cam_pos: smath.Vec3,
	max_dist: f32,
	veg: Veg_Shadow_Mode,
) {
	for vc in s.frame_chunks {
		// Hard distance bound (closest point of the chunk AABB to the camera) — keeps the caster
		// set within the shadowed region regardless of the light-frustum cull, so a huge streamed
		// window can't blow up the shadow draw/uniform count.
		cp := smath.Vec3 {
			clamp(cam_pos.x, vc.lo.x, vc.hi.x),
			clamp(cam_pos.y, vc.lo.y, vc.hi.y),
			clamp(cam_pos.z, vc.lo.z, vc.hi.z),
		}
		if smath.length3(cp - cam_pos) > max_dist {
			continue
		}
		if !smath.aabb_in_frustum(f, vc.lo, vc.hi) {
			continue
		}
		chunk := vc.c
		for p in chunk.terrain {
			render.draw_shadow(r, p.mesh, light_vp, smath.Mat4(1)) // terrain verts are world-space
		}
		for &inst in chunk.instances {
			if inst.vis != .Show {
				continue
			}
			if inst.model == nil {
				inst.model = assetdb.model_ptr(&s.cache, inst.model_path)
				if inst.model == nil {
					continue
				}
			}
			if pretty_hidden(s, &inst) {
				continue // --pretty: hidden, so it casts no shadow either
			}
			// Trees in proxy mode cast their cheap canopy-hull ONCE (the leaf shapes are then
			// skipped below); the trunk still casts via its opaque shapes. Blacklisted trees
			// (no proxy built) fall back to full alpha casting.
			is_tree := inst.veg == .Tree
			use_proxy := veg == .Proxy && is_tree && inst.model.has_shadow_proxy
			iworld := instance_world(s, &inst) // live pose if a movable clutter body carries it (3b)
			if use_proxy {
				render.draw_shadow(r, inst.model.shadow_proxy, light_vp, iworld)
			}
			for sh, si in inst.model.shapes {
				if sh.is_effect {
					continue
				}
				if s.pretty && sh.tex.tex == nil {
					continue // --pretty: untextured CK debug shape is hidden, so it casts no shadow either
				}
				if sh.alpha_cutoff <= 0 {
					render.draw_shadow(r, sh.mesh, light_vp, instance_shape_world(s, &inst, iworld, sh.local, si)) // opaque: statics, trunks, branches
					continue
				}
				// Alpha-tested foliage (leaves/plants).
				if use_proxy {
					continue // canopy already cast as the hull proxy
				}
				// Full mode → real cutout shadow; proxy mode + tree but no proxy = blacklisted → full.
				if veg == .Full || (veg == .Proxy && is_tree) {
					render.draw_shadow_alpha(r, sh.mesh, light_vp, instance_shape_world(s, &inst, iworld, sh.local, si), sh.tex, sh.alpha_cutoff)
				}
				// else (Off, or a plant in Proxy mode) → no foliage shadow
			}
		}
	}
}

// draw_effects draws the ADDITIVE effect shapes (BSEffectShaderProperty FX: flowing water,
// fire, light beams) — a separate pass AFTER all opaque geometry so they blend over the
// scene. Same frustum/instance traversal as draw, but only the effect shapes (which draw
// skips). `time` drives each shape's controller-derived UV scroll (the flow/beam motion).
draw_effects :: proc(s: ^Scene, r: ^render.Renderer, vp: smath.Mat4, time: f32 = 0) {
	f := smath.frustum_from_vp(vp)
	for vc in s.frame_chunks {
		if !smath.aabb_in_frustum(f, vc.lo, vc.hi) {
			continue
		}
		chunk := vc.c
		for &inst in chunk.instances {
			if inst.vis != .Show {
				continue // hidden / shadow-only (open-interiors shell clip)
			}
			if inst.model == nil {
				inst.model = assetdb.model_ptr(&s.cache, inst.model_path)
				if inst.model == nil {
					continue
				}
			}
			if !inst.model.has_effect {
				continue // no FX shapes — skip the sphere test + shape scan entirely
			}
			if pretty_hidden(s, &inst) {
				continue // --pretty: blank-white (untextured) FX placeholder — hidden; real effects stay
			}
			cw := inst.world * [4]f32{inst.model.center.x, inst.model.center.y, inst.model.center.z, 1}
			if !smath.sphere_in_frustum(f, {cw.x, cw.y, cw.z}, inst.model.radius * inst.scale) {
				continue
			}
			iworld := instance_world(s, &inst) // live pose if a movable clutter body carries it (3b)
			for sh in inst.model.shapes {
				if !sh.is_effect {
					continue
				}
				if s.pretty && sh.tex.tex == nil {
					continue // --pretty: untextured CK debug effect shape (route/bounding box) — hidden; real FX (textured) stay
				}
				model := iworld * sh.local
				render.draw_effect(r, sh.mesh, vp, model, sh.tex, sh.scroll, time)
			}
		}
	}
}

// draw_highlight overdraws the hovered instance's shapes in the highlight colour (a
// separate pass, after the opaque geometry) so the user sees exactly what a click will
// select. Uses the SAME wind/phase as draw so the highlight tracks a swaying tree. No-op
// when nothing is hovered. `wind`/`time` must match the draw pass.
draw_highlight :: proc(s: ^Scene, r: ^render.Renderer, vp: smath.Mat4, wind: render.Wind = {}, time: f32 = 0) {
	if !s.has_hover {
		return
	}
	chunk, ok := &s.chunks[s.hover_cell]
	if !ok || s.hover_inst < 0 || s.hover_inst >= len(chunk.instances) {
		return
	}
	inst := &chunk.instances[s.hover_inst]
	if inst.model == nil {
		return
	}
	if pretty_hidden(s, inst) {
		return // --pretty: hidden instance isn't pickable, so nothing to highlight
	}
	iw := veg_wind_for(inst.veg, wind)
	phase := veg_phase(inst.pos)
	iworld := instance_world(s, inst) // live pose if a movable clutter body carries it (3b)
	for sh in inst.model.shapes {
		if s.pretty && sh.tex.tex == nil {
			continue // --pretty: untextured CK debug shape is hidden, so don't highlight it
		}
		model := iworld * sh.local
		render.draw_highlight(r, sh.mesh, vp, model, sh.tex, sh.alpha_cutoff, iw, time, phase)
	}
}

// (hole spatial-queries :tags world :sev blocker) pick_nearest is the engine's ONLY ray — a brute-force loop over every loaded instance then every triangle of the survivors, against RENDER meshes with no acceleration structure. One crosshair per frame is fine; a script or AI query rate is not.
// pick_nearest ray-casts (origin + t·dir, dir normalized) against loaded instances and
// returns the nearest hit's chunk + index, by PRECISE ray-vs-FACE — so small detail
// meshes and foliage are selectable, not just whatever has the biggest bounding sphere.
// Three phases per instance: a cheap world-sphere reject, then transform the ray into the
// instance's local space and reject against the tight model AABB, then Möller-Trumbore over
// the model's triangles. `t` is world distance throughout (the inverse folds in 1/scale so
// it stays comparable). Everything runs off the instance's LIVE transform (instance_world) —
// the SAME pose the draw uses — so a movable-clutter item carried by a dynamic body is
// selectable where it actually is, not at its baked spawn placement. Pure query — mutates nothing.
@(private)
pick_nearest :: proc(s: ^Scene, origin, dir: smath.Vec3) -> (cell: Form_ID, idx: int, shape: int, dist: f32, ok: bool) {
	best_cell: Form_ID
	best_inst := -1
	best_shape := -1
	best_t := max(f32)
	for cid, &chunk in s.chunks {
		for &inst, ii in chunk.instances {
			m := inst.model
			if m == nil || assetdb.pick_index_count(m) == 0 {
				continue
			}
			if s.pretty && m.untextured {
				continue // --pretty: blank-white placeholder isn't selectable
			}
			// Live pose — a dynamic-body item has moved off its baked placement (matches the draw).
			iw := instance_world(s, &inst)
			ipos_h := iw * [4]f32{0, 0, 0, 1} // live instance origin (model-local 0 → world)
			ipos := smath.Vec3{ipos_h.x, ipos_h.y, ipos_h.z}
			// Cheap broad reject: a conservative world sphere around the live origin
			// (radius covers the off-origin model centre), before the inverse.
			rad := (m.radius + smath.length3(m.center)) * inst.scale
			oc := ipos - origin
			tca := smath.dot3(oc, dir)
			if tca < -rad {
				continue // entirely behind the eye
			}
			if smath.dot3(oc, oc) - tca * tca > rad * rad {
				continue // ray misses the bounding sphere
			}
			// Transform the ray into the instance's local (model) space via the live transform's
			// inverse. The inverse folds in 1/scale, so the intersection `t` stays in world units.
			invw := linalg.inverse(iw)
			lo_h := invw * [4]f32{origin.x, origin.y, origin.z, 1}
			ld_h := invw * [4]f32{dir.x, dir.y, dir.z, 0}
			lo_o := smath.Vec3{lo_h.x, lo_h.y, lo_h.z}
			ld := smath.Vec3{ld_h.x, ld_h.y, ld_h.z}
			if tb, hit := ray_aabb(lo_o, ld, m.lo, m.hi); !hit || tb >= best_t {
				continue
			}
			// Precise: nearest front-facing triangle (positions dequantized per test —
			// see assetdb.pick_vertex; error ≤ extent/65535, far below pick tolerance).
			for i := 0; i + 2 < assetdb.pick_index_count(m); i += 3 {
				a := assetdb.pick_vertex(m, assetdb.pick_index(m, i))
				b := assetdb.pick_vertex(m, assetdb.pick_index(m, i + 1))
				c := assetdb.pick_vertex(m, assetdb.pick_index(m, i + 2))
				if t, hit := ray_triangle(lo_o, ld, a, b, c); hit && t < best_t {
					best_t = t
					best_cell, best_inst = cid, ii
					best_shape = int(m.pick_shape[i / 3]) if i / 3 < len(m.pick_shape) else -1
				}
			}
		}
	}
	if best_inst < 0 {
		return 0, -1, -1, 0, false
	}
	return best_cell, best_inst, best_shape, best_t, true
}

// ray_aabb slab test. Returns the entry distance (negative if the origin is inside) and
// whether the ray meets the box at all (in front of, or surrounding, the origin).
ray_aabb :: proc(o, d, lo, hi: smath.Vec3) -> (t: f32, hit: bool) {
	tmin := -max(f32)
	tmax := max(f32)
	for i in 0 ..< 3 {
		if abs(d[i]) < 1e-9 {
			if o[i] < lo[i] || o[i] > hi[i] {
				return 0, false // parallel and outside this slab
			}
		} else {
			inv := 1.0 / d[i]
			t1 := (lo[i] - o[i]) * inv
			t2 := (hi[i] - o[i]) * inv
			if t1 > t2 {t1, t2 = t2, t1}
			tmin = max(tmin, t1)
			tmax = min(tmax, t2)
			if tmin > tmax {
				return 0, false
			}
		}
	}
	if tmax < 0 {
		return 0, false // box entirely behind the origin
	}
	return tmin, true
}

// ray_triangle: Möller-Trumbore, two-sided (meshes draw with cull_mode NONE). Returns the
// forward hit distance, or hit=false on a miss / parallel / behind-the-origin.
@(private)
ray_triangle :: proc(o, d, v0, v1, v2: smath.Vec3) -> (t: f32, hit: bool) {
	EPS :: f32(1e-7)
	e1 := v1 - v0
	e2 := v2 - v0
	p := smath.cross3(d, e2)
	det := smath.dot3(e1, p)
	if abs(det) < EPS {
		return 0, false // ray parallel to the triangle
	}
	inv := 1.0 / det
	tv := o - v0
	u := smath.dot3(tv, p) * inv
	if u < 0 || u > 1 {
		return 0, false
	}
	q := smath.cross3(tv, e1)
	v := smath.dot3(d, q) * inv
	if v < 0 || u + v > 1 {
		return 0, false
	}
	t = smath.dot3(e2, q) * inv
	if t <= EPS {
		return 0, false // behind the origin
	}
	return t, true
}

// pick selects the nearest instance along the ray (for the Inspector). Returns the instance
// and the index of the SHAPE the ray hit (-1 if unknown). ok=false on a miss.
pick :: proc(s: ^Scene, origin, dir: smath.Vec3) -> (inst: ^Instance, shape: int, ok: bool) {
	cell, idx, shp, _, hit := pick_nearest(s, origin, dir)
	if !hit {
		s.has_sel = false
		return nil, -1, false
	}
	s.sel_cell, s.sel_inst, s.has_sel = cell, idx, true
	chunk := &s.chunks[cell]
	return &chunk.instances[idx], shp, true
}

// hover_pick records the nearest instance along the ray as the HOVERED one (cursor inspect
// mode) without changing the selection. Returns the instance + the hit SHAPE index (-1 if
// unknown). ok=false on a miss (clears the hover). The hovered instance is drawn highlighted.
hover_pick :: proc(s: ^Scene, origin, dir: smath.Vec3) -> (inst: ^Instance, shape: int, ok: bool) {
	cell, idx, shp, _, hit := pick_nearest(s, origin, dir)
	if !hit {
		s.has_hover = false
		return nil, -1, false
	}
	s.hover_cell, s.hover_inst, s.has_hover = cell, idx, true
	chunk := &s.chunks[cell]
	return &chunk.instances[idx], shp, true
}

// probe_ray returns the nearest instance along the ray and its world-unit hit distance WITHOUT
// touching hover/selection state — the read-only pick the activation crosshair uses each frame.
// ok=false on a miss.
probe_ray :: proc(s: ^Scene, origin, dir: smath.Vec3) -> (inst: ^Instance, dist: f32, ok: bool) {
	cell, idx, _, t, hit := pick_nearest(s, origin, dir)
	if !hit {
		return nil, 0, false
	}
	chunk := &s.chunks[cell]
	return &chunk.instances[idx], t, true
}

// clear_hover drops the hover highlight (call when inspect mode is off).
clear_hover :: proc(s: ^Scene) {
	s.has_hover = false
}

// select_instance promotes the currently-hovered instance to the selection (on click).
select_instance :: proc(s: ^Scene) {
	if s.has_hover {
		s.sel_cell, s.sel_inst, s.has_sel = s.hover_cell, s.hover_inst, true
	}
}

// selected returns the currently-selected instance, if any.
selected :: proc(s: ^Scene) -> (^Instance, bool) {
	if !s.has_sel {
		return nil, false
	}
	chunk, ok := &s.chunks[s.sel_cell]
	if !ok || s.sel_inst < 0 || s.sel_inst >= len(chunk.instances) {
		return nil, false
	}
	return &chunk.instances[s.sel_inst], true
}
