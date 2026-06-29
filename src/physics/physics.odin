package physics

// Physics (ROADMAP §2e): a thin Jolt wrapper via the JoltC FFI bindings. This package
// is the ONLY importer of vendor/joltc-odin — the render-only-rule analog: the rest of
// the engine talks to this engine-neutral API (worlds, bodies, a future character
// controller) and never touches Jolt handles. Bodies are built from NIF bhk* collision
// shapes (see src/formats/nif/collision.odin) — reusing Havok's shape DATA, not its
// runtime.
//
// PRECISION: the vendored bindings are currently SINGLE precision (joltc.RVec3 == Vec3
// == [3]f32). DOUBLE precision (the decided target for Tamriel-scale worlds) is the
// planned follow-up — rebuild joltc with JOLT_DOUBLE=ON + regenerate bindings. All
// position handling is funnelled through to_rvec/from_rvec so that switch is contained.

import "core:math/linalg"

import jolt "../../vendor/joltc-odin"

// IDENTITY_QUAT is the no-rotation quaternion (Jolt Quat == Odin quaternion128).
IDENTITY_QUAT :: jolt.Quat(quaternion(w = 1, x = 0, y = 0, z = 0))

// GRAVITY is the world's gravity vector. Skyrim is Z-UP and collision data is in Skyrim
// units (≈69.99/m, the Havok→Skyrim scale), so real gravity (9.81 m/s²) becomes
// 9.81 × 69.99 ≈ 686.6 units/s² along −Z — not Jolt's metric −Y default.
GRAVITY :: [3]f32{0, 0, -9.81 * 69.99124}

// Two object layers: static world geometry (never moves) and moving (dynamic bodies +
// the character). The broadphase mirrors them. Collision is enabled moving↔moving and
// moving↔static (static↔static never collides — neither moves).
LAYER_STATIC :: jolt.ObjectLayer(0)
LAYER_MOVING :: jolt.ObjectLayer(1)

@(private) NUM_OBJECT_LAYERS :: 2
@(private) BP_STATIC :: jolt.BroadPhaseLayer(0)
@(private) BP_MOVING :: jolt.BroadPhaseLayer(1)
@(private) NUM_BP_LAYERS :: 2

// Body is an opaque handle into a World (Jolt's BodyID).
Body :: jolt.BodyID

// World owns a Jolt physics system + its job pool and the layer-filter tables the system
// references (the tables must outlive the system).
World :: struct {
	system:    ^jolt.PhysicsSystem,
	bodies:    ^jolt.BodyInterface, // borrowed from system (don't free)
	jobs:      ^jolt.JobSystem,
	bp_iface:  ^jolt.BroadPhaseLayerInterface,
	obj_pair:  ^jolt.ObjectLayerPairFilter,
	obj_vs_bp: ^jolt.ObjectVsBroadPhaseLayerFilter,
}

@(private) g_inited := false

// init brings up Jolt's global factory/allocator (once per process). Idempotent; safe to
// call before each world_create. Returns false if Jolt failed to initialize.
init :: proc() -> bool {
	if !g_inited {g_inited = jolt.Init()}
	return g_inited
}

// shutdown tears down Jolt's globals. Call once at process exit, after all worlds are
// destroyed.
shutdown :: proc() {
	if g_inited {
		jolt.Shutdown()
		g_inited = false
	}
}

// world_create builds a physics world (job pool + layer filters + system). Call init()
// first (world_create calls it defensively). Free with world_destroy.
world_create :: proc(max_bodies: u32 = 65536) -> (w: World, ok: bool) {
	if !init() {return {}, false}

	w.jobs = jolt.JobSystemThreadPool_Create(nil)

	w.obj_pair = jolt.ObjectLayerPairFilterTable_Create(NUM_OBJECT_LAYERS)
	jolt.ObjectLayerPairFilterTable_EnableCollision(w.obj_pair, LAYER_MOVING, LAYER_MOVING)
	jolt.ObjectLayerPairFilterTable_EnableCollision(w.obj_pair, LAYER_MOVING, LAYER_STATIC)

	w.bp_iface = jolt.BroadPhaseLayerInterfaceTable_Create(NUM_OBJECT_LAYERS, NUM_BP_LAYERS)
	jolt.BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(w.bp_iface, LAYER_STATIC, BP_STATIC)
	jolt.BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(w.bp_iface, LAYER_MOVING, BP_MOVING)

	w.obj_vs_bp = jolt.ObjectVsBroadPhaseLayerFilterTable_Create(
		w.bp_iface, NUM_BP_LAYERS, w.obj_pair, NUM_OBJECT_LAYERS,
	)

	settings := jolt.PhysicsSystemSettings {
		maxBodies                     = max_bodies,
		maxBodyPairs                  = 65536,
		maxContactConstraints         = 10240,
		broadPhaseLayerInterface      = w.bp_iface,
		objectLayerPairFilter         = w.obj_pair,
		objectVsBroadPhaseLayerFilter = w.obj_vs_bp,
	}
	w.system = jolt.PhysicsSystem_Create(&settings)
	if w.system == nil {return {}, false}
	w.bodies = jolt.PhysicsSystem_GetBodyInterface(w.system)
	g := jolt.Vec3(GRAVITY)
	jolt.PhysicsSystem_SetGravity(w.system, &g)
	return w, true
}

world_destroy :: proc(w: ^World) {
	if w.system != nil {jolt.PhysicsSystem_Destroy(w.system)}
	if w.jobs != nil {jolt.JobSystem_Destroy(w.jobs)}
	// The layer-filter tables are owned by Jolt's interface registry for the process's
	// lifetime; joltc exposes no destroy for them (one tiny set per world).
	w^ = {}
}

// step advances the simulation by `dt` seconds using `collision_steps` sub-steps
// (1 is fine for 60Hz). Jolt manages its own per-step temp allocator internally.
step :: proc(w: ^World, dt: f32, collision_steps := 1) {
	jolt.PhysicsSystem_Update(w.system, dt, i32(collision_steps), w.jobs)
}

// optimize_broadphase rebuilds the broadphase tree — call once after bulk-adding static
// bodies (e.g. a freshly loaded cell) before stepping.
optimize_broadphase :: proc(w: ^World) {
	jolt.PhysicsSystem_OptimizeBroadPhase(w.system)
}

// add_box / add_sphere create a primitive body at `pos` (centre). `is_dynamic` picks the
// moving layer + activates it; otherwise it's static world geometry. Returns its Body.
add_box :: proc(w: ^World, half_extents: [3]f32, pos: [3]f32, is_dynamic := false) -> Body {
	he := half_extents
	shape := jolt.BoxShape_Create(&he, jolt.DEFAULT_CONVEX_RADIUS)
	return make_body(w, cast(^jolt.Shape)shape, pos, IDENTITY_QUAT, is_dynamic)
}

add_sphere :: proc(w: ^World, radius: f32, pos: [3]f32, is_dynamic := false) -> Body {
	shape := jolt.SphereShape_Create(radius)
	return make_body(w, cast(^jolt.Shape)shape, pos, IDENTITY_QUAT, is_dynamic)
}

// --- static collision shapes (from NIF bhk* data; src/formats/nif/collision.odin) ---
//
// These take WORLD-space geometry: the caller (world layer) bakes the instance's REFR
// transform × the shape's NIF-root transform into the verts/points/centre before calling,
// so each body sits at the origin (mesh/hull) or a computed centre (sphere/capsule) with no
// matrix decomposition needed here. All are STATIC (the moving layer is for the character).

// add_static_mesh builds a triangle-mesh body from verts (relative to `origin`) + a flat
// index list (3/triangle), placed at `origin`. The MeshShape cook (AABB-tree build) happens
// here. Pass geometry in LOCAL coordinates with the cell/model `origin` in world space — Jolt
// shapes are single-precision, so baking large world coords into the verts breaks collision;
// the body position (double) carries the world placement. Returns 0 if degenerate.
// `two_sided` emits each triangle in BOTH windings — making collision winding-independent.
// Use it for source meshes whose winding can't be trusted (Havok bhk* collision destriped
// from triangle strips alternates winding, so single-sided lets every other triangle be
// passed through). Terrain (winding we control) can stay single-sided.
add_static_mesh :: proc(w: ^World, verts: [][3]f32, indices: []u32, origin: [3]f32 = {0, 0, 0}, two_sided := false) -> Body {
	if len(verts) == 0 || len(indices) < 3 {return 0}
	vs := make([]jolt.Vec3, len(verts), context.temp_allocator)
	for v, i in verts {vs[i] = {v.x, v.y, v.z}}
	nt := len(indices) / 3
	mul := 2 if two_sided else 1
	tris := make([]jolt.IndexedTriangle, nt * mul, context.temp_allocator)
	for i in 0 ..< nt {
		a, b, c := indices[i * 3], indices[i * 3 + 1], indices[i * 3 + 2]
		tris[i * mul] = {i1 = a, i2 = b, i3 = c}
		if two_sided {
			tris[i * mul + 1] = {i1 = a, i2 = c, i3 = b} // reversed winding
		}
	}
	settings := jolt.MeshShapeSettings_Create2(&vs[0], u32(len(vs)), &tris[0], u32(nt * mul))
	shape := jolt.MeshShapeSettings_CreateShape(settings)
	jolt.ShapeSettings_Destroy(cast(^jolt.ShapeSettings)settings)
	if shape == nil {return 0}
	return make_body(w, cast(^jolt.Shape)shape, origin, IDENTITY_QUAT, false)
}

// add_static_hull builds a convex-hull body from world-space points (QuickHull cook). Used
// for bhkConvexVerticesShape and boxes (passed as their 8 transformed corners — exact).
add_static_hull :: proc(w: ^World, points: [][3]f32) -> Body {
	if len(points) < 4 {return 0}
	ps := make([]jolt.Vec3, len(points), context.temp_allocator)
	for p, i in points {ps[i] = {p.x, p.y, p.z}}
	settings := jolt.ConvexHullShapeSettings_Create(&ps[0], u32(len(ps)), jolt.DEFAULT_CONVEX_RADIUS)
	shape := jolt.ConvexHullShapeSettings_CreateShape(settings)
	jolt.ShapeSettings_Destroy(cast(^jolt.ShapeSettings)settings)
	if shape == nil {return 0}
	return make_body(w, cast(^jolt.Shape)shape, {0, 0, 0}, IDENTITY_QUAT, false)
}

// add_dynamic_hull builds a DYNAMIC convex-hull body from world-space `points`, with the body
// frame placed at `origin` and the hull verts stored relative to it (Phase 3b movable clutter).
// `origin` is the instance's REFR placement position: verts stay small-magnitude (clutter is small
// and near its origin) so single precision holds even at far world coords, and — crucially — the
// renderer's follow math (world.instance_world = body_transform · translate(−origin) · world)
// assumes exactly this body frame, so origin MUST equal the inst.pos passed there. Mass is
// auto-derived from the hull volume (the NIF Havok mass only CLASSIFIES movable-ness — the unit
// systems differ and mass cancels for resting/free-falling clutter). Returns 0 if degenerate.
add_dynamic_hull :: proc(w: ^World, points: [][3]f32, origin: [3]f32) -> Body {
	if len(points) < 4 {return 0}
	ps := make([]jolt.Vec3, len(points), context.temp_allocator)
	for p, i in points {ps[i] = {p.x - origin.x, p.y - origin.y, p.z - origin.z}}
	settings := jolt.ConvexHullShapeSettings_Create(&ps[0], u32(len(ps)), jolt.DEFAULT_CONVEX_RADIUS)
	shape := jolt.ConvexHullShapeSettings_CreateShape(settings)
	jolt.ShapeSettings_Destroy(cast(^jolt.ShapeSettings)settings)
	if shape == nil {return 0}
	return make_body(w, cast(^jolt.Shape)shape, origin, IDENTITY_QUAT, true)
}

// kick wakes a body and sets its linear velocity outright (mass-independent, so the motion is
// always visible regardless of the hull's auto-computed mass). Used by the debug "shove" that
// scatters resting clutter to verify the dynamic-body + settle path.
kick :: proc(w: ^World, b: Body, vel: [3]f32) {
	jolt.BodyInterface_ActivateBody(w.bodies, b)
	v := vel
	jolt.BodyInterface_SetLinearVelocity(w.bodies, b, &v)
}

// add_static_sphere: a static sphere at a world centre (rotation-invariant; caller folds
// the instance scale into `radius`).
add_static_sphere :: proc(w: ^World, center: [3]f32, radius: f32) -> Body {
	if radius <= 0 {return 0}
	shape := jolt.SphereShape_Create(radius)
	return make_body(w, cast(^jolt.Shape)shape, center, IDENTITY_QUAT, false)
}

// add_static_capsule: a static capsule between two world endpoints. Jolt's CapsuleShape is
// Y-axis-aligned + centred, so we place it at the midpoint, length = |b-a|, rotated to align
// +Y with the endpoint axis.
add_static_capsule :: proc(w: ^World, a: [3]f32, b: [3]f32, radius: f32) -> Body {
	if radius <= 0 {return 0}
	axis := b - a
	half_h := linalg.length(axis) * 0.5
	if half_h <= 0 {return add_static_sphere(w, a, radius)} // degenerate → sphere
	shape := jolt.CapsuleShape_Create(half_h, radius)
	center := (a + b) * 0.5
	dir := axis / (half_h * 2)
	rot := jolt.Quat(linalg.quaternion_between_two_vector3_f32([3]f32{0, 1, 0}, dir))
	return make_body(w, cast(^jolt.Shape)shape, center, rot, false)
}

// make_body creates a body from a shape (the shape's creation ref is released afterward —
// the body holds its own ref, so remove_body frees the shape). Jolt shapes are ref-counted;
// without this the streaming churn would leak C++ shapes (invisible to the Odin [mem] report).
@(private)
make_body :: proc(w: ^World, shape: ^jolt.Shape, pos: [3]f32, rot: jolt.Quat, is_dynamic: bool) -> Body {
	p := to_rvec(pos)
	r := rot
	motion := jolt.MotionType.Dynamic if is_dynamic else jolt.MotionType.Static
	layer := jolt.ObjectLayer(LAYER_MOVING if is_dynamic else LAYER_STATIC)
	bcs := jolt.BodyCreationSettings_Create3(shape, &p, &r, motion, layer)
	// Dynamic bodies use continuous collision (LinearCast): at Skyrim-scale gravity a falling
	// body moves far per step and would tunnel through thin trimesh terrain / walls otherwise.
	if is_dynamic {
		jolt.BodyCreationSettings_SetMotionQuality(bcs, .LinearCast)
	}
	act := jolt.Activation.Activate if is_dynamic else jolt.Activation.DontActivate
	id := jolt.BodyInterface_CreateAndAddBody(w.bodies, bcs, act)
	jolt.BodyCreationSettings_Destroy(bcs)
	jolt.Shape_Destroy(shape) // release our creation ref; the body keeps the shape alive
	return id
}

remove_body :: proc(w: ^World, b: Body) {
	jolt.BodyInterface_RemoveAndDestroyBody(w.bodies, b)
}

set_velocity :: proc(w: ^World, b: Body, v: [3]f32) {
	vv := v
	jolt.BodyInterface_SetLinearVelocity(w.bodies, b, &vv)
}

// body_position returns a body's centre-of-mass in world space.
body_position :: proc(w: ^World, b: Body) -> [3]f32 {
	p: jolt.RVec3
	jolt.BodyInterface_GetCenterOfMassPosition(w.bodies, b, &p)
	return from_rvec(p)
}

body_active :: proc(w: ^World, b: Body) -> bool {
	return jolt.BodyInterface_IsActive(w.bodies, b)
}

// body_transform returns a body's world transform (position + orientation, no scale) as a
// 4×4 matrix — translation in column 3, matching the engine's render matrices. For drawing a
// dynamic body (e.g. a tumbling cube) at its live pose.
body_transform :: proc(w: ^World, b: Body) -> matrix[4, 4]f32 {
	p: jolt.RVec3
	q: jolt.Quat
	jolt.BodyInterface_GetPositionAndRotation(w.bodies, b, &p, &q)
	x, y, z, ww := f32(imag(q)), f32(jmag(q)), f32(kmag(q)), f32(real(q))
	xx, yy, zz := x * x, y * y, z * z
	xy, xz, yz := x * y, x * z, y * z
	wx, wy, wz := ww * x, ww * y, ww * z
	return matrix[4, 4]f32{
		1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy), f32(p.x),
		2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx), f32(p.y),
		2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy), f32(p.z),
		0, 0, 0, 1,
	}
}

// --- character controller (player locomotion; Jolt CharacterVirtual, Z-up) ---

// Character is the player's upright capsule. Its position is at the FEET. Drive it with
// character_move each frame and read character_position for the camera.
Character :: struct {
	cv:    ^jolt.CharacterVirtual,
	vel_z: f32, // accumulated vertical velocity (gravity + jump), units/s
}

// JUMP_SPEED: initial upward velocity on a hop (tune; ~Skyrim-ish at our gravity/scale).
JUMP_SPEED :: f32(440)

// character_create builds a Z-up capsule character with its origin at `feet`. radius +
// cylinder half-height → total height 2·(half_h + radius).
character_create :: proc(w: ^World, feet: [3]f32, radius: f32, half_h: f32) -> (c: Character, ok: bool) {
	if !init() {return {}, false}
	cap := jolt.CapsuleShape_Create(half_h, radius)
	// Jolt capsules run along Y; rotate +90° about X (Y→Z) for our Z-up world and lift the
	// capsule by its half-total-height so the shape's base sits at the character origin (feet).
	q := jolt.Quat(quaternion(w = 0.70710677, x = 0.70710677, y = 0, z = 0))
	off := jolt.Vec3{0, 0, half_h + radius} // capsule base at the character origin (feet)
	rts := jolt.RotatedTranslatedShape_Create(&off, &q, cast(^jolt.Shape)cap)
	jolt.Shape_Destroy(cast(^jolt.Shape)cap)
	if rts == nil {return {}, false}

	s: jolt.CharacterVirtualSettings
	jolt.CharacterVirtualSettings_Init(&s)
	s.base.up = {0, 0, 1}
	s.base.shape = cast(^jolt.Shape)rts
	s.base.maxSlopeAngle = 0.8727 // ~50°
	s.base.supportingVolume = {normal = {0, 0, 1}, distance = -radius}
	s.mass = 80
	p := to_rvec(feet)
	r := IDENTITY_QUAT
	cv := jolt.CharacterVirtual_Create(&s, &p, &r, 0, w.system)
	jolt.Shape_Destroy(cast(^jolt.Shape)rts) // CharacterVirtual holds its own ref
	if cv == nil {return {}, false}
	return Character{cv = cv}, true
}

character_destroy :: proc(c: ^Character) {
	if c.cv != nil {jolt.CharacterBase_Destroy(cast(^jolt.CharacterBase)c.cv)}
	c^ = {}
}

// character_move advances the character one frame: `horiz` = desired world XY velocity
// (units/s), `jump` requests a hop when grounded; gravity is integrated internally. The
// CharacterVirtual collides-and-slides against the world (incl. its own sweep, so no
// tunneling), so call it once per frame with the frame dt.
character_move :: proc(w: ^World, c: ^Character, horiz: [2]f32, jump: bool, dt: f32) {
	grounded := jolt.CharacterBase_GetGroundState(cast(^jolt.CharacterBase)c.cv) == .OnGround
	if grounded && c.vel_z <= 0 {
		c.vel_z = JUMP_SPEED if jump else 0
	}
	c.vel_z += GRAVITY.z * dt
	v := jolt.Vec3{horiz.x, horiz.y, c.vel_z}
	jolt.CharacterVirtual_SetLinearVelocity(c.cv, &v)
	jolt.CharacterVirtual_Update(c.cv, dt, LAYER_MOVING, w.system, nil, nil)
}

character_position :: proc(c: ^Character) -> [3]f32 {
	p: jolt.RVec3
	jolt.CharacterVirtual_GetPosition(c.cv, &p)
	return from_rvec(p)
}

character_set_position :: proc(c: ^Character, feet: [3]f32) {
	p := to_rvec(feet)
	jolt.CharacterVirtual_SetPosition(c.cv, &p)
	c.vel_z = 0
}

character_on_ground :: proc(c: ^Character) -> bool {
	return jolt.CharacterBase_GetGroundState(cast(^jolt.CharacterBase)c.cv) == .OnGround
}

// to_rvec / from_rvec convert between the engine's f32 positions and Jolt's RVec3. With
// single-precision bindings RVec3 is [3]f32 so these are identity; they are the single
// place to add the f32↔f64 narrowing/widening when we switch to double precision.
@(private)
to_rvec :: proc(v: [3]f32) -> jolt.RVec3 {
	return {auto_cast v.x, auto_cast v.y, auto_cast v.z}
}

@(private)
from_rvec :: proc(p: jolt.RVec3) -> [3]f32 {
	return {f32(p.x), f32(p.y), f32(p.z)}
}
