package magictranslate

// Magic records to Lua: SPEL, SCRL, ENCH, ALCH, INGR, SHOU and MGEF become rt.spell, rt.power,
// rt.item and rt.effect, and PERKs rt.hook functions (perks.odin), one file per record named by its editor ID,
// with form references as "Plugin.esm:012FCD" (ws.md Workstream M). The installer runs it once over
// the base game; tools/magic2lua runs it for a mod, which then ships the Lua. The runtime never reads
// magic records.

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "../formats/esm"
import "../gamedb"

Form_ID :: gamedb.Form_ID

Stats :: struct {
	effects, spells, items, perks: int,
	skipped:        int, // records it could not write: a condition with no Lua form, an ability that cannot merge
}

// Source is what the translator reads: the merged records, and per form what the DB drops.
Source :: struct {
	db:      gamedb.DB,
	files:   map[u32]string, // global slot -> plugin file name, as given
	edids:   map[Form_ID]string, // editor ids, as authored
	wanted:  map[Form_ID]bool, // forms a plugin in `only` defines or overrides
	lasting: map[Form_ID]Uses, // how each MGEF's users run it
}

// Uses says which kinds of source apply an MGEF: an ability or constant effect keeps it running; a
// timed one with a duration makes it Long; a poison or disease is one.
Uses :: bit_set[enum {Lasting, Timed, Long, Poison, Disease}]

// translate reads the winning version of each magic record over `plugins` (load order, in
// `data_dir`) and writes the ones that a plugin in `only` defines or overrides (all when empty)
// into `out_dir`.
// (hole rider-rules :tags magic :sev gap) perk riders (93 MGEFs: Intense Flames, Deep Freeze, Disintegrate, Impact) are copied into spells unevenly: none on scrolls, staffs, weapon enchantments or runes, and 34 test the player ref. Wanted: each rider stays an entry of the items that carry it (a spell names all its effects), with its per-spell values (Impact 0.05/0.25/0.5), its perk gate in the rider effect's own magichit; decide per item whether scrolls, staves and runes get the entries vanilla forgot.
translate :: proc(data_dir: string, plugins, only: []string, out_dir: string) -> (st: Stats, ok: bool) {
	src := load(data_dir, plugins, only) or_return
	defer destroy(&src)
	return write_all(&src, out_dir)
}

// write_all writes every wanted record `src` holds into `out_dir`.
write_all :: proc(src: ^Source, out_dir: string) -> (st: Stats, ok: bool) {
	effects_dir, _ := filepath.join({out_dir, "effects"}, context.temp_allocator)
	os.make_directory_all(effects_dir)
	for form, &mgef in src.db.magic_effects {
		if !src.wanted[form] {continue}
		text, done := effect_lua(src, form, &mgef)
		if !done {
			st.skipped += 1
			continue
		}
		write_file(effects_dir, src.edids[form], text) or_return
		st.effects += 1
	}
	items_dir, _ := filepath.join({out_dir, "items"}, context.temp_allocator)
	os.make_directory_all(items_dir)
	for form, potion in src.db.potions {
		if !src.wanted[form] {continue}
		write_file(items_dir, src.edids[form], item_lua(src, form, "ALCH", potion.effects, potion.poison)) or_return
		st.items += 1
	}
	for form, effects in src.db.ingredients {
		if !src.wanted[form] || len(effects) == 0 {continue}
		write_file(items_dir, src.edids[form], item_lua(src, form, "INGR", effects[:1], false)) or_return
		st.items += 1
	}
	spells_dir, _ := filepath.join({out_dir, "spells"}, context.temp_allocator)
	powers_dir, _ := filepath.join({out_dir, "powers"}, context.temp_allocator)
	os.make_directory_all(spells_dir)
	os.make_directory_all(powers_dir)
	copies: Copies
	copies.names, copies.files = make(map[string]string, context.temp_allocator), make(map[string]string, context.temp_allocator)
	copies.variants = make(map[Form_ID]int, context.temp_allocator)
	for _, sp in src.db.spells {if sp.info.type != .Ability {count_variants(&copies, sp.effects)}}
	for _, en in src.db.enchantments {count_variants(&copies, en.effects)}
	for form in sorted_keys(src.db.spells) { // form order: a copy is named by the first spell that needs it
		sp := src.db.spells[form]
		if !src.wanted[form] {continue}
		edid := src.edids[form]
		#partial switch sp.info.type {
		case .Ability:
			ab, done := ability_lua(src, form, sp)
			// (hole ability-splits :tags (magic records) :sev gap) 27 abilities whose parts carry different conditions keep their records (this warning names them): hand-write each, or split it into effects the ability's entries gate apart.
			if !done {
				log.warnf("magic: ability %s keeps its record: its parts' conditions differ", edid)
				st.skipped += 1
				continue
			}
			write_file(effects_dir, edid, ab.effect) or_return
			if ab.gate != "" {write_file(out_dir, ab.gate_class, ab.gate) or_return}
			st.effects += 1
		case .Spell:
			text, done := spell_lua(src, form, "SCRL" if sp.scroll else "SPEL", sp.info, sp.effects, spell_tags(src, sp), !sp.scroll, &copies)
			if !done {
				log.warnf("magic: spell %s keeps its record: an entry's condition has no Lua form", edid)
				st.skipped += 1
				continue
			}
			write_file(spells_dir, edid, text) or_return
			if sp.scroll {write_file(items_dir, edid, scroll_item_lua(src, form)) or_return}
			st.spells += 1
		case .Power, .Lesser_Power:
			text, done := power_lua(src, form, sp, &copies)
			if !done {
				log.warnf("magic: power %s keeps its record: an entry's condition has no Lua form", edid)
				st.skipped += 1
				continue
			}
			write_file(powers_dir, edid, text) or_return
			st.spells += 1
		}
	}
	for form in sorted_keys(src.db.enchantments) {
		en := src.db.enchantments[form]
		if !src.wanted[form] {continue}
		info := esm.Spell_Info{cast_type = en.info.cast_type, delivery = en.info.delivery}
		text, done := spell_lua(src, form, "ENCH", info, en.effects, {"enchantment"}, true, &copies)
		if !done {
			log.warnf("magic: enchantment %s keeps its record: an entry's condition has no Lua form", src.edids[form])
			st.skipped += 1
			continue
		}
		write_file(spells_dir, src.edids[form], text) or_return
		st.spells += 1
	}
	for form in sorted_keys(src.db.shouts) {
		if !src.wanted[form] {continue}
		text, done := shout_lua(src, form, src.db.shouts[form], &copies)
		if !done {
			log.warnf("magic: shout %s keeps its record: an entry's condition has no Lua form", src.edids[form])
			st.skipped += 1
			continue
		}
		write_file(powers_dir, src.edids[form], text) or_return
		st.spells += 1
	}
	for name, text in copies.files {
		write_file(effects_dir, name, text) or_return
		st.effects += 1
	}
	perks_dir, _ := filepath.join({out_dir, "perks"}, context.temp_allocator)
	os.make_directory_all(perks_dir)
	for form in src.db.perks {
		chain := perk_chain(src, form)
		if chain == nil || !chain_wanted(src, chain) {continue}
		text, done := perk_lua(src, chain)
		if !done {
			log.warnf("magic: perk %s keeps its record: a condition has no Lua form", src.edids[form])
			st.skipped += 1
			continue
		}
		if text == "" {continue}
		write_file(perks_dir, src.edids[form], text) or_return
		st.perks += 1
	}
	return st, true
}

@(private)
write_file :: proc(dir, name, text: string) -> bool {
	path, _ := filepath.join({dir, fmt.tprintf("%s.lua", name)}, context.temp_allocator)
	if err := os.write_entire_file(path, transmute([]u8)text); err != nil {
		log.errorf("magic: cannot write %s: %v", path, err)
		return false
	}
	return true
}

// load reads `plugins` from `data_dir` into a Source.
load :: proc(data_dir: string, plugins, only: []string) -> (src: Source, ok: bool) {
	inputs := make([dynamic]gamedb.Plugin_Input, context.temp_allocator)
	defer for p in inputs {delete(p.data)}
	for name in plugins {
		path, _ := filepath.join({data_dir, name}, context.temp_allocator)
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			log.errorf("magic: cannot read %s: %v", path, err)
			return
		}
		append(&inputs, gamedb.Plugin_Input{name = name, data = data})
	}
	order := gamedb.resolve_load_order(inputs[:], context.temp_allocator)
	src.db = gamedb.build_plugins(order)
	for p in order {
		src.files[p.self_slot] = p.name
		scan(&src, p, len(only) == 0 || has_fold(only, p.name))
	}
	for _, sp in src.db.spells {
		kind := Uses{.Poison} if sp.info.type == .Poison else {.Disease} if sp.info.type == .Disease else {}
		add_uses(&src, sp.effects, sp.info.type == .Ability || sp.info.cast_type == .Constant_Effect, kind)
	}
	for _, en in src.db.enchantments {add_uses(&src, en.effects, en.info.cast_type == .Constant_Effect)}
	for _, po in src.db.potions {add_uses(&src, po.effects, false, {.Poison} if po.poison else {})}
	return src, true
}

destroy :: proc(src: ^Source) {
	gamedb.destroy(&src.db)
	for _, e in src.edids {delete(e)}
	delete(src.edids)
	delete(src.files)
	delete(src.wanted)
	delete(src.lasting)
}

@(private)
add_uses :: proc(src: ^Source, refs: []gamedb.Magic_Effect_Ref, lasting: bool, kind: Uses = {}) {
	for r in refs {
		u := src.lasting[r.effect] + kind
		u += {.Lasting} if lasting else {.Timed}
		if !lasting && r.duration > 0 {u += {.Long}}
		src.lasting[r.effect] = u
	}
}

// Scan is one plugin's walk: it keeps editor ids, and marks magic forms it touches as wanted.
@(private)
Scan :: struct {
	src:    ^Source,
	wanted: bool,
}

// MAGIC_TYPES are the records the translator writes.
@(private)
MAGIC_TYPES := [?]string{"MGEF", "SPEL", "SCRL", "ENCH", "ALCH", "INGR", "SHOU", "PERK"}

// UNNAMED_TYPES have no editor id worth a decompress.
@(private)
UNNAMED_TYPES := [?]string{"NAVM", "LAND", "PGRE", "NAVI"}

@(private)
scan :: proc(src: ^Source, p: gamedb.Loaded_Plugin, wanted: bool) {
	s := Scan{src, wanted}
	fm := p.fm
	esm.walk(p.data, scan_record, &s, &fm)
}

@(private)
scan_record :: proc(rec: esm.Record, ctx: esm.Walk_Context, user: rawptr) -> bool {
	s := cast(^Scan)user
	if has(UNNAMED_TYPES[:], rec.type) {return true}
	fl, backing, ok := esm.fields(rec)
	if !ok {return true}
	defer {delete(fl); delete(backing)}
	if edid := esm.editor_id(fl); edid != "" {
		if old, seen := s.src.edids[rec.form_id]; seen {delete(old)}
		s.src.edids[rec.form_id] = strings.clone(edid)
	}
	if s.wanted && has(MAGIC_TYPES[:], rec.type) {s.src.wanted[rec.form_id] = true}
	return true
}

// form_name names a form for Lua: its editor id when that finds it again, else form_ref.
form_name :: proc(src: ^Source, form: Form_ID) -> string {
	edid := src.edids[form]
	if f, ok := gamedb.form_by_editor_id(&src.db, edid); ok && f == form {return edid}
	return form_ref(src, form)
}

// form_ref writes a form as its file and local id, "Skyrim.esm:012FCD".
form_ref :: proc(src: ^Source, form: Form_ID) -> string {
	return fmt.tprintf("%s:%06X", src.files[u32(form >> 32)], u32(form) & 0xFFFFFF)
}

// sorted_keys are a form map's keys in form order, so a run writes the same files each time.
@(private)
sorted_keys :: proc(m: map[Form_ID]$V) -> []Form_ID {
	out := make([dynamic]Form_ID, 0, len(m), context.temp_allocator)
	for k in m {append(&out, k)}
	slice.sort(out[:])
	return out[:]
}

@(private)
has :: proc(list: []string, s: string) -> bool {
	for x in list {if x == s {return true}}
	return false
}

@(private)
has_fold :: proc(list: []string, s: string) -> bool {
	for x in list {if strings.equal_fold(x, s) {return true}}
	return false
}
