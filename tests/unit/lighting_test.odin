package unit_tests

// Lighting preset primitives. apply_text (the internal layering primitive `parse` builds on) must
// override only the keys present in a (partial) txt, leaving the rest of the profile intact; a full
// serialize must round-trip back through parse (the preset save/load contract).

import "core:testing"
import "../../src/lighting"

@(test)
test_lighting_apply_text_partial :: proc(t: ^testing.T) {
	base := lighting.DEFAULTS
	base.fog_density = 0.1
	base.sun_intensity = 0.7

	// A partial txt overrides only fog_density; everything else keeps its current value.
	lighting.apply_text(&base, "fog_density = 0.5\n# a comment\nunknown_key = 9\n")
	testing.expect_value(t, base.fog_density, f32(0.5))
	testing.expect_value(t, base.sun_intensity, f32(0.7)) // untouched by the partial txt
}

@(test)
test_lighting_serialize_roundtrip :: proc(t: ^testing.T) {
	p := lighting.DEFAULTS
	p.fog_density = 0.5
	p.sun_intensity = 1.5
	p.tonemap = .Filmic
	p.veg_shadows = .Proxy

	// A full serialize round-trips through parse (a preset saved then loaded reproduces the look).
	rt := lighting.parse(lighting.serialize(&p, "test"))
	testing.expect_value(t, rt.fog_density, f32(0.5))
	testing.expect_value(t, rt.sun_intensity, f32(1.5))
	testing.expect_value(t, rt.tonemap, lighting.Tonemap.Filmic)
	testing.expect_value(t, rt.veg_shadows, lighting.Veg_Shadows.Proxy)
}
