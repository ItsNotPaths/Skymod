package mods

// The form-table (docs/mods.md "Two tiers"; docs/saves.md §4.4) is the global, cross-profile map
// from a plugin's STABLE identity to an interned u32 `slot` — the high word of every Form_ID that
// plugin defines. It decouples identity from load order: a slot is allocated once, monotonically,
// on a plugin's first sighting and NEVER reused (tombstone), so reordering/adding mods changes
// override PRECEDENCE (governed by load order) but never a form's IDENTITY — and saves survive
// reorders because they embed the slot↔identity bridge and remap on load. This file is data + text
// persistence only (no filesystem scan of mods), so it's unit-testable in isolation.
//
// Slot space (u32):
//   0x00..0x0F  reserved for official/system masters. Skyrim.esm is PINNED at 0 — raw refs like the
//               persistent cell 0x00000D74 and the player 0x14 assume a high word of 0.
//   0x10..      user plugins: monotonic, tombstoned (never reused, even across uninstall/re-add).
//   0xFFFFFFFF  runtime-created forms (formid.CREATED_FORM_BASE) — reserved, never interned here.
//
// form_table.txt line format (one plugin per line, tab-separated; ordered by slot):
//   <slot-hex8>\t<uuid>\t<filename>
// The install-local key is the case-folded filename (how master refs already resolve); `uuid` is the
// cross-install portability identity (the sidecar UUID or a content-hash fallback), carried alongside
// so a save from one install can be remapped onto another by matching identity rather than raw slot.

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

USER_SLOT_BASE :: u32(0x10) // first slot handed to a user plugin (official masters sit below)
RESERVED_SLOT_MAX :: u32(0x0F) // slots 0..this are official/system, pinned by formtable_assign_official
OFFICIAL_UUID :: "skyrim-official" // sentinel identity for vanilla/DLC masters (fixed low slots)

// Slot_Entry is one plugin's stable binding. Strings are owned by the Form_Table's allocator.
Slot_Entry :: struct {
	slot:     u32,
	uuid:     string, // cross-install portability id (sidecar UUID / content hash / OFFICIAL_UUID)
	filename: string, // original-case plugin filename (display + save bridge); key is its lowercasing
}

Form_Table :: struct {
	by_key:    map[string]Slot_Entry, // case-folded filename -> entry
	next_user: u32, // next free user slot (monotonic; never rewinds)
	allocator: runtime.Allocator,
}

formtable_init :: proc(ft: ^Form_Table, allocator := context.allocator) {
	ft.allocator = allocator
	ft.by_key = make(map[string]Slot_Entry, allocator)
	ft.next_user = USER_SLOT_BASE
}

formtable_destroy :: proc(ft: ^Form_Table) {
	for k, e in ft.by_key {
		delete(k, ft.allocator)
		delete(e.uuid, ft.allocator)
		delete(e.filename, ft.allocator)
	}
	delete(ft.by_key)
}

// formtable_intern returns the stable slot for a user plugin, allocating a fresh monotonic slot on
// first sight (recording its identity). Case-insensitive on filename. Re-interning a known plugin
// returns its ORIGINAL slot — that's the tombstone guarantee: a slot is never reused, and a mod
// removed then re-added maps back to the same slot because the binding persists in form_table.txt.
// If a stored entry has no uuid yet (legacy) and one is now supplied, it's backfilled.
formtable_intern :: proc(ft: ^Form_Table, filename, uuid: string) -> u32 {
	key := strings.to_lower(filename, context.temp_allocator)
	if e := &ft.by_key[key]; e != nil {
		if e.uuid == "" && uuid != "" {e.uuid = strings.clone(uuid, ft.allocator)}
		return e.slot
	}
	slot := ft.next_user
	ft.next_user += 1
	ft.by_key[strings.clone(key, ft.allocator)] = Slot_Entry {
		slot     = slot,
		uuid     = strings.clone(uuid, ft.allocator),
		filename = strings.clone(filename, ft.allocator),
	}
	return slot
}

// formtable_assign_official pins a fixed low slot for an official/system master (idempotent, and
// re-pins on every call since the official set is fixed). Skyrim.esm must be pinned to 0.
formtable_assign_official :: proc(ft: ^Form_Table, filename: string, slot: u32) {
	assert(slot <= RESERVED_SLOT_MAX, "official slot outside the reserved 0x00..0x0F range")
	key := strings.to_lower(filename, context.temp_allocator)
	if e := &ft.by_key[key]; e != nil {
		e.slot = slot
		return
	}
	ft.by_key[strings.clone(key, ft.allocator)] = Slot_Entry {
		slot     = slot,
		uuid     = strings.clone(OFFICIAL_UUID, ft.allocator),
		filename = strings.clone(filename, ft.allocator),
	}
}

// formtable_slot looks up a plugin's slot by (case-folded) filename — the install-local key. Used to
// build the resolve_load_order `slot_of` map and to source the save bridge.
formtable_slot :: proc(ft: ^Form_Table, filename: string) -> (slot: u32, ok: bool) {
	key := strings.to_lower(filename, context.temp_allocator)
	if e, has := ft.by_key[key]; has {return e.slot, true}
	return 0, false
}

// formtable_entry_by_slot returns the identity bound to `slot` (uuid + filename) — the save path
// walks the slots its Form_IDs reference and emits these into the save's embedded bridge. Linear
// (the table is small); returns ok=false for an unknown slot (e.g. the reserved created slot).
formtable_entry_by_slot :: proc(ft: ^Form_Table, slot: u32) -> (e: Slot_Entry, ok: bool) {
	for _, se in ft.by_key {
		if se.slot == slot {return se, true}
	}
	return {}, false
}

// formtable_resolve maps a SAVED identity (uuid, filename) to the CURRENT install's slot (the
// load-time remap). Filename is the PRIMARY key — plugin filenames are stable across installs, so a
// save from install A resolves onto B's slot for the same file; the uuid is the DISAMBIGUATOR that
// stops cross-wiring when a different mod now ships the same filename. Resolution order:
//   1. filename hit whose uuid is empty/OFFICIAL/matching   → the common path (same or identical mod)
//   2. filename hit but uuid DIFFERS (another mod took that name) → fall through, don't cross-wire
//   3. a UNIQUE uuid match                                    → plugin renamed but mod identity intact
// ok=false ⇒ the mod is missing/ambiguous on this install (the caller drops deltas keyed on it and
// lists it in the save-vs-modset report). Multiple plugins may share a mod uuid, so a non-unique
// uuid-only match is deliberately refused (conservative — better a dropped delta than a wrong object).
formtable_resolve :: proc(ft: ^Form_Table, uuid, filename: string) -> (slot: u32, ok: bool) {
	key := strings.to_lower(filename, context.temp_allocator)
	if e, has := ft.by_key[key]; has {
		if uuid == "" || uuid == OFFICIAL_UUID || e.uuid == uuid {return e.slot, true}
	}
	if uuid != "" && uuid != OFFICIAL_UUID {
		found: u32
		count := 0
		for _, se in ft.by_key {
			if se.uuid == uuid {found = se.slot; count += 1}
		}
		if count == 1 {return found, true}
	}
	return 0, false
}

// formtable_save writes the table to `path` as ordered, tab-separated text. Atomic: writes
// `<path>.tmp` then renames over `path`, so a crash mid-write can't corrupt the save-critical table.
formtable_save :: proc(ft: ^Form_Table, path: string) -> bool {
	entries := make([dynamic]Slot_Entry, 0, len(ft.by_key), context.temp_allocator)
	for _, e in ft.by_key {append(&entries, e)}
	slice.sort_by(entries[:], proc(a, b: Slot_Entry) -> bool {return a.slot < b.slot})

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "# SkyMod form-table — <slot-hex>\\t<uuid>\\t<filename>. Slots are stable and never reused.\n")
	for e in entries {
		fmt.sbprintf(&b, "%08X\t%s\t%s\n", e.slot, e.uuid, e.filename)
	}

	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if err := os.write_entire_file(tmp, transmute([]byte)strings.to_string(b)); err != nil {
		log.errorf("formtable: could not write %q: %v", tmp, err)
		return false
	}
	if err := os.rename(tmp, path); err != nil {
		log.errorf("formtable: could not rename %q -> %q: %v", tmp, path, err)
		return false
	}
	return true
}

// formtable_load reads `path` into `ft` (already formtable_init'd), restoring every binding and
// advancing next_user past the highest user slot seen so fresh interns can't collide. Missing file →
// false (caller starts empty). Malformed lines are skipped. Later lines win on a duplicate key.
formtable_load :: proc(ft: ^Form_Table, path: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return false}
	it := string(data)
	for raw in strings.split_lines_iterator(&it) {
		s := strings.trim_space(raw)
		if s == "" || s[0] == '#' {continue}
		parts := strings.split(s, "\t", context.temp_allocator)
		if len(parts) < 3 {continue}
		slot64, ok := strconv.parse_u64_of_base(strings.trim_space(parts[0]), 16)
		if !ok {continue}
		slot := u32(slot64)
		uuid := strings.trim_space(parts[1])
		fname := strings.trim_space(parts[2])
		key := strings.to_lower(fname, context.temp_allocator)
		if e := &ft.by_key[key]; e != nil { // duplicate line: update in place (free the prior strings)
			delete(e.uuid, ft.allocator)
			delete(e.filename, ft.allocator)
			e.slot = slot
			e.uuid = strings.clone(uuid, ft.allocator)
			e.filename = strings.clone(fname, ft.allocator)
		} else {
			ft.by_key[strings.clone(key, ft.allocator)] = Slot_Entry {
				slot     = slot,
				uuid     = strings.clone(uuid, ft.allocator),
				filename = strings.clone(fname, ft.allocator),
			}
		}
		if slot >= USER_SLOT_BASE && slot >= ft.next_user {ft.next_user = slot + 1}
	}
	return true
}
