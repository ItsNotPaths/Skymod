package assetdb

// Canopy-hull shadow proxy (ROADMAP full-scene-lighting Phase D2). For trees, casting the full
// alpha-tested canopy into the shadow map is expensive (huge overdraw + per-leaf discard). Instead
// we build ONCE, at model decode, a low-poly LATHE hull wrapping the canopy (the alpha-tested leaf
// shapes): bin the leaf vertices into height bands, take the max radius per band about the trunk
// axis, and stack rings into a closed solid. It follows the tree's vertical silhouette (narrow-top
// pine, round oak, …) species-agnostically — no cone assumption — and casts as cheap opaque
// geometry. The trunk casts via its own opaque shapes (handled by the normal caster path), so the
// hull only needs the canopy. Soft edges come from the shadow PCF.
//
// A model only gets a proxy if its canopy is substantial (PROXY_MIN_*); trees with little/no alpha
// foliage fail the test (has_proxy=false) and fall back to full alpha casting (the world layer's
// blacklist path). Plants are too small to pass and simply don't get one.

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
			v[b * PROXY_SIDES + s] = {
				pos     = {cx + ring_r[b] * math.cos(a), cy + ring_r[b] * math.sin(a), z},
				normal  = {0, 0, 1},
				tangent = {1, 0, 0, 1}, // shadow pass reads only position; safe defaults otherwise
			}
		}
	}
	v[apex_top] = {pos = {cx, cy, zmax}, normal = {0, 0, 1}, tangent = {1, 0, 0, 1}}
	v[apex_bot] = {pos = {cx, cy, zmin}, normal = {0, 0, 1}, tangent = {1, 0, 0, 1}}

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
