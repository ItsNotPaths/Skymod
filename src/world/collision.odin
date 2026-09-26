package world

// Static collision wiring (ROADMAP §2e physics, step B3). As cells stream in, each placed
// instance's bhk* collision (parsed + cached on its assetdb.Model — see decode_model /
// clone_collision) becomes Jolt static bodies in the scene's physics.World. Bodies are
// created LAZILY (a model resolves asynchronously) and BUDGETED (shape cooking — QuickHull /
// mesh AABB-tree — has a cost), then removed when the chunk unloads. The character controller
// (M4) and the drop-test (B5) collide against these.
//
// Geometry is baked to WORLD space here (instance.world × shape.transform) so the physics
// layer needs no matrix decomposition: meshes/hulls pass world-space verts; spheres/capsules
// pass world centre/endpoints + the instance's (uniform) scale folded into the radius.

import "core:math/linalg"
import "core:slice"

import "../assetdb"
import "../formats/nif"
import "../gamedb"
import smath "../math"
import "../physics"
import "../render"

// PHYS_BUDGET caps how many instances get their bodies cooked per sync_physics call, so a
// burst of newly-resolved models can't stall a frame on QuickHull/tree builds.
PHYS_BUDGET :: 8

// sync_physics creates collision bodies for loaded instances whose model has resolved but
// whose bodies aren't built yet, up to `budget` instances. Call once per frame (main thread)
// after stream_update. No-op if the scene has no physics world. Returns how many instances it
// built — the caller optimizes the broadphase when this is > 0 (Jolt's quad-tree degrades on
// incremental body adds that aren't followed by an OptimizeBroadPhase). Pass a large budget to
// drain the whole bubble at once (the load screen / interior entry).
sync_physics :: proc(s: ^Scene, cache: ^assetdb.Cache, budget := PHYS_BUDGET) -> int {
	if s.phys == nil {
		return 0
	}
	made := 0
	for _, &chunk in s.chunks {
		if chunk.phys_done {
			continue
		}
		all_built := true
		for &inst in chunk.instances {
			if inst.phys_built {
				continue
			}
			if inst.disabled {
				inst.phys_built = true // overlay-disabled: no collision; mark done so it isn't rescanned
				continue
			}
			m := inst.model
			if m == nil {
				m = assetdb.model_ptr(cache, inst.model_path)
			}
			if m == nil {
				all_built = false // model not uploaded yet — revisit next frame
				continue
			}
			build_instance_bodies(s.phys, &chunk, &inst, m, s.dynamic_clutter)
			inst.phys_built = true
			made += 1
			if made >= budget {
				return made
			}
		}
		// A chunk whose instances are all built needs no further scanning.
		if all_built {
			chunk.phys_done = true
		}
	}
	return made
}

// Phys_Stats is a snapshot of physics-side counts for the leak probe. If `bodies` or
// `instances` climb without bound while the player stays put, a release path is missing
// (chunks not freeing bodies, or instances re-accumulating). chunks/built track coverage.
Phys_Stats :: struct {
	chunks:    int, // resident chunks
	instances: int, // total placed instances across chunks
	built:     int, // instances whose collision bodies are built (phys_built)
	bodies:    int, // total Jolt body handles held across chunks (static + dynamic)
	dyn:       int, // of those, dynamic-clutter bodies (interiors)
}

// phys_stats totals the scene's physics-side counts (cheap; main thread). Feed the leak
// diagnostic: a steady climb with a stationary player = a body/instance release path missing.
phys_stats :: proc(s: ^Scene) -> (st: Phys_Stats) {
	for _, &chunk in s.chunks {
		st.chunks += 1
		st.instances += len(chunk.instances)
		for b in chunk.bodies {
			if b != 0 {st.bodies += 1} // exclude tombstones (live-disabled refs' freed bodies)
		}
		for &inst in chunk.instances {
			if inst.phys_built {st.built += 1}
			if inst.dyn_body != 0 {st.dyn += 1}
		}
	}
	return
}

// build_chunk_physics builds a chunk's static collision at load time — terrain now; per-
// instance object bodies are built lazily by sync_physics as their (async) models resolve.
// The symmetric counterpart to release_chunk_physics; call from EVERY chunk-load path
// (load_cell + the streamer). No-op without a physics world.
build_chunk_physics :: proc(s: ^Scene, db: ^gamedb.DB, chunk: ^Chunk) {
	if s.phys == nil {
		return
	}
	build_chunk_terrain_body(s, db, chunk)
}

// build_chunk_terrain_body adds a static trimesh collision body for a cell's LAND terrain,
// built from the SAME Z-up heightmap geometry the renderer uses (build_terrain_verts) — so
// collision matches the visual ground exactly. A trimesh (not Jolt's Y-up HeightFieldShape)
// keeps our Z-up convention with no axis juggling. Call at cell load (needs db); appends to
// the chunk for unload. No-op without a grid / heights / physics world.
build_chunk_terrain_body :: proc(s: ^Scene, db: ^gamedb.DB, chunk: ^Chunk) {
	if s.phys == nil || !chunk.has_grid {
		return
	}
	heights, ok := gamedb.cell_terrain(db, chunk.cell_form_id)
	if !ok {
		return
	}
	verts, _, _ := build_terrain_verts(heights, chunk.gx, chunk.gy, context.temp_allocator)
	pts := make([][3]f32, len(verts), context.temp_allocator)
	for v, i in verts {
		pts[i] = v.pos
	}
	G :: TERRAIN_GRID
	idx := make([dynamic]u32, 0, TERRAIN_QUADS * TERRAIN_QUADS * 6, context.temp_allocator)
	for y in 0 ..< TERRAIN_QUADS {
		for x in 0 ..< TERRAIN_QUADS {
			a := u32(y * G + x)
			b := u32(y * G + x + 1)
			c := u32((y + 1) * G + x)
			d := u32((y + 1) * G + x + 1)
			// Winding → UPWARD normals: Jolt's MeshShape is single-sided, so a downward-
			// facing terrain would let bodies fall straight through from above.
			append(&idx, a, b, c, b, d, c)
		}
	}
	body := physics.add_static_mesh(s.phys, pts, idx[:])
	if body != 0 {
		append(&chunk.bodies, body)
	}
}

// shove_clutter wakes and kicks every movable-clutter dynamic body (Phase 3b) within `radius` of
// `pos` with an outward + upward velocity — the debug "scatter" that makes interior clutter visibly
// come alive and then resettle (a quick eyeball test of the dynamic-body + settle path). Returns
// how many it kicked. No-op without a physics world.
shove_clutter :: proc(s: ^Scene, pos: smath.Vec3, radius: f32) -> int {
	if s.phys == nil {
		return 0
	}
	kick_body :: proc(s: ^Scene, b: physics.Body, pos: smath.Vec3, radius: f32, n: ^int) {
		if b == 0 {return}
		bp := physics.body_position(s.phys, b) // live position (clutter may have moved)
		d := smath.Vec3(bp) - pos
		if smath.length3(d) > radius {return}
		dir := smath.Vec3{d.x, d.y, 0}
		if smath.length3(dir) > 1 {dir = smath.normalize3(dir)}
		physics.kick(s.phys, b, smath.scale3(dir, 300) + {0, 0, 350})
		n^ += 1
	}
	n := 0
	for _, &chunk in s.chunks {
		for &inst in chunk.instances {
			// Articulated items keep dyn_body=0; their movable bodies live in dyn_bodies (Phase B). Kick
			// EACH so a hinged sign/animal actually swings when shoved. Single-body clutter uses dyn_body.
			if inst.dyn_bodies != nil {
				for b in inst.dyn_bodies {kick_body(s, b, pos, radius, &n)}
			} else {
				kick_body(s, inst.dyn_body, pos, radius, &n)
			}
		}
	}
	return n
}

// release_chunk_physics removes a chunk's collision bodies from the physics world and frees
// the list (+ the debug mesh). Called from every unload path + scene_destroy.
release_chunk_physics :: proc(s: ^Scene, chunk: ^Chunk) {
	if s.phys != nil {
		// Constraints FIRST — Jolt asserts if a body is removed while a live constraint still links it.
		for c in chunk.constraints {
			if c != nil {physics.remove_constraint(s.phys, c)}
		}
		for b in chunk.bodies {
			if b != 0 { // skip tombstones left by remove_instance_bodies (already freed)
				physics.remove_body(s.phys, b)
			}
		}
	}
	for &inst in chunk.instances {
		if inst.dyn_bodies != nil {delete(inst.dyn_bodies);inst.dyn_bodies = nil}
	}
	delete(chunk.constraints)
	chunk.constraints = nil
	delete(chunk.bodies)
	chunk.bodies = nil
	if chunk.has_debug {
		render.release_mesh(s.cache.r, chunk.debug_mesh)
		chunk.debug_mesh = {}
		chunk.has_debug = false
	}
}

// --- collision-hitbox debug overlay (--celltest) ---

// build_collision_debug builds a per-chunk wireframe mesh of EXACTLY the collision geometry
// fed to Jolt (world space): terrain + per-instance shapes — meshes/boxes as their true
// triangles, convex/sphere/capsule as their world AABB (enough to see presence + placement).
// Lets you eyeball whether a body exists where the visual mesh is. Call once (static scene).
build_collision_debug :: proc(s: ^Scene, db: ^gamedb.DB) {
	for _, &chunk in s.chunks {
		if chunk.has_debug {
			continue
		}
		verts := make([dynamic]render.Mesh_Vertex, 0, 4096, context.temp_allocator)
		idx := make([dynamic]u16, 0, 8192, context.temp_allocator)

		// Terrain trimesh (same geometry as build_chunk_terrain_body).
		if chunk.has_grid {
			if heights, ok := gamedb.cell_terrain(db, chunk.cell_form_id); ok {
				tv, _, _ := build_terrain_verts(heights, chunk.gx, chunk.gy, context.temp_allocator)
				G :: TERRAIN_GRID
				for y in 0 ..< TERRAIN_QUADS {
					for x in 0 ..< TERRAIN_QUADS {
						a := tv[y * G + x].pos
						b := tv[y * G + x + 1].pos
						c := tv[(y + 1) * G + x].pos
						d := tv[(y + 1) * G + x + 1].pos
						emit_tri(&verts, &idx, a, c, b)
						emit_tri(&verts, &idx, b, c, d)
					}
				}
			}
		}

		// Per-instance STATIC collision shapes (the exact geometry fed to Jolt). MOVABLE shapes in a
		// dynamic scene are drawn LIVE each frame (draw_collision_debug) at their body pose, so skip
		// them here; skip gameplay-only layers too (those aren't bodies).
		for &inst in chunk.instances {
			m := inst.model
			if m == nil {
				m = assetdb.model_ptr(&s.cache, inst.model_path)
			}
			if m == nil {
				continue
			}
			for sh in m.collision.shapes {
				if (sh.movable && s.dynamic_clutter) || !nif.layer_is_solid(sh.layer) {
					continue
				}
				emit_shape_wire(&verts, &idx, inst.world * sh.transform, sh)
				if len(verts) > 60000 {break} // u16 index ceiling — cap per chunk (debug only)
			}
			if len(verts) > 60000 {break}
		}

		if len(verts) > 0 && len(idx) > 0 {
			chunk.debug_mesh = render.upload_mesh(s.cache.r, verts[:], idx[:])
			chunk.has_debug = true
		}
	}
}

// draw_collision_debug draws the collision wireframe: cached per-chunk STATIC geometry, plus a
// per-frame rebuild of the DYNAMIC bodies at their LIVE pose (so a shoved item's box follows it).
// The dynamic mesh is the same geometry the physics build used, drawn at instance_world (= the body's
// transform), so it reveals the TRUE Jolt shape/pose independent of the render mesh.
draw_collision_debug :: proc(s: ^Scene, r: ^render.Renderer, vp: smath.Mat4) {
	for _, &chunk in s.chunks {
		if chunk.has_debug {
			render.draw_wire(r, chunk.debug_mesh, vp)
		}
	}
	// Rebuild the dynamic overlay each frame (bodies move). Release last frame's mesh first (drawn +
	// submitted last frame). Dynamic bodies are few (tens), so this is cheap.
	if s.has_dyn_debug {
		render.release_mesh(r, s.dyn_debug)
		s.has_dyn_debug = false
	}
	verts := make([dynamic]render.Mesh_Vertex, 0, 2048, context.temp_allocator)
	idx := make([dynamic]u16, 0, 4096, context.temp_allocator)
	for _, &chunk in s.chunks {
		for &inst in chunk.instances {
			m := inst.model
			if m == nil {continue}
			iw := instance_world(s, &inst) // single-body live pose (else inst.world)
			for sh in m.collision.shapes {
				if !(sh.movable && s.dynamic_clutter) {continue}
				// ARTICULATED item: pose each shape by ITS OWN linked body (Phase B/C), so a hinged part
				// draws where the constraint put it. Single-body items use the instance follow (iw).
				wm := iw
				if inst.dyn_bodies != nil {
					b := inst.dyn_bodies[sh.body]
					wm = physics.body_transform(s.phys, b) * smath.translate(-inst.pos) * inst.world if b != 0 else inst.world
				}
				emit_shape_wire(&verts, &idx, wm * sh.transform, sh)
				if len(verts) > 60000 {break}
			}
			if len(verts) > 60000 {break}
		}
		if len(verts) > 60000 {break}
	}
	if len(verts) > 0 && len(idx) > 0 {
		s.dyn_debug = render.upload_mesh(r, verts[:], idx[:])
		s.has_dyn_debug = true
		render.draw_wire(r, s.dyn_debug, vp)
	}
}

// clear_collision_debug releases all cached wireframe meshes (per-chunk static + the dynamic overlay)
// so the next enable rebuilds fresh — models that streamed in after the first build then appear.
clear_collision_debug :: proc(s: ^Scene) {
	for _, &chunk in s.chunks {
		if chunk.has_debug {
			render.release_mesh(s.cache.r, chunk.debug_mesh)
			chunk.debug_mesh = {}
			chunk.has_debug = false
		}
	}
	if s.has_dyn_debug {
		render.release_mesh(s.cache.r, s.dyn_debug)
		s.has_dyn_debug = false
	}
}

// emit_shape_wire appends one collision shape's wireframe under transform `wm`, drawing EXACTLY the
// shape physics uses: a FLAT convex → its box-ified OBB (matching dyn_sub), a Box → its box, a Mesh →
// its triangles, round convex/sphere/capsule → their AABB. The wire pipeline is LINE fill, so the
// emitted triangles render as edges.
@(private = "file")
emit_shape_wire :: proc(verts: ^[dynamic]render.Mesh_Vertex, idx: ^[dynamic]u16, wm: smath.Mat4, sh: nif.Collision_Shape) {
	switch sh.kind {
	case .Mesh:
		emit_indexed(verts, idx, wm, sh.vertices, sh.indices)
	case .Convex:
		if shape_is_flat(sh.vertices) {
			lo := [3]f32{max(f32), max(f32), max(f32)}
			hi := [3]f32{min(f32), min(f32), min(f32)}
			for p in sh.vertices {lo = linalg.min(lo, p);hi = linalg.max(hi, p)}
			m := [3]f32{sh.radius, sh.radius, sh.radius} // Havok convex margin = the shape's real thickness
			emit_box(verts, idx, obb_corners(wm, lo - m, hi + m))
		} else {
			emit_aabb(verts, idx, points_aabb(wm, sh.vertices))
		}
	case .Box:
		emit_box(verts, idx, box_corners(wm, sh.half_extents))
	case .Sphere:
		c := mat_point(wm, {0, 0, 0})
		rr := sh.radius * mat_scale(wm)
		emit_aabb(verts, idx, {c - rr, c + rr})
	case .Capsule:
		rr := sh.radius * mat_scale(wm)
		a := mat_point(wm, sh.point_a)
		b := mat_point(wm, sh.point_b)
		lo := [3]f32{min(a.x, b.x) - rr, min(a.y, b.y) - rr, min(a.z, b.z) - rr}
		hi := [3]f32{max(a.x, b.x) + rr, max(a.y, b.y) + rr, max(a.z, b.z) + rr}
		emit_aabb(verts, idx, {lo, hi})
	}
}

// obb_corners returns the 8 world corners of a SHAPE-LOCAL AABB [lo,hi] placed by `wm`, in the
// bit-order emit_box expects (i = x·4 + y·2 + z, lo at 0). An oriented box, not an axis box.
@(private = "file")
obb_corners :: proc(wm: smath.Mat4, lo, hi: [3]f32) -> [][3]f32 {
	xs := [2]f32{lo.x, hi.x};ys := [2]f32{lo.y, hi.y};zs := [2]f32{lo.z, hi.z}
	out := make([][3]f32, 8, context.temp_allocator)
	i := 0
	for ix in 0 ..< 2 {
		for iy in 0 ..< 2 {
			for iz in 0 ..< 2 {
				out[i] = mat_point(wm, {xs[ix], ys[iy], zs[iz]})
				i += 1
			}
		}
	}
	return out
}

@(private = "file")
emit_tri :: proc(verts: ^[dynamic]render.Mesh_Vertex, idx: ^[dynamic]u16, a, b, c: [3]f32) {
	base := u16(len(verts))
	append(verts, dbg_vert(a), dbg_vert(b), dbg_vert(c))
	append(idx, base, base + 1, base + 2)
}

@(private = "file")
emit_indexed :: proc(verts: ^[dynamic]render.Mesh_Vertex, idx: ^[dynamic]u16, wm: smath.Mat4, pts: [][3]f32, indices: []u32) {
	base := u16(len(verts))
	for p in pts {
		append(verts, dbg_vert(mat_point(wm, p)))
	}
	for i := 0; i + 2 < len(indices); i += 3 {
		append(idx, base + u16(indices[i]), base + u16(indices[i + 1]), base + u16(indices[i + 2]))
	}
}

// emit_box appends a box's 12 triangles from its 8 corners (box_corners ordering: bit0=x,1=y,2=z).
@(private = "file")
emit_box :: proc(verts: ^[dynamic]render.Mesh_Vertex, idx: ^[dynamic]u16, c: [][3]f32) {
	if len(c) < 8 {
		return
	}
	base := u16(len(verts))
	for p in c[:8] {
		append(verts, dbg_vert(p))
	}
	// Corners are ordered i = sx·4 + sy·2 + sz (− at 0, + at 1), matching box_corners/emit_aabb.
	faces := [12][3]u16 {
		{0, 1, 3}, {0, 3, 2}, {4, 5, 7}, {4, 7, 6}, // x−, x+
		{0, 1, 5}, {0, 5, 4}, {2, 3, 7}, {2, 7, 6}, // y−, y+
		{0, 2, 6}, {0, 6, 4}, {1, 3, 7}, {1, 7, 5}, // z−, z+
	}
	for f in faces {
		append(idx, base + f[0], base + f[1], base + f[2])
	}
}

emit_aabb :: proc(verts: ^[dynamic]render.Mesh_Vertex, idx: ^[dynamic]u16, box: [2][3]f32) {
	lo, hi := box[0], box[1]
	c: [8][3]f32
	i := 0
	for sx in 0 ..< 2 {
		for sy in 0 ..< 2 {
			for sz in 0 ..< 2 {
				c[i] = {lo.x if sx == 0 else hi.x, lo.y if sy == 0 else hi.y, lo.z if sz == 0 else hi.z}
				i += 1
			}
		}
	}
	emit_box(verts, idx, c[:])
}

@(private = "file")
points_aabb :: proc(wm: smath.Mat4, pts: [][3]f32) -> [2][3]f32 {
	lo := [3]f32{max(f32), max(f32), max(f32)}
	hi := [3]f32{min(f32), min(f32), min(f32)}
	for p in pts {
		w := mat_point(wm, p)
		lo = {min(lo.x, w.x), min(lo.y, w.y), min(lo.z, w.z)}
		hi = {max(hi.x, w.x), max(hi.y, w.y), max(hi.z, w.z)}
	}
	return {lo, hi}
}

@(private = "file")
dbg_vert :: proc(p: [3]f32) -> render.Mesh_Vertex {
	return render.mesh_vertex(p, {0, 0, 1}, {0, 0})
}

// build_instance_bodies turns one instance's cached collision into world-placed Jolt bodies,
// appending their handles to the chunk for later removal. Phase A (articulation): each bhkRigidBody
// (nif.Collision_Body) becomes ONE Jolt body — a STATIC body per solid shape for fixed geometry, or
// (interiors, when allow_dynamic) a single DYNAMIC compound body built from that rigid body's EXACT
// shapes (Box/Sphere/Capsule primitives; meshes as hulls). This replaces the old merge-the-whole-
// instance-into-one-hull path: it preserves articulation (each linked body moves independently) AND
// gives Jolt an analytic narrow phase — the coplanar flat-box-on-flat-mesh EPA-storm fix. The
// constraints that link the bodies (signs swing, wheels roll) are Phase B.
@(private = "file")
build_instance_bodies :: proc(w: ^physics.World, chunk: ^Chunk, inst: ^Instance, m: ^assetdb.Model, allow_dynamic: bool) {
	inst.body_first = len(chunk.bodies) // record this instance's contiguous slice of chunk.bodies
	shapes := m.collision.shapes
	nmov := 0 // dynamic bodies built (a single one drives render-follow; multi is Phase B/C)

	// body_ids[bi] = the Jolt body representing Collision_Body bi, so hinge constraints (Phase B) can
	// resolve their entity bodies. A dynamic body is one compound; a static multi-shape body builds
	// one Jolt body per shape — the FIRST is the representative (all its parts are fixed at the same
	// place, so a hinge anchored to any of them is equivalent).
	body_ids := make([]physics.Body, len(m.collision.bodies), context.temp_allocator)

	for body, bi in m.collision.bodies {
		if allow_dynamic && body.movable {
			// ONE dynamic compound body per movable rigid body, from its exact sub-shapes.
			subs := make([dynamic]physics.Dyn_Shape, 0, 8, context.temp_allocator)
			for sh in shapes {
				if sh.body == bi {dyn_sub(&subs, inst.world, inst.pos, sh)}
			}
			if len(subs) > 0 {
				// Body frame at inst.pos so the render-follow math (instance_world) lines up exactly.
				if b := physics.add_dynamic_body(w, subs[:], inst.pos); b != 0 {
					append(&chunk.bodies, b)
					body_ids[bi] = b
					inst.dyn_body = b
					nmov += 1
				}
			}
			continue
		}
		// Static geometry (fixed bodies, or every body when !allow_dynamic): each solid shape → its
		// own static body. Gameplay-only layers (weapon/projectile/spell/trigger/trap/non-collidable)
		// are aiming/LOS/trigger volumes, not walls — skip them (see nif.layer_is_solid).
		for sh in shapes {
			if sh.body != bi || !nif.layer_is_solid(sh.layer) {continue}
			wm := inst.world * sh.transform // REFR placement × the shape's NIF-root transform
			s := mat_scale(wm) // (uniform) scale for parametric shapes' radius
			b: physics.Body
			switch sh.kind {
			case .Mesh:
				// Single-sided: the bhk* destriper emits consistently-wound (outward) triangles, so a
				// single-sided MeshShape cleanly walls off clutter (half the triangle count of two-sided).
				b = physics.add_static_mesh(w, xform_points(wm, sh.vertices), sh.indices)
			case .Convex:
				b = physics.add_static_hull(w, xform_points(wm, sh.vertices), margin = sh.radius * s)
			case .Box:
				// Exact even when rotated/scaled: the convex hull of the 8 transformed corners.
				b = physics.add_static_hull(w, box_corners(wm, sh.half_extents))
			case .Sphere:
				b = physics.add_static_sphere(w, mat_point(wm, {0, 0, 0}), sh.radius * s)
			case .Capsule:
				b = physics.add_static_capsule(w, mat_point(wm, sh.point_a), mat_point(wm, sh.point_b), sh.radius * s)
			}
			if b != 0 {
				append(&chunk.bodies, b)
				if body_ids[bi] == 0 {body_ids[bi] = b} // representative for constraint anchoring
			}
		}
	}
	inst.body_count = len(chunk.bodies) - inst.body_first
	for b in chunk.bodies[inst.body_first:] {physics.set_owner(w, b, u64(inst.form_id))}

	// Hinges (Phase B): link the built bodies. Pivot/axis/perp are in NIF-root space → apply inst.world.
	inst.con_first = len(chunk.constraints)
	for c in m.collision.constraints {
		a := body_ids[c.body_a]
		b := body_ids[c.body_b]
		if a == 0 || b == 0 {continue} // an entity wasn't built (e.g. non-solid static) → skip the joint
		wp := mat_point(inst.world, c.pivot)
		wa := smath.normalize3(mat_dir(inst.world, c.axis))
		wperp := smath.normalize3(mat_dir(inst.world, c.perp))
		if h := physics.add_hinge(w, a, b, wp, wa, wperp, c.min_angle, c.max_angle, c.max_friction, c.limited);
		   h != nil {
			append(&chunk.constraints, h)
		}
	}
	inst.con_count = len(chunk.constraints) - inst.con_first

	// Render-follow: a single dynamic body drives the whole instance visual (the common case; keeps
	// inst.dyn_body). An ARTICULATED item (linked bodies) keeps its per-body handles so the collision
	// view (and Phase C render) can pose each body live; its whole-mesh follow stays off (dyn_body=0).
	if nmov != 1 {
		inst.dyn_body = 0
		if nmov > 1 || inst.con_count > 0 {inst.dyn_bodies = slice.clone(body_ids)}
	}
}

// dyn_sub appends one collision shape as a body-local Dyn_Shape descriptor (relative to `origin`,
// the dynamic body's frame origin; `wm0` is the instance placement), using an EXACT Jolt primitive
// for box/sphere/capsule and a convex hull for mesh/convex geometry. mat_rotation extracts the
// shape's world orientation (scale removed). Exported: the --clutterprobe harness calls it too, so
// the probe builds the SAME dynamic bodies the game does.
dyn_sub :: proc(subs: ^[dynamic]physics.Dyn_Shape, wm0: smath.Mat4, origin: [3]f32, sh: nif.Collision_Shape) {
	wm := wm0 * sh.transform
	s := mat_scale(wm)
	switch sh.kind {
	case .Box:
		append(subs, physics.Dyn_Shape {
			kind = .Box,
			pos  = mat_point(wm, {0, 0, 0}) - origin,
			rot  = mat_rotation(wm),
			half = sh.half_extents * s,
		})
	case .Sphere:
		append(subs, physics.Dyn_Shape{kind = .Sphere, pos = mat_point(wm, {0, 0, 0}) - origin, radius = sh.radius * s})
	case .Capsule:
		a := mat_point(wm, sh.point_a)
		b := mat_point(wm, sh.point_b)
		axis := b - a
		half_h := smath.length3(axis) * 0.5
		// Jolt capsules run along +Y (like add_static_capsule); align +Y to the endpoint axis.
		rot := quaternion128(1)
		if half_h > 0 {rot = linalg.quaternion_between_two_vector3_f32({0, 1, 0}, axis / (half_h * 2))}
		append(subs, physics.Dyn_Shape {
			kind = .Capsule, pos = (a + b) * 0.5 - origin, rot = rot,
			radius = sh.radius * s, half_h = half_h,
		})
	case .Mesh, .Convex:
		// FLAT convex/mesh clutter (ingots, plates, books, boards) coplanar with the floor trimesh
		// drives Jolt's convex-hull support function into a degenerate EPA normal → NaN blow-up
		// (~50ms/step storm). Represent a flat shape as its oriented bounding BOX instead — an analytic
		// BoxShape is well-conditioned, and a flat convex clutter shape IS essentially a box (the ingot
		// is literally an 8-vert box). Genuinely 3D clutter (pots, buckets) keeps its hull (stable).
		if len(sh.vertices) > 0 && (physics.dyn_boxify || shape_is_flat(sh.vertices)) {
			lo := [3]f32{max(f32), max(f32), max(f32)}
			hi := [3]f32{min(f32), min(f32), min(f32)}
			for p in sh.vertices {lo = linalg.min(lo, p);hi = linalg.max(hi, p)}
			// half-extent = vert AABB + the Havok convex MARGIN (sh.radius): flat clutter (ingots) stores
			// ~zero vert thickness and its real thickness in the margin, so without it the box is a
			// zero-height quad that falls through. The margin inflates every axis (Havok rounds the hull).
			append(subs, physics.Dyn_Shape {
				kind = .Box, pos = mat_point(wm, (lo + hi) * 0.5) - origin,
				rot = mat_rotation(wm), half = ((hi - lo) * 0.5 + sh.radius) * s,
			})
			return
		}
		pts := make([][3]f32, len(sh.vertices), context.temp_allocator)
		for p, i in sh.vertices {pts[i] = mat_point(wm, p) - origin}
		append(subs, physics.Dyn_Shape{kind = .Hull, points = pts, margin = sh.radius * s})
	}
}

// FLAT_RATIO: a shape is "flat" (→ box proxy) when its thinnest OBB extent is under this fraction of
// its longest — the coplanar-with-floor case that makes a convex-hull-vs-mesh EPA normal degenerate.
FLAT_RATIO :: f32(0.30)

// shape_is_flat reports whether a point cloud's shape-local AABB is thin in one axis (a plate/ingot/
// board) — the flat hulls that NaN-blow-up against the floor trimesh and are better as analytic boxes.
@(private = "file")
shape_is_flat :: proc(verts: [][3]f32) -> bool {
	lo := [3]f32{max(f32), max(f32), max(f32)}
	hi := [3]f32{min(f32), min(f32), min(f32)}
	for p in verts {lo = linalg.min(lo, p);hi = linalg.max(hi, p)}
	e := hi - lo
	mn := min(e.x, min(e.y, e.z))
	mx := max(e.x, max(e.y, e.z))
	return mx > 0 && mn < FLAT_RATIO * mx
}

// mat_rotation extracts a transform's rotation as a quaternion, dividing out the (uniform) scale
// from each basis column so a scaled placement still yields a unit rotation.
@(private = "file")
mat_rotation :: proc(m: smath.Mat4) -> quaternion128 {
	c0 := smath.normalize3({m[0, 0], m[1, 0], m[2, 0]})
	c1 := smath.normalize3({m[0, 1], m[1, 1], m[2, 1]})
	c2 := smath.normalize3({m[0, 2], m[1, 2], m[2, 2]})
	r := matrix[3, 3]f32{
		c0.x, c1.x, c2.x,
		c0.y, c1.y, c2.y,
		c0.z, c1.z, c2.z,
	}
	return linalg.quaternion_from_matrix3_f32(r)
}

// remove_instance_bodies destroys one instance's collision bodies (its contiguous slice of
// chunk.bodies, recorded at build) and tombstones the slots to 0 so release_chunk_physics won't
// double-free them. The live counterpart to sync_physics's build — used by disable_ref so a
// disabled ref loses its collision immediately, not just on the next chunk reload.
remove_instance_bodies :: proc(w: ^physics.World, chunk: ^Chunk, inst: ^Instance) {
	if w == nil {
		return
	}
	// Constraints first (Jolt asserts on removing a body a live constraint still links), tombstoned.
	for k in inst.con_first ..< inst.con_first + inst.con_count {
		if k >= 0 && k < len(chunk.constraints) && chunk.constraints[k] != nil {
			physics.remove_constraint(w, chunk.constraints[k])
			chunk.constraints[k] = nil
		}
	}
	inst.con_count = 0
	for k in inst.body_first ..< inst.body_first + inst.body_count {
		if k >= 0 && k < len(chunk.bodies) && chunk.bodies[k] != 0 {
			physics.remove_body(w, chunk.bodies[k])
			chunk.bodies[k] = 0 // tombstone (release_chunk_physics skips 0)
		}
	}
	inst.body_count = 0
	inst.dyn_body = 0
	if inst.dyn_bodies != nil {delete(inst.dyn_bodies);inst.dyn_bodies = nil}
}

// mat_point applies a 4×4 transform to a point (w=1) and returns the xyz.
@(private = "file")
mat_point :: proc(m: smath.Mat4, p: [3]f32) -> [3]f32 {
	v := m * [4]f32{p.x, p.y, p.z, 1}
	return {v.x, v.y, v.z}
}

// mat_dir applies a 4×4 transform to a DIRECTION (w=0 → ignores translation) — for hinge axes/perps.
@(private = "file")
mat_dir :: proc(m: smath.Mat4, d: [3]f32) -> [3]f32 {
	v := m * [4]f32{d.x, d.y, d.z, 0}
	return {v.x, v.y, v.z}
}

// xform_points transforms a point cloud to world space (temp-allocated; sync runs on the main
// thread which free_all's temp each frame).
@(private = "file")
xform_points :: proc(m: smath.Mat4, src: [][3]f32) -> [][3]f32 {
	out := make([][3]f32, len(src), context.temp_allocator)
	for p, i in src {
		out[i] = mat_point(m, p)
	}
	return out
}

// box_corners returns the 8 world-space corners of a centred box under transform `m`.
@(private = "file")
box_corners :: proc(m: smath.Mat4, h: [3]f32) -> [][3]f32 {
	out := make([][3]f32, 8, context.temp_allocator)
	i := 0
	for sx in ([2]f32{-1, 1}) {
		for sy in ([2]f32{-1, 1}) {
			for sz in ([2]f32{-1, 1}) {
				out[i] = mat_point(m, {h.x * sx, h.y * sy, h.z * sz})
				i += 1
			}
		}
	}
	return out
}

// mat_scale extracts the (assumed uniform) scale from a transform's first column length —
// REFR scale lives in instance.world; the NIF-internal collision transform is unscaled.
@(private = "file")
mat_scale :: proc(m: smath.Mat4) -> f32 {
	return smath.length3({m[0, 0], m[1, 0], m[2, 0]})
}
