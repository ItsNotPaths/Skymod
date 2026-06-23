package smath

// Thin math helpers (ROADMAP tech-stack: no external math dep). Z-up, right-handed
// — matching Skyrim's world convention. The view/projection builders are
// hand-written (rather than calling core:math/linalg's GL-style helpers) so the
// clip space is exactly what SDL3_gpu wants: right-handed, depth range [0,1].

import "core:math"

Vec3 :: [3]f32
Mat4 :: matrix[4, 4]f32

scale3 :: proc(v: Vec3, s: f32) -> Vec3 {
	return {v.x * s, v.y * s, v.z * s}
}

dot3 :: proc(a, b: Vec3) -> f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

cross3 :: proc(a, b: Vec3) -> Vec3 {
	return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
}

length3 :: proc(v: Vec3) -> f32 {
	return math.sqrt(dot3(v, v))
}

normalize3 :: proc(v: Vec3) -> Vec3 {
	l := math.sqrt(dot3(v, v))
	if l <= 1e-6 {
		return {0, 0, 0}
	}
	return scale3(v, 1.0 / l)
}

// translate builds a translation matrix.
translate :: proc(v: Vec3) -> Mat4 {
	return Mat4{1, 0, 0, v.x, 0, 1, 0, v.y, 0, 0, 1, v.z, 0, 0, 0, 1}
}

// scale_uniform builds a uniform scale matrix.
scale_uniform :: proc(s: f32) -> Mat4 {
	return Mat4{s, 0, 0, 0, 0, s, 0, 0, 0, 0, s, 0, 0, 0, 0, 1}
}

// rotate_x/y/z build right-handed rotation matrices about each axis (radians).
rotate_x :: proc(a: f32) -> Mat4 {
	c, s := math.cos(a), math.sin(a)
	return Mat4{1, 0, 0, 0, 0, c, -s, 0, 0, s, c, 0, 0, 0, 0, 1}
}

rotate_y :: proc(a: f32) -> Mat4 {
	c, s := math.cos(a), math.sin(a)
	return Mat4{c, 0, s, 0, 0, 1, 0, 0, -s, 0, c, 0, 0, 0, 0, 1}
}

rotate_z :: proc(a: f32) -> Mat4 {
	c, s := math.cos(a), math.sin(a)
	return Mat4{c, -s, 0, 0, s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
}

@(private)
transpose_m4 :: proc(m: Mat4) -> Mat4 {
	r: Mat4
	for i in 0 ..< 4 {
		for j in 0 ..< 4 {
			r[i, j] = m[j, i]
		}
	}
	return r
}

// trs composes a Bethesda REFR placement: translate · rotation · scale, with `rot`
// the XYZ euler angles (radians) from a REFR's DATA field. The rotation is the
// TRANSPOSE (inverse) of the naive right-handed Rz·Ry·Rx composition — determined
// empirically with the in-app model inspector (only "flip winding" made the whole
// cell, stairs and all, read correctly). Equivalent to applying the rotation
// clockwise / with negated angles in reverse order.
trs :: proc(pos: Vec3, rot: Vec3, scale: f32) -> Mat4 {
	r := transpose_m4(rotate_z(rot.z) * rotate_y(rot.y) * rotate_x(rot.x))
	return translate(pos) * r * scale_uniform(scale)
}

// look_at_rh: right-handed view matrix (camera looks down -forward), Z-up world.
// Literals are written row-major for readability; Odin stores matrices
// column-major in memory — which is exactly what a GLSL mat4 expects on upload.
look_at_rh :: proc(eye, center, up: Vec3) -> Mat4 {
	f := normalize3(center - eye)
	s := normalize3(cross3(f, up))
	u := cross3(s, f)
	return Mat4 {
		 s.x,  s.y,  s.z, -dot3(s, eye),
		 u.x,  u.y,  u.z, -dot3(u, eye),
		-f.x, -f.y, -f.z,  dot3(f, eye),
		   0,    0,    0,             1,
	}
}

// perspective_rh_zo: right-handed perspective, depth range [0,1] (Vulkan/D3D —
// the NDC SDL3_gpu targets). fovy in radians.
perspective_rh_zo :: proc(fovy, aspect, near, far: f32) -> Mat4 {
	t := 1.0 / math.tan(fovy * 0.5)
	return Mat4 {
		t / aspect, 0, 0, 0,
		0, t, 0, 0,
		0, 0, far / (near - far), (near * far) / (near - far),
		0, 0, -1, 0,
	}
}
