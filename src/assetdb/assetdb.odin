package assetdb

// Runtime asset cache (ROADMAP Iteration 1 Milestone C; Section F streaming). Loads
// models on demand, deduped by path. The load is split into two halves so the
// streamer can run the heavy part off the main thread WITHOUT a hitch:
//
//   decode_model  — pure CPU: VFS read (BSA+zlib via thread-safe pread) → NIF parse →
//                   DDS parse → owned CPU vertex/index/pixel buffers. NO GPU, NO cache
//                   access → safe to call from a worker thread.
//   upload_cpu_model — MAIN thread only: turns a Cpu_Model into GPU resources, deduped
//                      by path into the Cache. This is the only half that touches
//                      SDL3_gpu (through render) and the cache maps.
//
// get_model stays as the synchronous convenience (decode+upload in one call, via the
// temp allocator) for interiors / the bounded Whiterun load. The streamer instead
// calls decode_model on the worker (into an explicit heap allocator) and
// upload_cpu_model + free_cpu_model on the main thread.

import "core:log"
import "core:slice"
import "core:strings"

import "../formats/dds"
import "../collisions"
import "../formats/nif"
import smath "../math"
import "../models"
import "../render"
import "../vfs"

// --- GPU side (main thread) ---

// Shape is one uploaded sub-mesh: GPU mesh, diffuse texture (shared, owned by the
// texture cache), and the NIF-internal transform placing it in model space.
Shape :: struct {
	mesh:         render.Mesh,
	tex:          render.Texture,
	normal:       render.Texture, // normal map (cache-owned; flat-normal fallback at draw if zero)
	material:     nif.Material, // specular/glossiness/emissive scalars (DEFAULT_MATERIAL if none)
	diffuse_path: string, // owned diffuse texture path ("" = none) — for inspect + texture-based cull
	normal_path:  string, // owned normal-map texture path ("" = none) — D1: recompute the tex key at model evict
	local:        smath.Mat4,
	alpha_cutoff: f32, // alpha-test threshold in [0,1] (0 = opaque); foliage cutouts
	lod_tris:     [3]u32, // BSLODTriShape per-level triangle partition ({0,0,0} = none)
	is_effect:    bool, // BSEffectShaderProperty — draw additive (translucent), not opaque
	scroll:       [2]f32, // effect-shader UV scroll speed (tiles/sec); 0 unless animated
}

// Model is a loaded NIF: drawable shapes + a model-space bounding sphere (frustum cull) +
// the model it is + CPU pick geometry (model-space triangle positions, all
// shapes concatenated) for precise ray-vs-face mouse picking. The pick geometry is the
// only CPU copy retained after upload — and it's stored COMPACT (D1 measurements: the old
// f32/u32 copy was over half the size of the render mesh itself): positions quantized to
// u16 on the model AABB (decode with pick_vertex — max error extent/65535, far below pick
// tolerance), u16 indices when the model fits, u16 per-tri shape map.
Model :: struct {
	id:       models.ID,
	shapes:   []Shape,
	center:   smath.Vec3,
	radius:   f32,
	lo, hi:   smath.Vec3, // tight model-space AABB (broad-phase pick cull + the pick dequant frame)
	pick_pos: [][3]u16, // model-space vertex positions, quantized on [lo,hi] (pick_vertex decodes), owned
	pick_step: smath.Vec3, // dequant step per axis: (hi-lo)/65535 (0 on a flat axis)
	pick_idx16: []u16, // triangle indices into pick_pos (3 per face) — exactly ONE of idx16/idx32 is set…
	pick_idx32: []u32, // …(u32 only for models with more than 65536 concatenated verts), owned
	pick_shape: []u16, // per-triangle shape index (len = tri count) — maps a hit face to its Shape, owned
	has_effect: bool, // any shape is a BSEffectShaderProperty FX — lets draw_effects skip non-FX models
	untextured: bool, // EVERY shape resolved to the white-fallback texture (uploaded diffuse handle nil:
	                  // no texture named, or named one that's missing/undecodable) — i.e. the model renders
	                  // as a flat white placeholder. --pretty hides these; a real textured mesh (incl.
	                  // effects: rapids/fire/mist) has at least one bound diffuse, so untextured=false.
	shadow_proxy: render.Mesh, // low-poly canopy hull for cheap tree shadows (Phase D2); zero mesh if none
	has_shadow_proxy: bool, // canopy substantial enough for a proxy (else cast full alpha)
	// shape_body maps each render Shape → the movable Collision_Body (index) that drives it, for
	// ARTICULATED models only (hinged signs/carts — Phase C); -1 = static. nil for ordinary models.
	// The world layer poses a mapped shape by its live body transform so the visible mesh swings/rolls.
	shape_body:   []int,
	// Approximate resident footprint of THIS model (GPU mesh buffers + CPU pick geometry),
	// summed at upload. Feeds the cache byte tally (diag probe) and, later, the D1 eviction
	// budget — eviction subtracts exactly what upload added.
	bytes: int,
}

// pick_index_count returns the model's pick-triangle index count (0 = no pick geometry).
pick_index_count :: #force_inline proc(m: ^Model) -> int {
	return len(m.pick_idx16) if m.pick_idx16 != nil else len(m.pick_idx32)
}

// pick_index reads pick index k from whichever width the model stores.
pick_index :: #force_inline proc(m: ^Model, k: int) -> u32 {
	return u32(m.pick_idx16[k]) if m.pick_idx16 != nil else m.pick_idx32[k]
}

// pick_vertex dequantizes pick vertex i back to model space (lo + q·step per axis).
pick_vertex :: #force_inline proc(m: ^Model, i: u32) -> [3]f32 {
	q := m.pick_pos[i]
	return {
		m.lo.x + f32(q.x) * m.pick_step.x,
		m.lo.y + f32(q.y) * m.pick_step.y,
		m.lo.z + f32(q.z) * m.pick_step.z,
	}
}

// lod_index_count returns how many indices to draw for a shape at LOD `level` (0=full,
// 1=mid, 2=coarse), per the confirmed BSLODTriShape convention: the triangle list is
// coarse-complete-first, so each level draws a PREFIX (first N triangles). Level 0 (or a
// shape with no built-in LOD) returns 0 = "draw the whole mesh".
lod_index_count :: proc(lod_tris: [3]u32, level: int) -> u32 {
	if lod_tris == {0, 0, 0} || level <= 0 {
		return 0 // no LOD data, or full detail → whole mesh
	}
	tris := lod_tris[0] + lod_tris[1] if level == 1 else lod_tris[0] // level ≥2 = coarsest
	return tris * 3
}

// TEXTURE_MAX_DIM caps uploaded texture resolution (longest side, pixels) by dropping the
// DDS's own leading mips at upload — no resampling, so a texture that ships without a mip
// chain keeps its single level regardless. 0 (default) = full resolution. A memory/quality
// knob (settings `texture_max_dim`, read at boot): vanilla LE tops out at 2048 so the win
// there is modest, but high-res mod texture packs (2K/4K) shrink 4–16× per capped texture.
TEXTURE_MAX_DIM := 0

// capped_mips applies TEXTURE_MAX_DIM: the upload starts at the first mip level within the
// cap (mip data is a view into the decoded blob, so this is free).
@(private)
capped_mips :: proc(mips: []render.Tex_Mip) -> []render.Tex_Mip {
	if TEXTURE_MAX_DIM <= 0 || len(mips) == 0 {
		return mips
	}
	cap := u32(TEXTURE_MAX_DIM)
	for m, i in mips {
		if m.width <= cap && m.height <= cap {
			return mips[i:]
		}
	}
	return mips[len(mips) - 1:] // every level exceeds the cap — keep the smallest we have
}

// MODEL_CACHE_BYTES is the cold-model eviction budget (bytes): the amount of ZERO-REF resident
// model payload (cold list) the cache keeps warm before evicting oldest-first. 0 (default) =
// eviction OFF (the cache stays monotonic — ships DARK so the refcounts can be validated before
// they free anything). Set from settings `model_cache_mb` at boot. NOT the total cache size —
// referenced (in-use) models are never evicted; this bounds only the recently-let-go tail that
// absorbs backtracking without re-decoding. Package var (mirrors TEXTURE_MAX_DIM); the eviction
// budget is shared across every Cache, but each Cache trims only its own cold list.
MODEL_CACHE_BYTES := 0

// (hole cache-eviction :tags (assets unclaimed) :sev gap) both eviction budgets DEFAULT TO 0 (off), so a stock run keeps every model and texture it ever decoded — RSS grows without bound on a long walk. The collision store (src/collisions) never evicts; it is small CPU data.
// TEXTURE_CACHE_BYTES is the texture eviction budget (bytes) — the same cold-LRU scheme as
// MODEL_CACHE_BYTES but for the texture cache (D1 slice 2: textures are ~83% of a region's footprint).
// 0 (default) = eviction OFF. Set from settings `texture_cache_mb`. Terrain-ground textures are PINNED
// (get_texture) and never counted against this — the landscape set is bounded and Scene.last_land_tex
// borrows one of its handles. Only model-referenced textures refcount + evict here.
TEXTURE_CACHE_BYTES := 0

// Tex_Entry is one cached GPU texture plus its D1 bookkeeping: refs = how many resident model shapes
// reference it (terrain never increments this — see `pinned`), bytes = its capped-mips payload (the
// same sum that feeds tex_bytes), pinned = terrain-acquired (never evicted, even at 0 refs).
Tex_Entry :: struct {
	tex:    render.Texture,
	refs:   int,
	bytes:  int,
	pinned: bool,
}

// Cache owns every loaded model + unique texture and frees them on destroy. Mutated
// only on the main thread (upload_cpu_model / get_model); the worker never touches it.
Cache :: struct {
	r:        ^render.Renderer,
	v:        ^vfs.VFS,
	loaded:   map[models.ID]^Model,
	textures: map[string]Tex_Entry, // tex_key(path,srgb) -> entry (key owned); see Tex_Entry
	failed:   map[models.ID]bool, // models that decoded to nothing (missing / no shapes) — don't retry
	store:    ^collisions.Store, // gets each landing model's collision for the sim (nil: none)
	// D1 eviction (models). refs = live holders per model (a resident chunk's
	// instances/grass, a baked LOD draw); set BY the world layer via model_acquire/model_release,
	// independent of residency (a ref can precede the upload). A model with refs>0 is pinned. When
	// refs hits 0 the model — if resident — moves to `cold` (oldest-first, LRU) instead of freeing;
	// trim() frees the oldest cold models once cold_bytes exceeds MODEL_CACHE_BYTES. re-acquiring a
	// cold model revives it (no re-decode).
	refs:       map[models.ID]int,
	cold:       [dynamic]models.ID,
	cold_bytes: int,
	// Texture cold-LRU (slice 2), mirroring the model machinery: tex_cold holds owned clones of
	// zero-ref, non-pinned texture keys (oldest-first); trim_textures frees the oldest once
	// tex_cold_bytes exceeds TEXTURE_CACHE_BYTES.
	tex_cold:       [dynamic]string,
	tex_cold_bytes: int,
	// Running footprint tallies (approximate payload bytes, not allocator-exact): every model/
	// texture upload adds; eviction subtracts. Surfaced by cache_counts → the diag probe, so a
	// long walk's growth is attributable (models vs textures) without a heap profiler.
	model_bytes: int,
	tex_bytes:   int,
}

cache_init :: proc(r: ^render.Renderer, v: ^vfs.VFS, store: ^collisions.Store = nil) -> Cache {
	return Cache {
		r        = r,
		v        = v,
		loaded   = make(map[models.ID]^Model),
		textures = make(map[string]Tex_Entry),
		failed   = make(map[models.ID]bool),
		refs     = make(map[models.ID]int),
		store    = store,
	}
}

// cache_counts reports how many unique models + textures are resident and their approximate
// payload bytes, plus the cold (zero-ref, eviction-eligible) model count + bytes — a memory-growth
// probe. Without a budget the cache is monotonic (cold climbs with the walk); with one the cold
// count/bytes plateau under MODEL_CACHE_BYTES and total model bytes stop growing.
cache_counts :: proc(
	c: ^Cache,
) -> (models, textures, model_bytes, tex_bytes, cold, cold_bytes, tex_cold, tex_cold_bytes: int) {
	return len(c.loaded), len(c.textures), c.model_bytes, c.tex_bytes, len(c.cold), c.cold_bytes,
		len(c.tex_cold), c.tex_cold_bytes
}

// free_model_entry releases everything ONE cached Model owns (GPU meshes, retained CPU pick
// geometry, the struct). Shared by cache_destroy (bulk) and evict_model (single) so the two can
// never drift on WHAT a model frees. Does NOT touch the map slot, the owned map key, or the byte
// tally — the caller handles those (bulk destroy drops the whole map; eviction delete_keys + subtracts).
@(private)
free_model_entry :: proc(c: ^Cache, m: ^Model) {
	for sh in m.shapes {
		render.release_mesh(c.r, sh.mesh)
		delete(sh.diffuse_path)
		delete(sh.normal_path)
	}
	if m.has_shadow_proxy {
		render.release_mesh(c.r, m.shadow_proxy)
	}
	delete(m.shapes)
	delete(m.pick_pos)
	delete(m.pick_idx16)
	delete(m.pick_idx32)
	delete(m.pick_shape)
	delete(m.shape_body)
	free(m)
}

cache_destroy :: proc(c: ^Cache) {
	for _, m in c.loaded {free_model_entry(c, m)}
	delete(c.loaded)
	for key, e in c.textures {
		render.release_texture(c.r, e.tex)
		delete(key)
	}
	delete(c.textures)
	for key in c.tex_cold {
		delete(key)
	}
	delete(c.tex_cold)
	delete(c.failed)
	delete(c.refs)
	delete(c.cold)
	c^ = {}
}

// --- D1 eviction: model refcounting + cold-LRU budget (world layer drives acquire/release) ---

// model_acquire records one live holder for a model. Independent of residency (a chunk acquires
// when it builds, before the async decode finishes), so `refs[model]` can precede the upload. The
// FIRST ref revives it if it was cold (zero-ref-but-resident, awaiting eviction) — no re-decode.
// 0 is a no-op. MAIN THREAD (mutates the cache).
model_acquire :: proc(c: ^Cache, model: models.ID) {
	if model == 0 {
		return
	}
	if n, ok := &c.refs[model]; ok {
		n^ += 1
		return
	}
	c.refs[model] = 1
	uncold(c, model) // if it was resident-but-cold, pull it back out of the eviction queue
}

// model_release drops one live holder. At zero refs the ref entry is removed (owned key freed) and,
// if the model is resident, it moves to the cold list (eligible for eviction) and trim() runs.
// Balanced against model_acquire by the world layer's chunk load/unload. MAIN THREAD.
model_release :: proc(c: ^Cache, model: models.ID) {
	if model == 0 {
		return
	}
	n, ok := &c.refs[model]
	if !ok {
		return // never acquired (defensive — a balanced world layer never hits this)
	}
	n^ -= 1
	if n^ > 0 {
		return
	}
	delete_key(&c.refs, model)
	if m, resident := c.loaded[model]; resident {
		append(&c.cold, model) // oldest-first
		c.cold_bytes += m.bytes
		trim(c)
	}
}

// uncold removes `model` from the cold list (a zero-ref model just re-acquired). Linear scan +
// ordered_remove to keep the list oldest-first for LRU; cold is small (bounded by the budget) and
// this runs only on a re-acquire, not per frame. No-op if the model wasn't cold.
@(private)
uncold :: proc(c: ^Cache, model: models.ID) {
	for ck, i in c.cold {
		if ck == model {
			if m, ok := c.loaded[model]; ok {
				c.cold_bytes -= m.bytes
			}
			ordered_remove(&c.cold, i)
			return
		}
	}
}

// trim evicts oldest cold models while the cold payload exceeds the budget. MODEL_CACHE_BYTES==0
// disables eviction entirely (the dark-ship default). Keeping up to a full budget of cold models
// resident is deliberate — it's the backtracking buffer that absorbs a boundary re-cross without a
// re-decode (evicting eagerly at zero refs would thrash on every cell-line pace-back).
@(private)
trim :: proc(c: ^Cache) {
	for MODEL_CACHE_BYTES > 0 && c.cold_bytes > MODEL_CACHE_BYTES && len(c.cold) > 0 {
		model := c.cold[0] // oldest
		ordered_remove(&c.cold, 0)
		if m, ok := c.loaded[model]; ok {
			c.cold_bytes -= m.bytes
		}
		evict_model(c, model)
	}
}

// evict_model frees a resident model and drops it from the cache (map slot + byte tally).
// Only called by trim on a cold (zero-ref) model — never on one a live holder still points at, so no
// Instance.model / Lod_Draw.model pointer can dangle (releases run only in the stream/scene-mutation
// phase, never mid-render, and a holder still drawing still holds a ref). Frees the same per-model
// set as cache_destroy (shared free_model_entry).
@(private)
evict_model :: proc(c: ^Cache, model: models.ID) {
	m, ok := c.loaded[model]
	if !ok {
		return
	}
	// Release this model's texture refs FIRST — a texture the evicted model was the last holder of
	// becomes cold (own budget). Done here (not in free_model_entry) so cache_destroy's bulk free —
	// which frees the whole texture map separately — never double-frees.
	for sh in m.shapes {
		tex_release(c, sh.diffuse_path, true)
		tex_release(c, sh.normal_path, false)
	}
	c.model_bytes -= m.bytes
	free_model_entry(c, m)
	delete_key(&c.loaded, model)
}

// --- D1 slice 2: texture refcounting + cold-LRU (model uploads acquire, model evictions release) ---

// tex_acquire records one model-shape reference on a texture (by path + color-space slot). Called
// once per shape slot at model upload. No-op for "" or a path that resolved to the white fallback
// (no entry). The first ref revives a cold texture (0-ref-but-resident). Pinned (terrain) textures
// are never in cold, so the uncold scan simply misses them. MAIN THREAD.
@(private)
tex_acquire :: proc(c: ^Cache, path: string, srgb: bool) {
	if path == "" {
		return
	}
	key := tex_key(path, srgb)
	e, ok := &c.textures[key]
	if !ok {
		return // upload failed (white fallback) — nothing to refcount
	}
	if e.refs == 0 {
		tex_uncold(c, key) // was eviction-eligible; a live holder reclaims it
	}
	e.refs += 1
}

// tex_release drops one model-shape reference. At zero refs a non-pinned resident texture moves to
// the texture cold list (then trim_textures). Symmetric with tex_acquire — recomputed from the same
// shape paths at model evict. MAIN THREAD.
@(private)
tex_release :: proc(c: ^Cache, path: string, srgb: bool) {
	if path == "" {
		return
	}
	key := tex_key(path, srgb)
	e, ok := &c.textures[key]
	if !ok {
		return
	}
	if e.refs > 0 {
		e.refs -= 1
	}
	if e.refs == 0 && !e.pinned {
		append(&c.tex_cold, strings.clone(key)) // cold owns its clone
		c.tex_cold_bytes += e.bytes
		trim_textures(c)
	}
}

// tex_uncold removes a texture key from the cold list (re-acquired before eviction). Mirrors uncold.
@(private)
tex_uncold :: proc(c: ^Cache, key: string) {
	for ck, i in c.tex_cold {
		if ck == key {
			if e, ok := c.textures[key]; ok {
				c.tex_cold_bytes -= e.bytes
			}
			delete(ck)
			ordered_remove(&c.tex_cold, i)
			return
		}
	}
}

// trim_textures evicts oldest cold textures while the cold payload exceeds the budget (0 = off).
@(private)
trim_textures :: proc(c: ^Cache) {
	for TEXTURE_CACHE_BYTES > 0 && c.tex_cold_bytes > TEXTURE_CACHE_BYTES && len(c.tex_cold) > 0 {
		key := c.tex_cold[0]
		ordered_remove(&c.tex_cold, 0)
		if e, ok := c.textures[key]; ok {
			c.tex_cold_bytes -= e.bytes
		}
		evict_texture(c, key)
		delete(key) // free the cold clone
	}
}

// evict_texture frees a resident texture and drops it from the cache (GPU release + map slot + owned
// key + byte tally). Only called by trim_textures on a cold (zero-ref, non-pinned) texture — no
// resident model shape's sh.tex/sh.normal handle points at it (all its holders released), so no draw
// handle can dangle.
@(private)
evict_texture :: proc(c: ^Cache, key: string) {
	e, ok := c.textures[key]
	if !ok {
		return
	}
	render.release_texture(c.r, e.tex)
	c.tex_bytes -= e.bytes
	dk, _ := delete_key(&c.textures, key)
	delete(dk)
}

// has_model reports whether a model is already uploaded (main-thread cache hit) — the streamer
// uses this to skip enqueuing a decode for something already resident.
has_model :: proc(c: ^Cache, model: models.ID) -> bool {
	return model in c.loaded
}

// is_failed reports whether a model previously decoded to nothing (missing file or zero drawable
// shapes). The streamer skips re-enqueuing these — a missing mesh referenced by many cells would
// otherwise re-decode on the worker every time its cell rewindows.
is_failed :: proc(c: ^Cache, model: models.ID) -> bool {
	return c.failed[model]
}

// mark_failed records a model as undecodable so it's never retried.
mark_failed :: proc(c: ^Cache, model: models.ID) {
	c.failed[model] = true
	if c.store != nil {collisions.put(c.store, model, nil)}
}

// model_ptr returns the cached model, or nil if not yet uploaded.
model_ptr :: proc(c: ^Cache, model: models.ID) -> ^Model {
	return c.loaded[model]
}

// get_model loads (or returns the cached) model, synchronously. Used by the non-streamed loaders.
// Returns ok=false if the NIF can't be read/parsed or has no drawable shapes.
get_model :: proc(c: ^Cache, model: models.ID) -> (^Model, bool) {
	if m, hit := c.loaded[model]; hit {
		return m, true
	}
	cpu := decode_model(c.v, models.path(model), 0, context.temp_allocator) // temp: freed at frame end
	if !cpu.ok {
		mark_failed(c, model)
		return nil, false
	}
	return upload_cpu_model(c, model, cpu)
}

// get_texture loads (or returns the cached) diffuse texture for a full VFS path (e.g.
// "textures\\landscape\\dirt02.dds"), synchronously. Deduped by path across the cache,
// so a ground texture shared by many cells uploads once. MAIN THREAD. ok=false on
// read/parse/unsupported-format failure (the caller falls back to the white texture).
get_texture :: proc(c: ^Cache, path: string) -> (render.Texture, bool) {
	if path == "" {
		return {}, false
	}
	// Terrain ground = sRGB diffuse: key with tex_key(path, true), the SAME key upload_or_cached_texture
	// stores under (a bare to_lower missed it before — a harmless but wasteful re-decode on every hit).
	key := tex_key(path, true)
	if e, hit := &c.textures[key]; hit {
		// D1 slice 2: PIN — terrain textures are never evicted (bounded landscape set; Scene.last_land_tex
		// borrows one of these handles). Pin even if a MODEL uploaded it first (unpinned, refcounted) and
		// pull it back out of the cold queue if a model had released it to zero.
		if !e.pinned {
			e.pinned = true
			tex_uncold(c, key)
		}
		return e.tex, true
	}
	cpu := decode_texture(c.v, path, alloc = context.temp_allocator) // temp: freed at frame end
	if !cpu.ok {
		return {}, false
	}
	b := render.upload_begin(c.r)
	t := upload_or_cached_texture(c, &b, path, cpu, true) // get_texture is the diffuse (sRGB) path (terrain ground)
	render.upload_end(&b)
	if e, ok := &c.textures[key]; ok {
		e.pinned = true // fresh terrain entry: never evict
	}
	return t, true
}

// upload_cpu_model turns a decoded Cpu_Model into GPU resources and caches it.
// MAIN THREAD ONLY. Does NOT free `cpu` — the caller does (free_cpu_model, or temp
// wipe). Textures dedup across models by path. Returns the cached shared ^Model.
upload_cpu_model :: proc(c: ^Cache, model: models.ID, cpu: Cpu_Model) -> (^Model, bool) {
	if cpu.ok && cpu.extras && c.store != nil {store_collision(c.store, model, cpu)} // the sim's copy, before any GPU work
	if !cpu.ok || len(cpu.shapes) == 0 {
		return nil, false
	}
	if m, hit := c.loaded[model]; hit {
		return m, true // already uploaded (duplicate request) — reuse
	}

	// One batch for the whole model: every shape's mesh + diffuse uploads in a single
	// command buffer + submit (vs one submit per buffer). Textures still dedup by path.
	batch := render.upload_begin(c.r)
	shapes := make([]Shape, len(cpu.shapes))
	has_effect := false
	untextured := true // cleared by the first opaque shape that carries a diffuse texture
	for cs, i in cpu.shapes {
		shapes[i] = Shape {
			mesh         = render.upload_mesh_into(&batch, cs.verts, cs.indices),
			tex          = upload_or_cached_texture(c, &batch, cs.diffuse_path, cs.diffuse, true), // diffuse = sRGB
			normal       = upload_or_cached_texture(c, &batch, cs.normal_path, cs.normal, false), // normal = linear
			material     = cs.material,
			diffuse_path = strings.clone(cs.diffuse_path),
			normal_path  = strings.clone(cs.normal_path),
			local        = cs.local,
			alpha_cutoff = cs.alpha_cutoff,
			lod_tris     = cs.lod_tris,
			is_effect    = cs.is_effect,
			scroll       = cs.scroll,
		}
		// D1 slice 2: this shape references its diffuse + normal texture — record the refs (the
		// texture entry exists after upload_or_cached_texture; a white-fallback path is a no-op).
		// Balanced by evict_model's tex_release over the same shape paths.
		tex_acquire(c, cs.diffuse_path, true)
		tex_acquire(c, cs.normal_path, false)
		has_effect ||= cs.is_effect
		// "Blank white" is exactly the renderer's white-fallback condition: a shape draws
		// r.white_tex when its uploaded diffuse handle is nil — which happens both when the NIF
		// names no texture AND when it names one that's missing/undecodable. Keying on the
		// resolved handle (not the path string) catches the declared-but-unresolvable case too.
		if shapes[i].tex.tex != nil {
			untextured = false
		}
	}
	// Canopy-hull proxy uploads in the SAME batch (must be before upload_end, which submits +
	// frees the batch — uploading after would record into a freed batch and crash).
	proxy_mesh: render.Mesh
	if cpu.has_proxy {
		proxy_mesh = render.upload_mesh_into(&batch, cpu.proxy_verts, cpu.proxy_indices)
	}
	render.upload_end(&batch)

	m := new(Model)
	m.shapes = shapes
	m.id = model
	m.center = cpu.center
	m.radius = cpu.radius
	m.has_effect = has_effect
	m.untextured = untextured
	if cpu.has_proxy {
		m.shadow_proxy = proxy_mesh
		m.has_shadow_proxy = true
	}
	// Instance-only extras (pick copy, articulation map) — skipped for draw-only decodes
	// (want_extras=false: LOD bake meshes, billboards, grass).
	if cpu.extras {
		build_pick_geometry(m, cpu)
		map_articulated_shapes(m, cpu)
	}
	m.bytes = model_bytes(m, cpu)
	c.model_bytes += m.bytes
	c.loaded[model] = m
	// Born cold: if nothing holds a ref by upload time — the requesting chunk unloaded while the
	// decode was in flight — the model is immediately eviction-eligible. Pushing it to cold (rather
	// than dropping it) lets an imminent revisit revive it via model_acquire's uncold path.
	// refs[model] is 0 both when absent (zero value) and when a holder released before the upload landed.
	if c.refs[model] == 0 {
		append(&c.cold, model)
		c.cold_bytes += m.bytes
		trim(c)
	}
	return m, true
}

// model_bytes approximates a cached model's resident footprint: the GPU vertex/index buffers
// (+ shadow proxy) plus the retained CPU copy (pick geometry). Textures are
// tallied separately (shared across models). Payload bytes, not allocator-exact — for the diag
// probe + the eviction budget, where "close and consistent" beats exact.
@(private)
model_bytes :: proc(m: ^Model, cpu: Cpu_Model) -> int {
	b := 0
	for cs in cpu.shapes {
		b += len(cs.verts) * size_of(render.Mesh_Vertex) + len(cs.indices) * size_of(u16)
	}
	b += len(cpu.proxy_verts) * size_of(render.Mesh_Vertex) + len(cpu.proxy_indices) * size_of(u16)
	b += len(m.pick_pos) * size_of([3]u16) + len(m.pick_idx16) * size_of(u16) +
		len(m.pick_idx32) * size_of(u32) + len(m.pick_shape) * size_of(u16)
	b += len(m.shapes) * size_of(Shape)
	return b
}

// map_articulated_shapes builds Model.shape_body for ARTICULATED models (hinged: constraints or >1
// movable body — signs, carts). Each render Shape is matched to the movable Collision_Body it's
// CO-LOCATED with, by CENTROID: a shape whose mesh sits inside a movable body's collision AABB is that
// body's visual, so it's posed by the body's live transform at draw (Phase C — the board swings, the
// wheel rolls). Centroid (not node origin) is required because some NIFs — carts — put every part under
// the root node, offset only in vertices. Static parts (a sign post) match no movable body → -1. No-op
// for ordinary models.
@(private)
map_articulated_shapes :: proc(m: ^Model, cpu: Cpu_Model) {
	nmov := 0
	for b in cpu.collision.bodies {
		if b.movable {nmov += 1}
	}
	if len(cpu.collision.constraints) == 0 && nmov <= 1 {return}

	// Per body: its collision AABB (NIF-root) → centre + radius, for the co-location test.
	Box :: struct {
		lo, hi:  [3]f32,
		movable: bool,
	}
	boxes := make([]Box, len(cpu.collision.bodies), context.temp_allocator)
	for &bx, i in boxes {bx = {lo = {max(f32), max(f32), max(f32)}, hi = {min(f32), min(f32), min(f32)}, movable = cpu.collision.bodies[i].movable}}
	for sh in cpu.collision.shapes {
		if sh.body >= 0 && sh.body < len(boxes) {expand_collision_aabb(&boxes[sh.body].lo, &boxes[sh.body].hi, sh)}
	}

	sb := make([]int, len(m.shapes))
	any := false
	MARGIN :: f32(5) // collision is authored inset from the visual; let the centroid sit just outside
	for cs, i in cpu.shapes {
		sb[i] = -1
		rlo := [3]f32{max(f32), max(f32), max(f32)}
		rhi := [3]f32{min(f32), min(f32), min(f32)}
		for vtx in cs.verts {
			w := cs.local * [4]f32{vtx.pos.x, vtx.pos.y, vtx.pos.z, 1}
			rlo = {min(rlo.x, w.x), min(rlo.y, w.y), min(rlo.z, w.z)}
			rhi = {max(rhi.x, w.x), max(rhi.y, w.y), max(rhi.z, w.z)}
		}
		if rhi.x < rlo.x {continue} // empty shape
		rc := (rlo + rhi) * 0.5
		// The shape belongs to the movable body whose collision box CONTAINS its centroid; when several
		// nested boxes contain it (a wheel sits inside the cart's overall box) the SMALLEST is the true
		// owner. Distance-to-centre fails for large/offset bodies, so use point-in-box. Size = sum of
		// extents (not volume — a flat board has ~0 volume and would spuriously win every overlap).
		best_size := max(f32)
		for bx, k in boxes {
			if !bx.movable || bx.hi.x < bx.lo.x {continue}
			if rc.x < bx.lo.x - MARGIN || rc.x > bx.hi.x + MARGIN {continue}
			if rc.y < bx.lo.y - MARGIN || rc.y > bx.hi.y + MARGIN {continue}
			if rc.z < bx.lo.z - MARGIN || rc.z > bx.hi.z + MARGIN {continue}
			e := bx.hi - bx.lo
			if size := e.x + e.y + e.z; size < best_size {best_size = size;sb[i] = k;any = true}
		}
	}
	if any {m.shape_body = sb} else {delete(sb)}
}

// expand_collision_aabb grows [lo,hi] to cover one collision shape's NIF-root footprint (transform
// applied). Primitive shapes use their extents; mesh/convex use their vertices.
@(private)
expand_collision_aabb :: proc(lo, hi: ^[3]f32, sh: nif.Collision_Shape) {
	add :: proc(lo, hi: ^[3]f32, p: [3]f32) {
		lo^ = {min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)}
		hi^ = {max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)}
	}
	xf :: proc(m: smath.Mat4, p: [3]f32) -> [3]f32 {
		v := m * [4]f32{p.x, p.y, p.z, 1}
		return {v.x, v.y, v.z}
	}
	switch sh.kind {
	case .Mesh, .Convex:
		for v in sh.vertices {add(lo, hi, xf(sh.transform, v))}
	case .Box:
		for sx in ([2]f32{-1, 1}) {
			for sy in ([2]f32{-1, 1}) {
				for sz in ([2]f32{-1, 1}) {
					add(lo, hi, xf(sh.transform, {sh.half_extents.x * sx, sh.half_extents.y * sy, sh.half_extents.z * sz}))
				}
			}
		}
	case .Sphere:
		c := xf(sh.transform, {0, 0, 0})
		add(lo, hi, c - sh.radius);add(lo, hi, c + sh.radius)
	case .Capsule:
		for p in ([2][3]f32{sh.point_a, sh.point_b}) {
			c := xf(sh.transform, p)
			add(lo, hi, c - sh.radius);add(lo, hi, c + sh.radius)
		}
	}
}

// clone_collision deep-copies a parsed Collision into `alloc` (the cache heap) — the cached
// Model owns its own copy, independent of the transient Cpu_Model's buffers.
@(private)
clone_collision :: proc(src: nif.Collision, alloc := context.allocator) -> nif.Collision {
	if len(src.shapes) == 0 {
		return {}
	}
	dst := nif.Collision {
		unhandled = src.unhandled,
		shapes    = make([]nif.Collision_Shape, len(src.shapes), alloc),
	}
	for s, i in src.shapes {
		d := s // scalars + transform + body index
		if len(s.vertices) > 0 {d.vertices = slice.clone(s.vertices, alloc)}
		if len(s.indices) > 0 {d.indices = slice.clone(s.indices, alloc)}
		dst.shapes[i] = d
	}
	// bodies + constraints are POD (no owned pointers) — a flat clone suffices.
	if len(src.bodies) > 0 {dst.bodies = slice.clone(src.bodies, alloc)}
	if len(src.constraints) > 0 {dst.constraints = slice.clone(src.constraints, alloc)}
	return dst
}

// build_pick_geometry fills the model's CPU pick mesh: every shape's vertex positions
// placed by its NIF-internal transform (so they share one model space) + a concatenated
// triangle index list, plus the tight model-space AABB. Used for precise ray-vs-face
// mouse picking (broad-phased by the AABB). Positions only — no normals/UVs — and stored
// quantized (see the Model doc): pass 1 transforms into a temp buffer + finds the AABB,
// pass 2 snaps each position onto the u16 grid over it.
@(private)
build_pick_geometry :: proc(m: ^Model, cpu: Cpu_Model) {
	nverts, nidx := 0, 0
	for cs in cpu.shapes {
		nverts += len(cs.verts)
		nidx += len(cs.indices)
	}
	if nverts == 0 {
		return
	}
	pos := make([][3]f32, nverts, context.temp_allocator)
	lo := smath.Vec3{max(f32), max(f32), max(f32)}
	hi := smath.Vec3{min(f32), min(f32), min(f32)}
	vbase := 0
	for cs in cpu.shapes {
		for v, i in cs.verts {
			wp := cs.local * [4]f32{v.pos.x, v.pos.y, v.pos.z, 1}
			p := [3]f32{wp.x, wp.y, wp.z}
			pos[vbase + i] = p
			lo = {min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)}
			hi = {max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)}
		}
		vbase += len(cs.verts)
	}
	m.lo, m.hi = lo, hi

	// Quantize onto the AABB grid. step = 0 on a flat axis (every q lands on lo there).
	ext := hi - lo
	m.pick_step = {ext.x / 65535.0, ext.y / 65535.0, ext.z / 65535.0}
	quant :: #force_inline proc(v, lo, step: f32) -> u16 {
		if step <= 0 {return 0}
		return u16(clamp((v - lo) / step + 0.5, 0, 65535))
	}
	m.pick_pos = make([][3]u16, nverts)
	for p, i in pos {
		m.pick_pos[i] = {
			quant(p.x, lo.x, m.pick_step.x),
			quant(p.y, lo.y, m.pick_step.y),
			quant(p.z, lo.z, m.pick_step.z),
		}
	}

	// Concatenated triangle indices: u16 when every index fits (the common case), else u32.
	wide := nverts > 1 << 16
	if wide {
		m.pick_idx32 = make([]u32, nidx)
	} else {
		m.pick_idx16 = make([]u16, nidx)
	}
	m.pick_shape = make([]u16, nidx / 3)
	vbase = 0
	ibase := 0
	for cs, si in cpu.shapes {
		for idx, i in cs.indices {
			if wide {
				m.pick_idx32[ibase + i] = u32(vbase) + u32(idx)
			} else {
				m.pick_idx16[ibase + i] = u16(vbase) + idx
			}
		}
		for t in 0 ..< len(cs.indices) / 3 {
			m.pick_shape[ibase / 3 + t] = u16(si)
		}
		vbase += len(cs.verts)
		ibase += len(cs.indices)
	}
}

// debug_compare_refs (verification aid) checks the cache's live model refcounts against an
// EXPECTED set recounted independently from live holders (the world layer walks its chunks +
// LOD draws). Returns the first discrepancy as (model, want, got) or ok=true. It checks BOTH directions — a want not matched by the cache AND a
// cache ref nothing expects (the leaked-ref case, e.g. the rebuild_resident_overlay F9 trap) —
// so acquire/release imbalance surfaces deterministically instead of via a slow RSS plateau.
debug_compare_refs :: proc(c: ^Cache, expected: map[models.ID]int) -> (ok: bool, model: models.ID, want, got: int) {
	for k, w in expected {
		if g := c.refs[k]; g != w { // c.refs[k] is 0 when absent
			return false, k, w, g
		}
	}
	for k, g in c.refs {
		if _, in_exp := expected[k]; !in_exp {
			return false, k, 0, g // a ref no live holder accounts for → leak
		}
	}
	return true, 0, 0, 0
}

// debug_check_texture_refs (verification aid, slice 2) recounts texture refs straight from the
// resident models — every shape's diffuse (sRGB) + normal (linear) key — and compares to each
// entry's live refs. Texture refs derive PURELY from c.loaded (a model shape is the only thing that
// increments), so a mismatch means a tex_acquire/tex_release imbalance. Pinned (terrain) entries are
// skipped — their refs aren't model-driven. Self-contained (no world layer). Temp-allocated.
debug_check_texture_refs :: proc(c: ^Cache) -> (ok: bool, key: string, want, got: int) {
	expected := make(map[string]int, 1024, context.temp_allocator)
	for _, m in c.loaded {
		for sh in m.shapes {
			if sh.diffuse_path != "" {expected[tex_key(sh.diffuse_path, true)] += 1}
			if sh.normal_path != "" {expected[tex_key(sh.normal_path, false)] += 1}
		}
	}
	// Every resident, non-pinned texture's refs must equal the model-shape count referencing it.
	// (A key in `expected` with no entry = a shape whose texture failed to upload / white fallback —
	// tex_acquire was a no-op there, so there's nothing to check; the reverse walk covers the rest.)
	for k, e in c.textures {
		if e.pinned {
			continue
		}
		if w := expected[k]; e.refs != w {
			return false, k, w, e.refs
		}
	}
	return true, "", 0, 0
}

// --- CPU side (thread-safe; no GPU, no cache) ---

// Cpu_Tex is a decoded diffuse texture's CPU pixels: an owned blob + mip views into
// it (ready for render.upload_texture, which only reads the bytes).
Cpu_Tex :: struct {
	ok:     bool,
	format: render.Tex_Format,
	srgb:   bool,
	pixels: []u8, // owned
	mips:   []render.Tex_Mip, // owned; .data slices into pixels
}

// Cpu_Shape is one decoded sub-mesh: owned CPU geometry + its diffuse path + decoded
// diffuse pixels + the NIF-internal transform.
Cpu_Shape :: struct {
	verts:        []render.Mesh_Vertex, // owned
	indices:      []u16, // owned
	diffuse_path: string, // owned ("" if none)
	diffuse:      Cpu_Tex,
	normal_path:  string, // owned ("" if none) — normal-map texture path
	normal:       Cpu_Tex, // decoded normal map (linear, NOT sRGB)
	material:     nif.Material, // specular/glossiness/emissive scalars
	local:        smath.Mat4,
	alpha_cutoff: f32, // alpha-test threshold in [0,1] (0 = opaque)
	lod_tris:     [3]u32, // BSLODTriShape per-level triangle partition ({0,0,0} = none)
	is_effect:    bool, // BSEffectShaderProperty — draw additive
	scroll:       [2]f32, // effect-shader UV scroll speed (tiles/sec)
}

// Cpu_Model is decode_model's output: owned CPU buffers, all allocated in the
// allocator passed to decode_model. Free with free_cpu_model (same allocator).
Cpu_Model :: struct {
	ok:            bool,
	path:          string, // owned
	shapes:        []Cpu_Shape,
	center:        smath.Vec3,
	radius:        f32,
	proxy_verts:   []render.Mesh_Vertex, // canopy-hull shadow proxy (owned; empty if none)
	proxy_indices: []u16, // owned
	has_proxy:     bool,
	collision:     nif.Collision, // bhk* collision shapes (owned in `alloc`; physics, Phase 2e)
	furniture:     []nif.Furniture_Marker, // owned in `alloc`
	projectile:    Maybe(matrix[4, 4]f32), // where it launches projectiles, in model space
	extras:        bool, // decode carried pick/collision/proxy (want_extras) — upload builds them only then
}

// decode_model reads + parses a model into owned CPU buffers (in `alloc`). Pure CPU,
// no GPU, no cache — safe on a worker thread (vfs.read is thread-safe: positional
// pread, no shared cursor). `lod` selects detail level (only 0/full implemented;
// plumbed for Section-F LOD). Intermediate work uses the calling thread's temp
// allocator — the caller should free_all(temp) after each decode. Returns ok=false
// on read/parse failure or zero drawable shapes.
//
// `want_extras` = also decode what only PLACED INSTANCES need: bhk* collision (physics
// build), the canopy shadow proxy, and (at upload) the CPU pick copy. Draw-only decodes —
// the object-LOD bake meshes, tree billboards, grass — pass false and skip all three
// (they are never picked, cooked, or proxy-shadowed). The two request kinds never share
// a model (LOD/billboard/grass NIFs aren't cell-instance models), so the model-keyed cache
// can't conflate a slim decode with a full one.
decode_model :: proc(v: ^vfs.VFS, modl: string, lod: int, alloc := context.allocator, want_extras := true) -> Cpu_Model {
	full := strings.concatenate({"meshes\\", modl}, context.temp_allocator)
	data, ok := vfs.read(v, full, context.temp_allocator)
	if !ok {
		log.warnf("assetdb: model not found: %s", full)
		return {}
	}
	h, hok := nif.parse_header(data, context.temp_allocator)
	if !hok {
		log.warnf("assetdb: bad NIF: %s", full)
		return {}
	}
	placed := nif.parse_scene(data, &h, context.temp_allocator)
	if len(placed) == 0 {
		return {}
	}

	shapes := make([]Cpu_Shape, len(placed), alloc)
	// Within-model diffuse dedup: many shapes of one mesh share a texture (a building's
	// wall set, etc.). Decode each distinct path ONCE; later shapes carry the path with no
	// pixels and pick up the cached GPU texture at upload. (Cross-model dedup still happens
	// at upload — the worker has no cache access by design.)
	seen_tex := make(map[string]bool, 8, context.temp_allocator)
	lo := smath.Vec3{max(f32), max(f32), max(f32)}
	hi := smath.Vec3{min(f32), min(f32), min(f32)}
	for ps, si in placed {
		verts := make([]render.Mesh_Vertex, len(ps.geometry.vertices), alloc)
		for i in 0 ..< len(ps.geometry.vertices) {
			n := smath.Vec3{0, 0, 1}
			if i < len(ps.geometry.normals) {
				n = ps.geometry.normals[i]
			}
			uv := [2]f32{0, 0}
			if i < len(ps.geometry.uvs) {
				uv = ps.geometry.uvs[i]
			}
			// Tangent: prefer the authored NIF basis (matches the baked normal map); else a
			// stable perpendicular to the normal (only matters if a normal map exists w/o
			// authored tangents — rare; usually no tangents ⇔ no normal map).
			t := [4]f32{1, 0, 0, 1}
			if i < len(ps.geometry.tangents) {
				t = ps.geometry.tangents[i]
			} else {
				t = default_tangent(n)
			}
			verts[i] = render.mesh_vertex(ps.geometry.vertices[i], n, uv, t)
		}
		// Model-space bounds: the shape's bounding sphere placed by its NIF transform,
		// expanded into the model AABB (for picking).
		wc := ps.world * [4]f32{ps.geometry.center.x, ps.geometry.center.y, ps.geometry.center.z, 1}
		rad := ps.geometry.radius
		lo = {min(lo.x, wc.x - rad), min(lo.y, wc.y - rad), min(lo.z, wc.z - rad)}
		hi = {max(hi.x, wc.x + rad), max(hi.y, wc.y + rad), max(hi.z, wc.z + rad)}

		dpath := ""
		tex: Cpu_Tex
		if ps.diffuse != "" {
			dpath = strings.clone(ps.diffuse, alloc)
			low := tex_key(ps.diffuse, true) // color-space-tagged: same path as diffuse+normal decodes both
			if !seen_tex[low] {
				seen_tex[low] = true
				tex = decode_texture(v, ps.diffuse, alloc = alloc) // first use → decode; dups stay un-ok
			}
		}
		// Normal map (texture-set slot 1) — decoded LINEAR (srgb=false); deduped like diffuse.
		npath := ""
		ntex: Cpu_Tex
		if ps.normal != "" {
			npath = strings.clone(ps.normal, alloc)
			low := tex_key(ps.normal, false) // linear-tagged (see the diffuse note); distinct from an sRGB use of the same file
			if !seen_tex[low] {
				seen_tex[low] = true
				ntex = decode_texture(v, ps.normal, srgb = false, alloc = alloc)
			}
		}
		shapes[si] = Cpu_Shape {
			verts        = verts,
			indices      = slice.clone(ps.geometry.triangles, alloc),
			diffuse_path = dpath,
			diffuse      = tex,
			normal_path  = npath,
			normal       = ntex,
			material     = ps.material,
			local        = ps.world,
			alpha_cutoff = ps.alpha_cutoff,
			lod_tris     = ps.lod_tris,
			is_effect    = ps.is_effect,
			scroll       = ps.scroll,
		}
	}

	// Instance-only extras (skipped for draw-only decodes — see the doc comment):
	//
	// Canopy-hull shadow proxy: gather the alpha-tested (leaf) shapes' vertices in MODEL space
	// (apply each shape's local transform) and wrap them in a low-poly lathe hull. Built here on
	// the worker (pure CPU); uploaded in upload_cpu_model. ok=false → cast full (blacklist path).
	pv: []render.Mesh_Vertex
	pi: []u16
	phas: bool
	col: nif.Collision
	furn: []nif.Furniture_Marker
	pnode: Maybe(matrix[4, 4]f32)
	if want_extras {
		canopy := make([dynamic][3]f32, 0, 256, context.temp_allocator)
		for ps in placed {
			if ps.alpha_cutoff <= 0 || ps.is_effect {
				continue
			}
			for vtx in ps.geometry.vertices {
				wp := ps.world * [4]f32{vtx.x, vtx.y, vtx.z, 1}
				append(&canopy, [3]f32{wp.x, wp.y, wp.z})
			}
		}
		pv, pi, phas = build_canopy_proxy(canopy[:], alloc)

		// bhk* collision (Phase 2e physics): pure CPU, worker-safe (reads + allocs in `alloc`,
		// scratch in temp) — the body geometry the streamer feeds to Jolt. Cheap vs the render
		// decode; piggybacks the NIF load we already did.
		col = nif.parse_collision(data, &h, alloc)
		furn = nif.furniture_markers(data, &h, alloc)
		if m, found := nif.node_world_by_name(data, &h, "ProjectileNode"); found {pnode = m}
	}

	return Cpu_Model {
		ok            = true,
		path          = strings.clone(modl, alloc),
		shapes        = shapes,
		center        = smath.scale3(lo + hi, 0.5),
		radius        = 0.5 * smath.length3(hi - lo),
		proxy_verts   = pv,
		proxy_indices = pi,
		has_proxy     = phas,
		collision     = col,
		furniture     = furn,
		projectile    = pnode,
		extras        = want_extras,
	}
}

// free_cpu_model releases every buffer a Cpu_Model owns. Use the SAME allocator that
// decode_model was given. Call after upload_cpu_model (or on a decode the streamer
// drops).
free_cpu_model :: proc(cpu: Cpu_Model, alloc := context.allocator) {
	for cs in cpu.shapes {
		delete(cs.verts, alloc)
		delete(cs.indices, alloc)
		if cs.diffuse_path != "" {
			delete(cs.diffuse_path, alloc)
		}
		if cs.diffuse.ok {
			delete(cs.diffuse.pixels, alloc)
			delete(cs.diffuse.mips, alloc)
		}
		if cs.normal_path != "" {
			delete(cs.normal_path, alloc)
		}
		if cs.normal.ok {
			delete(cs.normal.pixels, alloc)
			delete(cs.normal.mips, alloc)
		}
	}
	delete(cpu.shapes, alloc)
	if cpu.path != "" {
		delete(cpu.path, alloc)
	}
	delete(cpu.proxy_verts, alloc)
	delete(cpu.proxy_indices, alloc)
	// Collision was allocated in `alloc` by parse_collision; free with the same allocator
	// (nif.destroy_collision uses the ambient allocator, which may differ — free explicitly).
	for s in cpu.collision.shapes {
		delete(s.vertices, alloc)
		delete(s.indices, alloc)
	}
	delete(cpu.collision.shapes, alloc)
	delete(cpu.furniture, alloc)
}

// --- internals ---

// default_tangent derives a stable unit tangent perpendicular to `n` (handedness +1) — the
// fallback when a shape has no authored NIF tangent. Picks the world axis least aligned with
// the normal to avoid a degenerate cross product.
@(private)
default_tangent :: proc(n: smath.Vec3) -> [4]f32 {
	axis := smath.Vec3{1, 0, 0}
	if abs(n.x) > 0.9 {
		axis = {0, 1, 0}
	}
	t := smath.normalize3(smath.cross3(axis, n))
	return {t.x, t.y, t.z, 1}
}

// decode_texture reads + parses a DDS into an owned Cpu_Tex (pixels copied out of the
// temp-read file into `alloc`). `srgb` tags the color space for upload — diffuse/glow are
// sRGB (true), NORMAL maps are linear data (false). Returns an un-ok Cpu_Tex on miss /
// unsupported format (→ white fallback at upload).
@(private)
decode_texture :: proc(v: ^vfs.VFS, path: string, srgb := true, alloc := context.allocator) -> Cpu_Tex {
	if path == "" {
		return {}
	}
	data, ok := vfs.read(v, path, context.temp_allocator)
	if !ok {
		return {}
	}
	img, pok := dds.parse(data)
	if !pok {
		return {}
	}
	rfmt, fok := to_render_format(img.format, img.bgra)
	if !fok {
		return {}
	}
	chain := dds.mip_chain(img, context.temp_allocator)
	if len(chain) == 0 {
		return {}
	}
	total := 0
	for mp in chain {
		total += len(mp.data)
	}
	blob := make([]u8, total, alloc)
	mips := make([]render.Tex_Mip, len(chain), alloc)
	off := 0
	for mp, i in chain {
		copy(blob[off:], mp.data)
		mips[i] = {width = mp.width, height = mp.height, data = blob[off:off + len(mp.data)]}
		off += len(mp.data)
	}
	return Cpu_Tex{ok = true, format = rfmt, srgb = srgb, pixels = blob, mips = mips}
}

// upload_or_cached_texture returns the cache's GPU texture for (`path`, `srgb`), uploading `cpu`
// into the open batch on a miss. The cache is checked BEFORE cpu.ok, so a shape that carries a path
// but no decoded pixels (within-model dedup) still resolves to the texture a prior shape uploaded.
// `srgb` is the SLOT's color space (diffuse = true, normal = false) — passed explicitly (not read
// from cpu) so the dedup lookup keys correctly even when cpu is the un-ok placeholder. MAIN THREAD.
@(private)
upload_or_cached_texture :: proc(c: ^Cache, b: ^render.Upload_Batch, path: string, cpu: Cpu_Tex, srgb: bool) -> render.Texture {
	if path == "" {
		return {}
	}
	key := tex_key(path, srgb)
	if e, hit := c.textures[key]; hit {
		return e.tex
	}
	if !cpu.ok {
		return {} // no pixels to upload and nothing cached → white fallback
	}
	mips := capped_mips(cpu.mips)
	t := render.upload_texture_into(b, cpu.format, cpu.srgb, mips)
	bytes := 0
	for m in mips {
		bytes += len(m.data) // payload ≈ GPU size (BC uploads stay block-compressed)
	}
	c.tex_bytes += bytes
	c.textures[strings.clone(key)] = Tex_Entry{tex = t, bytes = bytes}
	return t
}

// tex_key is the texture cache / within-model dedup key: the lowercased path PLUS a color-space
// tag. The same DDS used as an sRGB diffuse in one shape and a LINEAR normal map in another must
// cache as TWO distinct GPU textures (each uploaded in the right color space) — keying on path
// alone let whichever uploaded first win, silently mis-coloring the other use. Cheap (one temp
// concat) and off the per-frame path (texture resolution happens at upload). Temp-allocated.
@(private)
tex_key :: proc(path: string, srgb: bool) -> string {
	return strings.concatenate({strings.to_lower(path, context.temp_allocator), "|s" if srgb else "|l"}, context.temp_allocator)
}

@(private)
to_render_format :: proc(f: dds.Format, bgra: bool) -> (render.Tex_Format, bool) {
	switch f {
	case .BC1:
		return .BC1, true
	case .BC2:
		return .BC2, true
	case .BC3:
		return .BC3, true
	case .BC4:
		return .BC4, true
	case .BC5:
		return .BC5, true
	case .BC7:
		return .BC7, true
	case .RGBA8:
		return (.BGRA8 if bgra else .RGBA8), true
	case .Unknown:
		return {}, false
	}
	return {}, false
}
