package assetdb

// Canopy-hull proxy. Built ONCE, at model decode: a low-poly LATHE hull wrapping a tree's canopy
// (the alpha-tested leaf shapes): bin the leaf vertices into height bands, take the max radius per
// band about the trunk axis, and stack rings into a closed solid. It follows the tree's vertical
// silhouette species-agnostically. Sight uses it as the tree's cutout (collision_fill.cutout_mesh):
// thousands of leaf cards are too many to cook per placed tree.
//
// A model only gets a proxy if its canopy is substantial (PROXY_MIN_*); otherwise the cutout is the
// leaf shapes themselves.

import "core:math"
import smath "../math"
import "../render"

PROXY_BANDS :: 5 // canopy height bands (lathe rings)
PROXY_SIDES :: 8 // ring tessellation
PROXY_MIN_RADIUS :: f32(40) // a canopy narrower than this isn't worth a proxy → full
PROXY_MIN_HEIGHT :: f32(80) // …shorter than this either
PROXY_MIN_VERTS :: 48 // …or with too few leaf verts to form a meaningful hull

// build_canopy_proxy builds the lathe hull mesh from canopy points (model space). Returns ok=false
// (no proxy) when the canopy is too small/sparse to bother — the caller then casts full.
build_canopy_proxy :: proc(pts: [][3]f32, alloc := context.allocator) -> (verts: []render.Mesh_Vertex, indices: []u16, ok: bool) {
	if len(pts) < PROXY_MIN_VERTS {
		return
	}
	// Trunk axis = canopy XY centroid; vertical extent = canopy Z range.
	cx, cy: f32
	zmin := max(f32)
	zmax := min(f32)
	for p in pts {
		cx += p.x
		cy += p.y
		zmin = min(zmin, p.z)
		zmax = max(zmax, p.z)
	}
	cx /= f32(len(pts))
	cy /= f32(len(pts))
	if zmax - zmin < PROXY_MIN_HEIGHT {
		return
	}

	// Max radius per height band.
	ring_r: [PROXY_BANDS]f32
	span := zmax - zmin
	for p in pts {
		b := clamp(int((p.z - zmin) / span * PROXY_BANDS), 0, PROXY_BANDS - 1)
		dx, dy := p.x - cx, p.y - cy
		ring_r[b] = max(ring_r[b], math.sqrt(dx * dx + dy * dy))
	}
	maxr: f32 = 0
	for r in ring_r {
		maxr = max(maxr, r)
	}
	if maxr < PROXY_MIN_RADIUS {
		return
	}
	// Fill empty bands (gaps in canopy height) so the hull doesn't pinch to a zero-radius spike:
	// carry the nearest non-empty radius down then up.
	last: f32 = maxr * 0.4
	for b in 0 ..< PROXY_BANDS {
		if ring_r[b] <= 0 {ring_r[b] = last} else {last = ring_r[b]}
	}
	last = ring_r[PROXY_BANDS - 1]
	for b := PROXY_BANDS - 1; b >= 0; b -= 1 {
		if ring_r[b] <= 0 {ring_r[b] = last} else {last = ring_r[b]}
	}

	// Mesh: PROXY_BANDS rings × PROXY_SIDES + a top & bottom apex (closed solid).
	nring := PROXY_BANDS * PROXY_SIDES
	v := make([]render.Mesh_Vertex, nring + 2, alloc)
	apex_top := nring
	apex_bot := nring + 1
	for b in 0 ..< PROXY_BANDS {
		z := zmin + (f32(b) + 0.5) / f32(PROXY_BANDS) * span
		for s in 0 ..< PROXY_SIDES {
			a := f32(s) / f32(PROXY_SIDES) * 2 * math.PI
			// only position is read; safe defaults otherwise
			v[b * PROXY_SIDES + s] = render.mesh_vertex(
				{cx + ring_r[b] * math.cos(a), cy + ring_r[b] * math.sin(a), z},
				{0, 0, 1},
				{0, 0},
			)
		}
	}
	v[apex_top] = render.mesh_vertex({cx, cy, zmax}, {0, 0, 1}, {0, 0})
	v[apex_bot] = render.mesh_vertex({cx, cy, zmin}, {0, 0, 1}, {0, 0})

	idx := make([dynamic]u16, 0, nring * 6, alloc)
	for b in 0 ..< PROXY_BANDS - 1 { 	// side quads between adjacent rings
		for s in 0 ..< PROXY_SIDES {
			s1 := (s + 1) % PROXY_SIDES
			a := u16(b * PROXY_SIDES + s)
			bb := u16(b * PROXY_SIDES + s1)
			c := u16((b + 1) * PROXY_SIDES + s1)
			d := u16((b + 1) * PROXY_SIDES + s)
			append(&idx, a, bb, c, a, c, d)
		}
	}
	top := PROXY_BANDS - 1
	for s in 0 ..< PROXY_SIDES { 	// top fan
		s1 := (s + 1) % PROXY_SIDES
		append(&idx, u16(apex_top), u16(top * PROXY_SIDES + s), u16(top * PROXY_SIDES + s1))
	}
	for s in 0 ..< PROXY_SIDES { 	// bottom fan
		s1 := (s + 1) % PROXY_SIDES
		append(&idx, u16(apex_bot), u16(s1), u16(s))
	}
	return v, idx[:], true
}
