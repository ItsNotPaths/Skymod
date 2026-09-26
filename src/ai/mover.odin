package ai

// The mover walks one actor's capsule to a goal. Packages drive it now; combat will drive it later.
// It knows nothing of physics: it takes the feet and returns a velocity.

import "../nav"

// Gait is a package's preferred speed.
Gait :: enum u8 {
	Walk,
	Fast_Walk,
	Jog,
	Run,
}

// Goal is where the mover goes. A procedure re-aims it each tick to follow a moving ref.
Goal :: struct {
	active: bool,
	point:  [3]f32,
	radius: f32, // arrived inside this distance
	gait:   Gait,
}

Mover :: struct {
	goal:    Goal,
	path:    [dynamic]nav.Corner,
	heading: f32, // radians about Z
	arrived: bool,
	stuck:   bool,
	door:    Form_ID, // a load door reached this tick
}

// (hole movement-speeds :tags ai :sev gap) gait speeds are constants; Skyrim reads them from the race's movement types (MOVT), which are not decoded.
gait_speed :: proc(g: Gait) -> f32 {
	switch g {
	case .Walk:      return 80
	case .Fast_Walk: return 120
	case .Jog:       return 200
	case .Run:       return 300
	}
	return 0
}

// (hole mover :tags ai :sev blocker :needs nav-path) the mover never paths or steers (combat AI will drive it too, and adds nothing to it): wanted re-path when the goal moves past its radius, follow the corners, turn toward the next one, report arrived or stuck, stop at a load door.
// mover_step is the XY velocity that walks the feet one tick toward the goal.
mover_step :: proc(m: ^Mover, mesh: ^nav.Path_Mesh, feet: [3]f32, dt: f32) -> (vel: [2]f32) {
	return bump_turn(m, vel, false)
}

// (hole mover-bump :tags ai :sev gap :needs mover) two NPCs that touch do not turn aside; decided: both turn slightly clockwise, so a head-on pair passes like traffic. The capsules already stop clipping.
bump_turn :: proc(m: ^Mover, vel: [2]f32, touching: bool) -> [2]f32 {
	return vel
}
