package unit_tests

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "../../src/formats/esm"
import "../../src/formula"
import "../../src/magictranslate"

// quoted is the string after `key = "` in `text`.
@(private = "file")
quoted :: proc(text, key: string) -> string {
	i := strings.index(text, fmt.tprintf("%s = \"", key))
	rest := text[i + len(key) + 4:]
	return rest[:strings.index_byte(rest, '"')]
}

@(private = "file")
eval_src :: proc(t: ^testing.T, src: string, vars: []string, values: []f64) -> f64 {
	f, err := formula.compile(src, vars, context.temp_allocator)
	testing.expectf(t, err == "", "%q: %s", src, err)
	return formula.eval(f, values)
}

// A translated effect's baked formulas move each AV as its archetype class does with the record's
// flags, for held and timed copies, with and without a taper, on both sides of an Absorb.
@(test)
test_magic_translate_terms :: proc(t: ^testing.T) {
	text, err := os.read_entire_file("src/script/effects/archetypevaluemodifier.lua", context.temp_allocator)
	testing.expect(t, err == nil, "read the Value Modifier class")
	cap, amt := quoted(string(text), "capacity"), quoted(string(text), "amount")
	CLASS_VARS := []string{"t", "m", "d", "held", "sign", "w", "tw", "tc", "td"}
	Key :: struct {
		av:        string,
		knob:      string,
		on_caster: bool,
	}
	for arch in ([]esm.Effect_Archetype{.Value_Modifier, .Peak_Value_Modifier, .Dual_Value_Modifier, .Absorb}) {
		for flags in ([]u32{0, esm.MGEF_RECOVER, esm.MGEF_DETRIMENTAL, esm.MGEF_RECOVER | esm.MGEF_DETRIMENTAL}) {
			for tw in ([]f32{0, 0.3}) {
				for lasting in ([]bool{false, true}) {
					info := esm.Magic_Effect_Info{archetype = arch, flags = flags, primary_av = 24, second_av = 26, second_av_weight = 0.5, taper_weight = tw, taper_curve = 2, taper_duration = 1}
					held := lasting || flags & esm.MGEF_RECOVER != 0
					class := make(map[Key]string, context.temp_allocator)
					#partial switch arch {
					case .Absorb:
						class[{"Health", "amount", false}] = amt
						class[{"Health", "amount", true}] = fmt.tprintf("-(%s)", amt)
					case .Dual_Value_Modifier:
						class[{"Stamina", "capacity", false}] = fmt.tprintf("w * %s", cap)
						class[{"Stamina", "amount", false}] = fmt.tprintf("w * %s", amt)
						fallthrough
					case:
						class[{"Health", "capacity", false}] = cap
						class[{"Health", "amount", false}] = amt
					}
					baked := magictranslate.effect_terms(info, held)
					for m in ([]f64{25}) {
						for d in ([]f64{0, 3}) {
							for step in 0 ..= 20 {
								tt := f64(step) * 0.25
								tt = tt if lasting else min(tt, d + 1)
								vals := []f64{tt, m, d, 1 if held else 0, -1 if flags & esm.MGEF_DETRIMENTAL != 0 else 1, 0.5, f64(tw), 2, 1}
								for k, src in class {
									want := eval_src(t, src, CLASS_VARS, vals)
									got: f64
									for b in baked {
										if b.av == k.av && b.knob == k.knob && b.on_caster == k.on_caster {
											got += eval_src(t, b.f, CLASS_VARS[:3], vals[:3])
										}
									}
									testing.expectf(t, math.abs(got - want) < 1e-4, "%v flags %X tw %v lasting %v d %v t %v %v: baked %v, class %v", arch, flags, tw, lasting, d, tt, k, got, want)
								}
							}
						}
					}
				}
			}
		}
	}
}
