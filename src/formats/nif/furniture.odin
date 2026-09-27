package nif

Marker_Kind :: enum u16 {
	Sit  = 1,
	Lay  = 2,
	Lean = 4,
}

Entry_Point :: enum u16 {
	Front,
	Behind,
	Right,
	Left,
	Up,
}

// (hole furniture-marker-unknowns :tags ai :sev polish) unsourced: the heading's turn direction (assumed REFR z rotation; the data only shows 0 and pi clearly), and how FURN MNAM bits 0-23 (the markers turned on; build/out/wsI/formats.md) map to NIF marker indexes, which 12 records need (more NIF markers than FNPR entries).
// Furniture_Marker is one place to sit, lie or lean on a furniture model, in model space.
// The root node's transform does not apply to it (sovthrone01.nif: rotated root, heading still faces off the back).
Furniture_Marker :: struct {
	offset:  [3]f32,
	heading: f32, // radians about Z; 0 faces +Y
	kind:    Marker_Kind,
	entry:   bit_set[Entry_Point;u16], // sides an actor may walk up from
}

// furniture_markers is a model's furniture markers: the positions of every BSFurnitureMarker(Node)
// extra data block. Skyrim layout: name, count, then per position offset, heading, u16 kind, u16 entry.
furniture_markers :: proc(data: []u8, h: ^Header, allocator := context.allocator) -> []Furniture_Marker {
	out := make([dynamic]Furniture_Marker, allocator)
	for i in 0 ..< int(h.num_blocks) {
		t := block_type(h, i)
		if t != "BSFurnitureMarkerNode" && t != "BSFurnitureMarker" {continue}
		r := Reader{data = block_data(h, data, i), ok = true}
		_ = read_i32(&r) // name
		n := int(read_u32(&r))
		if !have(&r, n * 20) {continue}
		for _ in 0 ..< n {
			m: Furniture_Marker
			m.offset = read_vec3(&r)
			m.heading = read_f32(&r)
			m.kind = Marker_Kind(read_u16(&r))
			m.entry = transmute(bit_set[Entry_Point;u16])read_u16(&r)
			append(&out, m)
		}
	}
	return out[:]
}
