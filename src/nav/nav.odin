package nav

// Paths over NAVM. Fine paths run on the loaded cells' navmeshes, stitched by their edge links.
// Coarse routes run cell to cell on the NAVI index, for actors in unloaded cells.

import "../gamedb"

Form_ID :: gamedb.Form_ID

// Path_Mesh is the loaded cells' navmeshes as one walkable surface.
Path_Mesh :: struct {
	cells:  map[Form_ID]bool,
	meshes: [dynamic]gamedb.Navmesh,
}

// Corner is one point of a path. `door` is set where the path goes through a load door.
Corner :: struct {
	pos:  [3]f32,
	door: Form_ID,
}

// (hole nav-path :tags ai :sev blocker :needs navmesh) no path finding: wanted A* over triangles, then a funnel pass to corners; door links end a path at the door.
// rebuild stitches the navmeshes of `cells` into the mesh.
rebuild :: proc(m: ^Path_Mesh, db: ^gamedb.DB, cells: []Form_ID) {
}

// (hole nav-path) find_path always fails, so no mover has corners to follow.
// find_path writes the corners from `from` to `to` into `out`.
find_path :: proc(m: ^Path_Mesh, from, to: [3]f32, out: ^[dynamic]Corner) -> bool {
	return false
}

// Route_Step is one cell of a coarse route: the actor stays in `cell` until it can leave at `exit`.
Route_Step :: struct {
	cell: Form_ID,
	exit: [3]f32,
}

// (hole coarse-route :tags ai :sev gap :needs navmesh-index) no cell-to-cell route: wanted A* over NAVI entries (edge links across cell borders, door links into interiors).
// coarse_route is the cells from one place to another, each with the point where it is left.
coarse_route :: proc(db: ^gamedb.DB, from_cell: Form_ID, from: [3]f32, to_cell: Form_ID, to: [3]f32, allocator := context.allocator) -> []Route_Step {
	return nil
}
