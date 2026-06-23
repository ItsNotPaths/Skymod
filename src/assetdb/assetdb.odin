package assetdb

// Runtime asset cache (ROADMAP Phase 2a / Iteration 1, Milestone C): load-on-demand,
// deduped by path. A cell places hundreds of refs but shares far fewer unique
// models/textures — this cache loads each NIF (→ GPU meshes) and each diffuse DDS (→
// GPU texture) exactly once, then hands back shared handles the renderer draws with
// a per-instance transform. The asset-loading layer that turns formats (nif/dds) +
// vfs bytes into render resources; it consumes render's public API, never SDL.

import "core:log"
import "core:strings"

import "../formats/dds"
import "../formats/nif"
import smath "../math"
import "../render"
import "../vfs"

// Shape is one uploaded sub-mesh of a model: its GPU mesh, diffuse texture (a shared
// handle owned by the texture cache), and the NIF-internal world transform that
// places it within the model's local space.
Shape :: struct {
	mesh:  render.Mesh,
	tex:   render.Texture,
	local: smath.Mat4,
}

// Model is a loaded NIF: its drawable shapes + a model-space bounding sphere (for
// picking) and the MODL path it came from (for the inspector).
Model :: struct {
	path:   string, // owned
	shapes: []Shape,
	center: smath.Vec3,
	radius: f32,
}

// Cache owns every loaded model + unique texture and frees them on destroy.
Cache :: struct {
	r:        ^render.Renderer,
	v:        ^vfs.VFS,
	models:   map[string]^Model, // "meshes\..."-relative MODL path -> model (key owned)
	textures: map[string]render.Texture, // "textures\..." path -> texture (key owned)
}

cache_init :: proc(r: ^render.Renderer, v: ^vfs.VFS) -> Cache {
	return Cache{r = r, v = v, models = make(map[string]^Model), textures = make(map[string]render.Texture)}
}

cache_destroy :: proc(c: ^Cache) {
	for key, m in c.models {
		for sh in m.shapes {
			render.release_mesh(c.r, sh.mesh)
		}
		delete(m.shapes)
		delete(m.path)
		free(m)
		delete(key)
	}
	delete(c.models)
	for key, t in c.textures {
		render.release_texture(c.r, t)
		delete(key)
	}
	delete(c.textures)
	c^ = {}
}

// get_model loads (or returns the cached) model for a MODL path (e.g.
// "Furniture\\Foo.nif" — relative to meshes\). Returns ok=false if the NIF can't be
// read/parsed or has no drawable shapes.
get_model :: proc(c: ^Cache, modl: string) -> (^Model, bool) {
	key := strings.to_lower(modl, context.temp_allocator)
	if m, hit := c.models[key]; hit {
		return m, true
	}

	full := strings.concatenate({"meshes\\", modl}, context.temp_allocator)
	data, ok := vfs.read(c.v, full, context.temp_allocator)
	if !ok {
		log.warnf("assetdb: model not found: %s", full)
		return nil, false
	}
	h, hok := nif.parse_header(data, context.temp_allocator)
	if !hok {
		log.warnf("assetdb: bad NIF: %s", full)
		return nil, false
	}

	shapes := make([dynamic]Shape, 0, 8)
	lo := smath.Vec3{max(f32), max(f32), max(f32)}
	hi := smath.Vec3{min(f32), min(f32), min(f32)}
	for ps in nif.parse_scene(data, &h, context.temp_allocator) {
		verts := make([]render.Mesh_Vertex, len(ps.geometry.vertices), context.temp_allocator)
		for i in 0 ..< len(ps.geometry.vertices) {
			n := smath.Vec3{0, 0, 1}
			if i < len(ps.geometry.normals) {
				n = ps.geometry.normals[i]
			}
			uv := [2]f32{0, 0}
			if i < len(ps.geometry.uvs) {
				uv = ps.geometry.uvs[i]
			}
			verts[i] = {pos = ps.geometry.vertices[i], normal = n, uv = uv}
		}
		// Model-space bounds: the shape's bounding sphere placed by its NIF-internal
		// transform, expanded into the model AABB (used for ray-picking).
		wc := ps.world * [4]f32{ps.geometry.center.x, ps.geometry.center.y, ps.geometry.center.z, 1}
		r := ps.geometry.radius
		lo = {min(lo.x, wc.x - r), min(lo.y, wc.y - r), min(lo.z, wc.z - r)}
		hi = {max(hi.x, wc.x + r), max(hi.y, wc.y + r), max(hi.z, wc.z + r)}
		append(
			&shapes,
			Shape {
				mesh = render.upload_mesh(c.r, verts, ps.geometry.triangles),
				tex = get_texture(c, ps.diffuse),
				local = ps.world,
			},
		)
	}

	if len(shapes) == 0 {
		delete(shapes)
		return nil, false
	}
	m := new(Model)
	m.shapes = shapes[:]
	m.path = strings.clone(modl)
	m.center = smath.scale3(lo + hi, 0.5)
	m.radius = 0.5 * smath.length3(hi - lo)
	c.models[strings.clone(key)] = m
	return m, true
}

// --- internals ---

// get_texture loads (or returns the cached) diffuse texture for a "textures\..." DDS
// path. Returns the zero Texture (→ white fallback at draw) on miss/unsupported.
@(private)
get_texture :: proc(c: ^Cache, path: string) -> render.Texture {
	if path == "" {
		return {}
	}
	key := strings.to_lower(path, context.temp_allocator)
	if t, hit := c.textures[key]; hit {
		return t
	}
	t := load_texture(c, path)
	c.textures[strings.clone(key)] = t // cache even a zero result (don't re-attempt)
	return t
}

@(private)
load_texture :: proc(c: ^Cache, path: string) -> render.Texture {
	data, ok := vfs.read(c.v, path, context.temp_allocator)
	if !ok {
		return {}
	}
	img, pok := dds.parse(data)
	if !pok {
		return {}
	}
	rfmt, fok := to_render_format(img.format)
	if !fok {
		return {}
	}
	chain := dds.mip_chain(img, context.temp_allocator)
	mips := make([]render.Tex_Mip, len(chain), context.temp_allocator)
	for mp, i in chain {
		mips[i] = {width = mp.width, height = mp.height, data = mp.data}
	}
	return render.upload_texture(c.r, rfmt, true, mips) // diffuse = sRGB
}

@(private)
to_render_format :: proc(f: dds.Format) -> (render.Tex_Format, bool) {
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
		return .RGBA8, true
	case .Unknown:
		return {}, false
	}
	return {}, false
}
