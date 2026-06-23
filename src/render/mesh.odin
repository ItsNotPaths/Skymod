package render

// Demo geometry for Phase 0 (the textured cube, step 4). Real meshes arrive from
// src/formats/nif via src/assetdb in Phase 2; this stand-in exercises the
// vertex/index-buffer + depth + texture-sampler paths through the interface.

import smath "../math"

// Vertex: position + UV. Normals/tangents arrive with the lit pass (Phase 2d).
Vertex :: struct {
	pos: smath.Vec3, // offset 0
	uv:  [2]f32,     // offset 12
}
#assert(size_of(Vertex) == 20)

// build_cube returns a cube of `half` extent, each face wound CCW from outside
// (so back-face culling keeps it solid) and UV-mapped 0..1.
build_cube :: proc(half: f32) -> (verts: [24]Vertex, indices: [36]u16) {
	Face :: struct {
		n, u, v: smath.Vec3, // outward normal + the two in-face axes (u × v == n)
	}
	faces := [6]Face {
		{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}},   // +X
		{{-1, 0, 0}, {0, 0, 1}, {0, 1, 0}},  // -X
		{{0, 1, 0}, {0, 0, 1}, {1, 0, 0}},   // +Y
		{{0, -1, 0}, {1, 0, 0}, {0, 0, 1}},  // -Y
		{{0, 0, 1}, {1, 0, 0}, {0, 1, 0}},   // +Z
		{{0, 0, -1}, {0, 1, 0}, {1, 0, 0}},  // -Z
	}
	// Corner sign pattern (-u-v, u-v, u+v, -u+v) wound CCW, with matching UVs.
	signs := [4][2]f32{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}
	uvs := [4][2]f32{{0, 1}, {1, 1}, {1, 0}, {0, 0}}

	vi, ii := 0, 0
	for f, fi in faces {
		base := u16(fi * 4)
		for k in 0 ..< 4 {
			su, sv := signs[k].x, signs[k].y
			p := smath.Vec3 {
				f.n.x * half + f.u.x * su * half + f.v.x * sv * half,
				f.n.y * half + f.u.y * su * half + f.v.y * sv * half,
				f.n.z * half + f.u.z * su * half + f.v.z * sv * half,
			}
			verts[vi] = Vertex{pos = p, uv = uvs[k]}
			vi += 1
		}
		tri := [6]u16{base + 0, base + 1, base + 2, base + 0, base + 2, base + 3}
		for t in tri {
			indices[ii] = t
			ii += 1
		}
	}
	return
}
