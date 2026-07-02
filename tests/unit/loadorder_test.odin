package unit_tests

// Dependency-validation tests (docs/mods.md "Manager/profiles"): gamedb.validate_masters flags a
// plugin whose declared master isn't in the enabled set, and resolve_load_order poisons an
// unresolved master's slot to esm.INVALID_SLOT rather than cross-wiring it onto the identity slot.

import "core:encoding/endian"
import "core:testing"
import "../../src/formats/esm"
import "../../src/gamedb"

@(test)
test_validate_masters :: proc(t: ^testing.T) {
	names := []string{"Skyrim.esm", "Cool.esp", "Orphan.esp"}
	masters := [][]string {
		{}, // Skyrim
		{"Skyrim.esm"}, // Cool: satisfied
		{"Skyrim.esm", "Missing.esm"}, // Orphan: Missing.esm is absent
	}
	miss := gamedb.validate_masters(names, masters)
	defer {
		for m in miss {delete(m.plugin);delete(m.master)}
		delete(miss)
	}
	testing.expect(t, len(miss) == 1, "exactly one missing-master failure")
	if len(miss) == 1 {
		testing.expect(t, miss[0].plugin == "Orphan.esp", "the dependent plugin is named")
		testing.expect(t, miss[0].master == "Missing.esm", "the missing master is named")
	}
}

@(test)
test_validate_masters_case_insensitive :: proc(t: ^testing.T) {
	// A master reference resolves case-insensitively against the present set (Skyrim's convention).
	names := []string{"skyrim.esm", "Dep.esp"}
	masters := [][]string{{}, {"Skyrim.ESM"}}
	miss := gamedb.validate_masters(names, masters)
	defer delete(miss)
	testing.expect(t, len(miss) == 0, "case-insensitive master match ⇒ no failure")
}

@(test)
test_resolve_missing_master_poisons_slot :: proc(t: ^testing.T) {
	// Orphan.esp declares Missing.esm as its FIRST master (local index 0), but it isn't in the set.
	// resolve_load_order must map slot[0] to INVALID_SLOT, not leave the identity default slot[0]==0
	// (which would cross-wire Orphan's master-0 refs onto whatever plugin owns global slot 0).
	orphan := tes4_header({"Missing.esm"})
	skyrim := tes4_header({})
	inputs := []gamedb.Plugin_Input {
		{name = "Skyrim.esm", data = skyrim},
		{name = "Orphan.esp", data = orphan},
	}
	order := gamedb.resolve_load_order(inputs)
	defer delete(order)

	found := false
	for lp in order {
		if lp.name == "Orphan.esp" {
			found = true
			testing.expect(t, lp.fm.slot[0] == esm.INVALID_SLOT, "missing master's slot is poisoned to INVALID_SLOT")
			// The self slot (local index 1 == len(masters)) still resolves to Orphan's own global slot.
			testing.expect(t, lp.fm.slot[1] == u32(lp.index), "self slot resolves to the plugin's own index")
		}
	}
	testing.expect(t, found, "Orphan.esp is in the resolved order")
}

// tes4_header builds minimal TES4 header bytes (HEDR + one MAST per master) for the resolver — just
// enough for esm.parse_header to read the master list. Temp-allocated (auto-freed at test end).
@(private = "file")
tes4_header :: proc(masters: []string) -> []u8 {
	body := make([dynamic]u8, 0, 64, context.temp_allocator)
	hedr: [12]u8 // version f32, num records i32, next object id u32
	endian.put_u32(hedr[8:], .Little, 0x0000_0500)
	tes4_field(&body, "HEDR", hedr[:])
	for m in masters {
		name := make([]u8, len(m) + 1, context.temp_allocator) // NUL-terminated master filename
		copy(name, transmute([]u8)m)
		tes4_field(&body, "MAST", name)
	}
	out := make([dynamic]u8, 0, 128, context.temp_allocator)
	// record header: type[4] size:u32 flags:u32 formid:u32 timestamp:u32 versions:u32
	append(&out, ..transmute([]u8)string("TES4"))
	put_le_u32(&out, u32(len(body)))
	put_le_u32(&out, 0) // flags
	put_le_u32(&out, 0) // formid
	put_le_u32(&out, 0) // timestamp/vc
	put_le_u32(&out, 0) // versions
	append(&out, ..body[:])
	return out[:]
}

@(private = "file")
tes4_field :: proc(b: ^[dynamic]u8, type: string, data: []u8) {
	append(b, ..transmute([]u8)type)
	sz: [2]u8
	endian.put_u16(sz[:], .Little, u16(len(data)))
	append(b, ..sz[:])
	append(b, ..data)
}

@(private = "file")
put_le_u32 :: proc(b: ^[dynamic]u8, v: u32) {
	t: [4]u8
	endian.put_u32(t[:], .Little, v)
	append(b, ..t[:])
}
