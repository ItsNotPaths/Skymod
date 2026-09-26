package nif

// Furniture_Marker is one place to sit, lie or lean on a furniture model, in model space.
Furniture_Marker :: struct {
	offset:  [3]f32,
	heading: f32, // radians about Z
	kind:    u8, // sit, lay, lean
}

// (hole furniture-markers :tags ai :sev gap) BSFurnitureMarkerNode is never read, so no actor knows where on a bed or chair to go or which way to face (FURN 515 records, 14,397 placed; IDLM 7,402 placed).
// furniture_markers is a model's furniture markers.
furniture_markers :: proc(data: []u8, h: ^Header, allocator := context.allocator) -> []Furniture_Marker {
	return nil
}
