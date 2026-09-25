package worldstate

// Levels and leveled lists (sources: build/out/wsP/formulas/lvl_*). A zone gets its level the
// first time something asks, and keeps it; a leveled list rolls on the first read of what holds it,
// and the result stays until that owner resets (drop_inventory).

import "core:math/rand"
import "../formats/esm"
import "../formid"
import "../gamedb"

// (hole special-loot :tags records :sev polish) the Special Loot flag (LVLF 0x08) rolls as a plain list: no source gives its formula (fSpecialLoot* GMSTs).
// (hole level-difference-max :tags records :sev polish) iLevItemLevelDifferenceMax / iLevCharLevelDifferenceMax may cut entries far below the roll level; the SE default and rule are unsourced.

MAX_LIST_DEPTH :: 8

// player_level is the level rolls start from.
player_level :: proc(db: ^gamedb.DB) -> i32 {
	return max(i32(db.actors[formid.PLAYER_BASE].level), 1)
}

// zone_level is a zone's level: set from the player's level on the first ask, then kept.
zone_level :: proc(ws: ^World_State, db: ^gamedb.DB, zone: Form_ID) -> i32 {
	if zone == 0 {return player_level(db)}
	if l, ok := ws.zone_levels[zone]; ok {return l}
	l := zone_level_from(db.zones[zone], player_level(db))
	ws.zone_levels[zone] = l
	return l
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
	if v, ok := get_global(ws, ll.chance_global); ok {return v}
	v, _ := gamedb.global_value(db, ll.chance_global)
	return v
}

@(private)
add_content :: proc(out: ^[dynamic]gamedb.Content_Entry, item: Form_ID, count: i32) {
	for &e in out {
		if e.item == item {e.count += count; return}
	}
	append(out, gamedb.Content_Entry{item, count})
}

// inv_start is the contents owner starts with. A leveled entry rolls at the owner's zone level on
// the first read, and the result stays until the owner resets.
inv_start :: proc(ws: ^World_State, db: ^gamedb.DB, owner: Form_ID) -> []gamedb.Content_Entry {
	if rolled, ok := ws.rolled[owner]; ok {return rolled[:]}
	start, _ := gamedb.contents_of(db, record_of(ws, owner))
	has_leveled := false
	for e in start {
		if _, ok := gamedb.leveled_list_of(db, e.item); ok {has_leveled = true}
	}
	if !has_leveled {return start}
	level := zone_level(ws, db, gamedb.zone_of(db, owner))
	rolled := make([dynamic]gamedb.Content_Entry)
	for e in start {roll(ws, db, e.item, level, e.count, &rolled)}
	ws.rolled[owner] = rolled
	return rolled[:]
}
