package worldstate

// Levels and leveled lists (sources: build/out/wsP/formulas/lvl_*). A zone gets its level the
// first time something asks, and keeps it; a leveled list rolls on the first read of what holds it,
// and the result stays until that owner resets (drop_inventory).

import "core:math/rand"
import "../formats/esm"
import "../gamedb"

// (hole special-loot :tags records :sev polish) the Special Loot flag (LVLF 0x08) rolls as a plain list: no source gives its formula (fSpecialLoot* GMSTs).
// (hole level-difference-max :tags records :sev polish) iLevItemLevelDifferenceMax / iLevCharLevelDifferenceMax may cut entries far below the roll level; the SE default and rule are unsourced.

MAX_LIST_DEPTH :: 8

// zone_level is a zone's level: set on the first ask from the player's level through the ZoneLevel
// formula, then kept. OnZoneLevelSet announces it on the next tick.
zone_level :: proc(ws: ^World_State, db: ^gamedb.DB, zone: Form_ID) -> i32 {
	if zone == 0 {return player_level(ws, db)}
	if l, ok := ws.zone_levels[zone]; ok {return l}
	z, pc := zone_band(ws, db, zone), player_level(ws, db)
	clamped := zone_level_from(z, pc)
	l := i32(calc(ws, .ZoneLevel, f64(pc), f64(z.min_level), f64(z.max_level), f64(clamped)))
	ws.zone_levels[zone] = l
	append(&ws.zone_level_sets, zone)
	return l
}

// zone_band is a zone with a script's SetEncounterZoneRange applied.
zone_band :: proc(ws: ^World_State, db: ^gamedb.DB, zone: Form_ID) -> gamedb.Zone {
	z := db.zones[zone]
	if r, ok := ws.zone_ranges[zone]; ok {z.min_level, z.max_level = r[0], r[1]}
	return z
}

// zone_level_from clamps the player's level to the zone's band (CK wiki, Encounter Zone). Match PC
// Below Minimum lets a player under the band keep their own level.
zone_level_from :: proc(z: gamedb.Zone, pc: i32) -> i32 {
	if pc < z.min_level && z.flags & esm.ECZN_MATCH_PC_BELOW_MIN != 0 {return pc}
	l := max(pc, z.min_level)
	if z.max_level > 0 {l = min(l, z.max_level)}
	return l
}

// roll adds what `count` of a leveled list yields at `level` to `out`; a plain form adds itself.
roll :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID, level, count: i32, out: ^[dynamic]gamedb.Content_Entry, depth := 0) {
	ll, leveled := gamedb.leveled_list_of(db, form)
	if !leveled {
		add_content(out, form, count)
		return
	}
	if depth >= MAX_LIST_DEPTH || rand.float32() * 100 < chance_none(ws, db, ll) {return}
	if ll.flags & esm.LVLI_USE_ALL != 0 {
		for e in ll.entries {roll(ws, db, e.form, level, i32(e.count) * count, out, depth + 1)}
		return
	}
	top := -1
	for e in ll.entries {
		if i32(e.level) <= level {top = max(top, int(e.level))}
	}
	if top < 0 {return}
	all := ll.flags & esm.LVLI_CALC_FROM_ALL_LEVELS != 0
	picks := make([dynamic]gamedb.Leveled_Entry, context.temp_allocator)
	for e in ll.entries {
		if i32(e.level) <= level && (all || int(e.level) == top) {append(&picks, e)}
	}
	each := ll.flags & esm.LVLI_CALC_FOR_EACH != 0
	for _ in 0 ..< (count if each else 1) {
		e := rand.choice(picks[:])
		roll(ws, db, e.form, level, i32(e.count) * (1 if each else count), out, depth + 1)
	}
}

@(private)
chance_none :: proc(ws: ^World_State, db: ^gamedb.DB, ll: gamedb.Leveled_List) -> f32 {
	if ll.chance_global == 0 {return f32(ll.chance_none)}
	return global_value(ws, db, ll.chance_global)
}

@(private)
add_content :: proc(out: ^[dynamic]gamedb.Content_Entry, item: Form_ID, count: i32) {
	for &e in out {
		if e.item == item {e.count += count; return}
	}
	append(out, gamedb.Content_Entry{item, count})
}

// inv_start is the contents owner starts with: its own, plus its outfit's gear, which it wears. A
// leveled entry rolls on the first read, and the result stays until the owner resets: contents at
// the owner's zone level, outfit gear at the player's (CK wiki Outfit: "based on the player's Level").
inv_start :: proc(ws: ^World_State, db: ^gamedb.DB, owner: Form_ID) -> []gamedb.Content_Entry {
	if rolled, ok := ws.rolled[owner]; ok {return rolled[:]}
	record, pick := record_of(ws, owner), actor_pick(ws, db, owner)
	start, _ := gamedb.contents_of(db, record, pick)
	outfit := outfit_items(ws, db, owner)
	has_leveled := false
	for e in start {
		if _, ok := gamedb.leveled_list_of(db, e.item); ok {has_leveled = true}
	}
	if !has_leveled && len(outfit) == 0 {return start}
	level := zone_level(ws, db, gamedb.zone_of(db, owner))
	rolled := make([dynamic]gamedb.Content_Entry)
	for e in start {roll(ws, db, e.item, level, e.count, &rolled)}
	gear := make([dynamic]gamedb.Content_Entry, context.temp_allocator)
	for item in outfit {roll(ws, db, item, player_level(ws, db), 1, &gear)}
	for e in gear {add_content(&rolled, e.item, e.count)}
	ws.rolled[owner] = rolled
	wear_outfit(ws, db, owner, gear[:])
	return rolled[:]
}

// actor_traits is the NPC_ an actor takes race, sex and voice type from.
actor_traits :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) -> gamedb.Actor_Base {
	if db == nil {return {}}
	return gamedb.actor_traits(db, record_of(ws, actor), actor_pick(ws, db, actor))
}

// actor_pick is the NPC_ a leveled actor rolled from the LVLN its base's template chain reaches: on
// the first ask, at its zone level times its difficulty (CK wiki, LeveledCharacter), kept until the
// actor resets. 0 for an actor with no leveled template, or a roll that gave nothing.
// (hole level-mod-picks :tags records :sev polish) an Easy actor should pick from every level up to its target and a Very Hard one a step above Hard's pick; both use the list's own flags.
actor_pick :: proc(ws: ^World_State, db: ^gamedb.DB, ref: Form_ID) -> Form_ID {
	if p, ok := ws.actor_picks[ref]; ok {return p}
	if db == nil || pick_list(ws, db, ref) == 0 {return 0}
	return roll_pick(ws, db, ref, f32(zone_level(ws, db, gamedb.zone_of(db, ref))) * level_mult(db, ref))
}

// pick_list is the LVLN an actor's base template chain reaches; 0 for an actor that is not leveled.
pick_list :: proc(ws: ^World_State, db: ^gamedb.DB, ref: Form_ID) -> Form_ID {
	base := record_of(ws, ref)
	if r, ok := db.ref_by_id[base]; ok {base = r.base}
	return gamedb.leveled_template(db, base)
}

// roll_pick rolls and keeps the NPC_ a leveled actor spawns as at `level`.
roll_pick :: proc(ws: ^World_State, db: ^gamedb.DB, ref: Form_ID, level: f32) -> Form_ID {
	list := pick_list(ws, db, ref)
	if list == 0 {return 0}
	out := make([dynamic]gamedb.Content_Entry, context.temp_allocator)
	roll(ws, db, list, max(i32(level), 1), 1, &out)
	pick: Form_ID
	if len(out) > 0 && out[0].item in db.actors {pick = out[0].item}
	ws.actor_picks[ref] = pick
	return pick
}

// encounter_level is a zone's level at a difficulty (esm.LEVEL_MOD_*; any other is none), as
// CalculateEncounterLevel and PlaceActorAtMe take it.
encounter_level :: proc(ws: ^World_State, db: ^gamedb.DB, zone: Form_ID, difficulty: i32) -> i32 {
	return max(i32(f32(zone_level(ws, db, zone)) * difficulty_mult(db, difficulty)), 1)
}

// level_mult scales a leveled actor's target level by its difficulty (XLCM); none is 1.
@(private)
level_mult :: proc(db: ^gamedb.DB, ref: Form_ID) -> f32 {
	m, ok := db.level_mods[ref]
	return difficulty_mult(db, i32(m)) if ok else 1
}

// difficulty_mult is a leveled difficulty's level multiplier; none is 1.
difficulty_mult :: proc(db: ^gamedb.DB, difficulty: i32) -> f32 {
	switch difficulty {
	case esm.LEVEL_MOD_EASY:      return gamedb.setting_float(db, "fLeveledActorMultEasy", 0.33)
	case esm.LEVEL_MOD_MEDIUM:    return gamedb.setting_float(db, "fLeveledActorMultMedium", 0.67)
	case esm.LEVEL_MOD_HARD:      return gamedb.setting_float(db, "fLeveledActorMultHard", 1)
	case esm.LEVEL_MOD_VERY_HARD: return gamedb.setting_float(db, "fLeveledActorMultVeryHard", 1.25)
	}
	return 1
}
