package physics

// Physics (ROADMAP §2e): a thin Jolt wrapper via the JoltC FFI bindings. This package
// is the ONLY importer of vendor/joltc-odin — the render-only-rule analog: the rest of
// the engine talks to this engine-neutral API (worlds, bodies, a future character
// controller) and never touches Jolt handles. Bodies are built from NIF bhk* collision
// shapes (see src/formats/nif/collision.odin) — reusing Havok's shape DATA, not its
// runtime.
//
// PRECISION: DOUBLE is ACTIVE (the Tamriel-scale target). The vendored Jolt is built with
// DOUBLE_PRECISION=ON (build/build-jolt.sh) and the bindings match: joltc.RVec3 == [3]f64 (world
// POSITIONS), while Vec3 stays [3]f32 (directions/extents/velocities). Body positions are therefore
// f64 — no far-from-origin jitter/tunneling across the whole world. Engine positions are f32; the
// widening/narrowing is funnelled through to_rvec/from_rvec (below), the single conversion point.
// NOTE: Jolt SHAPE geometry is always f32 regardless — a far-from-origin body must keep its verts
// LOCAL (small magnitude) and carry the world placement in the (double) body position; the static
// mesh/hull builders and add_dynamic_body do exactly that.

// (hole sensor-bodies :tags physics :sev blocker) no sensor bodies — Body_SetIsSensor is bound and never called, so trigger volumes are a box test polled each tick (script/lua/triggers.odin) and proximity stays a polled distance test (104 scripts poll GetDistance on a timer).
// (hole shape-cast :tags physics :sev gap) no shape cast — a moving body can only be swept by the character controller, so projectiles, melee arcs and teleport-safety checks have no primitive.

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:sync"

import jolt "../../vendor/joltc-odin"

// IDENTITY_QUAT is the no-rotation quaternion (Jolt Quat == Odin quaternion128).
IDENTITY_QUAT :: jolt.Quat(quaternion(w = 1, x = 0, y = 0, z = 0))

// GRAVITY is the world's gravity vector. Skyrim is Z-UP and collision data is in Skyrim
// units (≈69.99/m, the Havok→Skyrim scale), so real gravity (9.81 m/s²) becomes
// 9.81 × 69.99 ≈ 686.6 units/s² along −Z — not Jolt's metric −Y default.
GRAVITY :: [3]f32{0, 0, -9.81 * 69.99124}

// WORLD_FRICTION is the friction set on EVERY collision body (static world + dynamic clutter).
// Jolt's default (0.2) is ice — shoved clutter slid forever and never came to rest (so it never
// slept, so the settle-capture edge never fired). ~0.7 grips like real surfaces; friction combines
// across the contact pair, so both the floor and the object need it. Tune to feel.
WORLD_FRICTION :: f32(0.7)

// MAX_CLUTTER_VEL caps a dynamic body's linear speed (units/s). Placed clutter can spawn slightly
// inside static collision; Jolt's penetration recovery would otherwise eject it at 1000s of u/s (the
// z≈13000 "sky clutter" blow-up). ~2500 u/s (~36 m/s) is faster than any legitimate throw yet stops
// a bad contact from launching a body out of the world.
MAX_CLUTTER_VEL :: f32(2500)

// MAX_CLUTTER_ANG_VEL caps a dynamic body's angular speed (rad/s). A hinge-linked body yanked hard can
// spin up unbounded through the chain → inf → NaN (the Trader sign). ~15 rad/s (≈2.4 rev/s) is faster
// than any real swing yet stops a transient from diverging.
MAX_CLUTTER_ANG_VEL :: f32(15)

// A projectile keeps its authored speed: arrows fly 3600 u/s and up, past MAX_CLUTTER_VEL.
MAX_PROJECTILE_VEL :: f32(100000)

// convex_radius: the rounding radius (units) for convex shapes (hulls + boxes). Kept at Jolt's small
// default. An earlier theory raised it to ~3.5 u (0.05 m × 69.99) to give GJK a shrink margin against
// the convex-vs-mesh EPA storm — but the profiler+probe proved that storm was actually FLAT convex
// clutter hulls (the ingots — 8-vert bhkConvexVerticesShape) coplanar with the floor trimesh driving
// Jolt's hull support function into a degenerate/NaN EPA normal. The real fix is representing flat
// dynamic shapes as analytic BoxShapes (world/collision.odin shape_is_flat / dyn_boxify), which makes
// convex_radius irrelevant to the hitch. So it stays at 0.05 (avoids the ~5 cm hover a big radius
// caused). Overridable via --clutterprobe for tuning.
convex_radius := f32(0.05)

// mesh_active_edge_cos: diagnostic override for a MeshShape's active-edge cosine threshold. Our
// bhk collision destripes to ALTERNATING winding, which can make Jolt treat every internal triangle
// edge as "active" (a resting body catches on each one → pathological contacts). -1 = no edge is
// active (test if that's the cost); >1 (e.g. 2) = leave Jolt's default. Set via the probe.
mesh_active_edge_cos := f32(2)

// dyn_boxify (diagnostic): represent dynamic convex/mesh sub-shapes as their oriented bounding BOX
// (a Jolt BoxShape, analytic support function) instead of a ConvexHullShape. Flat clutter hulls (the
// ingots = 8-vert bhkConvexVerticesShape) coplanar with the floor trimesh drive Jolt's convex-hull
// support function into a degenerate EPA normal → NaN blow-up (~50ms/step). A BoxShape is
// well-conditioned. Set via `--clutterprobe boxify` to A/B; if it kills the NaN, box-like hulls
// become boxes for real (accurate — the ingot IS a box).
dyn_boxify := false

// clutter_ccd: give dynamic clutter continuous collision (LinearCast) so a shoved item can't TUNNEL
// through the single-sided floor/wall trimesh in one discrete step (a fast body moves ~10 u/step and
// passes clean through a one-sided mesh → falls forever, "as if the floor isn't there"). ON by
// default: LinearCast only runs its swept test when a body moves far relative to its size, so resting
// clutter (the common case) pays nothing, and box-ify (world/collision.odin) removed the EPA storm
// that made CCD unaffordable before. Probe (stress-fling all clutter): fall-through 14→0, worst
// 0.6→0.9ms. (`--clutterprobe ccd` also forces it on for A/B; edit here to test it OFF.)
clutter_ccd := true

// Two object layers: static world geometry (never moves) and moving (dynamic bodies +
// the character). The broadphase mirrors them. Collision is enabled moving↔moving and
// moving↔static (static↔static never collides — neither moves).
LAYER_STATIC :: jolt.ObjectLayer(0)
LAYER_MOVING :: jolt.ObjectLayer(1)
LAYER_PROJECTILE :: jolt.ObjectLayer(2) // collides with nothing: a flight's hits come from rays

@(private) NUM_OBJECT_LAYERS :: 3
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

	// Render interpolation for the fixed tick (docs/shipped.md §E). `prev` is the
	// pre-step pose of every body awake over the last step; `alpha` is how far the render
	// frame sits into the step that hasn't run yet. body_transform blends the two so a
	// 144 Hz display doesn't judder on a 60 Hz sim. body_position stays exact — it is what
	// logic reads. alpha returns to 1 (the live pose) at the end of every step.
	prev:      map[Body]Pose,
	awake:     [dynamic]Body, // scratch for the active-body query
	alpha:     f32,
}

// Pose is a body's position + orientation, the interpolation endpoint kept in World.prev.
Pose :: struct {
	pos: [3]f32,
	rot: jolt.Quat,
}

@(private) g_inited := false
@(private) g_init_lock: sync.Mutex // worlds may be made on several threads (the unit tests)

// init brings up Jolt's global factory/allocator (once per process). Idempotent; safe to
// call before each world_create. Returns false if Jolt failed to initialize.
init :: proc() -> bool {
	sync.guard(&g_init_lock)
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

	// (hole jolt-job-pool :tags (threading physics) :sev polish) each World makes its own Jolt pool of cores-1 threads; with two worlds, stream workers and a sim thread the cores are oversubscribed. Wanted: one pool all worlds share.
	w.jobs = jolt.JobSystemThreadPool_Create(nil)

	w.obj_pair = jolt.ObjectLayerPairFilterTable_Create(NUM_OBJECT_LAYERS)
	jolt.ObjectLayerPairFilterTable_EnableCollision(w.obj_pair, LAYER_MOVING, LAYER_MOVING)
	jolt.ObjectLayerPairFilterTable_EnableCollision(w.obj_pair, LAYER_MOVING, LAYER_STATIC)

	w.bp_iface = jolt.BroadPhaseLayerInterfaceTable_Create(NUM_OBJECT_LAYERS, NUM_BP_LAYERS)
	jolt.BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(w.bp_iface, LAYER_STATIC, BP_STATIC)
	jolt.BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(w.bp_iface, LAYER_MOVING, BP_MOVING)
	jolt.BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(w.bp_iface, LAYER_PROJECTILE, BP_MOVING)

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

	// UNIT-SCALE the solver tuning. Jolt's default PhysicsSettings are lengths/velocities in METERS,
	// but we feed it SKYRIM UNITS (~69.99/m). Left unscaled, e.g. penetrationSlop 0.02 means Jolt
	// tries to resolve contacts to 0.02 units (~0.3 mm) — absurdly precise for our scale, so it flickers
	// contacts and over-corrects penetration (the clutter blow-up, and general micro-jitter). Scale the
	// distance fields by S and the squared-distance / velocity fields accordingly so the tuning matches
	// our world. Fetch-modify-set so we scale the real defaults, not hardcoded ones.
	{
		S :: f32(69.99124)
		ps: jolt.PhysicsSettings
		jolt.PhysicsSystem_GetPhysicsSettings(w.system, &ps)
		ps.speculativeContactDistance *= S
		ps.penetrationSlop *= S
		ps.manifoldTolerance *= S
		ps.maxPenetrationDistance *= S
		ps.bodyPairCacheMaxDeltaPositionSq *= S * S
		ps.contactPointPreserveLambdaMaxDistSq *= S * S
		ps.minVelocityForRestitution *= S
		ps.pointVelocitySleepThreshold *= S
		jolt.PhysicsSystem_SetPhysicsSettings(w.system, &ps)
	}
	return w, true
}

world_destroy :: proc(w: ^World) {
	delete(w.prev)
	delete(w.awake)
	if w.system != nil {jolt.PhysicsSystem_Destroy(w.system)}
	if w.jobs != nil {jolt.JobSystem_Destroy(w.jobs)}
	// The layer-filter tables are owned by Jolt's interface registry for the process's
	// lifetime; joltc exposes no destroy for them (one tiny set per world).
	w^ = {}
}

// step advances the simulation by `dt` seconds using `collision_steps` sub-steps
// (1 is fine for 60Hz). Jolt manages its own per-step temp allocator internally.
// `dt` MUST be constant — Jolt's solver is not timestep-independent, so a varying step makes
// two machines converge differently. Callers drive it from the fixed tick.
step :: proc(w: ^World, dt: f32, collision_steps := 1) {
	snapshot_awake(w)
	jolt.PhysicsSystem_Update(w.system, dt, i32(collision_steps), w.jobs)
	w.alpha = 1 // between ticks, every read is the live pose
}

// snapshot_awake records the pre-step pose of the awake bodies — the only ones that can move,
// so the only ones needing a "from" end for the render blend. Rebuilt each step, so a body that
// falls asleep during the step keeps its blend for exactly the one frame it needs it and is then
// read live.
@(private)
snapshot_awake :: proc(w: ^World) {
	clear(&w.prev)
	n := int(jolt.PhysicsSystem_GetNumActiveBodies(w.system, .Rigid))
	if n == 0 {
		return
	}
	resize(&w.awake, n)
	jolt.PhysicsSystem_GetActiveBodies(w.system, .Rigid, &w.awake[0], u32(n))
	for b in w.awake {
		p: jolt.RVec3
		q: jolt.Quat
		jolt.BodyInterface_GetPositionAndRotation(w.bodies, b, &p, &q)
		w.prev[b] = {from_rvec(p), q}
	}
}

// set_render_alpha sets how far the frame about to be drawn sits past the last completed step:
// 0 = the pose that step started from, 1 = the live pose. The app writes the fixed-tick
// accumulator remainder here once per frame, after its tick loop and before it draws.
set_render_alpha :: proc(w: ^World, alpha: f32) {
	w.alpha = clamp(alpha, 0, 1)
}

// profile_next_frame / profile_dump drive Jolt's built-in hierarchical profiler (the lib must be
// built with JPH_PROFILE_ENABLED). Call profile_next_frame each step; profile_dump writes a
// profile_<tag>.html with the per-phase call tree + timings to the CWD.
profile_next_frame :: proc() {jolt.ProfileNextFrame()}
profile_dump :: proc(tag: cstring) {jolt.ProfileDump(tag)}

// num_active / num_bodies report the awake rigid-body count and the total — a cheap per-step cost
// proxy (step time scales with active bodies + their contacts, not the total).
num_active :: proc(w: ^World) -> int {
	return int(jolt.PhysicsSystem_GetNumActiveBodies(w.system, .Rigid))
}
num_bodies :: proc(w: ^World) -> int {
	return int(jolt.PhysicsSystem_GetNumBodies(w.system))
}

// set_sleep overrides the sleep thresholds: a body sleeps once its points move slower than
// `point_velocity` (units/s) for `time_before` seconds. Higher velocity / shorter time = clutter
// parks aggressively (so jittering-in-penetration bodies still sleep instead of costing every step).
set_sleep :: proc(w: ^World, point_velocity, time_before: f32) {
	ps: jolt.PhysicsSettings
	jolt.PhysicsSystem_GetPhysicsSettings(w.system, &ps)
	ps.pointVelocitySleepThreshold = point_velocity
	ps.timeBeforeSleep = time_before
	jolt.PhysicsSystem_SetPhysicsSettings(w.system, &ps)
}

// set_penetration_slop overrides how much overlap Jolt tolerates before correcting (units). Larger =
// a slightly-embedded body rests instead of being fought out (which manifests as endless jitter that
// never sleeps). Diagnostic knob.
set_penetration_slop :: proc(w: ^World, slop: f32) {
	ps: jolt.PhysicsSettings
	jolt.PhysicsSystem_GetPhysicsSettings(w.system, &ps)
	ps.penetrationSlop = slop
	jolt.PhysicsSystem_SetPhysicsSettings(w.system, &ps)
}

// set_speculative overrides the speculative-contact distance (units) — how far ahead Jolt creates
// contact points for not-yet-touching surfaces. Large values near a dense mesh create a contact per
// nearby triangle → a huge, expensive manifold. Diagnostic knob.
set_speculative :: proc(w: ^World, dist: f32) {
	ps: jolt.PhysicsSettings
	jolt.PhysicsSystem_GetPhysicsSettings(w.system, &ps)
	ps.speculativeContactDistance = dist
	jolt.PhysicsSystem_SetPhysicsSettings(w.system, &ps)
}

// set_solver_iterations overrides Jolt's velocity/position solver step counts (defaults 10/2).
// Fewer = cheaper but softer contacts — a diagnostic knob to test whether a step hitch is
// solver-iteration-bound (penetration depth) vs contact-count-bound (manifold creation).
set_solver_iterations :: proc(w: ^World, velocity, position: u32) {
	ps: jolt.PhysicsSettings
	jolt.PhysicsSystem_GetPhysicsSettings(w.system, &ps)
	ps.numVelocitySteps = velocity
	ps.numPositionSteps = position
	jolt.PhysicsSystem_SetPhysicsSettings(w.system, &ps)
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
	shape := jolt.BoxShape_Create(&he, convex_radius)
	// Dynamic primitives are the drop-test bodies (fall from camera height, fast) → keep CCD.
	return make_body(w, cast(^jolt.Shape)shape, pos, IDENTITY_QUAT, is_dynamic, ccd = is_dynamic)
}

add_sphere :: proc(w: ^World, radius: f32, pos: [3]f32, is_dynamic := false) -> Body {
	shape := jolt.SphereShape_Create(radius)
	return make_body(w, cast(^jolt.Shape)shape, pos, IDENTITY_QUAT, is_dynamic, ccd = is_dynamic)
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
	jolt.MeshShapeSettings_SetBuildQuality(settings, .FavorRuntimePerformance)
	jolt.MeshShapeSettings_Sanitize(settings) // drop degenerate/duplicate triangles → clean active-edge detection
	if mesh_active_edge_cos <= 1 {jolt.MeshShapeSettings_SetActiveEdgeCosThresholdAngle(settings, mesh_active_edge_cos)}
	shape := jolt.MeshShapeSettings_CreateShape(settings)
	jolt.ShapeSettings_Destroy(cast(^jolt.ShapeSettings)settings)
	if shape == nil {return 0}
	return make_body(w, cast(^jolt.Shape)shape, origin, IDENTITY_QUAT, false)
}

// add_static_hull builds a convex-hull body from points relative to `origin` (pass local points + the
// world origin so the shape stays small-magnitude and the body's f64 position carries the world
// placement — the far-from-origin precision pattern). `margin` is the shape's Havok CONVEX MARGIN (the
// bhkConvexVerticesShape radius): Skyrim authors hull verts INSET and the margin brings the collision
// surface out to the visual, so it must be honored per-shape (a global would over/under-inflate). 0 →
// a small default so GJK still has a shrink margin.
add_static_hull :: proc(w: ^World, points: [][3]f32, origin: [3]f32 = {0, 0, 0}, margin: f32 = 0) -> Body {
	if len(points) < 4 {return 0}
	ps := make([]jolt.Vec3, len(points), context.temp_allocator)
	for p, i in points {ps[i] = {p.x, p.y, p.z}}
	cr := margin if margin > convex_radius else convex_radius
	settings := jolt.ConvexHullShapeSettings_Create(&ps[0], u32(len(ps)), cr)
	shape := jolt.ConvexHullShapeSettings_CreateShape(settings)
	jolt.ShapeSettings_Destroy(cast(^jolt.ShapeSettings)settings)
	if shape == nil {return 0}
	return make_body(w, cast(^jolt.Shape)shape, origin, IDENTITY_QUAT, false)
}

// --- dynamic articulated clutter (Phase A: one Jolt body per bhkRigidBody) ---
//
// Dyn_Kind / Dyn_Shape describe ONE sub-shape of a dynamic body in BODY-LOCAL space (relative to
// the body `origin`, world-aligned at rest). The world layer fills a slice of these from a rigid
// body's bhk* shapes and calls add_dynamic_body. Using EXACT primitives (Box/Sphere/Capsule) rather
// than convex-hull approximations gives Jolt an ANALYTIC narrow phase — the fix for the coplanar
// flat-box-on-flat-mesh EPA degeneracy (the old merged-hull path hit GJK/EPA runaway on the ingot
// stack). A Mesh sub-shape has no dynamic-concave equivalent, so the caller passes it as a Hull.
Dyn_Kind :: enum u8 {
	Box,
	Sphere,
	Capsule,
	Hull,
}

Dyn_Shape :: struct {
	kind:   Dyn_Kind,
	pos:    [3]f32, // local center (relative to the body origin)
	rot:    quaternion128, // local orientation (Box/Capsule)
	half:   [3]f32, // Box: half extents
	radius: f32, // Sphere / Capsule radius
	half_h: f32, // Capsule: half cylinder height (local +Y)
	points: [][3]f32, // Hull: points relative to the body origin
	margin: f32, // Hull: the shape's Havok convex margin (bhkConvexVerticesShape radius; brings inset verts out to the visual surface)
}

// add_dynamic_body builds ONE dynamic body from a rigid body's sub-shapes as a StaticCompoundShape,
// placed at `origin` (the instance REFR position, so the render-follow math in world.instance_world
// lines up: verts/offsets are stored relative to origin and the body's f64 position carries the
// world placement). Spawns ASLEEP (placed clutter is inert until kicked/interacted — same as the old
// the old per-instance hull). Mass is auto-derived from the compound volume (the Havok mass only CLASSIFIES).
// Returns 0 if no sub-shape built.
add_dynamic_body :: proc(w: ^World, subs: []Dyn_Shape, origin: [3]f32, projectile := false) -> Body {
	if len(subs) == 0 {return 0}
	settings := jolt.StaticCompoundShapeSettings_Create()
	children := make([dynamic]^jolt.Shape, 0, len(subs), context.temp_allocator)
	for sub in subs {
		sh := build_sub_shape(sub)
		if sh == nil {continue}
		pos := jolt.Vec3(sub.pos)
		rot := jolt.Quat(sub.rot)
		jolt.CompoundShapeSettings_AddShape2(cast(^jolt.CompoundShapeSettings)settings, &pos, &rot, sh, 0)
		append(&children, sh)
	}
	if len(children) == 0 {
		jolt.ShapeSettings_Destroy(cast(^jolt.ShapeSettings)settings)
		return 0
	}
	shape := jolt.StaticCompoundShape_Create(settings)
	jolt.ShapeSettings_Destroy(cast(^jolt.ShapeSettings)settings)
	for c in children {jolt.Shape_Destroy(c)} // compound holds its own refs now; drop ours
	if shape == nil {return 0}
	return make_body(w, cast(^jolt.Shape)shape, origin, IDENTITY_QUAT, true, ccd = clutter_ccd, activate = false, projectile = projectile)
}

// build_sub_shape creates one Jolt leaf shape for a compound sub-shape. Caller owns the returned
// ref (destroys it after the compound is built). Returns nil on a degenerate sub-shape.
@(private)
build_sub_shape :: proc(sub: Dyn_Shape) -> ^jolt.Shape {
	switch sub.kind {
	case .Box:
		he := jolt.Vec3(sub.half)
		// Jolt requires convexRadius ≤ the smallest half extent; thin clutter (ingots) can be
		// thinner than the world-scaled radius, so clamp to half the smallest extent.
		mn := min(sub.half.x, min(sub.half.y, sub.half.z))
		if mn <= 0 {return nil}
		return cast(^jolt.Shape)jolt.BoxShape_Create(&he, min(convex_radius, mn * 0.5))
	case .Sphere:
		if sub.radius <= 0 {return nil}
		return cast(^jolt.Shape)jolt.SphereShape_Create(sub.radius)
	case .Capsule:
		if sub.radius <= 0 {return nil}
		if sub.half_h <= 0 {return cast(^jolt.Shape)jolt.SphereShape_Create(sub.radius)}
		return cast(^jolt.Shape)jolt.CapsuleShape_Create(sub.half_h, sub.radius)
	case .Hull:
		if len(sub.points) < 4 {return nil}
		ps := make([]jolt.Vec3, len(sub.points), context.temp_allocator)
		for p, i in sub.points {ps[i] = {p.x, p.y, p.z}}
		// Honor the shape's per-shape Havok convex margin (inset verts → visual surface); fall back to
		// the small global so GJK always has a shrink margin.
		cr := sub.margin if sub.margin > convex_radius else convex_radius
		st := jolt.ConvexHullShapeSettings_Create(&ps[0], u32(len(ps)), cr)
		sh := jolt.ConvexHullShapeSettings_CreateShape(st)
		jolt.ShapeSettings_Destroy(cast(^jolt.ShapeSettings)st)
		if sh == nil {return nil}
		return cast(^jolt.Shape)sh
	}
	return nil
}

// --- constraints (Phase B: hinges) ---
//
// Constraint is an opaque handle to a Jolt two-body constraint. HINGE_FRICTION_SCALE converts the
// Havok maxFriction (a small unitless-ish torque) into our ~70-unit world; 0 friction still settles
// because dynamic bodies carry angular damping. Tunable.
Constraint :: ^jolt.Constraint
HINGE_FRICTION_SCALE := f32(1)
// Per-hinge solver iteration overrides (Jolt defaults 10/2). Deep chains need more to stay rigid under
// a hard shove; scoped to the constraint so ordinary bodies keep the cheap global count.
HINGE_VEL_STEPS := u32(24)
HINGE_POS_STEPS := u32(16)

// add_hinge links bodies `a` and `b` with a Jolt HingeConstraint about `axis` through world-space
// `pivot`, with `perp` (⊥ axis) as the zero-angle reference. `limited` clamps the swing to
// [min_angle, max_angle] (bhkLimitedHingeConstraint — signs/animals); otherwise it's free rotation
// (bhkHingeConstraint — cart wheels). Bodies are resolved from their IDs via GetBodyPtr (valid once
// they're added, which they are by the time the world layer builds constraints). Returns the handle
// (nil on failure) — remove_constraint frees it before the bodies are removed.
add_hinge :: proc(w: ^World, a, b: Body, pivot, axis, perp: [3]f32, min_angle, max_angle, friction: f32, limited: bool) -> Constraint {
	ba := jolt.PhysicsSystem_GetBodyPtr(w.system, a)
	bb := jolt.PhysicsSystem_GetBodyPtr(w.system, b)
	if ba == nil || bb == nil {return nil}
	s: jolt.HingeConstraintSettings
	jolt.HingeConstraintSettings_Init(&s)
	s.space = .WorldSpace
	p := to_rvec(pivot)
	s.point1 = p
	s.point2 = p
	s.hingeAxis1 = axis
	s.hingeAxis2 = axis
	s.normalAxis1 = perp
	s.normalAxis2 = perp
	if limited && max_angle > min_angle {
		s.limitsMin = min_angle
		s.limitsMax = max_angle
	} else {
		s.limitsMin = -math.PI // free hinge: full range (Jolt treats [-π,π] as unlimited)
		s.limitsMax = math.PI
	}
	s.maxFrictionTorque = friction * HINGE_FRICTION_SCALE
	// Stiffer solve for the constraint: a deep/branching hinge chain (the Trader sign — 8 bodies, 7
	// hinges) diverges to NaN under a hard shove with Jolt's default 2 position steps. More steps per
	// constraint (not global) keep the chain rigid without a world-wide cost.
	s.base.numVelocityStepsOverride = HINGE_VEL_STEPS
	s.base.numPositionStepsOverride = HINGE_POS_STEPS
	c := jolt.HingeConstraint_Create(&s, ba, bb)
	if c == nil {return nil}
	jolt.PhysicsSystem_AddConstraint(w.system, cast(^jolt.Constraint)c)
	return cast(^jolt.Constraint)c
}

// remove_constraint detaches a constraint from the system and frees it. MUST be called before either
// constrained body is removed (Jolt asserts on a body still referenced by a live constraint).
remove_constraint :: proc(w: ^World, c: Constraint) {
	if c == nil {return}
	jolt.PhysicsSystem_RemoveConstraint(w.system, c)
	jolt.Constraint_Destroy(c)
}

// kick wakes a body and sets its linear velocity outright (mass-independent, so the motion is
// always visible regardless of the hull's auto-computed mass). Used by the debug "shove" that
// scatters resting clutter to verify the dynamic-body + settle path.
kick :: proc(w: ^World, b: Body, vel: [3]f32) {
	if jolt.BodyInterface_GetMotionType(w.bodies, b) != .Dynamic {return} // static anchors (mount) can't be kicked
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
make_body :: proc(w: ^World, shape: ^jolt.Shape, pos: [3]f32, rot: jolt.Quat, is_dynamic: bool, ccd := false, activate := true, projectile := false) -> Body {
	p := to_rvec(pos)
	r := rot
	motion := jolt.MotionType.Dynamic if is_dynamic else jolt.MotionType.Static
	layer := LAYER_PROJECTILE if projectile else LAYER_MOVING if is_dynamic else LAYER_STATIC
	bcs := jolt.BodyCreationSettings_Create3(shape, &p, &r, motion, layer)
	jolt.BodyCreationSettings_SetFriction(bcs, WORLD_FRICTION) // default 0.2 = ice; grip so clutter settles
	if is_dynamic {
		// Continuous collision (LinearCast) is OPT-IN (ccd): it does a swept test per active body
		// per step against the WHOLE terrain trimesh + static set — fine for a body that falls far/
		// fast (the drop-test primitives) but very expensive at exterior scale when a shove wakes a
		// cluster. Clutter is small + slow (≤~23 u/step even falling ≪ a 128 u terrain tri), so it
		// keeps the default DISCRETE quality and never gets the CCD cost.
		if ccd {
			jolt.BodyCreationSettings_SetMotionQuality(bcs, .LinearCast)
		}
		jolt.BodyCreationSettings_SetAngularDamping(bcs, 0.3) // bleed spin so tumbling clutter comes to rest
		// Clamp max linear velocity: placed clutter can spawn slightly interpenetrating static
		// geometry, and Jolt's penetration recovery would otherwise fling it at 1000s of u/s to
		// z≈13000 (the "sky clutter" blow-up). Capping keeps a bad contact from launching a body into
		// orbit; a real throw stays well under this.
		jolt.BodyCreationSettings_SetMaxLinearVelocity(bcs, MAX_CLUTTER_VEL)
		// Cap angular speed too: a hinge-constrained body yanked by a hard shove can spin up unbounded
		// through the chain toward inf → NaN (the Trader sign blow-up). Jolt's default is ~47 rad/s;
		// clamp to a sane spin so a transient can't diverge.
		jolt.BodyCreationSettings_SetMaxAngularVelocity(bcs, MAX_CLUTTER_ANG_VEL)
		if projectile {jolt.BodyCreationSettings_SetMaxLinearVelocity(bcs, MAX_PROJECTILE_VEL)}
	}
	// activate=false spawns the body ASLEEP: placed clutter stays inert (Skyrim keyframes it until
	// touched) so it neither simulates a mass-settle at load — the blow-up that froze the frame and
	// polluted the overlay — nor costs anything per frame; kick()/interaction wakes it on demand.
	act := jolt.Activation.Activate if (is_dynamic && activate) else jolt.Activation.DontActivate
	id := jolt.BodyInterface_CreateAndAddBody(w.bodies, bcs, act)
	jolt.BodyCreationSettings_Destroy(bcs)
	jolt.Shape_Destroy(shape) // release our creation ref; the body keeps the shape alive
	return id
}

// set_owner tags a body with the ref it belongs to, so a ray hit can name it.
set_owner :: proc(w: ^World, b: Body, owner: u64) {
	jolt.BodyInterface_SetUserData(w.bodies, b, owner)
}

// Ray_Hit is one body a ray crossed: its owner (0 = none) and how far along the ray, 0..1.
Ray_Hit :: struct {
	owner:    u64,
	fraction: f32,
}

// (hole sight-occluders :tags (physics query) :sev gap) cutout shapes (leaves, grass, fences: nif alpha_cutoff) have no bodies, so sight rays pass through them. Wanted: bodies on a sight-only layer that nothing collides with, each hit carrying its coverage.
// ray_hits returns every body the segment from→to crosses, nearest first. Mesh back faces count, so a
// one-sided wall blocks from both sides. Safe from any thread while the world does not step.
ray_hits :: proc(w: ^World, from, to: [3]f32, allocator := context.temp_allocator) -> []Ray_Hit {
	found := make([dynamic]jolt.RayCastResult, context.temp_allocator)
	collect :: proc "c" (found: rawptr, r: ^jolt.RayCastResult) {
		context = runtime.default_context()
		append((^[dynamic]jolt.RayCastResult)(found), r^)
	}
	origin := to_rvec(from)
	dir := jolt.Vec3(to - from)
	settings := jolt.RayCastSettings{.CollideWithBackFaces, .IgnoreBackFaces, true}
	query := jolt.PhysicsSystem_GetNarrowPhaseQuery(w.system)
	callback := (^jolt.CastRayResultCallback)(rawptr(collect)) // the binding types the C function pointer as a pointer to one
	jolt.NarrowPhaseQuery_CastRay3(query, &origin, &dir, &settings, .AllHit, callback, &found, nil, nil, nil, nil)

	hits := make([]Ray_Hit, len(found), allocator)
	for r, i in found {hits[i] = {jolt.BodyInterface_GetUserData(w.bodies, r.bodyID), r.fraction}}
	slice.sort_by(hits, proc(a, b: Ray_Hit) -> bool {return a.fraction < b.fraction})
	return hits
}

remove_body :: proc(w: ^World, b: Body) {
	delete_key(&w.prev, b) // Jolt recycles BodyIDs; a stale blend endpoint would pose the next body wrong
	jolt.BodyInterface_RemoveAndDestroyBody(w.bodies, b)
}

set_velocity :: proc(w: ^World, b: Body, v: [3]f32) {
	vv := v
	jolt.BodyInterface_SetLinearVelocity(w.bodies, b, &vv)
}

body_velocity :: proc(w: ^World, b: Body) -> [3]f32 {
	v: jolt.Vec3
	jolt.BodyInterface_GetLinearVelocity(w.bodies, b, &v)
	return {v[0], v[1], v[2]}
}

// launch wakes a body at `pos` with velocity `v`, falling at `gravity` times world gravity.
launch :: proc(w: ^World, b: Body, pos, v: [3]f32, gravity: f32) {
	p := to_rvec(pos)
	jolt.BodyInterface_SetPosition(w.bodies, b, &p, .Activate)
	jolt.BodyInterface_SetGravityFactor(w.bodies, b, gravity)
	set_velocity(w, b, v)
}

// body_origin is a body's frame origin, the point launch places (body_position is its centre of mass).
body_origin :: proc(w: ^World, b: Body) -> [3]f32 {
	p: jolt.RVec3
	jolt.BodyInterface_GetPosition(w.bodies, b, &p)
	return from_rvec(p)
}

set_rotation :: proc(w: ^World, b: Body, rot: quaternion128) {
	r := jolt.Quat(rot)
	jolt.BodyInterface_SetRotation(w.bodies, b, &r, .Activate)
}

set_gravity_factor :: proc(w: ^World, b: Body, gravity: f32) {
	jolt.BodyInterface_SetGravityFactor(w.bodies, b, gravity)
}

// body_position returns a body's centre-of-mass in world space — the EXACT simulated value,
// never interpolated. Logic reads this; rendering reads body_transform.
body_position :: proc(w: ^World, b: Body) -> [3]f32 {
	p: jolt.RVec3
	jolt.BodyInterface_GetCenterOfMassPosition(w.bodies, b, &p)
	return from_rvec(p)
}

body_active :: proc(w: ^World, b: Body) -> bool {
	return jolt.BodyInterface_IsActive(w.bodies, b)
}

// body_speed returns a body's linear speed (units/s).
body_speed :: proc(w: ^World, b: Body) -> f32 {
	v: jolt.Vec3
	jolt.BodyInterface_GetLinearVelocity(w.bodies, b, &v)
	return linalg.length([3]f32{v[0], v[1], v[2]})
}

// deactivate forces a body to sleep. Used by the settle-timeout: clutter that has been active a
// while but is barely moving is stuck jittering in penetration (it would never sleep on its own and
// so accumulates, growing every step); parking it caps the active set. A real contact re-wakes it.
deactivate :: proc(w: ^World, b: Body) {
	jolt.BodyInterface_DeactivateBody(w.bodies, b)
}

// (hole body-pose-snapshot :tags (threading render physics) :sev gap) render reads Jolt live, and the blend state (World.prev, awake, alpha) sits in physics. Wanted: moved and awake body poses by form ID in the snapshot; physics loses its render state.
// body_transform returns a body's RENDER transform (position + orientation, no scale) as a
// 4×4 matrix — translation in column 3, matching the engine's render matrices. Blended toward
// the pose the last step started from by set_render_alpha, so a body drawn between fixed ticks
// moves smoothly. At alpha 1 (during the tick, and for any body that was asleep) it is the
// live pose exactly.
body_transform :: proc(w: ^World, b: Body) -> matrix[4, 4]f32 {
	p: jolt.RVec3
	q: jolt.Quat
	jolt.BodyInterface_GetPositionAndRotation(w.bodies, b, &p, &q)
	pos, rot := from_rvec(p), q
	if w.alpha < 1 {
		if from, blend := w.prev[b]; blend {
			pos = from.pos + (pos - from.pos) * w.alpha
			rot = linalg.quaternion_slerp(from.rot, rot, w.alpha)
		}
	}
	return pose_matrix(pos, rot)
}

// pose_matrix builds the 4×4 from a position + unit quaternion.
@(private)
pose_matrix :: proc(pos: [3]f32, q: jolt.Quat) -> matrix[4, 4]f32 {
	x, y, z, w := f32(imag(q)), f32(jmag(q)), f32(kmag(q)), f32(real(q))
	xx, yy, zz := x * x, y * y, z * z
	xy, xz, yz := x * y, x * z, y * z
	wx, wy, wz := w * x, w * y, w * z
	return matrix[4, 4]f32{
		1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy), pos.x,
		2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx), pos.y,
		2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy), pos.z,
		0, 0, 0, 1,
	}
}

// --- character controller (player locomotion; Jolt CharacterVirtual, Z-up) ---

// Character is an actor's upright capsule. Its position is at the FEET. Drive it with
// character_move each frame and read character_position for the camera.
Character :: struct {
	cv:    ^jolt.CharacterVirtual,
	vel_z: f32, // accumulated vertical velocity (gravity + jump), units/s
	prev:  [3]f32, // feet position before the last character_move — the render-blend "from" end
}

// JUMP_SPEED: initial upward velocity on a hop (tune; ~Skyrim-ish at our gravity/scale).
JUMP_SPEED :: f32(440)

// Character stick-to-floor + walk-stairs tuning (Jolt CharacterVirtual_ExtendedUpdate). Values are
// ≈ Jolt's metric defaults × the Skyrim unit scale (~69.99/m). STICK_DOWN re-snaps the capsule to
// the floor after a move so it follows down slopes/small drops instead of launching (which, with the
// old plain Update, read as endless micro-sliding); STEP_UP lets it climb small ledges/stairs. Tune
// to feel.
STICK_DOWN :: f32(35) // ~0.5 m: max downward floor snap after a move
STEP_UP :: f32(10) // step-up height
STEP_FWD_MIN :: f32(2)
STEP_FWD_TEST :: f32(12)
STEP_FWD_COS :: f32(0.26) // ≈ cos(75°); unitless

// character_create builds a Z-up capsule character with its origin at `feet`. radius +
// cylinder half-height → total height 2·(half_h + radius).
character_create :: proc(w: ^World, feet: [3]f32, radius: f32, half_h: f32, owner: u64 = 0) -> (c: Character, ok: bool) {
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
	s.innerBodyShape = cast(^jolt.Shape)rts // a body that rays and other characters hit
	s.innerBodyLayer = LAYER_MOVING
	p := to_rvec(feet)
	r := IDENTITY_QUAT
	cv := jolt.CharacterVirtual_Create(&s, &p, &r, 0, w.system)
	jolt.Shape_Destroy(cast(^jolt.Shape)rts) // CharacterVirtual holds its own ref
	if cv == nil {return {}, false}
	set_owner(w, jolt.CharacterVirtual_GetInnerBodyID(cv), owner)
	return Character{cv = cv, prev = feet}, true
}

character_destroy :: proc(c: ^Character) {
	if c.cv != nil {jolt.CharacterBase_Destroy(cast(^jolt.CharacterBase)c.cv)}
	c^ = {}
}

// (hole swimming :tags physics :sev gap) no actor swims: a capsule in water sinks to the bed and walks it, so a steep bank traps it (seen: Alvor in the Riverwood river), and IsSwimming has no state. Decided: physics acts on the mover capsule; an actor in water walks slowly with its capsule held about 1 m below the surface. The swim animation is animation work.
// character_move advances the character one fixed tick: `horiz` = desired world XY velocity
// (units/s), `jump` requests a hop when grounded; gravity is integrated internally. The
// CharacterVirtual collides-and-slides against the world (incl. its own sweep, so no
// tunneling). Call it once per TICK with the tick dt, not per rendered frame — the camera
// reads character_render_position to fill the gap between ticks.
character_move :: proc(w: ^World, c: ^Character, horiz: [2]f32, jump: bool, dt: f32) {
	c.prev = character_position(c)
	grounded := jolt.CharacterBase_GetGroundState(cast(^jolt.CharacterBase)c.cv) == .OnGround
	if grounded {
		// Grounded: DON'T accumulate gravity. The old code left vel_z at -gravity·dt every grounded
		// frame; on any slight terrain slope the slide solver turned that downward velocity into a
		// tangential creep, so the capsule never stood still. Zero it (hop on jump); stick-to-floor
		// below keeps contact walking downhill so idling stays put but slopes/steps still follow.
		c.vel_z = JUMP_SPEED if jump else 0
	} else {
		c.vel_z += GRAVITY.z * dt // airborne: integrate gravity (fall / jump arc)
	}
	v := jolt.Vec3{horiz.x, horiz.y, c.vel_z}
	jolt.CharacterVirtual_SetLinearVelocity(c.cv, &v)
	us := jolt.ExtendedUpdateSettings {
		stickToFloorStepDown             = {0, 0, -STICK_DOWN},
		walkStairsStepUp                 = {0, 0, STEP_UP},
		walkStairsMinStepForward         = STEP_FWD_MIN,
		walkStairsStepForwardTest        = STEP_FWD_TEST,
		walkStairsCosAngleForwardContact = STEP_FWD_COS,
	}
	jolt.CharacterVirtual_ExtendedUpdate(c.cv, dt, &us, LAYER_MOVING, w.system, nil, nil)
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
	c.prev = feet // a teleport has nothing to blend from — land there outright
}

// character_render_position is where to draw the eye between fixed ticks: the last two move
// results blended by `alpha` (1 = the live position). Rendering off character_position instead
// makes the camera step in 60 Hz jerks on a faster display.
character_render_position :: proc(c: ^Character, alpha: f32) -> [3]f32 {
	cur := character_position(c)
	return c.prev + (cur - c.prev) * clamp(alpha, 0, 1)
}

// capsule_fits is whether an upright capsule standing on `feet` would overlap nothing (a little
// above them, so the floor it stands on does not count).
capsule_fits :: proc(w: ^World, feet: [3]f32, radius, half_h: f32) -> bool {
	FLOOR_GAP :: 4
	cap := jolt.CapsuleShape_Create(half_h, radius)
	defer jolt.Shape_Destroy(cast(^jolt.Shape)cap)
	xf := jolt.RMat4 {
		column  = {{1, 0, 0, 0}, {0, 0, 1, 0}, {0, -1, 0, 0}}, // Jolt capsules run along Y; stand it on Z
		column3 = to_rvec(feet + {0, 0, half_h + radius + FLOOR_GAP}),
	}
	scale := jolt.Vec3{1, 1, 1}
	base := jolt.RVec3{}
	settings: jolt.CollideShapeSettings
	jolt.CollideShapeSettings_Init(&settings)
	hits := 0
	count :: proc "c" (hits: rawptr, _: ^jolt.CollideShapeResult) {(^int)(hits)^ += 1}
	callback := (^jolt.CollideShapeResultCallback)(rawptr(count))
	query := jolt.PhysicsSystem_GetNarrowPhaseQuery(w.system)
	jolt.NarrowPhaseQuery_CollideShape2(query, cast(^jolt.Shape)cap, &scale, &xf, &settings, &base, .AnyHit, callback, &hits, nil, nil, nil, nil)
	return hits == 0
}

// character_touching is the owner of a moving body the character pushed against in its last move
// (another character's inner body, for one), 0 for none.
character_touching :: proc(w: ^World, c: ^Character) -> u64 {
	for i in 0 ..< jolt.CharacterVirtual_GetNumActiveContacts(c.cv) {
		ct: jolt.CharacterVirtualContact
		jolt.CharacterVirtual_GetActiveContact(c.cv, i, &ct)
		if ct.hadCollision && ct.motionTypeB != .Static {
			if owner := jolt.BodyInterface_GetUserData(w.bodies, ct.bodyB); owner != 0 {return owner}
		}
	}
	return 0
}

character_on_ground :: proc(c: ^Character) -> bool {
	return jolt.CharacterBase_GetGroundState(cast(^jolt.CharacterBase)c.cv) == .OnGround
}

// to_rvec / from_rvec convert between the engine's f32 positions and Jolt's RVec3 ([3]f64 under the
// active double-precision build): to_rvec widens f32→f64 on the way in, from_rvec narrows f64→f32 on
// the way out. The single conversion point between engine space (f32) and Jolt world positions (f64).
@(private)
to_rvec :: proc(v: [3]f32) -> jolt.RVec3 {
	return {auto_cast v.x, auto_cast v.y, auto_cast v.z}
}

@(private)
from_rvec :: proc(p: jolt.RVec3) -> [3]f32 {
	return {f32(p.x), f32(p.y), f32(p.z)}
}
