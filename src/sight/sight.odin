package sight

// What one ref sees of another, 0..1, at three levels (Mode). The player sees through the camera; an
// NPC through its eyes, facing its heading. Line of sight (CK wiki HasLOS, GetLineOfSight,
// RegisterForLOS; build/out/wsQ/wiki/) sits on top: three picks at the target's bottom, middle and
// top, any clear one is enough, and an NPC sees only actors. This is a seam (ws.md Workstream H):
// the host answers the queries in Host and calls through Table; a plugin replaces its entries.

import "core:math"
import "../plugin"

Form_ID :: plugin.Form_ID

SEAM :: "skymod_sight"
VERSION :: u32(1)

Mode :: enum u8 {
	Raw, // how much of the target the eye sees along its three picks; cutouts dim, solids block
	Cone, // Raw, counting only picks inside the view cone and range
	Detect, // the viewer's awareness of the target (detection)
}

// Body is what sight needs of a ref.
Body :: struct {
	loaded:   bool, // its 3D is in the world
	actor:    bool,
	interior: bool,
	pos:      [3]f32,
	heading:  f32, // radians, z rotation
	lo, hi:   f32, // its bounds' bottom and top above pos, scaled
}

Ray :: struct {
	from, to: [3]f32,
}

// Hit is one body a ray crosses; the host lists them nearest first.
Hit :: struct {
	owner:  Form_ID, // the ref the body belongs to; 0 = none
	cutout: bool, // an alpha-cutout surface (leaves, a fence) on the sight-only layer
}

MAX_HITS :: 32

// Host is what the engine answers; each proc gets `data` back.
Host :: struct {
	data:      rawptr,
	player:    Form_ID,
	eye:       [3]f32, // the player's camera
	vp:        matrix[4, 4]f32, // the player's view-projection
	space:     bool, // a physics world to cast rays in
	body:      proc "c" (data: rawptr, ref: Form_ID) -> Body,
	hits:      proc "c" (data: rawptr, ray: Ray, out: [^]Hit, cap: int) -> int,
	setting:   proc "c" (data: rawptr, name: cstring, fallback: f32) -> f32, // a GMST
	awareness: proc "c" (data: rawptr, viewer, target: Form_ID) -> f32,
}

Table :: struct {
	level:   proc "c" (h: ^Host, viewer, target: Form_ID, mode: Mode) -> f32,
	has_los: proc "c" (h: ^Host, viewer, target: Form_ID) -> bool,
	range:   proc "c" (h: ^Host, viewer: Form_ID) -> f32, // how far an NPC sees
	light:   proc "c" (h: ^Host, ref: Form_ID) -> f32, // how lit the ref stands, 0 dark .. 1 lit
}

BUILTIN :: Table{level_builtin, has_los_builtin, range_builtin, light_builtin}

// NPC_EYE is how high an NPC's eye sits, as a part of its height.
NPC_EYE :: f32(0.9)

// (hole view-cone-source :tags ai :sev polish) unsourced: the NPC view cone is 190 degrees from memory (fDetectionViewCone); Skyrim.esm has no such GMST (build/out/wsW/gmst.txt).
VIEW_CONE :: f32(190)

// (hole cutout-cover-source :tags query :sev polish) unsourced: how much one cutout surface (a leaf canopy wall, a fence) hides; a guess.
CUTOUT_COVER :: f32(0.4)

level_builtin :: proc "c" (h: ^Host, viewer, target: Form_ID, mode: Mode) -> f32 {
	switch mode {
	case .Raw:    return seen(h, viewer, target, false)
	case .Cone:   return seen(h, viewer, target, true)
	case .Detect: return h.awareness(h.data, viewer, target)
	}
	return 0
}

has_los_builtin :: proc "c" (h: ^Host, viewer, target: Form_ID) -> bool {
	if viewer != h.player && !h.body(h.data, target).actor {return false}
	return seen(h, viewer, target, viewer == h.player) > 0
}

// range_builtin is fSneakMaxDistance, times fSneakExteriorDistanceMult outdoors.
range_builtin :: proc "c" (h: ^Host, viewer: Form_ID) -> f32 {
	r := h.setting(h.data, "fSneakMaxDistance", 2500)
	if !h.body(h.data, viewer).interior {r *= h.setting(h.data, "fSneakExteriorDistanceMult", 2.1)}
	return r
}

// (hole light-at-point :tags (query ai unclaimed) :sev gap :needs (day-night weather-select)) nothing says how lit a point is (placed lights, sun), so detection cannot weigh light; every point reads fully lit. It runs on the sim: build it from LIGH refs, the cell lighting and the game clock and weather, never from render's lighting state.
light_builtin :: proc "c" (h: ^Host, ref: Form_ID) -> f32 {
	return 1
}

// seen is the mean visibility of the target's three picks; `cone` counts only picks inside its view.
@(private = "file")
seen :: proc "contextless" (h: ^Host, viewer, target: Form_ID, cone: bool) -> f32 {
	t := h.body(h.data, target)
	if !h.space || !t.loaded {return 0}
	eye := h.eye
	v: Body
	if viewer != h.player {
		v = h.body(h.data, viewer)
		if !v.loaded {return 0}
		eye = v.pos + {0, 0, v.hi * NPC_EYE}
	}
	reach := range_builtin(h, viewer)
	sum: f32
	for p in picks(t) {
		if cone && !in_cone(h, viewer, v, eye, p, reach) {continue}
		sum += visibility(h, viewer, target, eye, p)
	}
	return sum / 3
}

@(private = "file")
in_cone :: proc "contextless" (h: ^Host, viewer: Form_ID, v: Body, eye, p: [3]f32, reach: f32) -> bool {
	if viewer == h.player {
		c := h.vp * [4]f32{p.x, p.y, p.z, 1}
		return c.w > 0 && abs(c.x) <= c.w && abs(c.y) <= c.w
	}
	d := p - eye
	if math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z) > reach {return false}
	turn := math.to_degrees(math.atan2(d.x, d.y) - v.heading)
	return abs(math.mod(math.mod(turn, 360) + 540, 360) - 180) <= VIEW_CONE / 2
}

// picks are the target's bottom, middle and top, inside its bounds.
@(private = "file")
picks :: proc "contextless" (t: Body) -> [3][3]f32 {
	h := t.hi - t.lo
	return {t.pos + {0, 0, t.lo + 0.1 * h}, t.pos + {0, 0, t.lo + 0.5 * h}, t.pos + {0, 0, t.lo + 0.9 * h}}
}

// visibility is how much of the ray reaches the target, 0..1: a solid body blocks it, each cutout
// surface dims it.
@(private = "file")
visibility :: proc "contextless" (h: ^Host, viewer, target: Form_ID, from, to: [3]f32) -> f32 {
	buf: [MAX_HITS]Hit
	n := h.hits(h.data, {from, to}, &buf[0], MAX_HITS)
	v := f32(1)
	for hit in buf[:n] {
		if hit.owner == viewer {continue}
		if hit.owner == target {return v}
		if !hit.cutout {return 0}
		v *= 1 - CUTOUT_COVER
	}
	return v
}
