package worldstate

// Engine archetypes (CK wiki, Magic Effect: Effect Archetypes): an MGEF's actor values, flags and
// taper as effect terms, run beside its scripts' __effect terms. With Recover, or on a lasting
// effect, `m` is held on the capacity. Without, `m` a second is an amount that stays (all at once
// when the duration is 0), then the taper. Detrimental negates.
// (hole ability-value-modifier :tags magic :sev polish) a lasting Value Modifier without Recover (VampireAbSkills02) is held like a fortify; the CK says an unrecovered one applies every second, which for an ability would never stop. Unsourced either way.
// (hole absorb-cap :tags magic :sev polish) Absorb gives the caster the full amount even when the target had less; the CK says "by the amount of damage done".
// (hole other-archetypes :tags magic :sev gap) only Value Modifier, Peak Value Modifier, Dual Value Modifier and Absorb run; summon, paralysis, invisibility, cloak, bound weapon, calm/frenzy and the rest start an effect that does nothing.

import "core:fmt"
import "core:log"
import "core:strings"
import "../formats/esm"
import "../formula"
import "../gamedb"

Archetype_Shape :: enum u8 {
	Held,    // on the capacity while it runs
	Instant, // duration 0: the amount at once
	Timed,   // the amount a second, over the duration
}

Archetype_Key :: struct {
	effect: Form_ID,
	shape:  Archetype_Shape,
}

// archetype_terms is what an effect's engine archetype does, compiled once per MGEF and shape.
@(private)
archetype_terms :: proc(ws: ^World_State, db: ^gamedb.DB, e: Active_Effect) -> []Effect_Term {
	mgef, ok := gamedb.magic_effect_of(db, e.effect)
	if !ok {return nil}
	info := mgef.info
	shape := Archetype_Shape.Held
	if !e.lasts && info.flags & esm.MGEF_RECOVER == 0 {shape = .Instant if e.duration == 0 else .Timed}
	key := Archetype_Key{e.effect, shape}
	if terms, cached := ws.archetype_terms[key]; cached {return terms[:]}

	knob := Knob.Capacity if shape == .Held else .Amount
	amount := "m * min(t, d)" if shape == .Timed else "m"
	if shape != .Held && info.taper_duration > 0 {
		w, c, td := info.taper_weight, info.taper_curve, info.taper_duration
		amount = fmt.tprintf("%s + m * %f * %f / (%f + 1) * (1 - (1 - clamp(t - d, 0, %f) / %f) ^ (%f + 1))", amount, w, td, c, td, td, c)
	}
	harm := info.flags & esm.MGEF_DETRIMENTAL != 0
	terms := make([dynamic]Effect_Term)
	#partial switch info.archetype {
	case .Value_Modifier, .Peak_Value_Modifier:
		add_term(&terms, info.primary_av, knob, amount, harm, false)
	case .Dual_Value_Modifier:
		add_term(&terms, info.primary_av, knob, amount, harm, false)
		add_term(&terms, info.second_av, knob, fmt.tprintf("%f * (%s)", info.second_av_weight, amount), harm, false)
	case .Absorb:
		add_term(&terms, info.primary_av, knob, amount, harm, false)
		add_term(&terms, info.primary_av, knob, amount, !harm, true)
	}
	ws.archetype_terms[key] = terms
	return terms[:]
}

@(private)
add_term :: proc(terms: ^[dynamic]Effect_Term, av_index: i32, knob: Knob, amount: string, negate, on_caster: bool) {
	if av_index < 0 || int(av_index) >= len(gamedb.AV_NAMES) {return}
	src := fmt.tprintf("-(%s)", amount) if negate else amount
	f, err := formula.compile(src, EFFECT_VARS)
	if err != "" {
		log.errorf("worldstate: archetype formula %q: %s", src, err)
		return
	}
	append(terms, Effect_Term{av = strings.clone(gamedb.AV_NAMES[av_index]), knob = knob, f = f, on_caster = on_caster})
}
