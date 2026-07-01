package nif

// Door rig helpers (open-interiors door integration). Skyrim load doors carry a "Door" hinge
// node (the swinging panel subtree — its shapes are tagged under_hinge by parse_scene) and a
// "DoorBlack" aperture quad. These helpers surface the named-node world frames the door
// harness / portal need. (The authored Open/Close keyframes are NOT used: the door swings a
// fixed +90° OUTWARD, opposite the authored ~18° inward pose, which clips past a few inches.)

// node_world_by_name composes the world transform of the first block named `target` (node or
// shape), or ok=false if absent. Used to locate the "Door" hinge frame (pivot + axes) and the
// "DoorBlack" aperture placement. Re-parses block infos (cheap for a single door mesh).
node_world_by_name :: proc(
	data: []u8,
	h: ^Header,
	target: string,
) -> (world: matrix[4, 4]f32, ok: bool) {
	infos := make([]Block_Info, int(h.num_blocks), context.temp_allocator)
	for i in 0 ..< int(h.num_blocks) {
		infos[i] = parse_block_info(h, data, i)
	}
	visited := make([]bool, int(h.num_blocks), context.temp_allocator) // cycle/DAG guard
	for root in parse_footer(data, h) {
		if m, found := find_named(infos, h, visited, int(root), 1, target); found {
			return m, true
		}
	}
	return {}, false
}

// aperture_rect returns the doorway opening as four corner points in the door NIF's LOCAL space
// (the caller places them with the door REFR's world transform). It uses the door PANEL — the
// swinging `under_hinge` subtree at rest, which fills the doorway — falling back to a shape named
// "DoorBlack", then to the whole mesh. The panel's axis-aligned bounds give the rectangle: the
// thinnest axis is the door's facing normal (dropped), the other two are width + height. This
// matches the portal stencil to the actual door instead of a guessed quad. ok=false if no usable
// geometry. Corners are ordered CCW (bl, br, tr, tl) in the rect's two thick axes.
aperture_rect :: proc(data: []u8, h: ^Header) -> (corners: [4][3]f32, ok: bool) {
	// Scratch parse into the temp allocator (bulk-freed by the caller's per-frame free_all) — do
	// NOT destroy_shapes here: that would free temp-arena pointers via the heap allocator (segfault).
	shapes := parse_scene(data, h, context.temp_allocator)

	accumulate :: proc(s: PlacedShape, lo, hi: ^[3]f32) -> (any: bool) {
		for v in s.geometry.vertices {
			wv := s.world * [4]f32{v[0], v[1], v[2], 1}
			for k in 0 ..< 3 {
				lo[k] = min(lo[k], wv[k])
				hi[k] = max(hi[k], wv[k])
			}
			any = true
		}
		return
	}

	lo := [3]f32{max(f32), max(f32), max(f32)}
	hi := [3]f32{min(f32), min(f32), min(f32)}
	found := false
	for s in shapes {
		if s.under_hinge {found |= accumulate(s, &lo, &hi)}
	}
	if !found {
		for s in shapes {
			if s.name == "DoorBlack" {found |= accumulate(s, &lo, &hi)}
		}
	}
	if !found {
		for s in shapes {found |= accumulate(s, &lo, &hi)}
	}
	if !found {
		return {}, false
	}

	center := [3]f32{(lo[0] + hi[0]) * 0.5, (lo[1] + hi[1]) * 0.5, (lo[2] + hi[2]) * 0.5}
	half := [3]f32{(hi[0] - lo[0]) * 0.5, (hi[1] - lo[1]) * 0.5, (hi[2] - lo[2]) * 0.5}
	// Thinnest axis = the door's facing normal; the rect spans the other two.
	ti := 0
	if half[1] < half[ti] {ti = 1}
	if half[2] < half[ti] {ti = 2}
	a := (ti + 1) % 3
	b := (ti + 2) % 3
	ea, eb: [3]f32
	ea[a] = half[a]
	eb[b] = half[b]
	corners[0] = {center[0] - ea[0] - eb[0], center[1] - ea[1] - eb[1], center[2] - ea[2] - eb[2]}
	corners[1] = {center[0] + ea[0] - eb[0], center[1] + ea[1] - eb[1], center[2] + ea[2] - eb[2]}
	corners[2] = {center[0] + ea[0] + eb[0], center[1] + ea[1] + eb[1], center[2] + ea[2] + eb[2]}
	corners[3] = {center[0] - ea[0] + eb[0], center[1] - ea[1] + eb[1], center[2] - ea[2] + eb[2]}
	return corners, true
}

@(private)
find_named :: proc(
	infos: []Block_Info,
	h: ^Header,
	visited: []bool,
	idx: int,
	parent_world: matrix[4, 4]f32,
	target: string,
) -> (matrix[4, 4]f32, bool) {
	if idx < 0 || idx >= len(infos) || visited[idx] {
		return {}, false
	}
	visited[idx] = true
	info := infos[idx]
	if !info.is_node && !info.is_shape {
		return {}, false
	}
	world := parent_world * transform_to_mat4(info.transform)
	if block_name(h, info) == target {
		return world, true
	}
	for c in info.children {
		if m, ok := find_named(infos, h, visited, int(c), world, target); ok {
			return m, ok
		}
	}
	return {}, false
}
