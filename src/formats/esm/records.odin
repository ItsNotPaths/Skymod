package esm

// Typed decoders for the record subset Iteration 1 (Milestone C) needs: CELL
// metadata, REFR placement + door teleport, and base-form model paths. These read
// fields already split by fields(); strings are returned as views into the field
// bytes (the caller clones what it keeps). Field layouts: UESP "Skyrim Mod:Mod File
// Format". Validated against the real Skyrim.esm (tools/esmdump).

import "core:encoding/endian"
import "core:math"

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

// object_bounds reads a base form's OBND (object bounds): 6 i16 = min(x,y,z) + max(x,y,z).
// Returns a bounding RADIUS (half the box diagonal, in world units) — a cheap size proxy
// for distance/LOD culling WITHOUT loading the mesh. ok=false if absent/short.
object_bounds :: proc(fields: []Field) -> (radius: f32, ok: bool) {
	f, fok := find_field(fields, "OBND")
	if !fok || len(f.data) < 12 {
		return 0, false
	}
	x1 := f32(transmute(i16)rd16(f.data, 0))
	y1 := f32(transmute(i16)rd16(f.data, 2))
	z1 := f32(transmute(i16)rd16(f.data, 4))
	x2 := f32(transmute(i16)rd16(f.data, 6))
	y2 := f32(transmute(i16)rd16(f.data, 8))
	z2 := f32(transmute(i16)rd16(f.data, 10))
	dx, dy, dz := x2 - x1, y2 - y1, z2 - z1
	return 0.5 * math.sqrt(dx * dx + dy * dy + dz * dz), true
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

// WATER_NONE is the XCLW "no override" sentinel (FLT_MAX): the cell defers to its
// worldspace's default water height. Bit pattern 0x7F7FFFFF == max(f32).
WATER_NONE :: max(f32)

// WATER_MAX_PLAUSIBLE bounds a real water height. Besides WATER_NONE, Skyrim cells carry
// other "no water" markers in XCLW (observed 0xCF000000 = −2³¹, and a positive ~4.3e9),
// which are NOT sea levels — they'd float a plane in the sky. Any |XCLW| above this bound
// is treated as "no water". Real Skyrim heights sit well under ±100k, so 1e6 is safe.
WATER_MAX_PLAUSIBLE :: f32(1e6)

// cell_water_height reads a CELL's XCLW (water height, f32). The returned value may be
// the WATER_NONE sentinel (FLT_MAX) — meaning "use the worldspace default"; the caller
// resolves that. ok=false when the cell has no XCLW at all (no water).
cell_water_height :: proc(fields: []Field) -> (f32, bool) {
	if f, ok := find_field(fields, "XCLW"); ok && len(f.data) >= 4 {
		return rf32(f.data, 0), true
	}
	return 0, false
}

// cell_water_type reads a CELL's XCWT — the formID of the WATR water type painted in
// this cell (river/ocean/marsh; governs the eventual water appearance). ok=false if
// absent (the cell either has no water or falls back to the worldspace default type).
cell_water_type :: proc(fields: []Field) -> (u32, bool) {
	if f, ok := find_field(fields, "XCWT"); ok && len(f.data) >= 4 {
		return rd32(f.data, 0), true
	}
	return 0, false
}

// world_water_height reads a WRLD's default water height — the level a cell's XCLW
// sentinel (WATER_NONE) resolves to (e.g. Tamriel's −14000 sea level). Prefers NAM4
// (LOD water height, the authoritative sea level), else DNAM's second f32
// ({defaultLandHeight, defaultWaterHeight}). ok=false if neither is present.
world_water_height :: proc(fields: []Field) -> (f32, bool) {
	if f, ok := find_field(fields, "NAM4"); ok && len(f.data) >= 4 {
		return rf32(f.data, 0), true
	}
	if f, ok := find_field(fields, "DNAM"); ok && len(f.data) >= 8 {
		return rf32(f.data, 4), true
	}
	return 0, false
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

// LAND_GRID is the side length of a cell's heightmap vertex grid (33×33 = 1089
// vertices → 32×32 quads spanning the 4096-unit cell).
LAND_GRID :: 33

// land_heights decodes a LAND record's VHGT heightmap into a row-major LAND_GRID²
// grid of CUMULATIVE height values (the gradient sum, NOT yet world-scaled — the
// caller multiplies by its height scale). VHGT = base offset f32 + LAND_GRID²
// signed-byte gradients (row-major) + 3 pad bytes. Each gradient is a delta: the
// first column of each row is relative to the previous row's first column, and
// every other cell is relative to the previous cell in its row. ok=false if there's
// no VHGT or it's truncated. Ref: UESP "Skyrim Mod:Mod File Format/LAND".
land_heights :: proc(fields: []Field, allocator := context.allocator) -> ([]f32, bool) {
	f, ok := find_field(fields, "VHGT")
	if !ok || len(f.data) < 4 + LAND_GRID * LAND_GRID {
		return nil, false
	}
	offset := rf32(f.data, 0)
	grad := f.data[4:]
	out := make([]f32, LAND_GRID * LAND_GRID, allocator)
	col0 := offset
	for y in 0 ..< LAND_GRID {
		col0 += f32(transmute(i8)grad[y * LAND_GRID]) // first column: delta from previous row
		h := col0
		out[y * LAND_GRID] = h
		for x in 1 ..< LAND_GRID {
			h += f32(transmute(i8)grad[y * LAND_GRID + x]) // delta from previous cell in row
			out[y * LAND_GRID + x] = h
		}
	}
	return out, true
}

// land_base_textures reads a LAND record's BTXT base-texture references — the bottom
// landscape layer of each of the cell's 4 quadrants (0=SW, 1=SE, 2=NW, 3=NE). Each
// BTXT is 8 bytes: LTEX formID (u32) + quadrant (u8) + unused (u8) + layer (i16).
// Returns the LTEX formID per quadrant; 0 where a quadrant has no base. (Additional
// ATXT/VTXT alpha layers are deferred to the blending step.)
land_base_textures :: proc(fields: []Field) -> [4]u32 {
	out: [4]u32
	for f in fields {
		if f.type == "BTXT" && len(f.data) >= 8 {
			q := f.data[4]
			if q < 4 {
				out[q] = rd32(f.data, 0)
			}
		}
	}
	return out
}

// Land_Alpha is one painted opacity sample of an ATXT layer: which point in the 17×17
// quadrant grid (0-288, row-major y·17+x) and how opaque the layer is there.
Land_Alpha :: struct {
	point:   u16,
	opacity: f32,
}

// Land_Layer is one landscape texture layer of a LAND quadrant: the LTEX form and, for
// additional (ATXT) layers, the per-point alpha that paints it over the layers below.
// Base (BTXT) layers cover their whole quadrant (alpha empty). quadrant is 0=SW,1=SE,
// 2=NW,3=NE.
Land_Layer :: struct {
	ltex:     u32,
	quadrant: u8,
	base:     bool,
	alpha:    []Land_Alpha, // owned; empty for base layers
}

// land_layers decodes a LAND record's texture layers in file order: each BTXT (base,
// 8 bytes: LTEX + quadrant + pad + layer) and each ATXT (additional layer, same 8 bytes)
// paired with its following VTXT (the alpha array: per entry point u16 + pad u16 +
// opacity f32). Layers are returned base-first per quadrant (BTXT precede ATXT). Free
// with free_land_layers.
land_layers :: proc(fields: []Field, allocator := context.allocator) -> ([]Land_Layer, bool) {
	layers := make([dynamic]Land_Layer, 0, 16, allocator)
	for f, i in fields {
		switch f.type {
		case "BTXT":
			if len(f.data) >= 8 && f.data[4] < 4 {
				append(&layers, Land_Layer{ltex = rd32(f.data, 0), quadrant = f.data[4], base = true})
			}
		case "ATXT":
			if len(f.data) < 8 || f.data[4] >= 4 {
				continue
			}
			layer := Land_Layer{ltex = rd32(f.data, 0), quadrant = f.data[4]}
			// The alpha for this layer is the VTXT field that immediately follows.
			if i + 1 < len(fields) && fields[i + 1].type == "VTXT" {
				v := fields[i + 1].data
				n := len(v) / 8
				alpha := make([]Land_Alpha, n, allocator)
				for k in 0 ..< n {
					alpha[k] = {point = rd16(v, k * 8), opacity = rf32(v, k * 8 + 4)}
				}
				layer.alpha = alpha
			}
			append(&layers, layer)
		}
	}
	return layers[:], true
}

free_land_layers :: proc(layers: []Land_Layer, allocator := context.allocator) {
	for l in layers {
		delete(l.alpha, allocator)
	}
	delete(layers, allocator)
}

// landscape_grass reads an LTEX record's GNAM — the formID of the GRAS grass type the
// engine scatters over terrain painted with this texture. ok=false if absent (the
// texture grows no grass).
landscape_grass :: proc(fields: []Field) -> (u32, bool) {
	if f, ok := find_field(fields, "GNAM"); ok && len(f.data) >= 4 {
		return rd32(f.data, 0), true
	}
	return 0, false
}

// grass_density reads a GRAS record's DATA density — the first byte (clusters scattered
// per unit area; the rest of DATA is slope/water/wave fields, deferred). ok=false if no
// DATA. Pair with model_path (GRAS carries a MODL grass-cluster mesh).
grass_density :: proc(fields: []Field) -> (u8, bool) {
	if f, ok := find_field(fields, "DATA"); ok && len(f.data) >= 1 {
		return f.data[0], true
	}
	return 0, false
}

// landscape_txst reads an LTEX (Landscape Texture) record's TNAM — the formID of the
// TXST texture set it draws its diffuse from. ok=false if absent.
landscape_txst :: proc(fields: []Field) -> (u32, bool) {
	if f, ok := find_field(fields, "TNAM"); ok && len(f.data) >= 4 {
		return rd32(f.data, 0), true
	}
	return 0, false
}

// texture_set_diffuse reads a TXST (Texture Set) record's TX00 — the diffuse texture
// path (e.g. "Landscape\\Dirt01.dds"), or "" if absent.
texture_set_diffuse :: proc(fields: []Field) -> string {
	if f, ok := find_field(fields, "TX00"); ok {
		return cstr(f.data)
	}
	return ""
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
