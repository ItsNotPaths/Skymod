package assetdb

// (hole collision-store-package :tags (threading assets) :sev struct) the collision store is sim data inside the render asset package (assetdb), and world imports assetdb partly to reach it; once the streamer is a loader it is the loader-to-sim handoff and wants its own package beside the streamer.
// Collision_Store holds what the sim builds and aims bodies from, apart from the GPU cache so the
// sim never reads render data: each model's collision and bounds, put when its decode lands, and
// its furniture markers and ProjectileNode, read from the NIF on first ask (the AI asks about
// furniture in cells that never loaded). Any thread may read; an entry never changes once put, so
// a reader holds it without the lock. Keyed by lowercased model path; nothing is evicted.

import "core:strings"
import "core:sync"
import "../formats/nif"
import smath "../math"
import "../vfs"

Collision_Store :: struct {
	v:          ^vfs.VFS,
	mu:         sync.Mutex,
	models:     map[string]^Model_Collision, // nil entry: the model decoded to nothing
	furniture:  map[string][]nif.Furniture_Marker,
	projectile: map[string]Maybe(matrix[4, 4]f32),
}

Model_Collision :: struct {
	collision: nif.Collision,
	lo, hi:    smath.Vec3, // the render mesh's model-space bounds (a projectile's capsule)
}

collision_store_init :: proc(s: ^Collision_Store, v: ^vfs.VFS) {
	s.v = v
}

collision_store_destroy :: proc(s: ^Collision_Store) {
	for key, m in s.models {
		if m != nil {
			nif.destroy_collision(&m.collision)
			free(m)
		}
		delete(key)
	}
	delete(s.models)
	for key, f in s.furniture {
		delete(key)
		delete(f)
	}
	delete(s.furniture)
	for key in s.projectile {delete(key)}
	delete(s.projectile)
	s^ = {}
}

// collision_of is a model's collision: known false until its decode lands, then nil if it decoded
// to nothing. Without a store (a scene with no physics) every model is known to have none.
collision_of :: proc(s: ^Collision_Store, modl: string) -> (m: ^Model_Collision, known: bool) {
	if s == nil {return nil, true}
	key := strings.to_lower(modl, context.temp_allocator)
	sync.guard(&s.mu)
	return s.models[key]
}

// store_collision keeps a decoded model's collision (a copy) and bounds.
@(private)
store_collision :: proc(s: ^Collision_Store, cpu: Cpu_Model) {
	m := new(Model_Collision)
	m.collision = clone_collision(cpu.collision)
	m.lo, m.hi = model_bounds(cpu)
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
		if m != nil {
			nif.destroy_collision(&m.collision)
			free(m)
		}
		return
	}
	s.models[strings.clone(key)] = m
}

// furniture_markers is a model's furniture markers (none for a missing or bad NIF), read once.
furniture_markers :: proc(s: ^Collision_Store, modl: string) -> []nif.Furniture_Marker {
	key := strings.to_lower(modl, context.temp_allocator)
	sync.guard(&s.mu)
	if m, hit := s.furniture[key]; hit {return m}
	markers: []nif.Furniture_Marker
	if data, h, ok := read_nif(s.v, modl); ok {markers = nif.furniture_markers(data, &h)}
	s.furniture[strings.clone(key)] = markers
	return markers
}

// projectile_node is where a model launches projectiles, in model space: its ProjectileNode, read once.
projectile_node :: proc(s: ^Collision_Store, modl: string) -> (matrix[4, 4]f32, bool) {
	key := strings.to_lower(modl, context.temp_allocator)
	sync.guard(&s.mu)
	if m, hit := s.projectile[key]; hit {return m.? or_else 1, m != nil}
	node: Maybe(matrix[4, 4]f32)
	if data, h, ok := read_nif(s.v, modl); ok {
		if m, found := nif.node_world_by_name(data, &h, "ProjectileNode"); found {node = m}
	}
	s.projectile[strings.clone(key)] = node
	return node.? or_else 1, node != nil
}

@(private)
read_nif :: proc(v: ^vfs.VFS, modl: string) -> (data: []u8, h: nif.Header, ok: bool) {
	full := strings.concatenate({"meshes\\", modl}, context.temp_allocator)
	data = vfs.read(v, full, context.temp_allocator) or_return
	h = nif.parse_header(data, context.temp_allocator) or_return
	return data, h, true
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
