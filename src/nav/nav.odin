package nav

// Paths over NAVM. Fine paths run on the loaded cells' navmeshes, stitched by their edge links.
// Coarse routes run cell to cell on the NAVI index, for actors in unloaded cells.

import pq "core:container/priority_queue"
import "core:math/linalg"
import "core:math/rand"
import "core:slice"
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
		if !loaded || link.kind != .Portal {continue}
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
			c := cost[cur] + linalg.distance(at, center(m, nb))
			if old, seen := cost[nb]; seen && old <= c {continue}
			cost[nb] = c
			came[nb] = cur
			pq.push(&open, Open{nb, c + linalg.distance(center(m, nb), goal_at)})
		}
	}
	return came, false
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

// Route_Step is one cell of a coarse route: the actor stays in `cell` until it can leave at `exit`.
Route_Step :: struct {
	cell: Form_ID,
	exit: [3]f32,
}

// (hole coarse-route :tags ai :sev gap) no cell-to-cell route: wanted A* over NAVI entries (edge links across cell borders, door links into interiors).
// coarse_route is the cells from one place to another, each with the point where it is left.
coarse_route :: proc(db: ^gamedb.DB, from_cell: Form_ID, from: [3]f32, to_cell: Form_ID, to: [3]f32, allocator := context.allocator) -> []Route_Step {
	return nil
}

// random_point_near is the centre of a random triangle whose centre lies within radius of p.
random_point_near :: proc(m: ^Path_Mesh, p: [3]f32, radius: f32) -> (point: [3]f32, ok: bool) {
	seen := 0
	for &nm, mi in m.meshes {
		for _, ti in nm.tris {
			c := center(m, {i32(mi), i32(ti)})
			if linalg.length(c.xy - p.xy) > radius {continue}
			seen += 1
			if rand.int_max(seen) == 0 {point, ok = c, true} // reservoir pick
		}
	}
	return
}
