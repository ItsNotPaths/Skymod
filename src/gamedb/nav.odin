package gamedb

// Navmeshes (NAVM) and the navmesh index (NAVI). Same format in SE and LE (version 12).

// Nav_Tri is one navmesh triangle: its corners, and the triangle across each edge (-1 = none;
// an edge link to another navmesh sits in `edge_links`).
Nav_Tri :: struct {
	verts: [3]u16,
	adj:   [3]i16,
	flags: u16,
}

// Nav_Edge_Link joins a triangle edge to a triangle of another navmesh, often in the next cell.
Nav_Edge_Link :: struct {
	navmesh: Form_ID,
	tri:     u16,
	kind:    u8, // portal, ledge up, ledge down
}

// Nav_Door_Link is a triangle that leads through a load door.
Nav_Door_Link :: struct {
	tri:  u16,
	door: Form_ID,
}

Navmesh :: struct {
	form:       Form_ID,
	cell:       Form_ID,
	verts:      [][3]f32,
	tris:       []Nav_Tri,
	edge_links: []Nav_Edge_Link,
	door_links: []Nav_Door_Link,
}

// (hole navmesh :tags ai :sev blocker) NAVM is never decoded, so there is no navigable surface and nothing can path even once an agent exists. Measured (build/out/wsI/findings.md): SE 19,269 navmeshes, 3.18M tris, median 51, largest 3,342; skip cell 0x25 (505 unindexed duplicates). Decided: NAVM, not Recast (maybe a later experiment).
// navmeshes_in is every navmesh in a cell.
navmeshes_in :: proc(db: ^DB, cell: Form_ID) -> []Navmesh {
	return nil
}

// Nav_Index_Entry is one navmesh as the index sees it, enough to route across unloaded cells.
Nav_Index_Entry :: struct {
	cell:       Form_ID,
	center:     [3]f32,
	links:      []Form_ID, // navmeshes it touches through edge links
	door_links: []Form_ID, // load doors on it
}

// (hole navmesh-index :tags ai :sev blocker) NAVI 0x12FB4 is never decoded. Each plugin's override holds only the navmeshes it adds or edits (Skyrim 15,462 entries), so entries MERGE per navmesh across plugins; last-wins would lose Skyrim's.
// nav_index_entry is a navmesh's merged index entry.
nav_index_entry :: proc(db: ^DB, navmesh: Form_ID) -> (Nav_Index_Entry, bool) {
	return {}, false
}
