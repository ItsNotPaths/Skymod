package esm

// NAVM navmesh geometry (NVNM, version 12; same in SE and LE). Layout: xEdit wbDefinitionsTES5,
// validated by parsing every vanilla NAVM with 0 bytes left over (build/out/wsI/navm.py).

// Nav_Tri flag bit i marks edge i as leading to another navmesh: its `adj` is then an index into
// `edge_links`, not a triangle.
NAV_TRI_WATER :: 0x200 // 98% of these lie under their cell's water plane, 7% of the rest

Nav_Tri :: struct {
	verts: [3]u16,
	adj:   [3]i16, // the triangle across each edge; -1 = open border
	flags: u16,
}

Nav_Edge_Kind :: enum u8 {
	Portal,
	Ledge_Up,
	Ledge_Down,
}

Nav_Edge_Link :: struct {
	navmesh: Form_ID,
	tri:     u16,
	kind:    Nav_Edge_Kind,
}

Nav_Door_Link :: struct {
	tri:  u16,
	door: Form_ID,
}

// Navmesh is one NAVM. Form IDs are raw until the caller remaps them.
Navmesh :: struct {
	verts:      [][3]f32,
	tris:       []Nav_Tri,
	edge_links: []Nav_Edge_Link,
	door_links: []Nav_Door_Link,
}

navmesh :: proc(fields: []Field, allocator := context.allocator) -> (m: Navmesh, ok: bool) {
	defer if !ok {
		destroy_navmesh(m, allocator)
		m = {}
	}
	f := find_field(fields, "NVNM") or_return
	b := f.data
	if len(b) < 20 || rd32(b, 0) != 12 {return}
	o := 16 // version, magic, worldspace, grid or cell
	count :: proc(b: []u8, o: ^int, size: int) -> (n: int, ok: bool) {
		if o^ + 4 > len(b) {return}
		n = int(rd32(b, o^))
		o^ += 4
		return n, o^ + n * size <= len(b)
	}
	nv := count(b, &o, 12) or_return
	m.verts = make([][3]f32, nv, allocator)
	for &v in m.verts {
		v = {rf32(b, o), rf32(b, o + 4), rf32(b, o + 8)}
		o += 12
	}
	nt := count(b, &o, 16) or_return
	m.tris = make([]Nav_Tri, nt, allocator)
	for &t in m.tris {
		t = {
			verts = {rd16(b, o), rd16(b, o + 2), rd16(b, o + 4)},
			adj   = {i16(rd16(b, o + 6)), i16(rd16(b, o + 8)), i16(rd16(b, o + 10))},
			flags = rd16(b, o + 12),
		}
		o += 16
	}
	ne := count(b, &o, 10) or_return
	m.edge_links = make([]Nav_Edge_Link, ne, allocator)
	for &e in m.edge_links {
		e = {navmesh = Form_ID(rd32(b, o + 4)), tri = rd16(b, o + 8), kind = Nav_Edge_Kind(min(rd32(b, o), 2))}
		o += 10
	}
	nd := count(b, &o, 10) or_return
	m.door_links = make([]Nav_Door_Link, nd, allocator)
	for &d in m.door_links {
		d = {tri = rd16(b, o), door = Form_ID(rd32(b, o + 6))}
		o += 10
	}
	return m, true
}

destroy_navmesh :: proc(m: Navmesh, allocator := context.allocator) {
	delete(m.verts, allocator)
	delete(m.tris, allocator)
	delete(m.edge_links, allocator)
	delete(m.door_links, allocator)
}

// Nav_Info is one NAVI entry: a navmesh as the global index sees it. Form IDs are raw.
Nav_Info :: struct {
	navmesh:    Form_ID,
	center:     [3]f32,
	edge_links: []Form_ID, // navmeshes it touches
	door_links: []Form_ID, // load door refs on it
	world:      Form_ID, // 0 = interior; then `cell` holds the cell
	grid:       [2]i16, // exterior grid x, y
	cell:       Form_ID,
}

// navmesh_infos decodes NAVI's NVMI entries and its NVSI deleted-navmesh list.
navmesh_infos :: proc(fields: []Field, allocator := context.allocator) -> (infos: []Nav_Info, deleted: []Form_ID) {
	out := make([dynamic]Nav_Info, allocator)
	del := make([dynamic]Form_ID, allocator)
	for f in fields {
		switch f.type {
		case "NVMI":
			if n, ok := nav_info(f.data, allocator); ok {append(&out, n)}
		case "NVSI":
			for o := 0; o + 4 <= len(f.data); o += 4 {append(&del, Form_ID(rd32(f.data, o)))}
		}
	}
	return out[:], del[:]
}

destroy_nav_info :: proc(n: Nav_Info, allocator := context.allocator) {
	delete(n.edge_links, allocator)
	delete(n.door_links, allocator)
}

@(private = "file")
nav_info :: proc(b: []u8, allocator := context.allocator) -> (n: Nav_Info, ok: bool) {
	defer if !ok {
		destroy_nav_info(n, allocator)
		n = {}
	}
	if len(b) < 28 {return}
	n.navmesh = Form_ID(rd32(b, 0))
	n.center = {rf32(b, 8), rf32(b, 12), rf32(b, 16)}
	o := 24
	ids :: proc(b: []u8, o: ^int, stride, at: int, allocator := context.allocator) -> (out: []Form_ID, ok: bool) {
		if o^ + 4 > len(b) {return}
		c := int(rd32(b, o^))
		o^ += 4
		if o^ + c * stride > len(b) {return}
		out = make([]Form_ID, c, allocator)
		for &id, i in out {id = Form_ID(rd32(b, o^ + i * stride + at))}
		o^ += c * stride
		return out, true
	}
	n.edge_links = ids(b, &o, 4, 0, allocator) or_return
	if o + 4 > len(b) {return}
	o += 4 + int(rd32(b, o)) * 4 // preferred edge links, a subset of edge_links
	n.door_links = ids(b, &o, 8, 4, allocator) or_return
	if o >= len(b) {return}
	if b[o] != 0 { // island data: bounds, triangles, vertices
		o += 1 + 24
		if o + 4 > len(b) {return}
		o += 4 + int(rd32(b, o)) * 6
		if o + 4 > len(b) {return}
		o += 4 + int(rd32(b, o)) * 12
	} else {
		o += 1
	}
	if o + 12 > len(b) {return}
	n.world = Form_ID(rd32(b, o + 4))
	if n.world != 0 {
		n.grid = {i16(rd16(b, o + 10)), i16(rd16(b, o + 8))}
	} else {
		n.cell = Form_ID(rd32(b, o + 8))
	}
	return n, true
}
