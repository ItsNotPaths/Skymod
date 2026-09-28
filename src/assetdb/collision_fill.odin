package assetdb

// The sim's copy of each decoded model (collisions.Store), filled as its decode lands.

import "core:slice"
import "../collisions"
import smath "../math"
import "../models"
import "../render"

// store_collision keeps a decoded model's collision (a copy) and bounds.
@(private)
store_collision :: proc(s: ^collisions.Store, model: models.ID, cpu: Cpu_Model) {
	m := new(collisions.Model)
	m.collision = clone_collision(cpu.collision)
	m.cutout = cutout_mesh(cpu)
	m.lo, m.hi = model_bounds(cpu)
	m.furniture = slice.clone(cpu.furniture)
	m.projectile = cpu.projectile
	collisions.put(s, model, m)
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
cutout_mesh :: proc(cpu: Cpu_Model) -> (out: collisions.Cutout) {
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
