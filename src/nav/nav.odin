package nav

// Paths over NAVM. Fine paths run on the loaded cells' navmeshes, stitched by their edge links.
// Coarse routes run cell to cell on the NAVI index, for actors in unloaded cells.

import pq "core:container/priority_queue"
import "core:math/linalg"
import "core:math/rand"
import "core:slice"
import "../formats/esm"
import "../gamedb"

Form_ID :: gamedb.Form_ID

// Path_Mesh is the loaded cells' navmeshes as one walkable surface. The geometry is borrowed from gamedb.
Path_Mesh :: struct {
	cells:   map[Form_ID]bool,
	meshes:  [dynamic]gamedb.Navmesh,
	by_form: map[Form_ID]int,
}

// Tri names one triangle: its mesh in the Path_Mesh and its index there.
Tri :: [2]i32

// rebuild stitches the navmeshes of `cells` into the mesh, if the set changed.
rebuild :: proc(m: ^Path_Mesh, db: ^gamedb.DB, cells: []Form_ID) {
	same := len(cells) == len(m.cells)
	for c in cells {same = same && c in m.cells}
	if same {return}
	clear(&m.cells)
	clear(&m.meshes)
	clear(&m.by_form)
	for c in cells {
		m.cells[c] = true
		for nm in gamedb.navmeshes_in(db, c) {
			m.by_form[nm.form] = len(m.meshes)
			append(&m.meshes, nm)
		}
	}
}

destroy :: proc(m: ^Path_Mesh) {
	delete(m.cells)
	delete(m.meshes)
	delete(m.by_form)
}

// find_path writes the corners from `from` to `to` into `out`, `to` last. Both ends snap to the
// nearest triangle, so an actor a little off the mesh still paths.
find_path :: proc(m: ^Path_Mesh, from, to: [3]f32, out: ^[dynamic][3]f32) -> bool {
	clear(out)
	start := nearest_tri(m, from) or_return
	goal := nearest_tri(m, to) or_return
	came := astar(m, start, goal) or_return
	portals := make([dynamic][2][3]f32, context.temp_allocator)
	append(&portals, [2][3]f32{from, from})
	walk := make([dynamic]Tri, context.temp_allocator)
	for t := goal; t != start; t = came[t] {append(&walk, t)}
	append(&walk, start)
	slice.reverse(walk[:])
	for i in 1 ..< len(walk) {append(&portals, portal(m, walk[i - 1], walk[i]))}
	append(&portals, [2][3]f32{to, to})
	funnel(portals[:], out)
	return true
}

// neighbors are the triangles across a triangle's edges, with the edge each crosses. Ledges are skipped.
@(private)
neighbors :: proc(m: ^Path_Mesh, t: Tri) -> (out: [3]Tri, edge: [3]int, n: int) {
	nm := &m.meshes[t.x]
	tri := nm.tris[t.y]
	for e in 0 ..< 3 {
		a := tri.adj[e]
		if a < 0 {continue}
		if tri.flags & (1 << u16(e)) == 0 {
			out[n], edge[n] = {t.x, i32(a)}, e
			n += 1
			continue
		}
		link := nm.edge_links[a]
		other, loaded := m.by_form[link.navmesh]
		if !loaded || link.kind != .Portal || int(link.tri) >= len(m.meshes[other].tris) {continue} // 36 vanilla links outlived an override
		out[n], edge[n] = {i32(other), i32(link.tri)}, e
		n += 1
	}
	return
}

@(private)
astar :: proc(m: ^Path_Mesh, start, goal: Tri) -> (came: map[Tri]Tri, ok: bool) {
	Open :: struct {
		tri:  Tri,
		f:    f32,
	}
	came = make(map[Tri]Tri, context.temp_allocator)
	cost := make(map[Tri]f32, context.temp_allocator)
	open: pq.Priority_Queue(Open)
	pq.init(&open, proc(a, b: Open) -> bool {return a.f < b.f}, pq.default_swap_proc(Open), allocator = context.temp_allocator)
	goal_at := center(m, goal)
	cost[start] = 0
	pq.push(&open, Open{start, 0})
	for pq.len(open) > 0 {
		cur := pq.pop(&open).tri
		if cur == goal {return came, true}
		at := center(m, cur)
		next, _, n := neighbors(m, cur)
		for nb in next[:n] {
			c := cost[cur] + linalg.distance(at, center(m, nb)) * (WATER_COST if water(m, nb) else 1)
			if old, seen := cost[nb]; seen && old <= c {continue}
			cost[nb] = c
			came[nb] = cur
			pq.push(&open, Open{nb, c + linalg.distance(center(m, nb), goal_at)})
		}
	}
	return came, false
}

WATER_COST :: f32(8) // a path wades only where the dry way is much longer

@(private)
water :: proc(m: ^Path_Mesh, t: Tri) -> bool {
	return m.meshes[t.x].tris[t.y].flags & esm.NAV_TRI_WATER != 0
}

// portal is the edge from `a` into `b` as (left, right), seen walking out of `a`.
@(private)
portal :: proc(m: ^Path_Mesh, a, b: Tri) -> [2][3]f32 {
	next, edge, n := neighbors(m, a)
	e := 0
	for i in 0 ..< n {if next[i] == b {e = edge[i]}}
	nm := &m.meshes[a.x]
	tri := nm.tris[a.y]
	p0, p1 := nm.verts[tri.verts[e]], nm.verts[tri.verts[(e + 1) % 3]]
	return {p1, p0} if area2(nm.verts[tri.verts[0]], nm.verts[tri.verts[1]], nm.verts[tri.verts[2]]) > 0 else {p0, p1}
}

// funnel pulls the string through the portals (the simple stupid funnel algorithm).
@(private)
funnel :: proc(portals: [][2][3]f32, out: ^[dynamic][3]f32) {
	apex, left, right := portals[0][0], portals[0][0], portals[0][1]
	apex_i, left_i, right_i := 0, 0, 0
	for i := 1; i < len(portals); i += 1 {
		l, r := portals[i][0], portals[i][1]
		if area2(apex, right, r) >= 0 {
			if apex == right || area2(apex, left, r) < 0 {
				right, right_i = r, i
			} else {
				append(out, left)
				apex, apex_i = left, left_i
				left, right, left_i, right_i = apex, apex, apex_i, apex_i
				i = apex_i
				continue
			}
		}
		if area2(apex, left, l) <= 0 {
			if apex == left || area2(apex, right, l) > 0 {
				left, left_i = l, i
			} else {
				append(out, right)
				apex, apex_i = right, right_i
				left, right, left_i, right_i = apex, apex, apex_i, apex_i
				i = apex_i
				continue
			}
		}
	}
	append(out, portals[len(portals) - 1][0])
}

// area2 is twice the signed XY area of abc: positive when c is left of a->b.
@(private)
area2 :: proc(a, b, c: [3]f32) -> f32 {
	return (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
}

@(private)
center :: proc(m: ^Path_Mesh, t: Tri) -> [3]f32 {
	nm := &m.meshes[t.x]
	v := nm.tris[t.y].verts
	return (nm.verts[v[0]] + nm.verts[v[1]] + nm.verts[v[2]]) / 3
}

// nearest_tri is the triangle under p, or failing that the one whose centre is nearest.
@(private)
nearest_tri :: proc(m: ^Path_Mesh, p: [3]f32) -> (best: Tri, ok: bool) {
	best_d := max(f32)
	for &nm, mi in m.meshes {
		for tri, ti in nm.tris {
			a, b, c := nm.verts[tri.verts[0]], nm.verts[tri.verts[1]], nm.verts[tri.verts[2]]
			s := area2(a, b, c)
			inside := s != 0 && area2(a, b, p) * s >= 0 && area2(b, c, p) * s >= 0 && area2(c, a, p) * s >= 0
			mid := (a + b + c) / 3
			d := abs(p.z - mid.z) if inside else 1e6 + linalg.distance(p, mid) // under p, only height separates floors
			if d < best_d {best, best_d, ok = {i32(mi), i32(ti)}, d, true}
		}
	}
	return
}

// Route_Step is one cell of a coarse route: the actor crosses `cell` and leaves it at `exit`,
// through `door` when that is set. The last step ends at the destination.
Route_Step :: struct {
	cell: Form_ID,
	exit: [3]f32,
	door: Form_ID,
}

// Route_Index maps each load door to the navmesh it stands on, and each navmesh to the island
// of navmeshes it connects to (through portals and doors). Built once.
Route_Index :: struct {
	door_mesh: map[Form_ID]Form_ID,
	island:    map[Form_ID]int,
}

route_index_destroy :: proc(r: ^Route_Index) {
	delete(r.door_mesh)
	delete(r.island)
}

@(private = "file")
route_index_build :: proc(r: ^Route_Index, db: ^gamedb.DB) {
	for _, list in db.navmeshes {
		for m in list {
			for d in m.door_links {r.door_mesh[d.door] = m.form}
		}
	}
	stack := make([dynamic]Form_ID, context.temp_allocator)
	for _, list in db.navmeshes {
		for m in list {
			if m.form in r.island {continue}
			id := len(r.island)
			append(&stack, m.form)
			for len(stack) > 0 {
				cur := pop(&stack)
				if cur in r.island {continue}
				r.island[cur] = id
				geo := gamedb.navmesh_of(db, cur) or_continue
				for e in geo.edge_links {if e.kind == .Portal {append(&stack, e.navmesh)}}
				for dl in geo.door_links {
					if other, ok := door_leads_to(r, db, dl.door); ok {append(&stack, other)}
				}
			}
		}
	}
}

// door_leads_to is the navmesh a load door's destination door stands on.
@(private = "file")
door_leads_to :: proc(r: ^Route_Index, db: ^gamedb.DB, door: Form_ID) -> (mesh: Form_ID, ok: bool) {
	d := gamedb.ref_by_formid(db, door) or_return
	dest := gamedb.ref_by_formid(db, d.teleport.door) or_return
	return r.door_mesh[dest.form_id]
}

DOOR_COST :: f32(512) // a door crossing, in units walked

// Hop is one navmesh of a route, and the load door crossed to reach it (0 = walked in).
Hop :: struct {
	mesh, door: Form_ID,
}

// navmesh_route is the navmeshes from one place to another (Dijkstra): NAVM portal links, and load
// doors to the navmesh their destination door stands on. Nodes sit at their NAVI centre; NAVI's
// own link lists are sparse. Exterior places take their grid cell.
navmesh_route :: proc(r: ^Route_Index, db: ^gamedb.DB, from_cell: Form_ID, from: [3]f32, to_cell: Form_ID, to: [3]f32, allocator := context.allocator) -> (route: []Hop, ok: bool) {
	if len(r.island) == 0 {route_index_build(r, db)}
	start := navmesh_near(db, from_cell, from) or_return
	goal := navmesh_near(db, to_cell, to) or_return
	if r.island[start] != r.island[goal] {return}
	Came :: struct {
		prev, door: Form_ID,
	}
	Open :: struct {
		mesh: Form_ID,
		cost: f32,
	}
	came := make(map[Form_ID]Came, context.temp_allocator)
	cost := make(map[Form_ID]f32, context.temp_allocator)
	open: pq.Priority_Queue(Open)
	pq.init(&open, proc(a, b: Open) -> bool {return a.cost < b.cost}, pq.default_swap_proc(Open), allocator = context.temp_allocator)
	cost[start] = 0
	pq.push(&open, Open{start, 0})
	relax :: proc(open: ^pq.Priority_Queue(Open), cost: ^map[Form_ID]f32, came: ^map[Form_ID]Came, next: Form_ID, c: f32, from: Came) {
		if old, seen := cost[next]; seen && old <= c {return}
		cost[next] = c
		came[next] = from
		pq.push(open, Open{next, c})
	}
	for pq.len(open) > 0 {
		cur := pq.pop(&open)
		if cur.mesh == goal {break}
		if cur.cost > cost[cur.mesh] {continue}
		n := gamedb.nav_index_entry(db, cur.mesh) or_continue
		geo := gamedb.navmesh_of(db, cur.mesh) or_continue
		for e in geo.edge_links {
			if e.kind != .Portal {continue}
			m := gamedb.nav_index_entry(db, e.navmesh) or_continue
			relax(&open, &cost, &came, e.navmesh, cur.cost + linalg.distance(n.center, m.center), {cur.mesh, 0})
		}
		for dl in geo.door_links {
			other := door_leads_to(r, db, dl.door) or_continue
			door, _ := gamedb.ref_by_formid(db, dl.door)
			dest, _ := gamedb.ref_by_formid(db, door.teleport.door)
			m := gamedb.nav_index_entry(db, other) or_continue
			c := cur.cost + linalg.distance(n.center, door.pos) + DOOR_COST + linalg.distance(dest.pos, m.center)
			relax(&open, &cost, &came, other, c, {cur.mesh, dl.door})
		}
	}
	if goal != start && goal not_in came {return}
	hops := make([dynamic]Hop, allocator)
	for m := goal; m != start; m = came[m].prev {append(&hops, Hop{m, came[m].door})}
	append(&hops, Hop{start, 0})
	slice.reverse(hops[:])
	return hops[:], true
}

// coarse_route is the cells from one place to another, each left at the next cell's navmesh
// centre or through a load door.
coarse_route :: proc(r: ^Route_Index, db: ^gamedb.DB, from_cell: Form_ID, from: [3]f32, to_cell: Form_ID, to: [3]f32, allocator := context.allocator) -> (route: []Route_Step, ok: bool) {
	hops := navmesh_route(r, db, from_cell, from, to_cell, to, context.temp_allocator) or_return
	steps := make([dynamic]Route_Step, allocator)
	for i in 1 ..< len(hops) {
		a, _ := gamedb.nav_index_entry(db, hops[i - 1].mesh)
		b, _ := gamedb.nav_index_entry(db, hops[i].mesh)
		if hops[i].door != 0 {
			d, _ := gamedb.ref_by_formid(db, hops[i].door)
			append(&steps, Route_Step{a.cell, d.pos, hops[i].door})
		} else if a.cell != b.cell {
			append(&steps, Route_Step{a.cell, b.center, 0})
		}
	}
	append(&steps, Route_Step{to_cell, to, 0})
	return steps[:], true
}

// Trip_Point is a corner of a walk across any cells. `jump` is reached through a load door, not walked.
Trip_Point :: struct {
	pos:  [3]f32,
	cell: Form_ID,
	jump: bool,
}

// trip is the fine walk from one place to another, loaded or not: A* and funnel over the route's
// navmeshes, one leg per load door. A leg with no path goes straight.
trip :: proc(r: ^Route_Index, db: ^gamedb.DB, from_cell: Form_ID, from: [3]f32, to_cell: Form_ID, to: [3]f32, allocator := context.allocator) -> (points: []Trip_Point, ok: bool) {
	hops := navmesh_route(r, db, from_cell, from, to_cell, to, context.temp_allocator) or_return
	out := make([dynamic]Trip_Point, allocator)
	start, jump := from, false
	for i := 0; i < len(hops); {
		j := i + 1
		for j < len(hops) && hops[j].door == 0 {j += 1}
		end := to
		door: gamedb.Ref
		if j < len(hops) {door, _ = gamedb.ref_by_formid(db, hops[j].door); end = door.pos}
		leg(db, hops[i:j], start, end, jump, &out)
		start, jump = door.teleport.pos, true
		i = j
	}
	return out[:], true
}

// leg walks one door-free stretch of a trip over its navmeshes.
@(private = "file")
leg :: proc(db: ^gamedb.DB, hops: []Hop, from, to: [3]f32, jump: bool, out: ^[dynamic]Trip_Point) {
	m := Path_Mesh {
		cells   = make(map[Form_ID]bool, context.temp_allocator),
		meshes  = make([dynamic]gamedb.Navmesh, context.temp_allocator),
		by_form = make(map[Form_ID]int, context.temp_allocator),
	}
	for h in hops {
		if h.mesh in m.by_form {continue}
		nm := gamedb.navmesh_of(db, h.mesh) or_continue
		m.by_form[h.mesh] = len(m.meshes)
		append(&m.meshes, nm)
	}
	if len(m.meshes) == 0 {return}
	cell, _ := gamedb.cell_by_formid(db, m.meshes[0].cell)
	at :: proc(db: ^gamedb.DB, cell: gamedb.Cell, p: [3]f32) -> Form_ID {
		return cell.form_id if cell.interior else gamedb.cell_under(db, cell.world_form_id, p)
	}
	append(out, Trip_Point{from, at(db, cell, from), jump})
	corners := make([dynamic][3]f32, context.temp_allocator)
	if !find_path(&m, from, to, &corners) {append(&corners, to)}
	for p in corners {append(out, Trip_Point{p, at(db, cell, p), false})}
}

// navmesh_near is the navmesh of a cell whose centre is nearest p.
@(private)
navmesh_near :: proc(db: ^gamedb.DB, cell: Form_ID, p: [3]f32) -> (best: Form_ID, ok: bool) {
	best_d := max(f32)
	for m in gamedb.navmeshes_in(db, cell) {
		n := gamedb.nav_index_entry(db, m.form) or_continue
		if d := linalg.distance(n.center, p); d < best_d {best, best_d, ok = m.form, d, true}
	}
	return
}

// random_point_near is the centre of a random dry triangle whose centre lies within radius of p.
random_point_near :: proc(m: ^Path_Mesh, p: [3]f32, radius: f32) -> (point: [3]f32, ok: bool) {
	seen := 0
	for &nm, mi in m.meshes {
		for tri, ti in nm.tris {
			c := center(m, {i32(mi), i32(ti)})
			if tri.flags & esm.NAV_TRI_WATER != 0 || linalg.length(c.xy - p.xy) > radius {continue}
			seen += 1
			if rand.int_max(seen) == 0 {point, ok = c, true} // reservoir pick
		}
	}
	return
}
