package magictranslate

// SPEL, SCRL and ENCH to rt.spell, powers and SHOU to rt.power, and a scroll's use to a hand rt.item.
// A spell's shape comes from its delivery and the first projectile its effects fly as. An entry
// with conditions applies a copy of its effect that carries them (user, 2026-09-30).

import "core:fmt"
import "core:strings"
import "../formats/esm"
import "../gamedb"

// Copies are the effect copies spell entries with conditions apply: effect and conditions -> the
// copy's name, and each copy's file. `variants` counts each effect's distinct condition sets.
Copies :: struct {
	names:    map[string]string,
	files:    map[string]string,
	variants: map[Form_ID]int,
}

// count_variants counts, per effect, the distinct condition sets its entries carry.
count_variants :: proc(copies: ^Copies, effects: []gamedb.Magic_Effect_Ref) {
	for e in effects {
		if len(e.conditions) == 0 {continue}
		key := copy_key(e)
		if key in copies.names {continue}
		copies.names[key] = ""
		copies.variants[e.effect] += 1
	}
}

@(private)
copy_key :: proc(e: gamedb.Magic_Effect_Ref) -> string {
	return strings.clone(fmt.tprintf("%v %v", e.effect, e.conditions), context.temp_allocator)
}

// spell_lua writes a SPEL, SCRL or ENCH as a spells/ file. `with_form` is false for a scroll's
// spell, which the scroll's item holds.
spell_lua :: proc(src: ^Source, form: Form_ID, what: string, info: esm.Spell_Info, effects: []gamedb.Magic_Effect_Ref, tags: []string, with_form: bool, copies: ^Copies) -> (text: string, ok: bool) {
	names := entry_names(src, form, effects, copies) or_return
	b := strings.builder_make(context.temp_allocator)
	write_head(&b, src, form, fmt.tprintf("%s %s", what, src.edids[form]), "spell", with_form)
	fmt.sbprintfln(&b, "  use = %q,", "held" if info.cast_type == .Concentration else "charged")
	if info.cost > 0 {fmt.sbprintfln(&b, "  cost = %v,", info.cost)}
	_, shape := shape_lua(src, info, effects)
	if shape != "" {fmt.sbprintfln(&b, "  shape = %s,", shape)}
	write_tags(&b, tags)
	write_applies(&b, src, effects, names)
	fmt.sbprintln(&b, "}")
	return strings.to_string(b), true
}

// spell_tags are a spell's own tags: the half-cost perk it counts as (SpellHasCastingPerk).
spell_tags :: proc(src: ^Source, sp: gamedb.Spell) -> []string {
	if sp.half_cost_perk == 0 {return nil}
	out := make([]string, 1, context.temp_allocator)
	out[0] = fmt.tprintf("casting.%s", src.edids[sp.half_cost_perk])
	return out
}

// power_lua writes a lesser power or power as a powers/ file: a power once a game day.
power_lua :: proc(src: ^Source, form: Form_ID, sp: gamedb.Spell, copies: ^Copies) -> (text: string, ok: bool) {
	names := entry_names(src, form, sp.effects, copies) or_return
	b := strings.builder_make(context.temp_allocator)
	write_head(&b, src, form, fmt.tprintf("SPEL %s, a power", src.edids[form]), "power")
	kind, _ := shape_lua(src, sp.info, sp.effects)
	fmt.sbprintfln(&b, "  shape = %q,", kind)
	if sp.info.type == .Power {fmt.sbprintln(&b, "  cooldown = \"24h\",")}
	write_applies(&b, src, sp.effects, names)
	fmt.sbprintln(&b, "}")
	return strings.to_string(b), true
}

// shout_lua writes a SHOU as a powers/ file: each word's spell, recovering on the shared Voice timer.
shout_lua :: proc(src: ^Source, form: Form_ID, words: [3]esm.Shout_Word, copies: ^Copies) -> (text: string, ok: bool) {
	b := strings.builder_make(context.temp_allocator)
	write_head(&b, src, form, fmt.tprintf("SHOU %s", src.edids[form]), "power")
	if first, has := src.db.spells[words[0].spell]; has {
		kind, _ := shape_lua(src, first.info, first.effects)
		fmt.sbprintfln(&b, "  shape = %q,", kind)
	}
	fmt.sbprintln(&b, "  cooldown_av = \"Voice\",")
	fmt.sbprintln(&b, "  cooldown_mult = \"ShoutRecoveryMult\",")
	fmt.sbprintln(&b, "  words = {")
	for w in words {
		sp, has := src.db.spells[w.spell]
		if !has {break}
		names := entry_names(src, w.spell, sp.effects, copies) or_return
		inner := strings.builder_make(context.temp_allocator)
		write_applies(&inner, src, sp.effects, names)
		fmt.sbprintfln(&b, "    {{ cooldown = \"%vs\",", w.recovery)
		for line in strings.split_lines(strings.trim_right(strings.to_string(inner), "\n"), context.temp_allocator) {fmt.sbprintfln(&b, "    %s", line)}
		fmt.sbprintln(&b, "    },")
	}
	fmt.sbprintln(&b, "  },")
	fmt.sbprintln(&b, "}")
	return strings.to_string(b), true
}

// scroll_item_lua writes a scroll's use: held in a hand, it casts its own spell.
scroll_item_lua :: proc(src: ^Source, form: Form_ID) -> string {
	b := strings.builder_make(context.temp_allocator)
	write_head(&b, src, form, fmt.tprintf("SCRL %s", src.edids[form]), "item")
	fmt.sbprintln(&b, "  use = \"hand\",")
	fmt.sbprintfln(&b, "  casts = %q,", src.edids[form])
	fmt.sbprintln(&b, "}")
	return strings.to_string(b)
}

// shape_lua is a spell's primitive and its shape field: "self", none ("") for a touch that a hit
// carries, else a primitive from its first projectile. Self with an area is an aura; an area
// elsewhere bursts where the shape lands.
shape_lua :: proc(src: ^Source, info: esm.Spell_Info, effects: []gamedb.Magic_Effect_Ref) -> (kind, text: string) {
	area: f32
	for e in effects {area = max(area, f32(e.area))}
	area *= esm.UNITS_PER_FOOT
	#partial switch info.delivery {
	case .Self:
		if area > 0 {return "aura", fmt.tprintf("{{ \"aura\", radius = %v }", area)}
		return "self", "\"self\""
	case .Contact:
		return "", ""
	}
	p, has := first_projectile(src, effects)
	b := strings.builder_make(context.temp_allocator)
	switch {
	case !has || p.type == .Beam || info.delivery == .Target_Actor:
		kind = "beam"
		fmt.sbprintf(&b, "{{ \"beam\", range = %v", p.range if has && p.range > 0 else info.range if info.range > 0 else 4096)
	case p.type == .Flame || p.type == .Cone:
		kind = "spray"
		fmt.sbprintf(&b, "{{ \"spray\", range = %v, speed = %v, spread = %v", p.range, p.speed, p.cone_spread if p.cone_spread > 0 else 15)
	case:
		kind = "projectile"
		fmt.sbprintf(&b, "{{ \"projectile\", speed = %v, range = %v, radius = %v", p.speed, p.range, p.collision_radius)
		if p.type == .Lobber || p.type == .Arrow {fmt.sbprintf(&b, ", gravity = %v", p.gravity)}
		if info.delivery == .Target_Location {strings.write_string(&b, ", place = true")}
	}
	if area > 0 && kind != "spray" {fmt.sbprintf(&b, ", burst = %v", area)}
	strings.write_string(&b, " }")
	return kind, strings.to_string(b)
}

@(private)
first_projectile :: proc(src: ^Source, effects: []gamedb.Magic_Effect_Ref) -> (esm.Projectile, bool) {
	for e in effects {
		mgef := src.db.magic_effects[e.effect] or_else {}
		if p, ok := gamedb.projectile_of(&src.db, mgef.projectile); ok {return p, true}
	}
	return {}, false
}

// entry_names are the effect names a source's entries apply: the effect's own, or for an entry with
// conditions its copy carrying them. False when a copy cannot be written.
@(private)
entry_names :: proc(src: ^Source, source: Form_ID, effects: []gamedb.Magic_Effect_Ref, copies: ^Copies) -> (names: []string, ok: bool) {
	out := make([]string, len(effects), context.temp_allocator)
	for e, i in effects {
		if len(e.conditions) == 0 {
			out[i] = form_name(src, e.effect)
			continue
		}
		key := copy_key(e)
		if name := copies.names[key]; name != "" {
			out[i] = name
			continue
		}
		mgef := src.db.magic_effects[e.effect] or_else {}
		text := effect_lua(src, e.effect, &mgef, e.conditions) or_return
		name := fmt.tprintf("%s_%s", src.edids[e.effect], "Conditioned" if copies.variants[e.effect] == 1 else src.edids[source])
		copies.names[key] = name
		copies.files[name] = text
		out[i] = name
	}
	return out, true
}
