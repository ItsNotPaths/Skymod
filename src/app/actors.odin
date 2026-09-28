package main

// Actor bodies: every loaded actor ref gets a capsule, as the player does. The AI drives it instead
// of input, and it is drawn.

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:time"
import imgui "../../vendor/odin-imgui"
import "../ai"
import "../assetdb"
import "../detection"
import "../formats/nif"
import "../formid"
import "../gamedb"
import "../input"
import "../nav"
import smath "../math"
import "../physics"
import "../render"
import "../script"
import "../world"
import "../worldstate"

// (hole actor-hitboxes :tags (combat unclaimed) :sev gap :needs (animation)) a hit can only land on the one capsule; combat wants the race skeleton's per-bone colliders, posed each tick, with the weapon swept through them (Precision-style, the default).
// (hole actor-fall-through :tags physics :sev gap) a capsule waits for its own cell's collision, but one standing on a neighbour cell's props can still spawn before that cell cooks, and nothing catches a falling actor (no out-of-bounds recovery).
// (hole actor-ragdoll :tags (combat physics) :sev gap :needs (animation actor-states combat-damage)) a dead actor keeps its standing capsule; nothing falls as a ragdoll.

// (hole anim-state-snapshot :tags (threading animation) :sev gap) the actor view carries only the capsule. Wanted: per actor the state, heading and (clip, t, weight) layers with transition info, so main samples the full skeleton at an interpolated t and cuts on a clip change.
// Actor_Body is an actor's capsule. `placed` is the ref position it was last put at, so a script
// move teleports it and a fall does not.
Actor_Body :: struct {
	char:    physics.Character,
	placed:  smath.Vec3,
	capsule: Capsule,
}

Capsule :: struct {
	radius, half_h: f32,
}

// (hole actor-capsule-source :tags (player physics) :sev polish) the capsule is fitted to the race skeleton's BBX box, else the NPC_ OBND (radius = mean half-width, height = box height). Skyrim's controller is an 18-vertex convex built at runtime from an unknown source; 15 skeletons carry layer-30 capsules (human r 20 len 76) that may be bumpers (build/out/wsP/research/findings.md sections 1 and 8).
// actor_capsule fits an upright capsule to an actor's bounds at its scale.
actor_capsule :: proc(g: ^Game, form: Form_ID) -> Capsule {
	box := worldstate.actor_box(&g.sim.ws, &g.db, form)
	size := box[1] - box[0]
	radius := (size.x + size.y) / 4
	return {radius, max(size.z / 2 - radius, 1)}
}

// (hole animation) Decided (user, 2026-09-27): the sim owns the animation clock. It advances each actor's (clip, t) per tick, fires the annotations, applies root motion and samples the bones combat hitboxes need; main samples the full skeleton for drawing from the same clips.
// tick_actor_bodies gives each actor in the active scene's loaded cells a capsule, moves it one
// tick, and drops the capsules of actors that left or were disabled.
tick_actor_bodies :: proc(g: ^Game) {
	sp := active_space(g)
	if sp == nil || sp.phys == nil {return}
	phys := sp.phys
	t := time.tick_now()
	defer lap(g, .Actors, &t)
	cells := make([dynamic]Form_ID, 0, len(sp.cells), context.temp_allocator)
	for cell in sp.cells {append(&cells, cell)}
	nav.rebuild(&g.sim.agents.mesh, &g.db, cells[:]) // before new capsules are placed on it
	lap(g, .Nav, &t)
	ai.track_cells(&g.sim.agents, &g.sim.ws, &g.db, cells[:]) // pulls in actors whose package sends them to a cell that just loaded
	ai.skip_time(&g.sim.agents, &g.sim.ws, &g.db)
	seen := make(map[Form_ID]bool, context.temp_allocator)
	for id, &cell in sp.cells {
		for form in cell.actors {
			if d, ok := worldstate.get(&g.sim.ws, form); !ok || .Moved not_in d.live || d.cell == id {actor_body_keep(g, phys, form, &seen, &cell)}
		}
		for form in worldstate.created_in(&g.sim.ws, id) {actor_body_keep(g, phys, form, &seen, &cell)}
		for form in worldstate.refs_in(&g.sim.ws, id) {
			if d, _ := worldstate.get(&g.sim.ws, form); .Moved in d.live {actor_body_keep(g, phys, form, &seen, &cell)} // moved in by a script
		}
	}
	lap(g, .Actors, &t)
	detection.tick(&g.sim.detection, &g.sim.ws, &g.db, seen, TICK_DT) // before combat reads it
	lap(g, .Detection, &t)
	ai.set_present(&g.sim.agents, seen)
	worldstate.tick_crime(&g.sim.ws, &g.db, TICK_DT)
	lap(g, .Actors, &t)
	gone := make([dynamic]Form_ID, context.temp_allocator)
	for form, &b in g.sim.actor_bodies {
		if form in seen {
			touching := physics.character_touching(phys, &b.char)
			vel := ai.tick_loaded(&g.sim.agents, &g.sim.ws, &g.db, form, physics.character_position(&b.char), touching != 0, TICK_DT)
			if form == g.sim.carried.actor { // the dev carry pins it where main holds it
				physics.character_set_position(&b.char, g.sim.carried.at - {0, 0, b.capsule.half_h + b.capsule.radius})
				actor_publish(g, form, &b, {})
				continue
			}
			if seat, heading, ok := ai.seated(&g.sim.agents, &g.sim.ws, &g.db, form); ok { // pinned: no gravity or push-out
				if seat != b.placed {
					physics.character_set_position(&b.char, seat)
					actor_publish(g, form, &b, {}, heading)
				}
				continue
			}
			// (hole root-motion-velocity :tags (animation ai physics) :sev gap :needs (animation)) actor movement is only the AI velocity. Wanted: a set point where the clip's root motion replaces or scales vel before character_move.
			physics.character_move(phys, &b.char, vel, false, TICK_DT)
			if vel != {} {actor_publish(g, form, &b, vel)}
		} else {
			physics.character_destroy(&b.char)
			append(&gone, form)
		}
	}
	for form in gone {delete_key(&g.sim.actor_bodies, form)}
	clear(&g.sim.ws.ai.loaded)
	for form in g.sim.actor_bodies {g.sim.ws.ai.loaded[form] = true}
	g.sim.ws.ai.loaded[formid.PLAYER] = true // its capsule is g.sim.character (hole player-controller)
	lap(g, .AI, &t)
	ai.tick_social(&g.sim.agents, &g.sim.ws, &g.db, seen, TICK_DT)
	lap(g, .Social, &t)
	ai.tick_unloaded(&g.sim.agents, &g.sim.ws, &g.db, seen, TICK_DT)
	lap(g, .Offscreen, &t)
}

// Actor_Grab is the dev carry: hold DevGrabActor on an actor to carry its capsule at the crosshair,
// the wheel sets the reach, release drops it where it is.
Actor_Grab :: struct {
	actor: Form_ID,
	dist:  f32,
}

frame_actor_grab :: proc(g: ^Game) {
	if !input.held(&g.imgr, "DevGrabActor") || g.fr.kb_cap {
		if g.actor_grab.actor != 0 {push(&g.commands, Cmd_Release{g.actor_grab.actor})}
		g.actor_grab = {}
		return
	}
	ro, rd := camera_ray(g.cam, render.aspect(&g.r), {0, 0})
	if g.actor_grab.actor == 0 {
		form, dist, ok := pick_actor(g, ro, rd)
		if !ok {return}
		g.actor_grab = {form, clamp(dist, GRAB_MIN_DIST, GRAB_MAX_DIST)}
	}
	grab := &g.actor_grab
	grab.dist = clamp(grab.dist + g.p.input.scroll * GRAB_SCROLL, GRAB_MIN_DIST, GRAB_MAX_DIST)
	push(&g.commands, Cmd_Carry{grab.actor, ro + rd * grab.dist})
}

// actor_publish writes a walking actor's feet and heading into its ref's Moved delta, in the cell
// under it, so scripts and saves see where it is. It faces `face`, else the way it walks.
@(private = "file")
actor_publish :: proc(g: ^Game, form: Form_ID, b: ^Actor_Body, vel: [2]f32, face: Maybe(f32) = nil) {
	feet := physics.character_position(&b.char)
	cell := worldstate.ref_cell(&g.sim.ws, &g.db, form)
	if c, ok := g.db.cells[cell]; ok && c.world_form_id != 0 {
		if under := gamedb.cell_under(&g.db, c.world_form_id, feet); under != 0 {cell = under}
	}
	heading := worldstate.ref_rot(&g.sim.ws, &g.db, form).z
	if vel != {} {heading = math.PI / 2 - math.atan2(vel.y, vel.x)}
	if f, ok := face.?; ok {heading = f}
	worldstate.set_moved(&g.sim.ws, form, cell, smath.trs(feet, {0, 0, heading}, 1), feet)
	b.placed = feet
}

READY_RADIUS :: f32(1024) // collision this near must exist before a capsule appears
SPAWN_LIFT :: f32(32) // a placement or a walk between navmesh corners can sit under the ground; the capsule settles

@(private = "file")
actor_body_keep :: proc(g: ^Game, phys: ^physics.World, form: Form_ID, seen: ^map[Form_ID]bool, cell: ^world.Sim_Cell) {
	if form == formid.PLAYER || form in seen || !is_actor_ref(g, form) || !worldstate.ref_enabled(&g.sim.ws, &g.db, form) {return}
	seen[form] = true
	pos := worldstate.ref_pos(&g.sim.ws, &g.db, form)
	if form not_in g.sim.actor_bodies && !world.collision_ready_near(cell, pos, READY_RADIUS) {return} // loaded, waiting for the collision under it
	capsule := actor_capsule(g, form)
	if b, ok := &g.sim.actor_bodies[form]; ok && b.capsule == capsule {
		if b.placed != pos {
			physics.character_set_position(&b.char, pos)
			b.placed = pos
		}
		return
	} else if ok {
		physics.character_destroy(&b.char) // resized (SetScale): rebuild at the ref
	}
	start := pos
	switch p, placed := ai.place_on_load(&g.sim.agents, &g.sim.ws, &g.db, form, pos); placed {
	case .Stay:
	case .Here: start = p
	case .Away: return // it went on to its place in a cell that is not loaded
	}
	start = free_spot(g, phys, start, capsule)
	if ch, ok := physics.character_create(phys, start, capsule.radius, capsule.half_h, u64(form)); ok {
		g.sim.actor_bodies[form] = {char = ch, placed = pos, capsule = capsule}
		if start != pos {actor_publish(g, form, &g.sim.actor_bodies[form], {})}
	} else {
		delete_key(&g.sim.actor_bodies, form)
	}
}

// free_spot is where a capsule can appear without overlapping anything, lifted SPAWN_LIFT to settle:
// `feet`, else the nearest dry navmesh spot that fits. An overlap would be resolved by pushing the capsule out, often up onto
// the furniture it clipped.
@(private = "file")
free_spot :: proc(g: ^Game, phys: ^physics.World, feet: smath.Vec3, c: Capsule) -> smath.Vec3 {
	SEARCH :: 256
	lift := smath.Vec3{0, 0, SPAWN_LIFT}
	if physics.capsule_fits(phys, feet + lift, c.radius, c.half_h) {return feet + lift}
	for p in nav.dry_points_near(&g.sim.agents.mesh, feet, SEARCH) {
		if physics.capsule_fits(phys, p + lift, c.radius, c.half_h) {return p + lift}
	}
	return feet + lift
}

// actor_furniture_markers is ai.Furniture_Hook's markers: a FURN base's markers, from the collision store.
actor_furniture_markers :: proc(user: rawptr, base: Form_ID) -> []nif.Furniture_Marker {
	g := (^Game)(user)
	modl, ok := gamedb.model_of(&g.db, base)
	if !ok {return nil}
	return assetdb.furniture_markers(&g.collisions, modl)
}

@(private = "file")
is_actor_ref :: proc(g: ^Game, form: Form_ID) -> bool {
	return gamedb.is_actor(&g.db, worldstate.ref_base(&g.sim.ws, &g.db, form))
}

actor_bodies_clear :: proc(g: ^Game) {
	for _, &b in g.sim.actor_bodies {physics.character_destroy(&b.char)}
	clear(&g.sim.actor_bodies)
}

// Actor_View is an actor as the snapshot shows it to main.
Actor_View :: struct {
	form:    Form_ID,
	base:    Form_ID,
	feet:    Segment,
	capsule: Capsule,
	dead:    bool,
	combat:  ai.Combat_State,
	name:    Text_Span, // in Snapshot.text
}

// view_actors fills the snapshot's actor views from the sim's capsules.
view_actors :: proc(g: ^Game, s: ^Snapshot) {
	clear(&s.actors)
	for f, &b in g.sim.actor_bodies {
		from, to := physics.character_step(&b.char)
		append(&s.actors, Actor_View {
			form    = f,
			base    = worldstate.ref_base(&g.sim.ws, &g.db, f),
			feet    = {from, to},
			capsule = b.capsule,
			dead    = worldstate.is_dead(&g.sim.ws, &g.db, f),
			combat  = ai.combat_state(&g.sim.agents, f),
			name    = add_text(s, worldstate.display_name(&g.sim.ws, &g.db, f)),
		})
	}
}

// actor_box is the wire box drawn and picked for an actor capsule, from its feet to its top.
@(private = "file")
actor_box :: proc(g: ^Game, v: Actor_View, grow: f32 = 0) -> [2]smath.Vec3 {
	feet := blend(v.feet, g.fr.alpha)
	r := v.capsule.radius + grow
	return {feet - {r, r, grow}, feet + {r, r, 2 * (v.capsule.half_h + v.capsule.radius) + grow}}
}

// pick_actor is the nearest actor box along a ray.
pick_actor :: proc(g: ^Game, origin, dir: smath.Vec3) -> (form: Form_ID, dist: f32, ok: bool) {
	dist = max(f32)
	for v in g.snap.actors {
		box := actor_box(g, v)
		if t, hit := world.ray_aabb(origin, dir, box[0], box[1]); hit && t < dist {
			form, dist, ok = v.form, t, true
		}
	}
	return
}

// draw_actor_bodies draws each NPC capsule see-through in its own colour; the hovered one is near opaque.
draw_actor_bodies :: proc(g: ^Game, vp: smath.Mat4) {
	render.release_mesh(&g.r, g.actor_mesh)
	g.actor_mesh = {}
	if len(g.snap.actors) == 0 {return}
	Range :: struct {
		form:        Form_ID,
		first, count: u32,
		dead:        bool,
	}
	verts := make([dynamic]render.Mesh_Vertex, context.temp_allocator)
	idx := make([dynamic]u16, context.temp_allocator)
	ranges := make([dynamic]Range, context.temp_allocator)
	for v in g.snap.actors {
		if len(verts) > 60000 {break}
		first := u32(len(idx))
		emit_capsule(&verts, &idx, blend(v.feet, g.fr.alpha), v.capsule)
		append(&ranges, Range{v.form, first, u32(len(idx)) - first, v.dead})
	}
	g.actor_mesh = render.upload_mesh(&g.r, verts[:], idx[:])
	for rg in ranges {
		color := actor_color(rg.form, rg.dead)
		color.a = 0.9 if rg.form == g.hover_actor else 0.6
		render.draw_tint(&g.r, g.actor_mesh, vp, color, rg.first, rg.count)
	}
}

NAMETAG_RANGE :: f32(3000)
NAMETAG_PAD :: imgui.Vec2{4, 2}

// draw_actor_nametags floats each nearby actor's name above its capsule. Call before the frame
// renders, while the imgui frame is open.
draw_actor_nametags :: proc(g: ^Game) {
	w, h := ui_screen_size()
	vp := camera_view_proj(g.cam, render.aspect(&g.r))
	dl := imgui.GetBackgroundDrawList(imgui.GetMainViewport()) // no current window after a load screen closes the frame
	for v in g.snap.actors {
		feet := blend(v.feet, g.fr.alpha)
		if linalg.length(feet - g.cam.pos) > NAMETAG_RANGE {continue}
		top := feet + {0, 0, 2 * (v.capsule.half_h + v.capsule.radius) + 12}
		clip := vp * [4]f32{top.x, top.y, top.z, 1}
		if clip.w <= 0 {continue}
		name := fmt.ctprintf("%s (DEAD)" if v.dead else "%s", text(&g.snap, v.name))
		size := imgui.CalcTextSize(name)
		at := imgui.Vec2{(clip.x / clip.w * 0.5 + 0.5) * w - size.x / 2, (0.5 - clip.y / clip.w * 0.5) * h - size.y}
		imgui.DrawList_AddRectFilled(dl, at - NAMETAG_PAD, at + size + NAMETAG_PAD, 0xC000_0000, 3)
		imgui.DrawList_AddText(dl, at, ui_pack_color(actor_color(v.form, v.dead)), name)
		#partial switch v.combat {
		case .Combat: combat_marker(dl, {at.x + size.x / 2, at.y - NAMETAG_PAD.y - 4}, 0xFF20_20E0)
		case .Flee:   combat_marker(dl, {at.x + size.x / 2, at.y - NAMETAG_PAD.y - 4}, 0xFF20_D0F0)
		}
	}
}

// combat_marker is a downward triangle whose tip sits at `tip`: red in combat, yellow fleeing.
@(private = "file")
combat_marker :: proc(dl: ^imgui.DrawList, tip: imgui.Vec2, color: u32) {
	W, H :: 16, 26
	a, b := tip + {-W, -H}, tip + {W, -H}
	imgui.DrawList_AddTriangleFilled(dl, a, b, tip, color)
	imgui.DrawList_AddTriangle(dl, a, b, tip, 0xFF00_0000, 2)
}

// actor_color is a bright colour hashed from the form ID, so an actor keeps it across frames. The
// dead are grey.
@(private = "file")
actor_color :: proc(form: Form_ID, dead: bool) -> [4]f32 {
	if dead {return {0.5, 0.5, 0.5, 1}}
	hue := f32((u32(form) * 2654435761) >> 8) / (1 << 24) * 6
	x := 1 - abs(math.mod(hue, 2) - 1)
	rgb: [3]f32
	switch int(hue) {
	case 0: rgb = {1, x, 0}
	case 1: rgb = {x, 1, 0}
	case 2: rgb = {0, 1, x}
	case 3: rgb = {0, x, 1}
	case 4: rgb = {x, 0, 1}
	case:   rgb = {1, 0, x}
	}
	rgb = 0.25 + 0.75 * rgb
	return {rgb.r, rgb.g, rgb.b, 1}
}

// emit_capsule appends an upright capsule standing on `feet`: two hemispheres joined by a
// cylinder, as latitude rings wound counter-clockwise from outside.
@(private = "file")
emit_capsule :: proc(verts: ^[dynamic]render.Mesh_Vertex, idx: ^[dynamic]u16, feet: smath.Vec3, c: Capsule) {
	SEGS :: 16
	HEMI :: 6 // rings per hemisphere past the pole
	base := u16(len(verts))
	bottom := feet + {0, 0, c.radius}
	top := bottom + {0, 0, 2 * c.half_h}
	for ring in 0 ..= 2 * HEMI + 1 {
		upper := ring > HEMI
		lat := f32(ring - (HEMI + 1 if upper else HEMI)) * (math.PI / 2) / HEMI
		center := top if upper else bottom
		for seg in 0 ..< SEGS {
			lon := f32(seg) * 2 * math.PI / SEGS
			n := smath.Vec3{math.cos(lat) * math.cos(lon), math.cos(lat) * math.sin(lon), math.sin(lat)}
			append(verts, render.mesh_vertex(center + c.radius * n, n, {}))
		}
	}
	for ring in 0 ..< u16(2 * HEMI + 1) {
		for seg in 0 ..< u16(SEGS) {
			a := base + ring * SEGS + seg
			b := base + ring * SEGS + (seg + 1) % SEGS
			append(idx, a, b, b + SEGS, a, b + SEGS, a + SEGS)
		}
	}
}
