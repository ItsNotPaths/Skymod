package esm

// Typed decoders for the record subset Iteration 1 (Milestone C) needs: CELL
// metadata, REFR placement + door teleport, and base-form model paths. These read
// fields already split by fields(); strings are returned as views into the field
// bytes (the caller clones what it keeps). Field layouts: UESP "Skyrim Mod:Mod File
// Format". Validated against the real Skyrim.esm (tools/esmdump).

import "core:encoding/endian"

// CELL DATA flags (first byte). 0x01 = interior cell.
CELL_INTERIOR :: 0x01

// Placement is a REFR's base reference + world transform. rot is XYZ euler radians;
// scale defaults to 1 when no XSCL field is present.
Placement :: struct {
	base:  u32,
	pos:   [3]f32,
	rot:   [3]f32,
	scale: f32,
}

// Teleport is a door REFR's XTEL: the destination door (in some cell) and the marker
// transform the player is placed at on the far side.
Teleport :: struct {
	door: u32,
	pos:  [3]f32,
	rot:  [3]f32,
}

// editor_id returns the record's EDID (editor id), or "" if absent.
editor_id :: proc(fields: []Field) -> string {
	if f, ok := find_field(fields, "EDID"); ok {
		return cstr(f.data)
	}
	return ""
}

// model_path returns the record's MODL mesh path (e.g. "Furniture\\...\\.nif"), or
// "" if absent. The path is archive-internal (under meshes\), backslash-separated.
model_path :: proc(fields: []Field) -> string {
	if f, ok := find_field(fields, "MODL"); ok {
		return cstr(f.data)
	}
	return ""
}

// cell_is_interior reports whether a CELL's DATA flags mark it interior.
cell_is_interior :: proc(fields: []Field) -> bool {
	if f, ok := find_field(fields, "DATA"); ok && len(f.data) >= 1 {
		return f.data[0] & CELL_INTERIOR != 0
	}
	return false
}

// cell_grid reads an exterior CELL's XCLC grid coordinates (X i32, Y i32 — each cell
// is 4096 units square in the worldspace). ok=false for interior cells (no XCLC).
cell_grid :: proc(fields: []Field) -> (x: i32, y: i32, ok: bool) {
	if f, fok := find_field(fields, "XCLC"); fok && len(f.data) >= 8 {
		return i32(rd32(f.data, 0)), i32(rd32(f.data, 4)), true
	}
	return 0, 0, false
}

// decode_refr reads a REFR's NAME (base), DATA (pos+rot) and optional XSCL (scale).
decode_refr :: proc(fields: []Field) -> Placement {
	p := Placement{scale = 1}
	if f, ok := find_field(fields, "NAME"); ok && len(f.data) >= 4 {
		p.base = rd32(f.data, 0)
	}
	if f, ok := find_field(fields, "DATA"); ok && len(f.data) >= 24 {
		p.pos = {rf32(f.data, 0), rf32(f.data, 4), rf32(f.data, 8)}
		p.rot = {rf32(f.data, 12), rf32(f.data, 16), rf32(f.data, 20)}
	}
	if f, ok := find_field(fields, "XSCL"); ok && len(f.data) >= 4 {
		p.scale = rf32(f.data, 0)
	}
	return p
}

// refr_teleport reads a REFR's XTEL door teleport, if present. XTEL = destination
// door formID (4) + position (12) + rotation (12); a trailing flags word (Skyrim) is
// ignored.
refr_teleport :: proc(fields: []Field) -> (Teleport, bool) {
	f, ok := find_field(fields, "XTEL")
	if !ok || len(f.data) < 28 {
		return {}, false
	}
	return Teleport {
			door = rd32(f.data, 0),
			pos = {rf32(f.data, 4), rf32(f.data, 8), rf32(f.data, 12)},
			rot = {rf32(f.data, 16), rf32(f.data, 20), rf32(f.data, 24)},
		},
		true
}

@(private)
rf32 :: proc(b: []u8, off: int) -> f32 {
	v, _ := endian.get_u32(b[off:off + 4], .Little)
	return transmute(f32)v
}
