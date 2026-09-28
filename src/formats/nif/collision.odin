package nif

// NIF Havok (`bhk*`) collision decoder (Phase 2 / physics — ROADMAP §2e). Reuses
// Skyrim's *collision shape data* while replacing Havok's *runtime* with Jolt: this
// pure parser turns the `bhk*` block tree into engine-neutral `Collision_Shape`s
// (boxes / spheres / capsules / convex hulls / triangle meshes) in NIF-root space,
// in SKYRIM UNITS. The world integrator then applies the REFR transform on top, the
// same way it places render meshes (see parse_scene / PlacedShape).
//
// Layout is Skyrim LE (20.2.0.7, user 12, BS 83). Field offsets were taken from the
// niftools nif.xml spec, cross-checked against nifly (the modern Bodyslide/OS NIF
// lib) where the spec was ambiguous, and the scale/decompression conventions against
// NifSkope's collision renderer (the ground truth — it draws these correctly).
// Validated empirically via `nifdump --collision` (tools/nifdump): a rigid body's
// rotation must be a unit quaternion, mesh indices must be in range, and the parsed
// collision AABB must overlap the render-mesh AABB — strong signals the offsets and
// the ×HAVOK_SCALE factor are right.

import "core:fmt"
import "core:math"
import "core:strings"

// HAVOK_SCALE converts Havok units (how `bhk*` stores all lengths/positions) to
// Skyrim/NIF units. NifSkope applies this as shape-verts ×10 under a rigid-body
// transform of scale 7.0 → a uniform ×69.99124. We bake the whole factor into the
// leaf geometry so the body/placement transforms carry only rotation + translation.
HAVOK_SCALE :: f32(69.99124)

// CHUNK_QUANT is the fixed quantizer for bhkCompressedMeshShapeData chunk verts: the
// per-vertex u16 offsets are in thousandths of a Havok unit (NifSkope: `… / 1000`).
CHUNK_QUANT :: f32(1.0 / 1000.0)

Collision_Kind :: enum u8 {
	Box,
	Sphere,
	Capsule,
	Convex, // convex hull from a point cloud (bhkConvexVerticesShape)
	Mesh,   // triangle soup (bhkCompressedMeshShape: big verts + chunks)
}

// Collision_Shape is one leaf Havok shape, world-placed into NIF-root space via
// `transform` (= node world × rigid-body transform × any nested transform shapes).
// Lengths are Skyrim units. The hull/mesh point arrays are SHAPE-LOCAL (transform
// places them) so the consumer can build a Jolt shape + body transform directly.
Collision_Shape :: struct {
	kind:         Collision_Kind,
	transform:    matrix[4, 4]f32,
	half_extents: [3]f32,    // Box: half-size along x/y/z
	radius:       f32,       // Sphere / Capsule radius (Capsule: at point_a)
	radius_b:     f32,       // Capsule: radius at point_b
	point_a:      [3]f32,    // Capsule: first endpoint (shape-local)
	point_b:      [3]f32,    // Capsule: second endpoint (shape-local)
	vertices:     [][3]f32,  // Convex hull points / Mesh vertices (shape-local)
	indices:      []u32,     // Mesh: 3 per triangle, into `vertices`; empty for Convex
	// Rigid-body classification (from the owning bhkRigidBody — see parse_collision_object).
	// `movable` = a free-moving clutter body (mass > 0 + a dynamic motion system on a movable
	// layer); the world layer makes a Jolt DYNAMIC body for it instead of static. `mass` is the
	// Havok mass (classification only; Jolt computes its own from the shape volume). `layer` is
	// the SkyrimLayer for reference/debug. (`dynamic` is an Odin keyword, hence `movable`.)
	movable:      bool,
	mass:         f32,
	layer:        u8,
	// body indexes into Collision.bodies — the owning bhkRigidBody. All shapes under one rigid
	// body share its motion/mass and (Phase A multi-body) become ONE Jolt body: the world layer
	// groups shapes by this index instead of merging an instance's whole shape set into one hull.
	body:         int,
}

// Collision_Body is one bhkRigidBody (Phase A articulation): the motion classification shared by
// its shapes, plus the NIF block ref so bhk*Constraint blocks — which reference rigid-body blocks
// by ref — can resolve to a body index (Phase B). A shape belongs to the body whose index is in
// its `body` field. Most clutter is a single body; articulated props (signs, hanging animals, cart
// wheels) carry several linked by constraints.
Collision_Body :: struct {
	movable:   bool,
	mass:      f32,
	layer:     u8,
	motion:    u8,
	block_ref: int, // NIF block index of the bhkRigidBody (constraint entity resolution)
	frame:     matrix[4, 4]f32, // body-local → NIF-root transform (node_world × body_xform); a hinge pivot is in this frame
}

// Collision_Constraint is one bhk*Constraint joint (Phase B) linking two bodies. The hinge pivot/axis/
// perp are resolved to NIF-ROOT space (via body A's frame) so the world integrator only applies the REFR
// transform — same as shapes. min/max are the swing limits (radians); a plain bhkHingeConstraint is free
// (limited=false). See parse_constraints for the byte layout.
Collision_Constraint :: struct {
	limited:      bool, // true = bhkLimitedHingeConstraint (min/max apply); false = bhkHingeConstraint (free)
	body_a:       int, // indices into Collision.bodies (-1 if an entity isn't a decoded body)
	body_b:       int,
	pivot:        [3]f32, // hinge point, NIF-root space (Skyrim units)
	axis:         [3]f32, // hinge rotation axis (unit), NIF-root space
	perp:         [3]f32, // an axis perpendicular to the hinge axis (zero-angle reference), NIF-root space
	min_angle:    f32,
	max_angle:    f32,
	max_friction: f32,
}

// (hole collision-blob-abi :tags (assets unclaimed) :sev wish) Collision uses Odin slices and matrix[4,4]f32; a store filled from Rust needs a fixed C layout (flat arrays, stated column order).
Collision :: struct {
	shapes:      []Collision_Shape,
	bodies:      []Collision_Body,
	constraints: []Collision_Constraint,
	unhandled:   int, // shape blocks we recognized as bhk* but don't decode yet (e.g. transform shapes)
}

destroy_collision :: proc(c: ^Collision) {
	for &s in c.shapes {
		delete(s.vertices)
		delete(s.indices)
	}
	delete(c.shapes)
	delete(c.bodies)
	delete(c.constraints)
	c^ = {}
}

// parse_collision walks the node hierarchy (like parse_scene), and for every node
// carrying a Collision Object ref, resolves the bhk* shape tree into world-placed
// Collision_Shapes. Caller frees with destroy_collision.
parse_collision :: proc(data: []u8, h: ^Header, allocator := context.allocator) -> Collision {
	context.allocator = allocator

	infos := make([]Block_Info, int(h.num_blocks), context.temp_allocator)
	for i in 0 ..< int(h.num_blocks) {
		infos[i] = parse_block_info(h, data, i)
	}
	roots := parse_footer(data, h)
	visited := make([]bool, int(h.num_blocks), context.temp_allocator)

	col: Collision
	out := make([dynamic]Collision_Shape, 0, 8)
	bodies := make([dynamic]Collision_Body, 0, 4)
	for root in roots {
		walk_collision(infos, data, h, visited, int(root), Mat4_Id, &out, &bodies, &col.unhandled, is_root = true)
	}
	col.shapes = out[:]
	col.bodies = bodies[:]
	col.constraints = parse_constraints(infos, data, h, bodies[:])
	return col
}

// parse_constraints resolves every bhkLimitedHingeConstraint / bhkHingeConstraint block into a
// Collision_Constraint linking two decoded bodies (Phase B). Byte layout (Skyrim LE, RE'd via nifdump
// --conraw + cross-checked so both bodies' pivots resolve to the same world point):
//   @0 numEntities(u32)=2  @4 entityA(ref)  @8 entityB(ref)  @12 priority(u32)
//   @16 axleA  @32 perpA1  @48 perpA2  @64 pivotA  (each Vector4; body-A local frame)
//   @80 axleB  @96 perpB1  @112 perpB2  @128 pivotB
//   @144 minAngle  @148 maxAngle  @152 maxFriction  @156 enableMotor(u8)   [LimitedHinge only]
// A plain bhkHingeConstraint block ends at 144 (free rotation, no limits). The pivot is a POINT
// (×HAVOK_SCALE + translation), axle/perp are DIRECTIONS (rotation only); both are resolved to
// NIF-root space via body A's frame so the world integrator only needs the REFR transform.
@(private = "file")
parse_constraints :: proc(infos: []Block_Info, data: []u8, h: ^Header, bodies: []Collision_Body) -> []Collision_Constraint {
	if len(bodies) < 2 {return nil}
	out := make([dynamic]Collision_Constraint, 0, 2)
	for i in 0 ..< int(h.num_blocks) {
		t := block_type(h, i)
		limited := t == "bhkLimitedHingeConstraint"
		if !limited && t != "bhkHingeConstraint" {continue}
		b := block_data(h, data, i)
		if len(b) < 144 {continue}
		r := Reader{data = b, ok = true}
		if int(read_u32(&r)) != 2 {continue} // only the standard 2-entity constraint
		ea := int(read_i32(&r))
		eb := int(read_i32(&r))
		_ = read_u32(&r) // priority
		ba := body_index_of(bodies, ea)
		bb := body_index_of(bodies, eb)
		if ba < 0 || bb < 0 {continue}
		r.pos = 16
		axle := read_vec4(&r)
		perp := read_vec4(&r)
		_ = read_vec4(&r) // perpA2 — Jolt's hinge needs one perpendicular; perpA1 suffices
		pivot := read_vec4(&r)
		if !r.ok {continue}
		mn, mx, fric: f32
		if limited && len(b) >= 156 {
			r.pos = 144
			mn = read_f32(&r)
			mx = read_f32(&r)
			fric = read_f32(&r)
		}
		frame := bodies[ba].frame
		append(&out, Collision_Constraint {
			limited = limited, body_a = ba, body_b = bb,
			pivot = mat4_point(frame, {pivot.x * HAVOK_SCALE, pivot.y * HAVOK_SCALE, pivot.z * HAVOK_SCALE}),
			axis = normalize3(mat4_dir(frame, {axle.x, axle.y, axle.z})),
			perp = normalize3(mat4_dir(frame, {perp.x, perp.y, perp.z})),
			min_angle = mn, max_angle = mx, max_friction = fric,
		})
	}
	if len(out) == 0 {delete(out);return nil}
	return out[:]
}

// body_index_of maps a bhkRigidBody block ref (how a constraint names its entities) to the index of
// the Collision_Body we registered for it, or -1 if that block wasn't decoded as a body.
@(private = "file")
body_index_of :: proc(bodies: []Collision_Body, block_ref: int) -> int {
	for b, i in bodies {
		if b.block_ref == block_ref {return i}
	}
	return -1
}

@(private = "file")
mat4_point :: proc(m: matrix[4, 4]f32, p: [3]f32) -> [3]f32 {
	v := m * [4]f32{p.x, p.y, p.z, 1}
	return {v.x, v.y, v.z}
}

@(private = "file")
mat4_dir :: proc(m: matrix[4, 4]f32, d: [3]f32) -> [3]f32 {
	v := m * [4]f32{d.x, d.y, d.z, 0}
	return {v.x, v.y, v.z}
}

@(private = "file")
normalize3 :: proc(v: [3]f32) -> [3]f32 {
	l := math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	if l < 1e-8 {return {0, 0, 1}}
	return v / l
}

// --- internals ---

@(private = "file")
Mat4_Id :: matrix[4, 4]f32{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}

@(private = "file")
walk_collision :: proc(
	infos: []Block_Info,
	data: []u8,
	h: ^Header,
	visited: []bool,
	idx: int,
	parent_world: matrix[4, 4]f32,
	out: ^[dynamic]Collision_Shape,
	bodies: ^[dynamic]Collision_Body,
	unhandled: ^int,
	is_root := false,
) {
	if idx < 0 || idx >= len(infos) || visited[idx] {
		return
	}
	visited[idx] = true
	info := infos[idx]
	if !info.is_node && !info.is_shape {
		return
	}
	// Mirror walk_node: the ROOT node's own transform is superseded by the REFR
	// placement, so start its subtree at the parent frame (keeps collision aligned
	// with the render geometry, which does the same).
	world := parent_world if is_root else parent_world * transform_to_mat4(info.transform)

	if info.collision_ref >= 0 {
		parse_collision_object(data, h, int(info.collision_ref), world, out, bodies, unhandled)
	}
	for c in info.children {
		walk_collision(infos, data, h, visited, int(c), world, out, bodies, unhandled)
	}
}

// parse_collision_object: bhkCollisionObject → bhkRigidBody[T] → shape tree.
@(private = "file")
parse_collision_object :: proc(
	data: []u8,
	h: ^Header,
	co_ref: int,
	node_world: matrix[4, 4]f32,
	out: ^[dynamic]Collision_Shape,
	bodies: ^[dynamic]Collision_Body,
	unhandled: ^int,
) {
	t := block_type(h, co_ref)
	// Only the plain rigid-body collision objects carry static world shapes here.
	if t != "bhkCollisionObject" && t != "bhkSPCollisionObject" && t != "bhkPCollisionObject" {
		return
	}
	// bhkCollisionObject = NiCollisionObject(Target Ptr) + Flags(bhkCOFlags u16) + Body(Ref).
	r := Reader{data = block_data(h, data, co_ref), ok = true}
	_ = read_i32(&r) // Target (back-ptr to the node)
	_ = read_u16(&r) // Flags (bhkCOFlags)
	body_ref := int(read_i32(&r))
	if !r.ok || body_ref < 0 || body_ref >= int(h.num_blocks) {
		return
	}

	bt := block_type(h, body_ref)
	if bt != "bhkRigidBody" && bt != "bhkRigidBodyT" {
		return
	}
	bdata := block_data(h, data, body_ref)
	body := Reader{data = bdata, ok = true}
	shape_ref := int(read_i32(&body)) // bhkWorldObject.Shape is the first field

	// Only bhkRigidBodyT applies a body translation/rotation to its shape; a plain
	// bhkRigidBody ignores them (the fields exist but are dead). Offsets within the
	// body block (nifly layout): Translation @52 (Vector4), Rotation @68 (quat xyzw).
	body_xform := Mat4_Id
	if bt == "bhkRigidBodyT" {
		body.pos = 52
		trans := read_vec4(&body)
		rot := read_vec4(&body) // quaternion x,y,z,w
		if body.ok {
			body_xform = trs_from_havok(trans, rot)
		}
	}

	// Movable-vs-static classification (Phase 3b dynamic clutter). Read the body's Havok layer,
	// mass and motion system from fixed Skyrim-LE offsets in the bhkRigidBody block (see
	// rigidbody_props), and decide whether this body is free-moving clutter.
	layer, mass, motion, pok := rigidbody_props(bdata)
	mov := pok && is_movable(layer, motion, mass)
	if Debug_Collision {
		log_rigidbody(h, body_ref, layer, mass, motion, mov)
	}

	world := node_world * body_xform

	// Register this rigid body so its shapes can point back to it (Phase A multi-body: the world
	// layer builds ONE Jolt body per Collision_Body instead of merging the instance), constraints
	// can resolve it by block ref, and a hinge pivot can be placed in its frame (Phase B).
	bi := len(bodies)
	append(bodies, Collision_Body {
		movable = mov, mass = mass, layer = layer, motion = motion, block_ref = body_ref, frame = world,
	})

	start := len(out)
	if shape_ref >= 0 && shape_ref < int(h.num_blocks) {
		walk_shape(data, h, shape_ref, world, out, unhandled)
	}
	// Stamp the body's classification + index onto every leaf shape it emitted (a body shares one
	// motion/mass across its whole shape tree). Most clutter is a single convex shape per body.
	for i in start ..< len(out) {
		out[i].movable = mov
		out[i].mass = mass
		out[i].layer = layer
		out[i].body = bi
	}
}

// SkyrimLayer values (niftools nif.xml SkyrimLayer enum) — the Havok collision layer stored in the
// rigid body's filter (first byte). CLUTTER/WEAPON/PROPS are the free-moving physics layers (movable
// classification); the rest below are named for the player-solidity decision (layer_is_solid).
SKYL_CLUTTER :: u8(4)
SKYL_WEAPON :: u8(5)
SKYL_PROJECTILE :: u8(6)
SKYL_SPELL :: u8(7)
SKYL_BIPED :: u8(8)
SKYL_PROPS :: u8(10)
SKYL_WATER :: u8(11)
SKYL_TRIGGER :: u8(12)
SKYL_TRAP :: u8(14)
SKYL_NONCOLLIDABLE :: u8(15)

// layer_is_solid reports whether a STATIC collision shape on this SkyrimLayer should physically block
// the player/world (i.e. become a Jolt body). Some meshes carry collision on gameplay-only layers —
// weapons, projectiles, spells, biped/actor, trigger volumes, traps, or explicit non-collidable —
// which exist for aiming / line-of-sight / trigger detection, NOT to wall the player. Those must be
// skipped or a decorative/trigger mesh silently becomes an invisible wall. Everything else (STATIC,
// ANIM_STATIC, CLUTTER, TREES, PROPS, TERRAIN, GROUND, STAIRS, and any UNLISTED layer) stays solid —
// conservative: an unknown layer keeps its collision rather than vanishing a real wall.
//
// TUNE FROM REAL DATA: `./tools/nifdump --collision <mesh.nif>` prints each rigid body's layer. If a
// decorative mesh (e.g. thistle) still blocks the player, confirm its layer here and add it below only
// if it's genuinely a non-solid layer; if it reports SKYL_STATIC, the fix is elsewhere (record type /
// size), not this table.
layer_is_solid :: proc(layer: u8) -> bool {
	switch layer {
	case SKYL_WEAPON, SKYL_PROJECTILE, SKYL_SPELL, SKYL_BIPED, SKYL_TRIGGER, SKYL_TRAP,
	     SKYL_NONCOLLIDABLE, SKYL_WATER:
		return false
	}
	return true
}

// MotionSystem values (niftools nif.xml MotionSystem enum). FIXED/KEYFRAMED never free-move;
// the inertia types are the dynamic ones.
MO_INVALID :: u8(0)
MO_KEYFRAMED :: u8(6)
MO_FIXED :: u8(7)

// is_movable classifies a bhkRigidBody as free-moving clutter (→ a Jolt dynamic body) vs static
// world geometry. Requires a positive mass AND a dynamic motion system (not FIXED/KEYFRAMED/
// invalid) AND a movable Havok layer — all three so a mis-read offset can't turn architecture
// dynamic. This is deliberately conservative for 3b (cups/plates/bottles); broaden as needed.
@(private = "file")
is_movable :: proc(layer: u8, motion: u8, mass: f32) -> bool {
	if mass <= 0 {return false}
	if motion == MO_FIXED || motion == MO_KEYFRAMED || motion == MO_INVALID {return false}
	return layer == SKYL_CLUTTER || layer == SKYL_WEAPON || layer == SKYL_PROPS
}

// rigidbody_props reads the Havok layer, mass and motion system out of a bhkRigidBody block at
// fixed Skyrim-LE (BS user-version 83) offsets. Layout (nif.xml, validated against real meshes
// via nifdump --collision): Havok Filter @4 (layer = first byte); Mass @180 (after Shape, the
// filters/cinfo, translation+rotation, lin/ang velocity, the 48-byte inertia tensor and centre);
// Motion System @224 (after mass + the Skyrim float run: linDamp, angDamp, time, gravity,
// friction, rollingFriction, restitution, maxLinVel, maxAngVel, penetrationDepth). ok=false if
// the block is too short for these reads.
@(private = "file")
rigidbody_props :: proc(b: []u8) -> (layer: u8, mass: f32, motion: u8, ok: bool) {
	if len(b) < 225 {return 0, 0, 0, false}
	r := Reader{data = b, ok = true}
	r.pos = 4
	layer = read_u8(&r)
	r.pos = 180
	mass = read_f32(&r)
	r.pos = 224
	motion = read_u8(&r)
	return layer, mass, motion, r.ok
}

// log_rigidbody prints one body's classification inputs (dev only — Debug_Collision; nifdump
// uses it to validate the fixed offsets against real meshes). Never fires in the engine.
@(private = "file")
log_rigidbody :: proc(h: ^Header, body_ref: int, layer: u8, mass: f32, motion: u8, mov: bool) {
	fmt.printfln(
		"    rb[%d] %s: layer=%d mass=%.3f motion=%d -> movable=%v",
		body_ref, block_type(h, body_ref), layer, mass, motion, mov,
	)
}

// walk_shape dispatches one bhkShape block: collection shapes recurse, leaf shapes
// emit. `xform` is the accumulated NIF-root placement for this shape.
@(private = "file")
walk_shape :: proc(
	data: []u8,
	h: ^Header,
	idx: int,
	xform: matrix[4, 4]f32,
	out: ^[dynamic]Collision_Shape,
	unhandled: ^int,
) {
	if idx < 0 || idx >= int(h.num_blocks) {
		return
	}
	b := block_data(h, data, idx)
	switch block_type(h, idx) {
	case "bhkMoppBvTreeShape":
		// MOPP is just a BV-tree acceleration wrapper; the real geometry is its child.
		r := Reader{data = b, ok = true}
		child := int(read_i32(&r)) // shapeRef is the first field
		if r.ok {walk_shape(data, h, child, xform, out, unhandled)}

	case "bhkListShape":
		// numSubShapes (u32) then that many shape refs.
		r := Reader{data = b, ok = true}
		n := int(read_u32(&r))
		if !r.ok || n < 0 || n > MAX_LIST {return}
		refs := make([]i32, n, context.temp_allocator)
		for i in 0 ..< n {refs[i] = read_i32(&r)}
		if !r.ok {return}
		for ref in refs {walk_shape(data, h, int(ref), xform, out, unhandled)}

	case "bhkCompressedMeshShape":
		// dataRef is the last field (@52); the data block holds big verts + chunks.
		r := Reader{data = b, ok = true}
		r.pos = 52
		data_ref := int(read_i32(&r))
		if r.ok && data_ref >= 0 && data_ref < int(h.num_blocks) &&
		   block_type(h, data_ref) == "bhkCompressedMeshShapeData" {
			parse_compressed_mesh(block_data(h, data, data_ref), xform, out)
		}

	case "bhkNiTriStripsShape":
		// Legacy strip collision (Windhelm/Solitude architecture, some clutter): wraps
		// NiTriStripsData blocks. Layout: material@0, radius@4, unused@8 (20), growBy@28,
		// Scale@32 (Vector4), numStripsData@48, refs@52. NifSkope draws these verts at a
		// net ×1 (a 1/7 cancels the rigid body's ×7) → they are NIF-native units, NOT
		// Havok-scaled like the other shapes.
		r := Reader{data = b, ok = true}
		r.pos = 48
		n := int(read_u32(&r))
		if !r.ok || n < 0 || n > MAX_LIST {return}
		refs := make([]i32, n, context.temp_allocator)
		for i in 0 ..< n {refs[i] = read_i32(&r)}
		if !r.ok {return}
		for ref in refs {
			ri := int(ref)
			if ri < 0 || ri >= int(h.num_blocks) || block_type(h, ri) != "NiTriStripsData" {
				continue
			}
			v, ix, gok := parse_tri_strips_geometry(block_data(h, data, ri))
			if gok && len(v) > 0 && len(ix) > 0 {
				append(out, Collision_Shape{kind = .Mesh, transform = xform, vertices = v, indices = ix})
			} else {
				delete(v);delete(ix)
			}
		}

	case "bhkConvexTransformShape", "bhkTransformShape":
		// Wraps a child shape in a Matrix44. Layout: shapeRef@0, material@4, radius@8,
		// padding@12 (8 bytes), Transform(Matrix44 @20). Recurse with the transform
		// composed onto the placement (translation in Havok units → ×HAVOK_SCALE).
		r := Reader{data = b, ok = true}
		child := int(read_i32(&r))
		r.pos = 20
		m := read_matrix44(&r)
		if r.ok {walk_shape(data, h, child, xform * m, out, unhandled)}

	case "bhkBoxShape":
		// [Material 4][Radius 4][padding 8][Dimensions vec3 @16][unused float].
		r := Reader{data = b, ok = true}
		r.pos = 16
		dims := read_vec3(&r)
		if r.ok {
			append(out, Collision_Shape{kind = .Box, transform = xform, half_extents = dims * HAVOK_SCALE})
		}

	case "bhkSphereShape":
		// [Material 4][Radius 4].
		r := Reader{data = b, ok = true}
		r.pos = 4
		rad := read_f32(&r)
		if r.ok {
			append(out, Collision_Shape{kind = .Sphere, transform = xform, radius = rad * HAVOK_SCALE})
		}

	case "bhkCapsuleShape":
		// [Material 4][Radius 4][padding 8][point1 @16][radius1 @28][point2 @32][radius2 @44].
		r := Reader{data = b, ok = true}
		r.pos = 16
		p1 := read_vec3(&r)
		r1 := read_f32(&r)
		p2 := read_vec3(&r)
		r2 := read_f32(&r)
		if r.ok {
			append(out, Collision_Shape {
				kind = .Capsule, transform = xform,
				point_a = p1 * HAVOK_SCALE, radius = r1 * HAVOK_SCALE,
				point_b = p2 * HAVOK_SCALE, radius_b = r2 * HAVOK_SCALE,
			})
		}

	case "bhkConvexVerticesShape":
		// [Material 4][Radius 4][vertsProp 12][normalsProp 12][numVerts @32][verts Vector4…].
		// The Radius is the Havok CONVEX MARGIN: flat clutter (ingots, plates, coins) is authored as a
		// FLAT vertex hull (verts coplanar, ~zero thickness) and this margin inflates it into a rounded
		// 3D slab — the shape's real thickness lives here, NOT in the verts. We must carry it or the hull
		// is a degenerate flat quad (falls through / no volume). Stored in `radius` (Skyrim units).
		rr := Reader{data = b, ok = true}
		rr.pos = 4
		margin := read_f32(&rr) * HAVOK_SCALE
		r := Reader{data = b, ok = true}
		r.pos = 32
		n := int(read_u32(&r))
		if !r.ok || n < 0 || n > MAX_LIST {return}
		verts := make([][3]f32, n)
		for i in 0 ..< n {
			v := read_vec4(&r)
			verts[i] = {v.x * HAVOK_SCALE, v.y * HAVOK_SCALE, v.z * HAVOK_SCALE}
		}
		if r.ok {
			append(out, Collision_Shape{kind = .Convex, transform = xform, vertices = verts, radius = margin})
		} else {
			delete(verts)
		}

	case "":
	// out of range / unknown — ignore

	case:
		// A bhk* shape type we don't decode yet (transform shapes, cylinder, tri-strips…).
		// Tally so the sweep tells us how common it is before investing.
		unhandled^ += 1
		if Debug_Collision {
			t := block_type(h, idx)
			if Unhandled_Types == nil {Unhandled_Types = make(map[string]int)}
			// Clone the key on first insert — block_type views per-NIF header memory
			// that's freed each file, so stored keys must own their bytes (dev leak ok).
			if _, ok := Unhandled_Types[t]; ok {
				Unhandled_Types[t] += 1
			} else {
				Unhandled_Types[strings.clone(t)] = 1
			}
		}
	}
}

// Debug_Collision (dev only — nifdump sets it): when true, walk_shape tallies the
// names of bhk* shape blocks it doesn't decode into Unhandled_Types, so the sweep can
// report exactly what's left to implement. Off (and zero-cost) in the engine. NOT
// thread-safe — the streamer must never set it.
Debug_Collision := false
Unhandled_Types: map[string]int

// parse_compressed_mesh decodes a bhkCompressedMeshShapeData block into ONE triangle
// mesh: big verts (full-precision) followed by every chunk's decompressed verts, with
// big-tris + per-chunk strips/lists remapped into one combined index list.
// (hole havok-materials :tags (physics assets) :sev gap) collision shapes drop their Havok materials (the shape's own, a compressed mesh's chunk materials), so no hit knows its surface: stone, wood, dirt, flesh. Impacts and footsteps pick their sounds by it (IPDS keys MATT, which maps Havok material ids).
@(private = "file")
parse_compressed_mesh :: proc(b: []u8, xform: matrix[4, 4]f32, out: ^[dynamic]Collision_Shape) {
	r := Reader{data = b, ok = true}
	r.pos = 4 * 4 // bitsPerIndex, bitsPerWIndex, maskWIndex, maskIndex
	_ = read_f32(&r) // error
	_ = read_vec4(&r) // aabb min
	_ = read_vec4(&r) // aabb max
	_ = read_u8(&r) // welding type
	_ = read_u8(&r) // material type
	skip_nivector(&r, 4) // materials 32
	skip_nivector(&r, 4) // materials 16
	skip_nivector(&r, 4) // materials 8
	skip_nivector(&r, 8) // chunk materials (bhkMeshMaterial: u32 + HavokFilter)
	_ = read_u32(&r) // num named materials (named-material strings array is empty in Skyrim)

	// Chunk transforms (bhkCMSDTransform: Vector4 translation + quat). Needed to place
	// each chunk's verts (referenced by the chunk's Transform Index).
	nt := int(read_u32(&r))
	if !r.ok || nt < 0 || nt > MAX_LIST {return}
	trans := make([][3]f32, nt, context.temp_allocator)
	rots := make([][4]f32, nt, context.temp_allocator)
	for i in 0 ..< nt {
		t := read_vec4(&r)
		q := read_vec4(&r)
		trans[i] = {t.x, t.y, t.z}
		rots[i] = q
	}

	// Big verts (full-precision Vector4, Havok units) + big tris (index into big verts).
	nbv := int(read_u32(&r))
	if !r.ok || nbv < 0 || nbv > MAX_LIST {return}
	verts := make([dynamic][3]f32, 0, nbv + 64)
	idx := make([dynamic]u32, 0, 128)
	for i in 0 ..< nbv {
		v := read_vec4(&r)
		append(&verts, [3]f32{v.x * HAVOK_SCALE, v.y * HAVOK_SCALE, v.z * HAVOK_SCALE})
	}
	nbt := int(read_u32(&r))
	if !r.ok || nbt < 0 || nbt > MAX_LIST {
		delete(verts);delete(idx);return
	}
	for i in 0 ..< nbt {
		a := u32(read_u16(&r))
		bb := u32(read_u16(&r))
		c := u32(read_u16(&r))
		_ = read_u32(&r) // material
		_ = read_u16(&r) // welding info
		if u64(a) < u64(nbv) && u64(bb) < u64(nbv) && u64(c) < u64(nbv) {
			append(&idx, a, bb, c)
		}
	}

	// Chunks: each is a packed sub-mesh of u16 vertex offsets relative to its origin +
	// transform, with its own strips and triangle list. Decompress verts (NifSkope:
	// `(chunkOrigin + transform.trans + u16/1000) × scale`, then transform.rotation),
	// then append to the combined mesh and remap indices by the running vertex base.
	nc := int(read_u32(&r))
	if !r.ok || nc < 0 || nc > MAX_LIST {
		delete(verts);delete(idx);return
	}
	for _ in 0 ..< nc {
		origin := read_vec4(&r)
		_ = read_u32(&r) // material index
		_ = read_u16(&r) // reference
		ti := int(read_u16(&r)) // transform index
		nv := int(read_u32(&r)) // number of u16 offset components (3 per vertex)
		if !r.ok || nv < 0 || nv > MAX_LIST * 3 {break}
		offs := make([]u16, nv, context.temp_allocator)
		for i in 0 ..< nv {offs[i] = read_u16(&r)}
		ni := int(read_u32(&r))
		if !r.ok || ni < 0 || ni > MAX_LIST {break}
		cidx := make([]u16, ni, context.temp_allocator)
		for i in 0 ..< ni {cidx[i] = read_u16(&r)}
		ns := int(read_u32(&r))
		if !r.ok || ns < 0 || ns > MAX_LIST {break}
		strips := make([]u16, ns, context.temp_allocator)
		for i in 0 ..< ns {strips[i] = read_u16(&r)}
		skip_nivector(&r, 2) // welding info (u16 per entry)
		if !r.ok {break}

		// chunk transform (identity for the common transform index 0)
		ct := [3]f32{0, 0, 0}
		cr := [4]f32{0, 0, 0, 1}
		if ti >= 0 && ti < nt {ct = trans[ti];cr = rots[ti]}
		crm := quat_to_mat3(cr)

		base := u32(len(verts))
		chunk_nv := nv / 3
		for n in 0 ..< chunk_nv {
			lv := [3]f32 {
				(origin.x + ct.x + f32(offs[3 * n + 0]) * CHUNK_QUANT) * HAVOK_SCALE,
				(origin.y + ct.y + f32(offs[3 * n + 1]) * CHUNK_QUANT) * HAVOK_SCALE,
				(origin.z + ct.z + f32(offs[3 * n + 2]) * CHUNK_QUANT) * HAVOK_SCALE,
			}
			append(&verts, mat3_mul_vec3(crm, lv))
		}

		// strips → triangles, then the trailing flat triangle list. Winding is
		// consistently wound outward via ALTERNATING winding (odd triangles flip their first
		// two verts) — the CE winding fix that lets collision go single-sided. The trailing
		// flat list below is already independent tris with authored winding, so no flip.
		off := 0
		for s in 0 ..< ns {
			sl := int(strips[s])
			for k in 0 ..< max(0, sl - 2) {
				push_tri(&idx, base, cidx, off + k, chunk_nv, flip = k % 2 == 1)
			}
			off += sl
		}
		f := off
		for f + 2 < ni {
			push_tri(&idx, base, cidx, f, chunk_nv)
			f += 3
		}
	}

	if len(verts) == 0 || len(idx) == 0 {
		delete(verts);delete(idx);return
	}
	append(out, Collision_Shape {
		kind = .Mesh, transform = xform,
		vertices = verts[:], indices = idx[:],
	})
}

// push_tri appends one triangle (cidx[i0..i0+2], remapped by `base`) if all three
// chunk-local indices are in range. `flip` swaps the first two verts (odd strip triangles)
// to keep the destriped list consistently wound.
@(private = "file")
push_tri :: proc(idx: ^[dynamic]u32, base: u32, cidx: []u16, i0: int, chunk_nv: int, flip := false) {
	if i0 < 0 || i0 + 2 >= len(cidx) {return}
	a, b, c := int(cidx[i0]), int(cidx[i0 + 1]), int(cidx[i0 + 2])
	if flip {a, b = b, a}
	if a < chunk_nv && b < chunk_nv && c < chunk_nv {
		append(idx, base + u32(a), base + u32(b), base + u32(c))
	}
}

// --- small readers / math (package nif reuses the @(private) Reader helpers) ---

@(private = "file")
read_vec4 :: proc(r: ^Reader) -> [4]f32 {
	x := read_f32(r)
	y := read_f32(r)
	z := read_f32(r)
	w := read_f32(r)
	return {x, y, z, w}
}

// parse_tri_strips_geometry decodes a NiTriStripsData block into collision-ready
// verts + a flat triangle list (3 indices/tri). NiTriStripsData shares NiGeometryData's
// vertex prefix with NiTriShapeData (see parse_tri_shape_data) and diverges only at the
// tail: strips instead of a triangle list. We keep only positions + connectivity
// (collision needs no normals/uvs) and destripe, dropping degenerate (stitch) tris.
@(private = "file")
parse_tri_strips_geometry :: proc(
	b: []u8,
	allocator := context.allocator,
) -> (verts: [][3]f32, idx: []u32, ok: bool) {
	context.allocator = allocator
	r := Reader{data = b, ok = true}

	_ = read_i32(&r) // Group ID
	num_verts := int(read_u16(&r))
	if !r.ok || num_verts < 0 || num_verts > MAX_LIST {return nil, nil, false}
	_ = read_u8(&r) // Keep Flags
	_ = read_u8(&r) // Compress Flags
	has_vertices := read_u8(&r) != 0
	if has_vertices {
		verts = make([][3]f32, num_verts)
		for i in 0 ..< num_verts {verts[i] = read_vec3(&r)}
	}
	bsvf := read_u16(&r)
	num_uv := int(bsvf & BSVF_NUM_UV_MASK)
	has_tangents := bsvf & BSVF_HAS_TANGENTS != 0
	_ = read_u32(&r) // reserved
	has_normals := read_u8(&r) != 0
	if has_normals {
		for _ in 0 ..< num_verts {_ = read_vec3(&r)} // normals
		if has_tangents {
			for _ in 0 ..< num_verts {_ = read_vec3(&r)} // tangents
			for _ in 0 ..< num_verts {_ = read_vec3(&r)} // bitangents
		}
	}
	_ = read_vec3(&r) // center
	_ = read_f32(&r) // radius
	has_colors := read_u8(&r) != 0
	if has_colors {
		for _ in 0 ..< num_verts * 4 {_ = read_u32(&r)}
	}
	for _ in 0 ..< num_uv * num_verts {_ = read_vec2(&r)}
	_ = read_u16(&r) // consistency flags
	_ = read_i32(&r) // additional data ref
	_ = read_u16(&r) // NiTriBasedGeomData: Num Triangles

	// --- NiTriStripsData tail ---
	num_strips := int(read_u16(&r))
	if !r.ok || num_strips < 0 || num_strips > MAX_LIST {delete(verts);return nil, nil, false}
	lens := make([]int, num_strips, context.temp_allocator)
	for i in 0 ..< num_strips {lens[i] = int(read_u16(&r))}
	has_points := read_u8(&r) != 0
	if !r.ok || !has_points {delete(verts);return nil, nil, false}

	out := make([dynamic]u32, 0, 256)
	for s in 0 ..< num_strips {
		sl := lens[s]
		if sl < 0 || sl > MAX_LIST {delete(verts);delete(out[:]);return nil, nil, false}
		strip := make([]u16, sl, context.temp_allocator)
		for i in 0 ..< sl {strip[i] = read_u16(&r)}
		if !r.ok {delete(verts);delete(out[:]);return nil, nil, false}
		// Destripe: (a,b,c),(b,c,d),… Winding is irrelevant for two-sided collision,
		// keeping ALTERNATING winding (odd triangles flip their first two verts) so the
			// destriped list is consistently wound outward — the CE winding fix that lets
			// collision go single-sided. Drop degenerate (stitch) triangles with a repeated index.
		for i in 0 ..< max(0, sl - 2) {
			a, bb, c := strip[i], strip[i + 1], strip[i + 2]
			if a == bb || bb == c || a == c {continue}
			if i % 2 == 1 {a, bb = bb, a} // odd strip tri: swap first two → consistent winding
			if int(a) < num_verts && int(bb) < num_verts && int(c) < num_verts {
				append(&out, u32(a), u32(bb), u32(c))
			}
		}
	}
	return verts, out[:], true
}

// read_matrix44 reads a Skyrim Matrix44 (16 f32, COLUMN-major: m11,m21,m31,m41,
// m12,…) into a row-major matrix[4,4], with the translation column (Havok units)
// scaled to Skyrim units. Used by the transform shapes.
@(private = "file")
read_matrix44 :: proc(r: ^Reader) -> matrix[4, 4]f32 {
	f: [16]f32
	for i in 0 ..< 16 {f[i] = read_f32(r)}
	// column-major in file → m[row,col] = f[col*4 + row]; translation = column 3.
	return matrix[4, 4]f32{
		f[0], f[4], f[8], f[12] * HAVOK_SCALE,
		f[1], f[5], f[9], f[13] * HAVOK_SCALE,
		f[2], f[6], f[10], f[14] * HAVOK_SCALE,
		0, 0, 0, 1,
	}
}

// skip_nivector advances past a length-prefixed array (u32 count + count×elem bytes).
@(private = "file")
skip_nivector :: proc(r: ^Reader, elem: int) {
	n := int(read_u32(r))
	if n < 0 || n > MAX_LIST * 16 {r.ok = false;return}
	if have(r, n * elem) {r.pos += n * elem}
}

// trs_from_havok builds a body placement matrix from a Havok translation (×scale)
// and an x,y,z,w quaternion (rotation, unitless).
@(private = "file")
trs_from_havok :: proc(t: [4]f32, q: [4]f32) -> matrix[4, 4]f32 {
	m := quat_to_mat3(q)
	return matrix[4, 4]f32{
		m[0, 0], m[0, 1], m[0, 2], t.x * HAVOK_SCALE,
		m[1, 0], m[1, 1], m[1, 2], t.y * HAVOK_SCALE,
		m[2, 0], m[2, 1], m[2, 2], t.z * HAVOK_SCALE,
		0, 0, 0, 1,
	}
}

// quat_to_mat3 converts an x,y,z,w quaternion to a row-major rotation matrix. A zero
// quaternion (absent transform) degrades to identity.
@(private = "file")
quat_to_mat3 :: proc(q: [4]f32) -> matrix[3, 3]f32 {
	x, y, z, w := q[0], q[1], q[2], q[3]
	n := x * x + y * y + z * z + w * w
	if n < 1e-12 {
		return matrix[3, 3]f32{1, 0, 0, 0, 1, 0, 0, 0, 1}
	}
	s := 2.0 / n
	xs, ys, zs := x * s, y * s, z * s
	wx, wy, wz := w * xs, w * ys, w * zs
	xx, xy, xz := x * xs, x * ys, x * zs
	yy, yz, zz := y * ys, y * zs, z * zs
	return matrix[3, 3]f32{
		1 - (yy + zz), xy - wz, xz + wy,
		xy + wz, 1 - (xx + zz), yz - wx,
		xz - wy, yz + wx, 1 - (xx + yy),
	}
}

@(private = "file")
mat3_mul_vec3 :: proc(m: matrix[3, 3]f32, v: [3]f32) -> [3]f32 {
	return {
		m[0, 0] * v.x + m[0, 1] * v.y + m[0, 2] * v.z,
		m[1, 0] * v.x + m[1, 1] * v.y + m[1, 2] * v.z,
		m[2, 0] * v.x + m[2, 1] * v.y + m[2, 2] * v.z,
	}
}
