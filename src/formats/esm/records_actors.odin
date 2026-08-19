package esm

// Typed decoders for the actor-identity records an NPC_ links out to: its RACE, CLAS class,
// VTYP voice type and DOFT outfit, plus AVIF (the actor-value definitions). Companion to
// records_forms.odin; same contract — fields pre-split by fields(), strings alias the field
// bytes, formIDs RAW/local until the caller remaps. Offsets validated against the real
// Skyrim.esm, with the validating record named per decoder.

// --- OTFT (outfit) ----------------------------------------------------------------------

// outfit_items collects an OTFT's INAM contents — the items an NPC wearing this outfit spawns
// with. INAM is a packed u32 array (one field holding every item), so this reads all of them
// like KWDA rather than one-per-field. Returns a freshly-allocated slice the caller owns (nil
// when the outfit is empty). (Validated vs DremoraWarlockOutfit: one INAM, 8 bytes = 2 items.)
outfit_items :: proc(fields: []Field, allocator := context.allocator) -> []u32 {
	n := 0
	for f in fields {
		if f.type == "INAM" {
			n += len(f.data) / 4
		}
	}
	if n == 0 {
		return nil
	}
	out := make([]u32, n, allocator)
	i := 0
	for f in fields {
		if f.type != "INAM" {
			continue
		}
		for off := 0; off + 4 <= len(f.data); off += 4 {
			out[i] = rd32(f.data, off)
			i += 1
		}
	}
	return out
}

// --- VTYP (voice type) ------------------------------------------------------------------

// VTYP DNAM flag bits.
VTYP_ALLOW_DEFAULT_DIALOGUE :: 0x01
VTYP_FEMALE :: 0x02

// voice_type_flags reads a VTYP's DNAM flags byte. ok=false when absent. A voice type carries
// no other data — its identity is its editor id, and the dialogue system keys off the form.
voice_type_flags :: proc(fields: []Field) -> (u8, bool) {
	if f, ok := find_field(fields, "DNAM"); ok && len(f.data) >= 1 {
		return f.data[0], true
	}
	return 0, false
}

// --- RACE -------------------------------------------------------------------------------

// RACE_SKILL_BONUSES is how many (skill, bonus) pairs a RACE's DATA block carries. Unused slots
// are terminated with skill = RACE_SKILL_NONE.
RACE_SKILL_BONUSES :: 7

// RACE_SKILL_NONE marks an unused skill-bonus slot (the u8 0xFF terminator).
RACE_SKILL_NONE :: u8(0xFF)

// Race_Skill_Bonus is one racial skill bonus: `skill` is an ActorValue INDEX (the same space
// MGEF uses — 6 One-Handed, 7 Two-Handed, 9 Block …; resolve it through the AVIF tables), and
// `bonus` is the flat number added to that skill at character creation.
Race_Skill_Bonus :: struct {
	skill: u8,
	bonus: u8,
}

// Race_Info is a RACE's DATA block — the identity/stat layer only. RACE records are enormous
// (tint layers, head parts, body data, attack sets: 20k+ subrecords across the 99 vanilla
// races); everything past this struct is appearance and is deliberately left undecoded until
// a character/appearance phase needs it.
Race_Info :: struct {
	bonuses:       [RACE_SKILL_BONUSES]Race_Skill_Bonus,
	bonus_count:   int, // populated slots, counted up to the first RACE_SKILL_NONE
	height_male:   f32,
	height_female: f32,
	weight_male:   f32,
	weight_female: f32,
	flags:         u32, // kept raw — a wide CK bitfield (playable, child, immobile, …)
}

// race_info reads a RACE's DATA: 7 × {skill u8, bonus u8} @0, height male/female f32 @16/@20,
// weight male/female f32 @24/@28, flags u32 @32. ok=false when absent/short. (Validated vs
// NordRaceAstrid: bonuses decode as Two-Handed +10, One-Handed/Block/Smithing/Speechcraft/
// Light Armor +5 — Skyrim's published Nord bonuses, and an independent confirmation of the
// AVIF actor-value index derivation.)
race_info :: proc(fields: []Field) -> (ri: Race_Info, ok: bool) {
	f, fok := find_field(fields, "DATA")
	if !fok || len(f.data) < 36 {
		return {}, false
	}
	d := f.data
	for i in 0 ..< RACE_SKILL_BONUSES {
		s, b := d[i * 2], d[i * 2 + 1]
		ri.bonuses[i] = Race_Skill_Bonus{skill = s, bonus = b}
		if s != RACE_SKILL_NONE && ri.bonus_count == i {
			ri.bonus_count = i + 1
		}
	}
	ri.height_male = rf32(d, 16)
	ri.height_female = rf32(d, 20)
	ri.weight_male = rf32(d, 24)
	ri.weight_female = rf32(d, 28)
	ri.flags = rd32(d, 32)
	return ri, true
}

// --- CLAS (class) -----------------------------------------------------------------------

// CLASS_SKILL_WEIGHTS is how many per-skill weights a CLAS DATA block carries (the 18 Skyrim
// skills, in ActorValue order starting at One-Handed).
CLASS_SKILL_WEIGHTS :: 18

// Class_Info is a CLAS's DATA block: how an NPC of this class distributes its level-ups. The
// skill weights bias auto-calculated skills; the attribute weights split health/magicka/stamina.
Class_Info :: struct {
	training_skill:  u8, // ActorValue index this class can train
	training_level:  u8, // maximum level it trains to
	skill_weights:   [CLASS_SKILL_WEIGHTS]u8,
	bleedout_default: f32,
	voice_points:    u32,
	health_weight:   u8,
	magicka_weight:  u8,
	stamina_weight:  u8,
	flags:           u8,
}

// class_info reads a CLAS's DATA (36 bytes): unknown u32 @0, training skill u8 @4, training
// level u8 @5, 18 skill weights @6, bleedout default f32 @24, voice points u32 @28, health /
// magicka / stamina weights @32/@33/@34, flags u8 @35. ok=false when absent/short. (Validated
// vs EncClassDremoraMelee + TrainerMarksmanJourneyman.)
class_info :: proc(fields: []Field) -> (ci: Class_Info, ok: bool) {
	f, fok := find_field(fields, "DATA")
	if !fok || len(f.data) < 36 {
		return {}, false
	}
	d := f.data
	ci.training_skill = d[4]
	ci.training_level = d[5]
	copy(ci.skill_weights[:], d[6:6 + CLASS_SKILL_WEIGHTS])
	ci.bleedout_default = rf32(d, 24)
	ci.voice_points = rd32(d, 28)
	ci.health_weight = d[32]
	ci.magicka_weight = d[33]
	ci.stamina_weight = d[34]
	ci.flags = d[35]
	return ci, true
}

// --- PERK ------------------------------------------------------------------------------

// Perk_Header is a PERK's DATA block — the 5 bytes that sit before its first entry.
Perk_Header :: struct {
	trait:     bool,
	min_level: u8,
	num_ranks: u8,
	playable:  bool,
	hidden:    bool,
}

// perk_header decodes a PERK's header DATA. A PERK carries SEVERAL DATA subrecords — one header,
// then one inside each PRKE/PRKF entry — so this takes the one before the first PRKE rather than
// the first DATA it finds. VERIFIED against Skyrim.esm: 375 records, each with exactly one 5-byte
// DATA (entry DATAs are 3, 4 or 8 bytes). Byte order is trait, min level, rank count, playable,
// hidden. Validated on Armsman00 (playable, not hidden) and TG00Pickpockethelper (hidden).
//
// WARNING: num_ranks is authored inconsistently and must not be trusted. Armsman and Juggernaut
// are five-rank chains whose every record reports 1, while the single-rank ApprenticeLocks25
// reports 5. Across the base game 349 records say 1 and 26 say 5, which matches no real grouping.
// The reliable rank count is the length of the NNAM chain — see gamedb.perk_ranks.
perk_header :: proc(fields: []Field) -> (h: Perk_Header, ok: bool) {
	for f in fields {
		if f.type == "PRKE" {
			break // entries start here, and every DATA past this point belongs to one
		}
		if f.type == "DATA" && len(f.data) >= 5 {
			return Perk_Header {
					trait = f.data[0] != 0,
					min_level = f.data[1],
					num_ranks = f.data[2],
					playable = f.data[3] != 0,
					hidden = f.data[4] != 0,
				},
				true
		}
	}
	return {}, false
}

// --- AVIF (actor value information) ------------------------------------------------------

// ACTOR_VALUE_COUNT is the size of Skyrim's ActorValue index space (0 Aggression … 163 Reflect
// Damage). Not every index has an AVIF record — 149 of the 164 do; the rest are engine-only
// slots with no authored name.
ACTOR_VALUE_COUNT :: 164

// AV_ILLUSION is the one actor value whose AVIF editor id is a leftover from Oblivion: index 21
// is Illusion in every Skyrim UI and Papyrus call, but its record is still named "AVMysticism".
// Consumers that derive a name from the editor id must special-case it.
AV_ILLUSION :: 21

// Actor_Value_Block is one contiguous run of AVIF records: `lo`..`hi` local formIDs map onto
// ActorValue indices starting at `first`. The mapping is NOT file order and NOT a single
// offset — Skyrim's AVIF records sit in four separate formID runs whose order differs from the
// enum's. See ACTOR_VALUE_BLOCKS.
Actor_Value_Block :: struct {
	lo, hi: u32,
	first:  i32,
}

// ACTOR_VALUE_BLOCKS maps base-game AVIF formIDs onto ActorValue indices. DERIVED from the real
// Skyrim.esm, not guessed: these four runs cover all 149 AVIF records with none left over, and
// the last one lands exactly on index 163 (AVReflectDamage), the final actor value. Four
// independent cross-checks agree — MGEF magic-skill 18/19 read AVAlteration/AVConjuration,
// fortify-health primary 24 reads AVHealth, paralysis primary 53 reads AVParalysis, and
// NordRace's DATA bonuses decode to Skyrim's published Nord skill list.
ACTOR_VALUE_BLOCKS :: [4]Actor_Value_Block {
	{0x0000_04B0, 0x0000_04B5, 0}, // Aggression … Assistance
	{0x0000_044C, 0x0000_045D, 6}, // One-Handed … Enchanting (the 18 skills)
	{0x0000_03E8, 0x0000_03F6, 24}, // Health … Voice Rate
	{0x0000_05CE, 0x0000_064A, 39}, // Damage Resist … Reflect Damage
}

// actor_value_index maps a base-game AVIF's LOCAL formID to its ActorValue index. ok=false for
// any formID outside the four blocks — the enum is engine-hardcoded, so only Skyrim.esm's own
// AVIF records have an index (a mod's new AVIF is a form, not a new enum slot).
actor_value_index :: proc(local_form: u32) -> (i32, bool) {
	for b in ACTOR_VALUE_BLOCKS {
		if local_form >= b.lo && local_form <= b.hi {
			return b.first + i32(local_form - b.lo), true
		}
	}
	return 0, false
}

// actor_value_form maps an ActorValue index back to its base-game AVIF local formID. ok=false
// for an index with no AVIF record (an engine-only slot, e.g. 37 Voice Points).
actor_value_form :: proc(index: i32) -> (u32, bool) {
	for b in ACTOR_VALUE_BLOCKS {
		span := i32(b.hi - b.lo)
		if index >= b.first && index <= b.first + span {
			return b.lo + u32(index - b.first), true
		}
	}
	return 0, false
}
