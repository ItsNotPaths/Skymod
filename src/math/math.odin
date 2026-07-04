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

// rotate_axis builds a rotation matrix about an arbitrary unit-ish axis by `angle` radians
// (Rodrigues' formula). The axis is normalized internally; a zero axis yields identity. Used
// to swing a door panel about its hinge axis.
rotate_axis :: proc(axis: Vec3, angle: f32) -> Mat4 {
	a := normalize3(axis)
	if a == {0, 0, 0} {
		return Mat4(1)
	}
	c, s := math.cos(angle), math.sin(angle)
	t := 1 - c
	x, y, z := a.x, a.y, a.z
	// Row-major literal (Odin stores column-major in memory; matches the other builders here).
	return Mat4 {
		c + x * x * t,     x * y * t - z * s, x * z * t + y * s, 0,
		y * x * t + z * s, c + y * y * t,     y * z * t - x * s, 0,
		z * x * t - y * s, z * y * t + x * s, c + z * z * t,     0,
		0,                 0,                 0,                 1,
	}
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

// --- frustum culling (Section F streaming) ---

// Plane is (a,b,c,d): a point p is inside the half-space when a·px+b·py+c·pz+d >= 0.
Plane :: [4]f32
// Frustum is the 6 clip planes (left,right,bottom,top,near,far), inward-facing.
Frustum :: [6]Plane

// frustum_from_vp extracts the 6 world-space frustum planes from a view-projection
// matrix (Gribb-Hartmann). `vp` maps world → clip with clip.z in [0,w] (the Vulkan/
// SDL3_gpu range), so near = row2, far = row3-row2. Under the reversed-Z projection
// (perspective_rh_zo_rev) the two swap roles, but clip.z stays in [0,w] so the SAME six
// half-spaces bound the SAME volume — culling is unaffected. Planes are normalized so
// sphere distance tests are in world units. Inside = all planes >= 0.
frustum_from_vp :: proc(m: Mat4) -> Frustum {
	row :: proc(m: Mat4, i: int) -> Plane {return {m[i, 0], m[i, 1], m[i, 2], m[i, 3]}}
	r0, r1, r2, r3 := row(m, 0), row(m, 1), row(m, 2), row(m, 3)
	f := Frustum {
		r3 + r0, // left   (clip.x >= -w)
		r3 - r0, // right  (clip.x <=  w)
		r3 + r1, // bottom (clip.y >= -w)
		r3 - r1, // top    (clip.y <=  w)
		r2,      // near   (clip.z >=  0)
		r3 - r2, // far    (clip.z <=  w)
	}
	for &p in f {
		inv := 1.0 / math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
		p *= inv
	}
	return f
}

// aabb_in_frustum reports whether an axis-aligned box [lo,hi] intersects the frustum.
// Uses the positive-vertex test: if the box's farthest corner along a plane normal is
// still behind that plane, the box is fully outside. Conservative (no false culls).
aabb_in_frustum :: proc(f: Frustum, lo, hi: Vec3) -> bool {
	for p in f {
		px := hi.x if p.x >= 0 else lo.x
		py := hi.y if p.y >= 0 else lo.y
		pz := hi.z if p.z >= 0 else lo.z
		if p.x * px + p.y * py + p.z * pz + p.w < 0 {
			return false
		}
	}
	return true
}

// sphere_in_frustum reports whether a world-space sphere intersects the frustum.
sphere_in_frustum :: proc(f: Frustum, center: Vec3, radius: f32) -> bool {
	for p in f {
		if p.x * center.x + p.y * center.y + p.z * center.z + p.w < -radius {
			return false
		}
	}
	return true
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

// perspective_rh_zo_rev: reversed-Z perspective — near plane → 1, far plane → 0 (still the
// [0,1] Vulkan/SDL3_gpu depth range, just inverted). Pair with a depth buffer cleared to 0 and
// a GREATER depth test. On a FLOAT depth buffer this spreads precision ~uniformly across the
// whole range instead of bunching it all at the near plane, which is what the forward mapping
// (perspective_rh_zo) does — the cause of distant z-fighting over the 5..262144 world span.
// Algebraically it's perspective_rh_zo with near/far swapped in the depth row.
perspective_rh_zo_rev :: proc(fovy, aspect, near, far: f32) -> Mat4 {
	t := 1.0 / math.tan(fovy * 0.5)
	return Mat4 {
		t / aspect, 0, 0, 0,
		0, t, 0, 0,
		0, 0, near / (far - near), (far * near) / (far - near),
		0, 0, -1, 0,
	}
}

// ortho_rh_zo is a right-handed orthographic projection with a zero-to-one depth range
// (Vulkan/SDL3_gpu), matching perspective_rh_zo's conventions. Used for the directional-light
// shadow cascades: an axis-aligned box fitted around a camera frustum slice in light space.
ortho_rh_zo :: proc(l, r, b, t, near, far: f32) -> Mat4 {
	return Mat4 {
		2 / (r - l), 0, 0, -(r + l) / (r - l),
		0, 2 / (t - b), 0, -(t + b) / (t - b),
		0, 0, -1 / (far - near), -near / (far - near),
		0, 0, 0, 1,
	}
}
