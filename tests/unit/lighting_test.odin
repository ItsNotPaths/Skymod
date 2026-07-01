package unit_tests

// Lighting layering + delta tests (the mod-payload primitives). apply_text must override only the
// keys present in a (partial) txt, leaving the rest of the base profile intact; serialize_delta must
// emit only the changed fields, and round-trip back through apply_text.

import "core:strings"
import "core:testing"
import "../../src/lighting"

@(test)
test_lighting_apply_text_partial :: proc(t: ^testing.T) {
	base := lighting.DEFAULTS
	base.fog_density = 0.1
	base.sun_intensity = 0.7

	// A partial mod txt overrides only fog_density; everything else inherits from `base`.
	lighting.apply_text(&base, "fog_density = 0.5\n# a comment\nunknown_key = 9\n")
	testing.expect_value(t, base.fog_density, f32(0.5))
	testing.expect_value(t, base.sun_intensity, f32(0.7)) // untouched by the partial txt
}

@(test)
test_lighting_serialize_delta_roundtrip :: proc(t: ^testing.T) {
	base := lighting.DEFAULTS
	edited := base
	edited.fog_density = 0.5
	edited.sun_intensity = 1.5

	txt := lighting.serialize_delta(&edited, &base, "test")
	testing.expect(t, strings.contains(txt, "fog_density = 0.5"), "delta keeps changed fog_density")
	testing.expect(t, strings.contains(txt, "sun_intensity = 1.5"), "delta keeps changed sun_intensity")
	testing.expect(t, !strings.contains(txt, "albedo_lift"), "delta omits unchanged albedo_lift")

	// Applying the delta onto the base reproduces the edits (the layering contract).
	rt := base
	lighting.apply_text(&rt, txt)
	testing.expect_value(t, rt.fog_density, f32(0.5))
	testing.expect_value(t, rt.sun_intensity, f32(1.5))
}
