package collisions

// Store holds what the sim knows of each model: its collision, cutout geometry, bounds, furniture
// markers and ProjectileNode, put when its decode lands. It is the loader's handoff to the sim. A
// read of a model not in yet is a request: the store lists it, and the streamer takes the list
// (take_wanted). Any thread may read; an entry never changes once put, so a reader holds it without
// the lock. Nothing is evicted.

import "core:sync"
import "../formats/nif"
import smath "../math"
import "../models"

Store :: struct {
	mu:      sync.Mutex,
	entries: map[models.ID]^Model, // nil entry: the model decoded to nothing
	asked:   map[models.ID]bool, // models a loader has in hand
	wanted:  [dynamic]models.ID, // models read before they were in and not asked for yet
}

Model :: struct {
	collision:  nif.Collision,
	cutout:     Cutout,
	lo, hi:     smath.Vec3, // the render mesh's model-space bounds (a projectile's capsule)
	furniture:  []nif.Furniture_Marker,
	projectile: Maybe(matrix[4, 4]f32),
}

// Cutout is what of a model dims sight, in model space: a tree's canopy hull, else its alpha-tested
// shapes (fences, cobwebs, bushes).
Cutout :: struct {
	verts:   [][3]f32,
	indices: []u32,
}

destroy :: proc(s: ^Store) {
	for _, m in s.entries {free_model(m)}
	delete(s.entries)
	delete(s.asked)
	delete(s.wanted)
	s^ = {}
}

// of is a model's collision: known false until its decode lands, then nil if it decoded to nothing.
// Without a store (a scene with no physics) every model is known to have none.
of :: proc(s: ^Store, model: models.ID) -> (m: ^Model, known: bool) {
	if s == nil {return nil, true}
	sync.guard(&s.mu)
	m, known = s.entries[model]
	if !known {want(s, model)}
	return
}

// furniture_markers is a model's furniture markers; none until its decode lands.
furniture_markers :: proc(s: ^Store, model: models.ID) -> []nif.Furniture_Marker {
	m, _ := of(s, model)
	return m.furniture if m != nil else nil
}

// projectile_node is where a model launches projectiles, in model space: its ProjectileNode.
projectile_node :: proc(s: ^Store, model: models.ID) -> (matrix[4, 4]f32, bool) {
	m, _ := of(s, model)
	if m == nil {return 1, false}
	node, ok := m.projectile.?
	return node if ok else 1, ok
}

// note_asked records that a loader has a model in hand, so reading it before it lands asks for nothing.
note_asked :: proc(s: ^Store, model: models.ID) {
	sync.guard(&s.mu)
	s.asked[model] = true
}

// take_wanted moves the models read before they were in into `into` (cleared first).
take_wanted :: proc(s: ^Store, into: ^[dynamic]models.ID) {
	clear(into)
	sync.guard(&s.mu)
	s.wanted, into^ = into^, s.wanted
}

// put keeps a landed model's entry, which the store then owns; nil for a model that decoded to
// nothing. A model already in keeps its first entry.
put :: proc(s: ^Store, model: models.ID, m: ^Model) {
	sync.guard(&s.mu)
	if model in s.entries {
		free_model(m)
		return
	}
	s.entries[model] = m
}

@(private)
want :: proc(s: ^Store, model: models.ID) {
	if model in s.asked {return}
	s.asked[model] = true
	append(&s.wanted, model)
}

@(private)
free_model :: proc(m: ^Model) {
	if m == nil {return}
	nif.destroy_collision(&m.collision)
	delete(m.cutout.verts)
	delete(m.cutout.indices)
	delete(m.furniture)
	free(m)
}
