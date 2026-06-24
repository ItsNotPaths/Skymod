package unit_tests

// NIF material parse tests (ROADMAP Iteration 1, Milestone B4). Hermetic + SYNTHETIC:
// hand-built BSShaderTextureSet and BSLightingShaderProperty block bodies (no game
// bytes). Regression guard on the field-order logic only — REAL correctness is
// proven by parsing the user's own NIFs (tools/nifdump against the install), where
// the resolved diffuse paths must read as `textures\...\.dds`.

import "core:encoding/endian"
import "core:testing"
import "../../src/formats/nif"

@(test)
test_nif_texture_set :: proc(t: ^testing.T) {
	// BSShaderTextureSet: a u32 count then that many length-prefixed paths.
	b := make([dynamic]u8, 0, 64)
	defer delete(b)
	mput_u32(&b, 3)
	mput_sized(&b, "textures\\clutter\\Barrel01.dds")
	mput_sized(&b, "textures\\clutter\\Barrel01_n.dds")
	mput_sized(&b, "") // empty slot

	paths, ok := nif.parse_texture_set(b[:])
	testing.expect(t, ok, "parse texture set")
	defer nif.destroy_texture_set(paths)
	testing.expect_value(t, len(paths), 3)
	testing.expect_value(t, paths[nif.TEX_DIFFUSE], "textures\\clutter\\Barrel01.dds")
	testing.expect_value(t, paths[nif.TEX_NORMAL], "textures\\clutter\\Barrel01_n.dds")
	testing.expect_value(t, paths[2], "")
}

@(test)
test_nif_texture_set_ref :: proc(t: ^testing.T) {
	// BSLightingShaderProperty prefix (Skyrim LE): leading Skyrim Shader Type, then
	// NiObjectNET (name, num-extra=0, controller), two flag words, UV offset+scale,
	// then the Texture Set ref. We expect ref = 42 to read back.
	b := make([dynamic]u8, 0, 64)
	defer delete(b)
	mput_u32(&b, 0) // Skyrim Shader Type
	mput_u32(&b, transmute(u32)i32(-1)) // Name (string ref)
	mput_u32(&b, 0) // Num Extra Data List
	mput_u32(&b, transmute(u32)i32(-1)) // Controller
	mput_u32(&b, 0x12345678) // Shader Flags 1
	mput_u32(&b, 0x00000020) // Shader Flags 2
	mput_f32(&b, 0) // UV Offset x
	mput_f32(&b, 0) // UV Offset y
	mput_f32(&b, 1) // UV Scale x
	mput_f32(&b, 1) // UV Scale y
	mput_u32(&b, transmute(u32)i32(42)) // Texture Set ref

	ref, ok := nif.texture_set_ref(b[:])
	testing.expect(t, ok, "read texture set ref")
	testing.expect_value(t, ref, i32(42))
}

@(test)
test_nif_lighting_material :: proc(t: ^testing.T) {
	// BSLightingShaderProperty body: the texture_set_ref head, then the material scalars.
	// Guards the offsets (Emissive Color/Mult, clamp, alpha, refraction, Glossiness, Specular
	// Color/Strength). REAL validation is nifdump --all (0 garbage scalars game-wide).
	b := make([dynamic]u8, 0, 96)
	defer delete(b)
	mput_u32(&b, 0) // Skyrim Shader Type
	mput_u32(&b, transmute(u32)i32(-1)) // Name
	mput_u32(&b, 0) // Num Extra Data List
	mput_u32(&b, transmute(u32)i32(-1)) // Controller
	mput_u32(&b, 0) // Shader Flags 1
	mput_u32(&b, 0) // Shader Flags 2
	mput_f32(&b, 0);mput_f32(&b, 0) // UV Offset
	mput_f32(&b, 1);mput_f32(&b, 1) // UV Scale
	mput_u32(&b, transmute(u32)i32(7)) // Texture Set ref
	mput_f32(&b, 0.1);mput_f32(&b, 0.2);mput_f32(&b, 0.3) // Emissive Color
	mput_f32(&b, 2.5) // Emissive Multiple
	mput_u32(&b, 0) // Texture Clamp Mode
	mput_f32(&b, 1) // Alpha
	mput_f32(&b, 0) // Refraction Strength
	mput_f32(&b, 80) // Glossiness
	mput_f32(&b, 0.9);mput_f32(&b, 0.9);mput_f32(&b, 1.0) // Specular Color
	mput_f32(&b, 3.0) // Specular Strength

	ts_ref, mat, ok := nif.parse_lighting_material(b[:])
	testing.expect(t, ok, "parse lighting material")
	testing.expect_value(t, ts_ref, i32(7))
	testing.expect_value(t, mat.emissive_mult, f32(2.5))
	testing.expect_value(t, mat.glossiness, f32(80))
	testing.expect_value(t, mat.spec_strength, f32(3.0))
	testing.expect_value(t, mat.spec_color.z, f32(1.0))
	testing.expect_value(t, mat.emissive_color.x, f32(0.1))
}

@(private = "file")
mput_u32 :: proc(b: ^[dynamic]u8, v: u32) {
	tmp: [4]u8
	endian.put_u32(tmp[:], .Little, v)
	append(b, ..tmp[:])
}

@(private = "file")
mput_f32 :: proc(b: ^[dynamic]u8, v: f32) {
	mput_u32(b, transmute(u32)v)
}

@(private = "file")
mput_sized :: proc(b: ^[dynamic]u8, s: string) {
	mput_u32(b, u32(len(s)))
	append(b, ..transmute([]u8)s)
}
