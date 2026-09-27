package ai

// The mover walks one actor's capsule to a goal. Packages drive it now; combat will drive it later.
// It knows nothing of physics: it takes the feet and returns a velocity.

import "core:math"
import "core:math/linalg"
import "../gamedb"
import "../nav"

// Gait is a package's preferred speed.
Gait :: gamedb.Package_Speed

// Goal is where the mover goes. A procedure re-aims it each tick to follow a moving ref.
Goal :: struct {
	active: bool,
	point:  [3]f32,
	radius: f32, // arrived inside this distance
	gait:   Gait,
	door:   Form_ID, // a load door to go through on arrival
}

Mover :: struct {
	goal:    Goal,
	path:    [dynamic][3]f32, // corners still ahead
	aimed:   [3]f32, // the goal the path was made for; it may end short of it, off the mesh
	heading: f32, // radians about Z
	arrived: bool,
	stuck:   bool, // no progress for STUCK_AFTER seconds; it re-paths
	door:    Form_ID, // a load door reached this tick
	closest: f32, // nearest it has been to the next corner
	stalled: f32, // seconds since it got nearer
	dodge:   f32, // seconds of sidestep left
	dodges:  int, // sidesteps so far; they alternate sides
}

CORNER_REACHED :: f32(32)
DODGE_AFTER :: f32(0.5) // seconds without progress before a sidestep
DODGE_FOR :: f32(0.6)
DODGE_ANGLE :: f32(1) // radians off the way ahead
STUCK_AFTER :: f32(2)
BUMP_TURN :: f32(0.35) // radians clockwise while touching another actor

// (hole movement-speeds :tags ai :sev gap) gait speeds are constants; Skyrim reads them from the race's movement types (MOVT), which are not decoded.
gait_speed :: proc(g: Gait) -> f32 {
	switch g {
	case .Walk:      return 80
	case .FastWalk:  return 120
	case .Jog:       return 200
	case .Run:       return 300
	}
	return 0
}

// mover_step is the XY velocity that walks the feet one tick toward the goal. With no path on the
// navmesh (none loaded, or off it) it walks straight.
mover_step :: proc(m: ^Mover, mesh: ^nav.Path_Mesh, feet: [3]f32, touching: bool, dt: f32) -> [2]f32 {
	m.door = 0
	m.arrived = !m.goal.active || flat_dist(feet, m.goal.point) <= m.goal.radius
	if m.arrived {
		clear(&m.path)
		if m.goal.active {m.door = m.goal.door}
		return {}
	}
	if len(m.path) == 0 || flat_dist(m.aimed, m.goal.point) > m.goal.radius {repath(m, mesh, feet)}
	for len(m.path) > 1 && (flat_dist(feet, m.path[0]) < CORNER_REACHED || passed(feet, m.path[0], m.path[1])) {
		ordered_remove(&m.path, 0)
		m.closest = max(f32)
	}
	to := m.path[0] - feet
	d := flat_dist(feet, m.path[0])
	if d < m.closest {
		m.closest, m.stalled, m.stuck = d, 0, false
	} else {
		m.stalled += dt
		if m.stalled > DODGE_AFTER && m.dodge <= 0 {
			m.dodge = DODGE_FOR
			m.dodges += 1
		}
		if m.stalled > STUCK_AFTER {
			m.stuck = true
			repath(m, mesh, feet)
		}
	}
	if d < 0.001 {return {}}
	dir := [2]f32{to.x, to.y} / d
	if touching {dir = rotate(dir, -BUMP_TURN)}
	if m.dodge > 0 {
		m.dodge -= dt
		dir = rotate(dir, DODGE_ANGLE if m.dodges % 2 == 0 else -DODGE_ANGLE)
	}
	m.heading = math.atan2(dir.y, dir.x)
	return dir * gait_speed(m.goal.gait)
}

@(private = "file")
repath :: proc(m: ^Mover, mesh: ^nav.Path_Mesh, feet: [3]f32) {
	if !nav.find_path(mesh, feet, m.goal.point, &m.path) {
		clear(&m.path)
		append(&m.path, m.goal.point)
	}
	m.aimed, m.closest, m.stalled = m.goal.point, max(f32), 0
}

// passed is whether a near corner already lies behind the feet, seen along the leg after it (a far
// one may be a U-turn round a pillar).
@(private = "file")
passed :: proc(feet, corner, next: [3]f32) -> bool {
	return flat_dist(feet, corner) < 3 * CORNER_REACHED && linalg.dot(corner.xy - feet.xy, next.xy - corner.xy) < 0
}

@(private = "file")
flat_dist :: proc(a, b: [3]f32) -> f32 {
	return linalg.length(a.xy - b.xy)
}

@(private = "file")
rotate :: proc(v: [2]f32, angle: f32) -> [2]f32 {
	c, s := math.cos(angle), math.sin(angle)
	return {v.x * c - v.y * s, v.x * s + v.y * c}
}
