package assetdb

// (hole collision-store-package :tags (threading assets) :sev struct) the collision store is sim data inside the render asset package (assetdb), and world imports assetdb partly to reach it; once the streamer is a loader it is the loader-to-sim handoff and wants its own package beside the streamer.
// Collision_Store holds what the sim knows of each model: its collision, cutout geometry, bounds,
// furniture markers and ProjectileNode, put when its decode lands. A read of a model not in yet is a request: the store
// lists it, and the streamer takes the list (take_wanted). Any thread may read; an entry never
// changes once put, so a reader holds it without the lock. Keyed by lowercased model path; nothing
// is evicted.

import "core:slice"
import "core:strings"
import "core:sync"
import "../formats/nif"
import smath "../math"
import "../render"

Collision_Store :: struct {
	mu:     sync.Mutex,
	models: map[string]^Model_Collision, // nil entry: the model decoded to nothing
	asked:  map[string]bool, // models a loader has in hand (keys owned; wanted borrows them)
	wanted: [dynamic]string, // models read before they were in and not asked for yet
}

Model_Collision :: struct {
	collision:  nif.Collision,
	cutout:     Cutout_Mesh,
	lo, hi:     smath.Vec3, // the render mesh's model-space bounds (a projectile's capsule)
	furniture:  []nif.Furniture_Marker,
	projectile: Maybe(matrix[4, 4]f32),
}

// Cutout_Mesh is what of a model dims sight, in model space: a tree's canopy hull, else its
// alpha-tested shapes (fences, cobwebs, bushes).
Cutout_Mesh :: struct {
	verts:   [][3]f32,
	indices: []u32,
}

collision_store_destroy :: proc(s: ^Collision_Store) {
	for key, m in s.models {
		free_entry(m)
		delete(key)
	}
	delete(s.models)
	for key in s.asked {delete(key)}
	delete(s.asked)
	delete(s.wanted)
	s^ = {}
}

// collision_of is a model's collision: known false until its decode lands, then nil if it decoded
// to nothing. Without a store (a scene with no physics) every model is known to have none.
collision_of :: proc(s: ^Collision_Store, modl: string) -> (m: ^Model_Collision, known: bool) {
	if s == nil {return nil, true}
	key := strings.to_lower(modl, context.temp_allocator)
	sync.guard(&s.mu)
	m, known = s.models[key]
	if !known {want(s, key)}
	return
}

// furniture_markers is a model's furniture markers; none until its decode lands.
furniture_markers :: proc(s: ^Collision_Store, modl: string) -> []nif.Furniture_Marker {
	m, _ := collision_of(s, modl)
	return m.furniture if m != nil else nil
}

// projectile_node is where a model launches projectiles, in model space: its ProjectileNode.
projectile_node :: proc(s: ^Collision_Store, modl: string) -> (matrix[4, 4]f32, bool) {
	m, _ := collision_of(s, modl)
	if m == nil {return 1, false}
	node, ok := m.projectile.?
	return node if ok else 1, ok
}

// note_asked records that a loader has a model in hand, so reading it before it lands asks for nothing.
note_asked :: proc(s: ^Collision_Store, modl: string) {
	key := strings.to_lower(modl, context.temp_allocator)
	sync.guard(&s.mu)
	if key not_in s.asked {s.asked[strings.clone(key)] = true}
}

// take_wanted moves the models read before they were in into `into` (cleared first). The strings are
// the store's.
take_wanted :: proc(s: ^Collision_Store, into: ^[dynamic]string) {
	clear(into)
	sync.guard(&s.mu)
	s.wanted, into^ = into^, s.wanted
}

@(private)
want :: proc(s: ^Collision_Store, key: string) {
	if key in s.asked {return}
	k := strings.clone(key)
	s.asked[k] = true
	append(&s.wanted, k)
}

// store_collision keeps a decoded model's collision (a copy) and bounds.
@(private)
store_collision :: proc(s: ^Collision_Store, cpu: Cpu_Model) {
	m := new(Model_Collision)
	m.collision = clone_collision(cpu.collision)
	m.cutout = cutout_mesh(cpu)
	m.lo, m.hi = model_bounds(cpu)
	m.furniture = slice.clone(cpu.furniture)
	m.projectile = cpu.projectile
	put_model(s, cpu.path, m)
}

// store_failed records a model that decoded to nothing: it has no bodies.
@(private)
store_failed :: proc(s: ^Collision_Store, modl: string) {
	put_model(s, modl, nil)
}

@(private)
put_model :: proc(s: ^Collision_Store, modl: string, m: ^Model_Collision) {
	key := strings.to_lower(modl, context.temp_allocator)
	sync.guard(&s.mu)
	if key in s.models {
		free_entry(m)
		return
	}
	s.models[strings.clone(key)] = m
}

@(private)
free_entry :: proc(m: ^Model_Collision) {
	if m == nil {return}
	nif.destroy_collision(&m.collision)
	delete(m.cutout.verts)
	delete(m.cutout.indices)
	delete(m.furniture)
	free(m)
}

// model_bounds is a decoded model's model-space AABB over every shape's vertices.
@(private)
model_bounds :: proc(cpu: Cpu_Model) -> (lo, hi: smath.Vec3) {
	lo, hi = {max(f32), max(f32), max(f32)}, {min(f32), min(f32), min(f32)}
	for cs in cpu.shapes {
		for v in cs.verts {
			w := cs.local * [4]f32{v.pos.x, v.pos.y, v.pos.z, 1}
			lo = {min(lo.x, w.x), min(lo.y, w.y), min(lo.z, w.z)}
			hi = {max(hi.x, w.x), max(hi.y, w.y), max(hi.z, w.z)}
		}
	}
	return
}

// cutout_mesh is a model's cutout geometry. A canopy uses its hull: a tree's leaf cards are thousands
// of triangles, too many to cook per placed tree.
@(private)
cutout_mesh :: proc(cpu: Cpu_Model) -> (out: Cutout_Mesh) {
	verts: [dynamic][3]f32
	indices: [dynamic]u32
	add :: proc(verts: ^[dynamic][3]f32, indices: ^[dynamic]u32, local: smath.Mat4, vs: []render.Mesh_Vertex, is: []u16) {
		base := u32(len(verts))
		for v in vs {append(verts, (local * [4]f32{v.pos.x, v.pos.y, v.pos.z, 1}).xyz)}
		for i in is {append(indices, base + u32(i))}
	}
	if cpu.has_proxy {
		add(&verts, &indices, 1, cpu.proxy_verts, cpu.proxy_indices)
	} else {
		for cs in cpu.shapes {
			if cs.alpha_cutoff > 0 && !cs.is_effect {add(&verts, &indices, cs.local, cs.verts, cs.indices)}
		}
	}
	shrink(&verts)
	shrink(&indices)
	return {verts[:], indices[:]}
}
