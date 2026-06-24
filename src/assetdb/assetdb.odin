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
import "../formats/nif"
import smath "../math"
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
	local:        smath.Mat4,
	alpha_cutoff: f32, // alpha-test threshold in [0,1] (0 = opaque); foliage cutouts
	lod_tris:     [3]u32, // BSLODTriShape per-level triangle partition ({0,0,0} = none)
	is_effect:    bool, // BSEffectShaderProperty — draw additive (translucent), not opaque
	scroll:       [2]f32, // effect-shader UV scroll speed (tiles/sec); 0 unless animated
}

// Model is a loaded NIF: drawable shapes + a model-space bounding sphere (frustum cull) +
// the MODL path it came from + CPU pick geometry (model-space triangle positions, all
// shapes concatenated) for precise ray-vs-face mouse picking. The pick geometry is the
// only CPU copy retained after upload (positions + indices, no normals/UVs) — bounded by
// the loaded set, freed with the model.
Model :: struct {
	path:     string, // owned
	shapes:   []Shape,
	center:   smath.Vec3,
	radius:   f32,
	lo, hi:   smath.Vec3, // tight model-space AABB (broad-phase pick cull)
	pick_pos: [][3]f32, // model-space vertex positions (shapes' local transforms applied), owned
	pick_idx: []u32, // triangle indices into pick_pos (3 per face), owned
	pick_shape: []u32, // per-triangle shape index (len = len(pick_idx)/3) — maps a hit face to its Shape, owned
	has_effect: bool, // any shape is a BSEffectShaderProperty FX — lets draw_effects skip non-FX models
	untextured: bool, // EVERY shape resolved to the white-fallback texture (uploaded diffuse handle nil:
	                  // no texture named, or named one that's missing/undecodable) — i.e. the model renders
	                  // as a flat white placeholder. --pretty hides these; a real textured mesh (incl.
	                  // effects: rapids/fire/mist) has at least one bound diffuse, so untextured=false.
	shadow_proxy: render.Mesh, // low-poly canopy hull for cheap tree shadows (Phase D2); zero mesh if none
	has_shadow_proxy: bool, // canopy substantial enough for a proxy (else cast full alpha)
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

// Cache owns every loaded model + unique texture and frees them on destroy. Mutated
// only on the main thread (upload_cpu_model / get_model); the worker never touches it.
Cache :: struct {
	r:        ^render.Renderer,
	v:        ^vfs.VFS,
	models:   map[string]^Model, // "meshes\..."-relative MODL path -> model (key owned)
	textures: map[string]render.Texture, // "textures\..." path -> texture (key owned)
	failed:   map[string]bool, // model paths that decoded to nothing (missing / no shapes) — don't retry (key owned)
}

cache_init :: proc(r: ^render.Renderer, v: ^vfs.VFS) -> Cache {
	return Cache {
		r        = r,
		v        = v,
		models   = make(map[string]^Model),
		textures = make(map[string]render.Texture),
		failed   = make(map[string]bool),
	}
}

// cache_counts reports how many unique models + textures are resident — a memory-growth probe
// (the cache is monotonic during exploration; this climbing unbounded points at eviction).
cache_counts :: proc(c: ^Cache) -> (models, textures: int) {
	return len(c.models), len(c.textures)
}

cache_destroy :: proc(c: ^Cache) {
	for key, m in c.models {
		for sh in m.shapes {
			render.release_mesh(c.r, sh.mesh)
			delete(sh.diffuse_path)
		}
		if m.has_shadow_proxy {
			render.release_mesh(c.r, m.shadow_proxy)
		}
		delete(m.shapes)
		delete(m.path)
		delete(m.pick_pos)
		delete(m.pick_idx)
		delete(m.pick_shape)
		free(m)
		delete(key)
	}
	delete(c.models)
	for key, t in c.textures {
		render.release_texture(c.r, t)
		delete(key)
	}
	delete(c.textures)
	for key, _ in c.failed {
		delete(key)
	}
	delete(c.failed)
	c^ = {}
}

// has_model reports whether a model path is already uploaded (main-thread cache hit) —
// the streamer uses this to skip enqueuing a decode for something already resident.
has_model :: proc(c: ^Cache, modl: string) -> bool {
	key := strings.to_lower(modl, context.temp_allocator)
	_, hit := c.models[key]
	return hit
}

// is_failed reports whether a model path previously decoded to nothing (missing file or
// zero drawable shapes). The streamer skips re-enqueuing these — a missing mesh referenced
// by many cells would otherwise re-decode on the worker every time its cell rewindows.
is_failed :: proc(c: ^Cache, modl: string) -> bool {
	key := strings.to_lower(modl, context.temp_allocator)
	return c.failed[key]
}

// mark_failed records a model path as undecodable so it's never retried. Key is cloned.
mark_failed :: proc(c: ^Cache, modl: string) {
	key := strings.to_lower(modl, context.temp_allocator)
	if key not_in c.failed {
		c.failed[strings.clone(key)] = true
	}
}

// model_ptr returns the cached model for a path, or nil if not yet uploaded.
model_ptr :: proc(c: ^Cache, modl: string) -> ^Model {
	key := strings.to_lower(modl, context.temp_allocator)
	return c.models[key] if key in c.models else nil
}

// get_model loads (or returns the cached) model for a MODL path, synchronously. Used
// by the non-streamed loaders. Returns ok=false if the NIF can't be read/parsed or
// has no drawable shapes.
get_model :: proc(c: ^Cache, modl: string) -> (^Model, bool) {
	key := strings.to_lower(modl, context.temp_allocator)
	if m, hit := c.models[key]; hit {
		return m, true
	}
	cpu := decode_model(c.v, modl, 0, context.temp_allocator) // temp: freed at frame end
	if !cpu.ok {
		mark_failed(c, modl)
		return nil, false
	}
	return upload_cpu_model(c, cpu)
}

// get_texture loads (or returns the cached) diffuse texture for a full VFS path (e.g.
// "textures\\landscape\\dirt02.dds"), synchronously. Deduped by path across the cache,
// so a ground texture shared by many cells uploads once. MAIN THREAD. ok=false on
// read/parse/unsupported-format failure (the caller falls back to the white texture).
get_texture :: proc(c: ^Cache, path: string) -> (render.Texture, bool) {
	if path == "" {
		return {}, false
	}
	key := strings.to_lower(path, context.temp_allocator)
	if t, hit := c.textures[key]; hit {
		return t, true
	}
	cpu := decode_texture(c.v, path, alloc = context.temp_allocator) // temp: freed at frame end
	if !cpu.ok {
		return {}, false
	}
	b := render.upload_begin(c.r)
	t := upload_or_cached_texture(c, &b, path, cpu)
	render.upload_end(&b)
	return t, true
}

// upload_cpu_model turns a decoded Cpu_Model into GPU resources and caches it by path.
// MAIN THREAD ONLY. Does NOT free `cpu` — the caller does (free_cpu_model, or temp
// wipe). Textures dedup across models by path. Returns the cached shared ^Model.
upload_cpu_model :: proc(c: ^Cache, cpu: Cpu_Model) -> (^Model, bool) {
	if !cpu.ok || len(cpu.shapes) == 0 {
		return nil, false
	}
	key := strings.to_lower(cpu.path, context.temp_allocator)
	if m, hit := c.models[key]; hit {
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
			tex          = upload_or_cached_texture(c, &batch, cs.diffuse_path, cs.diffuse),
			normal       = upload_or_cached_texture(c, &batch, cs.normal_path, cs.normal),
			material     = cs.material,
			diffuse_path = strings.clone(cs.diffuse_path),
			local        = cs.local,
			alpha_cutoff = cs.alpha_cutoff,
			lod_tris     = cs.lod_tris,
			is_effect    = cs.is_effect,
			scroll       = cs.scroll,
		}
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
	m.path = strings.clone(cpu.path)
	m.center = cpu.center
	m.radius = cpu.radius
	m.has_effect = has_effect
	m.untextured = untextured
	if cpu.has_proxy {
		m.shadow_proxy = proxy_mesh
		m.has_shadow_proxy = true
	}
	build_pick_geometry(m, cpu)
	c.models[strings.clone(key)] = m
	return m, true
}

// build_pick_geometry fills the model's CPU pick mesh: every shape's vertex positions
// placed by its NIF-internal transform (so they share one model space) + a concatenated
// triangle index list, plus the tight model-space AABB. Used for precise ray-vs-face
// mouse picking (broad-phased by the AABB). Positions only — no normals/UVs.
@(private)
build_pick_geometry :: proc(m: ^Model, cpu: Cpu_Model) {
	nverts, nidx := 0, 0
	for cs in cpu.shapes {
		nverts += len(cs.verts)
		nidx += len(cs.indices)
	}
	m.pick_pos = make([][3]f32, nverts)
	m.pick_idx = make([]u32, nidx)
	m.pick_shape = make([]u32, nidx / 3)
	lo := smath.Vec3{max(f32), max(f32), max(f32)}
	hi := smath.Vec3{min(f32), min(f32), min(f32)}
	vbase, ibase := 0, 0
	for cs, si in cpu.shapes {
		for v, i in cs.verts {
			wp := cs.local * [4]f32{v.pos.x, v.pos.y, v.pos.z, 1}
			p := [3]f32{wp.x, wp.y, wp.z}
			m.pick_pos[vbase + i] = p
			lo = {min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)}
			hi = {max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)}
		}
		for idx, i in cs.indices {
			m.pick_idx[ibase + i] = u32(vbase) + u32(idx)
		}
		for t in 0 ..< len(cs.indices) / 3 {
			m.pick_shape[ibase / 3 + t] = u32(si)
		}
		vbase += len(cs.verts)
		ibase += len(cs.indices)
	}
	if nverts > 0 {
		m.lo, m.hi = lo, hi
	}
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
}

// decode_model reads + parses a model into owned CPU buffers (in `alloc`). Pure CPU,
// no GPU, no cache — safe on a worker thread (vfs.read is thread-safe: positional
// pread, no shared cursor). `lod` selects detail level (only 0/full implemented;
// plumbed for Section-F LOD). Intermediate work uses the calling thread's temp
// allocator — the caller should free_all(temp) after each decode. Returns ok=false
// on read/parse failure or zero drawable shapes.
decode_model :: proc(v: ^vfs.VFS, modl: string, lod: int, alloc := context.allocator) -> Cpu_Model {
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
			verts[i] = {pos = ps.geometry.vertices[i], normal = n, uv = uv, tangent = t}
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
			low := strings.to_lower(ps.diffuse, context.temp_allocator)
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
			low := strings.to_lower(ps.normal, context.temp_allocator)
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

	// Canopy-hull shadow proxy: gather the alpha-tested (leaf) shapes' vertices in MODEL space
	// (apply each shape's local transform) and wrap them in a low-poly lathe hull. Built here on
	// the worker (pure CPU); uploaded in upload_cpu_model. ok=false → cast full (blacklist path).
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
	pv, pi, phas := build_canopy_proxy(canopy[:], alloc)

	return Cpu_Model {
		ok            = true,
		path          = strings.clone(modl, alloc),
		shapes        = shapes,
		center        = smath.scale3(lo + hi, 0.5),
		radius        = 0.5 * smath.length3(hi - lo),
		proxy_verts   = pv,
		proxy_indices = pi,
		has_proxy     = phas,
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

// upload_or_cached_texture returns the cache's GPU texture for `path`, uploading `cpu`
// into the open batch on a miss. The cache is checked BEFORE cpu.ok, so a shape that
// carries a path but no decoded pixels (within-model dedup) still resolves to the
// texture a prior shape uploaded. MAIN THREAD.
@(private)
upload_or_cached_texture :: proc(c: ^Cache, b: ^render.Upload_Batch, path: string, cpu: Cpu_Tex) -> render.Texture {
	if path == "" {
		return {}
	}
	key := strings.to_lower(path, context.temp_allocator)
	if t, hit := c.textures[key]; hit {
		return t
	}
	if !cpu.ok {
		return {} // no pixels to upload and nothing cached → white fallback
	}
	t := render.upload_texture_into(b, cpu.format, cpu.srgb, cpu.mips)
	c.textures[strings.clone(key)] = t
	return t
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
