package gamedb

// Relationships (RELA, xEdit): the rank between two NPC_s and the kind of tie (ASTP: spouse,
// sibling, parent...). A pair has one record, read from either side.

import "../formats/esm"

Relationship :: struct {
	rank:        i32, // as GetRelationshipRank reads it: 4 Lover .. 0 Acquaintance .. -4 Archnemesis
	association: Form_ID, // ASTP
}

// ASTP DATA flag.
ASSOCIATION_FAMILY :: 0x1

@(private)
index_relationship :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	for f in fl {
		if f.type != "DATA" || len(f.data) < 16 {continue}
		a, b := esm.remap_form(fm, u32_le(f.data, 0)), esm.remap_form(fm, u32_le(f.data, 4))
		rank := i32(u16(f.data[8]) | u16(f.data[9]) << 8) // 0 Lover .. 4 Acquaintance .. 8 Archnemesis
		db.relationships[pair(a, b)] = {rank = 4 - rank, association = esm.remap_form(fm, u32_le(f.data, 12))}
	}
}

@(private)
index_association :: proc(db: ^DB, rec: esm.Record) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	for f in fl {
		if f.type == "DATA" && len(f.data) >= 1 {db.associations[rec.form_id] = u32(f.data[0])}
	}
}

// relationship is the authored tie between two NPC_s, either way round.
relationship :: proc(db: ^DB, a, b: Form_ID) -> (Relationship, bool) {
	if db == nil {return {}, false}
	return db.relationships[pair(a, b)]
}

association_is_family :: proc(db: ^DB, association: Form_ID) -> bool {
	return db.associations[association] & ASSOCIATION_FAMILY != 0
}

@(private = "file")
pair :: proc(a, b: Form_ID) -> [2]Form_ID {
	return {min(a, b), max(a, b)}
}

@(private = "file")
u32_le :: proc(b: []u8, off: int) -> u32 {
	return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24
}
