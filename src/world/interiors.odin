package world

// Open interiors (EXPERIMENTAL — behind settings `experimental_open_interiors`). Goal: walk
// through a load door with no load screen. The first approach (inlining the interior's REFRs
// into the exterior worldspace at a door-aligned offset) was abandoned — interiors don't fit
// or scale into the exterior space, so they came out chaotic. The PIVOT is PORTAL RENDERING:
// the interior stays in its own coordinate space and is rendered through the doorway from a
// virtual camera (render-to-texture), so nothing has to physically fit in the world.
//
// THIS FILE now owns just the door DISCOVERY + the door↔door transform that the portal renderer
// (forthcoming) consumes:
//   - build_portals (once at init): scan the whole worldspace's load-doors and register a Portal
//     for each whose destination is an interior. Whole-worldspace by necessity — a worldspace's
//     teleport doors are PERSISTENT refs collected into its persistent cell (Tamriel's is
//     0x00000D74, grid (0,0)) at their true world positions, NOT in the per-grid CELLs the
//     streamer loads, so the cell you stand in never carries its own doors. ~hundreds → cheap.
//   - Interior_Xform / xform_point: the rigid interior-local → world(door) transform. The portal
//     virtual camera = this transform (door-to-door) applied to the player's camera.
//
// A side-car: it never touches the streamer's grid logic.

import "core:log"
import "core:math"
import "core:strings"

import "../formats/nif"
import "../gamedb"
import smath "../math"
import "../render"
import "../vfs"

// Interior_Xform is the rigid interior-local → exterior(world) transform that aligns the
// interior's destination door with the exterior door: rotate by `yaw` about Z around the
// interior door (pivot) — the bare door-to-door facing rotation, see build_portals — then
// translate that door onto the exterior door. Z is a pure translate (worldspaces are
// gravity-aligned). The portal virtual camera inverts this to carry the player's eye + look
// into interior space.
Interior_Xform :: struct {
	yaw:     f32,
	int_org: smath.Vec3, // interior door position (pivot, interior-local)
	ext_org: smath.Vec3, // exterior door position (world)
}

// xform_point maps an interior-local point into exterior/world space.
xform_point :: proc(x: Interior_Xform, p: smath.Vec3) -> smath.Vec3 {
	c, s := math.cos(x.yaw), math.sin(x.yaw)
	d := p - x.int_org
	return smath.Vec3 {
		x.ext_org.x + d.x * c - d.y * s,
		x.ext_org.y + d.x * s + d.y * c,
		x.ext_org.z + d.z,
	}
}

// xform_inverse maps a world point back into interior-local space (inverse of xform_point) —
// used to carry the player's eye and the doorway rectangle into the interior's own coordinate
// space for the off-axis portal projection.
xform_inverse :: proc(x: Interior_Xform, p: smath.Vec3) -> smath.Vec3 {
	c, s := math.cos(-x.yaw), math.sin(-x.yaw)
	d := p - x.ext_org
	return smath.Vec3 {
		x.int_org.x + d.x * c - d.y * s,
		x.int_org.y + d.x * s + d.y * c,
		x.int_org.z + d.z,
	}
}

// Portal links one exterior load-door to the interior cell behind it. The off-axis portal needs
// just: where the doorway is (door_pos), which way it faces (ext_dir — marker-derived, horizontal,
// mesh-independent), the interior cell, and the world↔interior relay (xform). The interior-side
// window is the relay of the exterior doorway rectangle (built from door_pos+ext_dir), so it can't
// drift or mirror relative to the visible quad.
Portal :: struct {
	door_pos:   smath.Vec3, // exterior door world position (proximity + quad placement + window base)
	ext_dir:    smath.Vec3, // exterior door facing (horizontal, world) — from the teleport markers
	int_cell:   Form_ID, // interior cell behind the door
	xform:      Interior_Xform, // world ↔ interior relay (marker-based rotation + door-position anchor)
	tp_pos:     smath.Vec3, // arrival landing INSIDE the interior (interior coords) — the door panel sits here
	door_model: string, // exterior door mesh (gamedb path, borrowed) — for the aperture-aligned quad
	door_rot:   smath.Vec3, // exterior door REFR rotation (places the mesh aperture in world)
	door_scale: f32, // exterior door REFR scale
}

// Fallback doorway quad dimensions (world units) — used only if the door mesh's aperture can't
// be read. The accurate quad comes from the door panel's bounds via nif.aperture_rect (see
// build_portal_quad). BASE_DROP sinks the bottom edge slightly below the door REFR position.
PORTAL_HALF_W :: f32(36)
PORTAL_HEIGHT :: f32(140)
PORTAL_BASE_DROP :: f32(8)

// Interiors holds the discovered door→interior links AND the one interior currently rendered
// through its portal: a separate Scene (interior-LOCAL coords) loaded by proximity, plus the
// world-space doorway quad that masks the stencil. Borrows the exterior scene, db, streamer.
Interiors :: struct {
	scene:     ^Scene,
	db:        ^gamedb.DB,
	st:        ^Streamer,
	world_fid: Form_ID, // the worldspace whose load-doors we open (e.g. Tamriel)
	load_dist: f32, // how near a door before its interior view renders (portal renderer)
	portals:   map[Form_ID]Portal, // keyed by interior cell formID (one portal per interior)

	// The active portal's loaded interior (nil/empty when no door is in range).
	interior_scene: Scene,
	active:         bool,
	active_portal:  Portal,
	quad:           render.Mesh, // world-space doorway rectangle (stencil mask)
	has_quad:       bool,

	// Texture-based cull: interior shapes whose diffuse path contains any of these substrings
	// (case-insensitive) are skipped in the portal view — for clipping a door/aperture/black
	// occluder face by its texture (identified via the Inspector). Owned strings.
	cull_tex:       [dynamic]string,
}

interiors_init :: proc(
	m: ^Interiors,
	scene: ^Scene,
	db: ^gamedb.DB,
	st: ^Streamer,
	world_fid: Form_ID,
	load_dist: f32,
) {
	m.scene = scene
	m.db = db
	m.st = st
	m.world_fid = world_fid
	m.load_dist = load_dist
	m.portals = make(map[Form_ID]Portal)
	build_portals(m)
}

interiors_destroy :: proc(m: ^Interiors) {
	unload_interior(m)
	delete(m.portals)
	for t in m.cull_tex {
		delete(t)
	}
	delete(m.cull_tex)
	m^ = {}
}

// interiors_add_cull_tex marks a diffuse texture path (or substring) to skip in the portal
// view — the interactive "cull this texture" action. Stores a lowercased owned copy; ignores
// duplicates and empties.
interiors_add_cull_tex :: proc(m: ^Interiors, path: string) {
	if path == "" {
		return
	}
	low := strings.to_lower(path) // owned (context.allocator)
	for t in m.cull_tex {
		if t == low {
			delete(low)
			return
		}
	}
	append(&m.cull_tex, low)
	log.infof("interiors: portal cull texture added: %q (%d total)", low, len(m.cull_tex))
}

// shape_culled reports whether a shape's diffuse path matches any portal cull entry.
@(private = "file")
shape_culled :: proc(m: ^Interiors, diffuse_path: string) -> bool {
	if len(m.cull_tex) == 0 || diffuse_path == "" {
		return false
	}
	low := strings.to_lower(diffuse_path, context.temp_allocator)
	for t in m.cull_tex {
		if strings.contains(low, t) {
			return true
		}
	}
	return false
}

// interiors_update keeps the nearest in-range portal's interior loaded: when the closest
// portal door is within load_dist it (re)loads that interior into interior_scene (interior-
// LOCAL coords, own-door culled) and builds the doorway quad; when none is in range it
// unloads. Does GPU work (cell load) — call OUTSIDE begin_frame, like the streamer. Returns
// whether an interior is currently active (so the caller knows to issue the portal passes).
interiors_update :: proc(m: ^Interiors, cam_pos: smath.Vec3) -> bool {
	p, dist, ok := nearest_portal(m, cam_pos)
	if !ok || dist > m.load_dist {
		unload_interior(m)
		return false
	}
	if m.active && m.active_portal.int_cell == p.int_cell {
		return true // already the loaded interior
	}
	// A different (or first) portal is in range — swap the loaded interior. Door panels are
	// not hidden here: interiors_render skips ALL DOOR-record instances in the portal view
	// (so the door's solid black aperture face never fills the opening), while the "Load Into
	// Cell" walk-in still shows them for inspection.
	unload_interior(m)
	r, v := m.scene.cache.r, m.scene.cache.v
	m.interior_scene = scene_init(r, v)
	m.interior_scene.pretty = m.scene.pretty // inherit --pretty from the exterior
	load_cell(&m.interior_scene, m.db, p.int_cell)
	m.quad = build_portal_quad(r, v, p)
	m.has_quad = true
	m.active = true
	m.active_portal = p
	log.infof("interiors: portal to cell 0x%08X loaded (dist %.0f)", p.int_cell, dist)
	// DIAGNOSTIC: report every loaded instance gamedb flags as a DOOR (these are the ones the
	// portal view skips). If the door you see in the opening is NOT listed here, its base isn't
	// a DOOR record at runtime — which is why the is_door skip misses it.
	for _, &chunk in m.interior_scene.chunks {
		for &inst in chunk.instances {
			if gamedb.is_door(m.db, inst.base) {
				log.infof("  is_door base=0x%08X %q", inst.base, inst.model_path)
			}
		}
	}
	return true
}

// interiors_render issues the stencil-portal passes for the active interior: mark the doorway
// quad into the stencil (exterior `ext_vp`), reset depth in that region to far, then draw the
// interior cell's meshes from the relayed virtual camera (`relay_vp`) behind the stencil test.
// Call INSIDE begin_frame, AFTER the exterior opaque geometry. No-op when no interior is active.
interiors_render :: proc(m: ^Interiors, r: ^render.Renderer, ext_vp, relay_vp: smath.Mat4) {
	if !m.active || !m.has_quad || !render.portals_enabled(r) {
		return
	}
	render.draw_portal_mark(r, m.quad, ext_vp)
	render.draw_portal_reset(r, m.quad, ext_vp)
	for _, &chunk in m.interior_scene.chunks {
		for &inst in chunk.instances {
			if inst.vis != .Show || inst.model == nil {
				continue
			}
			// Heuristic door cull: skip every DOOR-record placement in the portal view — door
			// panels carry a solid black aperture face that would fill the opening. By RECORD
			// TYPE (gamedb.is_door), so it catches all door meshes but NOT doorway frames
			// (FarmIntDoorway*, which are STATs). General to every portal, no per-door tuning.
			if gamedb.is_door(m.db, inst.base) {
				continue
			}
			world := inst.world
			for sh in inst.model.shapes {
				if sh.is_effect {
					continue // interior FX (candle flames) deferred — no stencil+blend pass yet
				}
				if shape_culled(m, sh.diffuse_path) {
					continue // texture-culled occluder (door/aperture face), per the Inspector
				}
				model := world * sh.local
				render.draw_mesh_stencil(
					r,
					sh.mesh,
					relay_vp,
					model,
					sh.tex,
					sh.alpha_cutoff,
					normal = sh.normal,
					mat = shape_mat(sh),
				)
			}
		}
	}
}

// relay_view_proj builds the through-door VIRTUAL camera's view-projection: the player's eye
// + look relayed from world space into the portal's interior-local space (xform_inverse for
// the eye, a yaw rotation for the look direction), with the SAME perspective as the main
// camera. Rendering the interior with this gives correct parallax through the opening.
relay_view_proj :: proc(
	p: Portal,
	cam_pos, cam_fwd: smath.Vec3,
	aspect, fovy, near, far: f32,
	push: f32 = 0,
	yaw_offset: f32 = 0,
) -> smath.Mat4 {
	eye := xform_inverse(p.xform, cam_pos)
	// Keep the eye on the ROOM side of the doorway plane (through the interior door, normal =
	// into-room). The entrance wall sits in this plane; as the player moves, the relayed eye
	// would otherwise cross it and the wall fills the opening ("camera moves through the face").
	// Clamping the eye's depth to at least `push` past the plane keeps the wall behind the eye
	// while preserving lateral/vertical parallax. `push` is the depth margin (slider). `yaw_offset`
	// adds to the relayed look direction (facing fix).
	into := smath.normalize3(relay_dir(p.xform.yaw, p.ext_dir))
	into = smath.normalize3({into.x, into.y, 0})
	sd := smath.dot3(into, eye - p.xform.int_org) // signed depth past the doorway plane
	if sd < push {
		eye += smath.scale3(into, push - sd)
	}
	fwd := yaw_rotate(relay_dir(p.xform.yaw, cam_fwd), yaw_offset)
	view := smath.look_at_rh(eye, eye + fwd, {0, 0, 1})
	proj := smath.perspective_rh_zo(fovy, aspect, near, far)
	return proj * view
}

// into_room_dir is the horizontal direction pointing INTO the interior room, in interior-local
// coords (the exterior door faces ext_dir into the building; relayed into interior space). Used
// to orient the camera when loading into the cell.
into_room_dir :: proc(p: Portal) -> smath.Vec3 {
	d := relay_dir(p.xform.yaw, p.ext_dir)
	return smath.normalize3({d.x, d.y, 0})
}

// relay_dir rotates a world-space DIRECTION into interior-local space (by -yaw about Z, the
// rotation part of xform_inverse) — used for the relayed camera look direction.
@(private = "file")
relay_dir :: proc(yaw: f32, d: smath.Vec3) -> smath.Vec3 {
	c, s := math.cos(-yaw), math.sin(-yaw)
	return {d.x * c - d.y * s, d.x * s + d.y * c, d.z}
}

// yaw_rotate rotates a vector by `a` radians about +Z (the live facing-tuning offset).
@(private = "file")
yaw_rotate :: proc(d: smath.Vec3, a: f32) -> smath.Vec3 {
	c, s := math.cos(a), math.sin(a)
	return {d.x * c - d.y * s, d.x * s + d.y * c, d.z}
}

// build_portal_quad uploads the world-space doorway rectangle for the stencil mask. It prefers
// the ALIGNED quad: read the exterior door mesh, take the door panel's aperture rectangle
// (nif.aperture_rect, in door-local space), and place it with the door REFR's world transform —
// so the mask matches the actual door. Falls back to a synthetic rectangle (door_pos + ext_dir +
// fixed dims) if the mesh/aperture can't be read. Only position is read by the portal pipelines.
@(private = "file")
build_portal_quad :: proc(r: ^render.Renderer, v: ^vfs.VFS, p: Portal) -> render.Mesh {
	if p.door_model != "" {
		full := strings.concatenate({"meshes\\", p.door_model}, context.temp_allocator)
		if data, ok := vfs.read(v, full, context.temp_allocator); ok {
			if h, hok := nif.parse_header(data, context.temp_allocator); hok {
				if corners, aok := nif.aperture_rect(data, &h); aok {
					dw := smath.trs(p.door_pos, p.door_rot, p.door_scale)
					verts: [4]render.Mesh_Vertex
					uvs := [4][2]f32{{0, 1}, {1, 1}, {1, 0}, {0, 0}}
					for i in 0 ..< 4 {
						c := corners[i]
						w := dw * [4]f32{c[0], c[1], c[2], 1}
						verts[i] = render.mesh_vertex({w[0], w[1], w[2]}, p.ext_dir, uvs[i])
					}
					indices := [6]u16{0, 1, 2, 0, 2, 3}
					return render.upload_mesh(r, verts[:], indices[:])
				}
			}
		}
		log.warnf("interiors: aperture read failed for %q — synthetic portal quad", p.door_model)
	}
	// Fallback: a guessed rectangle from the door position + facing.
	up := smath.Vec3{0, 0, 1}
	right := smath.normalize3(smath.cross3(up, p.ext_dir))
	base := p.door_pos - smath.scale3(up, PORTAL_BASE_DROP)
	bl := base - smath.scale3(right, PORTAL_HALF_W)
	br := base + smath.scale3(right, PORTAL_HALF_W)
	tl := bl + smath.scale3(up, PORTAL_HEIGHT)
	tr := br + smath.scale3(up, PORTAL_HEIGHT)
	verts := [4]render.Mesh_Vertex {
		render.mesh_vertex(bl, p.ext_dir, {0, 1}),
		render.mesh_vertex(br, p.ext_dir, {1, 1}),
		render.mesh_vertex(tr, p.ext_dir, {1, 0}),
		render.mesh_vertex(tl, p.ext_dir, {0, 0}),
	}
	indices := [6]u16{0, 1, 2, 0, 2, 3}
	return render.upload_mesh(r, verts[:], indices[:])
}

// unload_interior frees the active interior scene + doorway quad (no-op when none is loaded).
@(private = "file")
unload_interior :: proc(m: ^Interiors) {
	if m.has_quad {
		render.release_mesh(m.scene.cache.r, m.quad)
		m.has_quad = false
	}
	if m.active {
		scene_destroy(&m.interior_scene)
		m.active = false
		m.active_portal = {}
	}
}

// Interiors_Stats is a snapshot for the debug overlay. nearest_dist is to the closest door.
Interiors_Stats :: struct {
	portals:      int,
	load_dist:    f32,
	nearest_dist: f32, // to the nearest portal door (max(f32) if no portals)
}

// interiors_stats snapshots the manager for the overlay relative to the player's position.
interiors_stats :: proc(m: ^Interiors, pos: smath.Vec3) -> Interiors_Stats {
	st := Interiors_Stats {
		portals      = len(m.portals),
		load_dist    = m.load_dist,
		nearest_dist = max(f32),
	}
	for _, p in m.portals {
		if d := smath.length3(p.door_pos - pos); d < st.nearest_dist {
			st.nearest_dist = d
		}
	}
	return st
}

// nearest_portal returns the portal whose door is closest to `pos`, and that distance.
// ok=false if there are no portals.
nearest_portal :: proc(m: ^Interiors, pos: smath.Vec3) -> (p: Portal, dist: f32, ok: bool) {
	best := max(f32)
	for _, portal in m.portals {
		if d := smath.length3(portal.door_pos - pos); d < best {
			best = d
			p = portal
			ok = true
		}
	}
	return p, best, ok
}

// --- internals ---

// build_portals discovers every load-door in the worldspace ONCE and registers a portal for
// each whose destination is an interior. Whole-worldspace (not per-streamed-cell) because the
// doors are PERSISTENT refs in the worldspace's persistent cell (see file header), absent from
// the per-grid CELLs the streamer loads. A portal's `ext_cell` is the GRID cell the door's
// world position falls in (the resident chunk that holds the building), NOT the persistent cell.
@(private = "file")
build_portals :: proc(m: ^Interiors) {
	doors, interiors := 0, 0
	for cid in gamedb.cells_of(m.db, m.world_fid) {
		for r in gamedb.refs_of(m.db, cid) {
			if !r.has_tp || gamedb.ref_effective_disabled(m.db, r) {
				continue
			}
			doors += 1
			int_door, ok := gamedb.ref_by_formid(m.db, r.teleport.door)
			if !ok {
				continue
			}
			cell, cok := gamedb.cell_by_formid(m.db, int_door.cell_form_id)
			if !cok || !cell.interior {
				continue // destination isn't an interior (exterior↔exterior / other worldspace)
			}
			if int_door.cell_form_id in m.portals {
				continue // interior already linked by another door — keep the first
			}
			door_pos := smath.Vec3(r.pos)
			// Alignment from the teleport landing MARKERS, not the door REFR rotations — the
			// exterior & interior doors are usually different MESHES with different local-normal
			// conventions, so door rotations are off by a mesh-dependent amount (90° in Riverwood).
			// The markers are designer-placed real geometry: r.teleport.pos is the spot just INSIDE,
			// int_door.teleport.pos the spot just OUTSIDE. Two horizontal unit directions:
			//   w  = exterior door − outside-landing  (world, points INTO the building)
			//   iv = interior door − inside-landing   (interior, points toward the threshold)
			// Relay rotation: R(iv) = -w. With the eye following the player (parallax), this lands
			// the OUTSIDE player's relayed eye on the THRESHOLD side of the interior door so the
			// off-axis frustum looks INTO the room. (The +w sense looked backward — verified live;
			// it only seemed right earlier while the eye was PINNED to a fixed side, which masked
			// the relay sign.) ext_dir = w gives the door's world facing for the visible quad.
			// Falls back to door rotations if the marker is missing/degenerate.
			yaw := r.rot[2] - int_door.rot[2]
			ext_dir := smath.Vec3{math.cos(r.rot[2]), math.sin(r.rot[2]), 0}
			if int_door.has_tp {
				wx := r.pos[0] - int_door.teleport.pos[0]
				wy := r.pos[1] - int_door.teleport.pos[1]
				ix := int_door.pos[0] - r.teleport.pos[0]
				iy := int_door.pos[1] - r.teleport.pos[1]
				if wx * wx + wy * wy > 1 && ix * ix + iy * iy > 1 {
					yaw = math.atan2(-wy, -wx) - math.atan2(iy, ix) // R(iv) = -w
					ext_dir = smath.normalize3({wx, wy, 0})
				}
			}
			door_model, _ := gamedb.model_of(m.db, r.base) // exterior door mesh (for the aperture quad)
			m.portals[int_door.cell_form_id] = Portal {
				door_pos = door_pos,
				ext_dir  = ext_dir,
				int_cell = int_door.cell_form_id,
				xform = Interior_Xform {
					yaw = yaw,
					int_org = smath.Vec3(int_door.pos),
					ext_org = door_pos,
				},
				// The exterior door teleports the player TO this spot just inside the interior —
				// interior coords, right at the interior door panel. The cull anchors on it.
				tp_pos = smath.Vec3(r.teleport.pos),
				// The exterior door REFR's mesh + placement — for the aperture-aligned portal quad.
				door_model = door_model,
				door_rot = smath.Vec3(r.rot),
				door_scale = r.scale,
			}
			interiors += 1
		}
	}
	log.infof(
		"interiors: discovered %d load-doors in worldspace 0x%08X -> %d unique interiors linked",
		doors,
		m.world_fid,
		interiors,
	)
}
