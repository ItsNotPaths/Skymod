package esm

// Typed decoders for the form-metadata + magic + quest-alias record subset (companion to
// records.odin, which covers cells / placements / base models). Same contract: fields come
// pre-split by fields(), strings alias the field bytes, formIDs are RAW/local until the
// caller remaps them. Every byte offset below was validated against the real Skyrim.esm —
// the validating record is named in each comment.

// Records the base game ships that nothing here decodes into their content.
//
// (hole arma-records :tags records :sev blocker) ARMA is never decoded — ARMO has stats and slots but no per-race mesh, so worn armour cannot be drawn.
// (hole weather-select :tags records :sev gap) REGN and CLMT are never decoded — WTHR is read but nothing selects a weather, so there is no regional climate.

// --- keywords -------------------------------------------------------------------------

// keywords collects a form's KWDA keyword formIDs — the tag set `Form.HasKeyword` tests
// against. KSIZ (a u32 count) is a convenience header; the KWDA payload is authoritative,
// so this reads every KWDA field's u32s and ignores KSIZ. Returns a freshly-allocated slice
// the caller owns (nil when the form carries none). Raw/local formIDs. (Validated vs
// DA14DremoraGreatswordFire03: KSIZ=3, KWDA=12 bytes.)
keywords :: proc(fields: []Field, allocator := context.allocator) -> []u32 {
	n := 0
	for f in fields {
		if f.type == "KWDA" {
			n += len(f.data) / 4
		}
	}
	if n == 0 {
		return nil
	}
	out := make([]u32, n, allocator)
	i := 0
	for f in fields {
		if f.type != "KWDA" {
			continue
		}
		for off := 0; off + 4 <= len(f.data); off += 4 {
			out[i] = rd32(f.data, off)
			i += 1
		}
	}
	return out
}

// field_u32 reads a subrecord's leading u32 — the shape of every "one number" subrecord
// (a FACT RNAM rank index, …). ok=false when the field is too short.
field_u32 :: proc(f: Field) -> (u32, bool) {
	if len(f.data) < 4 {
		return 0, false
	}
	return rd32(f.data, 0), true
}

// keyword_color reads a KYWD record's CNAM display color (packed RGB). ok=false if absent.
// A KYWD's identity is its EDID — the record carries no FULL.
keyword_color :: proc(fields: []Field) -> (u32, bool) {
	if f, ok := find_field(fields, "CNAM"); ok && len(f.data) >= 4 {
		return rd32(f.data, 0), true
	}
	return 0, false
}

// --- linked references ----------------------------------------------------------------

// Linked_Ref is one XLKR link of a placed reference: the reference it points at, tagged by a
// keyword. `keyword` 0 is the DEFAULT link (the one bare `GetLinkedRef()` returns); a non-zero
// keyword names the channel `GetLinkedRef(akKeyword)` selects. Both are raw/local until remapped.
Linked_Ref :: struct {
	keyword: u32,
	ref:     u32,
}

// linked_refs collects a REFR's XLKR links in declaration order. XLKR is 8 bytes: keyword
// formID (u32) + target reference formID (u32). Returns a freshly-allocated slice the caller
// owns (nil when the ref links nothing — the common case). (Validated vs Skyrim.esm REFRs:
// 7 of the first 3000 carry XLKR, all 8 bytes, keyword 0.)
linked_refs :: proc(fields: []Field, allocator := context.allocator) -> []Linked_Ref {
	n := 0
	for f in fields {
		if f.type == "XLKR" && len(f.data) >= 8 {
			n += 1
		}
	}
	if n == 0 {
		return nil
	}
	out := make([]Linked_Ref, n, allocator)
	i := 0
	for f in fields {
		if f.type == "XLKR" && len(f.data) >= 8 {
			out[i] = Linked_Ref{keyword = rd32(f.data, 0), ref = rd32(f.data, 4)}
			i += 1
		}
	}
	return out
}

// --- faction membership (NPC_ SNAM) ----------------------------------------------------

// Faction_Membership is one SNAM row of an actor base: a faction it belongs to and its rank in
// it. `faction` is raw/local until remapped. Rank is signed (−1 means "member, no rank" in the
// CK's convention; vanilla NPCs are almost all rank 0). This is the BASELINE the runtime
// faction overlay diverges from.
Faction_Membership :: struct {
	faction: u32,
	rank:    i8,
}

// faction_memberships collects an NPC_'s SNAM faction rows in declaration order. SNAM is 8
// bytes: faction formID (u32) + rank (i8) + 3 unused. Returns a freshly-allocated slice the
// caller owns (nil when the actor joins none). (Validated vs dunTransmogrifyHare: 3 SNAMs,
// 8 bytes each, rank byte @4.)
faction_memberships :: proc(fields: []Field, allocator := context.allocator) -> []Faction_Membership {
	n := 0
	for f in fields {
		if f.type == "SNAM" && len(f.data) >= 8 {
			n += 1
		}
	}
	if n == 0 {
		return nil
	}
	out := make([]Faction_Membership, n, allocator)
	i := 0
	for f in fields {
		if f.type == "SNAM" && len(f.data) >= 8 {
			out[i] = Faction_Membership{faction = rd32(f.data, 0), rank = cast(i8)f.data[4]}
			i += 1
		}
	}
	return out
}

// --- FACT (faction) --------------------------------------------------------------------

// FACT DATA flag bits. Only the ones a consumer branches on are named; the raw u32 is kept so
// unlisted bits survive.
FACT_HIDDEN_FROM_PC :: 0x0000_0001
FACT_SPECIAL_COMBAT :: 0x0000_0002
FACT_TRACK_CRIME :: 0x0000_0040
FACT_IGNORE_MURDER :: 0x0000_0080
FACT_IGNORE_ASSAULT :: 0x0000_0100
FACT_IGNORE_STEALING :: 0x0000_0200
FACT_IGNORE_TRESPASS :: 0x0000_0400
FACT_DO_NOT_REPORT_CRIMES :: 0x0000_0800
FACT_IGNORE_PICKPOCKET :: 0x0000_2000
FACT_VENDOR :: 0x0000_4000

// Combat_Reaction is how members of one faction treat members of another (an XNAM row).
Combat_Reaction :: enum u32 {
	Neutral = 0,
	Enemy   = 1,
	Ally    = 2,
	Friend  = 3,
}

// Faction_Relation is one XNAM row: how this faction regards `faction`. `modifier` shifts the
// disposition; `combat` is the hard reaction. `faction` is raw/local until remapped.
Faction_Relation :: struct {
	faction:  u32,
	modifier: i32,
	combat:   Combat_Reaction,
}

// faction_relations collects a FACT's XNAM rows in declaration order. XNAM is 12 bytes:
// faction formID (u32) + modifier (i32) + combat reaction (u32). Returns a freshly-allocated
// slice the caller owns (nil when the faction relates to none). (Validated vs
// WinterholdJailFaction: one XNAM, faction 0x0DB1, modifier 0, combat 2 = Ally.)
faction_relations :: proc(fields: []Field, allocator := context.allocator) -> []Faction_Relation {
	n := 0
	for f in fields {
		if f.type == "XNAM" && len(f.data) >= 12 {
			n += 1
		}
	}
	if n == 0 {
		return nil
	}
	out := make([]Faction_Relation, n, allocator)
	i := 0
	for f in fields {
		if f.type == "XNAM" && len(f.data) >= 12 {
			out[i] = Faction_Relation {
				faction  = rd32(f.data, 0),
				modifier = cast(i32)rd32(f.data, 4),
				combat   = Combat_Reaction(rd32(f.data, 8)),
			}
			i += 1
		}
	}
	return out
}

// ECZN DATA flags (CommonLib BGSEncounterZone; UESP's table is off by one bit).
ECZN_NEVER_RESETS :: 0x01
ECZN_MATCH_PC_BELOW_MIN :: 0x02

Encounter_Zone :: struct {
	location:             u32, // raw formID
	min_level, max_level: u8,  // max 0 = no cap
	flags:                u8,  // ECZN_*
}

// encounter_zone reads an ECZN's DATA: owner, location, rank, min level, flags, max level.
encounter_zone :: proc(fields: []Field) -> (z: Encounter_Zone, ok: bool) {
	f := find_field(fields, "DATA") or_return
	if len(f.data) < 12 {return}
	return {rd32(f.data, 4), f.data[9], f.data[11], f.data[10]}, true
}

// Leveled actor difficulty (ACHR XLCM, CommonLib LEV_CREA_MODIFIER); absent = none.
LEVEL_MOD_EASY :: 0
LEVEL_MOD_MEDIUM :: 1
LEVEL_MOD_HARD :: 2
LEVEL_MOD_VERY_HARD :: 3

CONT_RESPAWNS :: 0x02

// container_respawns reads a CONT's DATA flags: a respawning container's contents reset with its cell.
container_respawns :: proc(fields: []Field) -> bool {
	f, ok := find_field(fields, "DATA")
	return ok && len(f.data) >= 1 && f.data[0] & CONT_RESPAWNS != 0
}

// faction_flags reads a FACT's DATA flags word (FACT_* bits). ok=false when absent.
faction_flags :: proc(fields: []Field) -> (u32, bool) {
	if f, ok := find_field(fields, "DATA"); ok && len(f.data) >= 4 {
		return rd32(f.data, 0), true
	}
	return 0, false
}

// Crime_Values is a crime faction's CRVA block: the bounty each offence carries and how the
// faction's guards respond. `steal_multiplier` scales the stolen item's gold value into bounty.
Crime_Values :: struct {
	arrest:           bool, // guards attempt arrest rather than attacking outright
	attack_on_detect: bool, // guards attack the moment they detect a wanted player
	murder:           u16,  // bounty per offence, in gold
	assault:          u16,
	trespass:         u16,
	pickpocket:       u16,
	steal_multiplier: f32,
	escape:           u16, // bounty for escaping custody
	werewolf:         u16, // bounty for being seen transformed
}

// faction_crime reads a FACT's CRVA crime values (20 bytes): arrest u8@0, attack-on-detect u8@1,
// murder u16@2, assault u16@4, trespass u16@6, pickpocket u16@8, unused u16@10, steal multiplier
// f32@12, escape u16@16, werewolf u16@18. ok=false when absent/short. (Validated vs
// CrimeFactionWhiterun: 1000 / 40 / 5 / 25 gold, ×0.5 steal, 100 escape, 1000 werewolf —
// Skyrim's canonical hold bounties.)
faction_crime :: proc(fields: []Field) -> (cv: Crime_Values, ok: bool) {
	f, fok := find_field(fields, "CRVA")
	if !fok || len(f.data) < 20 {
		return {}, false
	}
	return Crime_Values {
			arrest           = f.data[0] != 0,
			attack_on_detect = f.data[1] != 0,
			murder           = rd16(f.data, 2),
			assault          = rd16(f.data, 4),
			trespass         = rd16(f.data, 6),
			pickpocket       = rd16(f.data, 8),
			steal_multiplier = rf32(f.data, 12),
			escape           = rd16(f.data, 16),
			werewolf         = rd16(f.data, 18),
		},
		true
}

// --- magic: SPEL / SCRL / ENCH / MGEF ---------------------------------------------------

// Cast_Type is how a magic item is cast. Delivery is how it reaches its target. Both indices
// are the CK's, shared by SPIT / ENIT / MGEF DATA.
Cast_Type :: enum u32 {
	Constant_Effect = 0,
	Fire_And_Forget = 1,
	Concentration   = 2,
}

Delivery :: enum u32 {
	Self            = 0,
	Contact         = 1,
	Aimed           = 2,
	Target_Actor    = 3,
	Target_Location = 4,
}

// Spell_Type classifies a SPEL/SCRL — what slot the form occupies for the caster.
Spell_Type :: enum u32 {
	Spell        = 0,
	Disease      = 1,
	Power        = 2,
	Lesser_Power = 3,
	Ability      = 4,
	Poison       = 5,
	Addiction    = 10,
	Voice        = 11,
}

// Spell_Info is a SPEL/SCRL's SPIT block (36 bytes): what the spell costs, how it's cast, and
// how it reaches its target. `half_cost_perk` is raw/local until remapped.
SPELL_IGNORE_RESISTANCE :: 0x0010_0000 // SPIT flag (UESP Mod File Format/SPEL)

Spell_Info :: struct {
	cost:           u32,
	flags:          u32,
	type:           Spell_Type,
	charge_time:    f32,
	cast_type:      Cast_Type,
	delivery:       Delivery,
	cast_duration:  f32,
	range:          f32,
	half_cost_perk: u32,
}

// spell_info reads a SPEL/SCRL's SPIT: cost u32@0, flags u32@4, type u32@8, charge time f32@12,
// cast type u32@16, delivery u32@20, cast duration f32@24, range f32@28, half-cost perk u32@32.
// ok=false when absent/short. (Validated vs PerkNightThief: type 4 = Ability; and
// AbMG08AncanoMagicka: cost 792, charge time 0.5.)
spell_info :: proc(fields: []Field) -> (si: Spell_Info, ok: bool) {
	f, fok := find_field(fields, "SPIT")
	if !fok || len(f.data) < 36 {
		return {}, false
	}
	return Spell_Info {
			cost           = rd32(f.data, 0),
			flags          = rd32(f.data, 4),
			type           = Spell_Type(rd32(f.data, 8)),
			charge_time    = rf32(f.data, 12),
			cast_type      = Cast_Type(rd32(f.data, 16)),
			delivery       = Delivery(rd32(f.data, 20)),
			cast_duration  = rf32(f.data, 24),
			range          = rf32(f.data, 28),
			half_cost_perk = rd32(f.data, 32),
		},
		true
}

// Enchant_Type is what an ENCH can be applied to (the CK's "enchantment type").
Enchant_Type :: enum u32 {
	Enchantment = 6,  // armor / apparel
	Staff_Enchantment = 12, // weapons + staves
}

// Enchant_Info is an ENCH's ENIT block (36 bytes). `base_enchantment` links the "parent"
// enchantment a scaled variant derives from; `worn_restrictions` is an FLST of slots it may
// occupy. Both raw/local until remapped.
Enchant_Info :: struct {
	cost:              u32,
	flags:             u32,
	cast_type:         Cast_Type,
	charge_amount:     u32,
	delivery:          Delivery,
	type:              Enchant_Type,
	charge_time:       f32,
	base_enchantment:  u32,
	worn_restrictions: u32,
}

// enchant_info reads an ENCH's ENIT: cost u32@0, flags u32@4, cast type u32@8, charge amount
// u32@12, delivery u32@16, enchant type u32@20, charge time f32@24, base enchantment u32@28,
// worn restrictions u32@32. ok=false when absent/short. (Validated vs
// MGArchMageRobeHoodedEnchant: cost 3161 = charge amount, cast type 0 = Constant Effect,
// delivery 0 = Self, type 6 = armor enchantment.)
enchant_info :: proc(fields: []Field) -> (ei: Enchant_Info, ok: bool) {
	f, fok := find_field(fields, "ENIT")
	if !fok || len(f.data) < 36 {
		return {}, false
	}
	return Enchant_Info {
			cost              = rd32(f.data, 0),
			flags             = rd32(f.data, 4),
			cast_type         = Cast_Type(rd32(f.data, 8)),
			charge_amount     = rd32(f.data, 12),
			delivery          = Delivery(rd32(f.data, 16)),
			type              = Enchant_Type(rd32(f.data, 20)),
			charge_time       = rf32(f.data, 24),
			base_enchantment  = rd32(f.data, 28),
			worn_restrictions = rd32(f.data, 32),
		},
		true
}

// Effect_Item is one effect a spell / scroll / enchantment / potion applies: which MGEF, and
// how strongly / how wide / how long. On disk it's an EFID (the MGEF formID) immediately
// followed by an EFIT (12 bytes: magnitude f32@0, area u32@4, duration u32@8). `effect` is
// raw/local until remapped.
Effect_Item :: struct {
	effect:    u32,
	magnitude: f32,
	area:      u32,
	duration:  u32,
}

// potion_is_poison reads an ALCH's ENIT flags (value u32@0, flags u32@4): 0x20000 is Poison
// (UESP Mod File Format/ALCH).
potion_is_poison :: proc(fields: []Field) -> bool {
	f, ok := find_field(fields, "ENIT")
	return ok && len(f.data) >= 8 && rd32(f.data, 4) & 0x20000 != 0
}

// activate_parents reads a placement's XAPR entries (parent ref u32@0, delay f32@4), one per subrecord.
activate_parents :: proc(fields: []Field, allocator := context.allocator) -> []u32 {
	out: [dynamic]u32
	for f in fields {
		if f.type != "XAPR" || len(f.data) < 4 {continue}
		if out == nil {out = make([dynamic]u32, allocator)}
		append(&out, rd32(f.data, 0))
	}
	return out[:]
}

// effect_items collects a record's EFID/EFIT effect pairs in declaration order — the shape
// shared by SPEL, SCRL, ENCH, ALCH and INGR. An EFID with no following EFIT contributes a
// zero-magnitude entry (the effect is still applied). The CTDAs after an EFIT are its
// conditions; gamedb reads them. Returns a freshly-allocated slice the caller owns (nil when none).
// (Validated vs MGArchMageRobeHoodedEnchant: 7 EFID/EFIT pairs, magnitudes 15/15/15/15/15/100/50.)
effect_items :: proc(fields: []Field, allocator := context.allocator) -> []Effect_Item {
	n := 0
	for f in fields {
		if f.type == "EFID" && len(f.data) >= 4 {
			n += 1
		}
	}
	if n == 0 {
		return nil
	}
	out := make([]Effect_Item, n, allocator)
	i := 0
	for f, k in fields {
		if f.type != "EFID" || len(f.data) < 4 {
			continue
		}
		e := Effect_Item{effect = rd32(f.data, 0)}
		if k + 1 < len(fields) && fields[k + 1].type == "EFIT" && len(fields[k + 1].data) >= 12 {
			d := fields[k + 1].data
			e.magnitude = rf32(d, 0)
			e.area = rd32(d, 4)
			e.duration = rd32(d, 8)
		}
		out[i] = e
		i += 1
	}
	return out
}

// Effect_Archetype is what an MGEF actually DOES — the CK's "effect archetype". Only the
// archetypes a consumer branches on are named; the raw index is preserved for the rest.
// (Validated vs Skyrim.esm: ChillrendParalysisFFContact = 21, dunHagsEndSoulTrapFFContact = 23,
// DA11AbFortifyHealth = 34.)
Effect_Archetype :: enum u32 {
	Value_Modifier      = 0,
	Script              = 1,
	Dispel              = 2,
	Cure_Disease        = 3,
	Absorb              = 4,
	Dual_Value_Modifier = 5,
	Calm                = 6,
	Demoralize          = 7,
	Frenzy              = 8,
	Disarm              = 9,
	Command_Summoned    = 10,
	Invisibility        = 11,
	Light               = 12,
	Night_Eye           = 14,
	Lock                = 15,
	Open                = 16,
	Bound_Weapon        = 17,
	Summon_Creature     = 18,
	Detect_Life         = 19,
	Telekinesis         = 20,
	Paralysis           = 21,
	Reanimate           = 22,
	Soul_Trap           = 23,
	Turn_Undead         = 24,
	Guide               = 25,
	Werewolf_Feed       = 26,
	Cure_Paralysis      = 27,
	Cure_Addiction      = 28,
	Cure_Poison         = 29,
	Concussion          = 30,
	Value_And_Parts     = 31,
	Accumulate_Magnitude = 32,
	Stagger             = 33,
	Peak_Value_Modifier = 34,
	Cloak               = 35,
	Werewolf            = 36,
	Slow_Time           = 37,
	Rally               = 38,
	Enhance_Weapon      = 39,
	Spawn_Hazard        = 40,
	Etherealize         = 41,
	Banish              = 42,
	Disguise            = 44,
	Grab_Actor          = 45,
	Vampire_Lord        = 46,
}

// MGEF DATA flag bits (the raw u32 is kept; only the commonly-queried ones are named).
MGEF_HOSTILE :: 0x0000_0001
MGEF_RECOVER :: 0x0000_0002
MGEF_DETRIMENTAL :: 0x0000_0004
MGEF_NO_HIT_EVENT :: 0x0000_0010
MGEF_DISPEL_WITH_KEYWORDS :: 0x0000_0100 // applying it dispels the spells whose effects share a keyword
MGEF_NO_DURATION :: 0x0000_0200
MGEF_NO_MAGNITUDE :: 0x0000_0400
MGEF_NO_AREA :: 0x0000_0800
MGEF_PAINLESS :: 0x0000_4000

// AV_NONE is the "no actor value" sentinel MGEF stores for the skill / resistance / affected
// value slots (an i32 −1).
AV_NONE :: i32(-1)

// Magic_Effect_Info is an MGEF's DATA block (152 bytes) — the half of it the data layer needs.
// Actor-value slots are the CK's ActorValue INDICES (validated: 18 Alteration, 19 Conjuration,
// 24 Health, 53 Paralysis), AV_NONE when unset; naming them is the consumer's job, so the raw
// index is what's stored. Form slots are raw/local until remapped. The unread tail is art and
// sound links (casting art, hit shader, impact data, …) — appearance, not data-layer concerns.
Magic_Effect_Info :: struct {
	flags:        u32, // MGEF_* bits
	base_cost:    f32,
	related:      u32, // the archetype's associated item (a Peak Value Modifier's no-stack keyword)
	magic_skill:  i32, // the school the effect trains (AV index; AV_NONE = none)
	resist_av:    i32, // the AV that resists it (AV_NONE = unresistable)
	skill_level:  u32, // minimum skill to cast
	area:         u32,
	casting_time: f32,
	archetype:    Effect_Archetype,
	primary_av:   i32, // the AV the effect modifies (AV_NONE = none)
	second_av:    i32,
	second_av_weight: f32, // a Dual Value Modifier's second AV moves by magnitude times this
	taper_weight:     f32, // the effect goes on for taper_duration after its duration, at
	taper_curve:      f32, // magnitude * weight * (1 - taper time / taper_duration) ^ curve
	taper_duration:   f32,
	projectile:   u32,
	explosion:    u32,
	cast_type:    Cast_Type,
	delivery:     Delivery,
}

// magic_effect_info reads an MGEF's DATA: flags u32@0, base cost f32@4, related u32@8, magic skill i32@12,
// resist AV i32@16, taper weight f32@28, min skill level u32@40, area u32@44, casting time f32@48,
// taper curve f32@52, taper duration f32@56, second AV weight f32@60, archetype u32@64,
// primary AV i32@68, projectile u32@72, explosion u32@76, cast type u32@80, delivery u32@84,
// second AV i32@88. ok=false when absent/short. (Offsets validated by editor-id convention
// across Skyrim.esm: every "…FFContact" reads cast type 1 / delivery 1, "…FFAimedArea" reads
// 1 / 2, "…FFSelfArea" reads 1 / 0; paralysis effects read archetype 21, soul trap 23.)
magic_effect_info :: proc(fields: []Field) -> (mi: Magic_Effect_Info, ok: bool) {
	f, fok := find_field(fields, "DATA")
	if !fok || len(f.data) < 92 {
		return {}, false
	}
	d := f.data
	return Magic_Effect_Info {
			flags        = rd32(d, 0),
			base_cost    = rf32(d, 4),
			related      = rd32(d, 8),
			magic_skill  = cast(i32)rd32(d, 12),
			resist_av    = cast(i32)rd32(d, 16),
			skill_level  = rd32(d, 40),
			area         = rd32(d, 44),
			casting_time = rf32(d, 48),
			second_av_weight = rf32(d, 60),
			taper_weight = rf32(d, 28),
			taper_curve = rf32(d, 52),
			taper_duration = rf32(d, 56),
			archetype    = Effect_Archetype(rd32(d, 64)),
			primary_av   = cast(i32)rd32(d, 68),
			projectile   = rd32(d, 72),
			explosion    = rd32(d, 76),
			cast_type    = Cast_Type(rd32(d, 80)),
			delivery     = Delivery(rd32(d, 84)),
			second_av    = cast(i32)rd32(d, 88),
		},
		true
}

// --- QUST aliases -----------------------------------------------------------------------

// Alias_Fill is how a quest alias finds its reference or location when the quest starts (xEdit;
// CK wiki, Quest Alias Tab). Only Specific resolves statically.
Alias_Fill :: enum u8 {
	None,         // nothing: a script fills it
	Specific,     // ALFR (a ref) or ALFL (a location): `target`
	Unique_Actor, // ALUA: the placed actor of the unique NPC_ `target`
	External,     // ALEQ/ALEA: alias `alias` of quest `target`
	Create_Ref,   // ALCO/ALCA/ALCL: a new ref of base `target` at (or in) ref alias `alias`
	// Location_Ref: a ref alias (ALFA/ALRT) takes the ref of type `target` in location alias `alias`;
	// a location alias (ALFA/KNAM) takes the location of ref alias `alias`, up to keyword `target`.
	Location_Ref,
	// Matching: Find Matching Reference or Location. The Match Conditions pick among the world, the
	// loaded area (ALIAS_IN_LOADED_AREA), the refs linked from ref alias `alias` (ALNA, Near Alias),
	// or the event member `event_member` (ALFE/ALFD, From Event).
	Matching,
}

// Quest alias FNAM flags (xEdit).
ALIAS_RESERVES :: 0x0000_0001 // no other alias takes its ref, unless Allow Reserved or External
ALIAS_OPTIONAL :: 0x0000_0002 // the quest starts without this alias filled
ALIAS_QUEST_OBJECT :: 0x0000_0004 // the player cannot drop or sell the ref
ALIAS_ALLOW_REUSE :: 0x0000_0008 // may take a ref another alias of the quest took
ALIAS_ALLOW_DEAD :: 0x0000_0010
ALIAS_IN_LOADED_AREA :: 0x0000_0020 // a Matching fill searches the loaded cells only
ALIAS_ESSENTIAL :: 0x0000_0040
ALIAS_ALLOW_DISABLED :: 0x0000_0080
ALIAS_ALLOW_RESERVED :: 0x0000_0200
ALIAS_PROTECTED :: 0x0000_0400
ALIAS_ALLOW_DESTROYED :: 0x0000_1000
ALIAS_CLOSEST :: 0x0000_2000 // a loaded-area Matching fill takes the closest match
ALIAS_INITIALLY_DISABLED :: 0x0000_8000 // a Create_Ref fill makes its ref disabled
ALIAS_ALLOW_CLEARED :: 0x0001_0000 // a location alias may take a cleared location
ALIAS_CLEARS_NAME :: 0x0002_0000 // the display name goes when the ref leaves

// Quest_Alias is one QUST alias definition: the slot a quest's scripts address by id, its fill rule
// and its editor name. `target` is raw/local; `name` and `match` borrow the record's fields.
Quest_Alias :: struct {
	id:           u32,
	location:     bool, // a location alias (ALLS) rather than a reference alias (ALST)
	flags:        u32,
	fill:         Alias_Fill,
	target:       u32, // the fill's form operand (see Alias_Fill)
	alias:        i32, // the fill's alias operand; -1 when it has none
	force_into:   i32, // ALFI: another alias of the quest filled with the same thing; -1 when none
	event:        [4]u8, // ALFE: the event of a From Event fill
	event_member: u32, // ALFD: the member it reads (R1, L1...)
	create_in:    bool, // ALCA: create inside the container alias, not at it
	create_level: u32, // ALCL: 0 easy, 1 medium, 2 hard, 3 very hard, 4 none
	match:        []Field, // the Match Conditions (CTDA/CIS runs), for esm.conditions
	body:         []Field, // every subrecord between ALST/ALLS and ALED: the alias data (ALFC, KWDA...)
	name:         string,
}

// quest_aliases decodes a QUST's alias definitions. Each alias runs from an ALST (reference alias)
// or ALLS (location alias) to its ALED; the subrecords between belong to it. Field ORDER carries
// the grouping (FNAM is also an objective's flags earlier in the record), so this walks in order
// and only reads inside an open alias. Returns a slice the caller owns (nil when the quest has
// none). (Validated vs Skyrim.esm: KingOlafsFestivalStarter "Karita" = ALUA; DA15Return = ALFR;
// MQGreybeardCall = ALCO/ALCA/ALCL; JailQuest = ALFA+ALRT and ALFI+ALFR; BardAudienceQuest =
// ALEQ/ALEA and an ALLS location alias.)
quest_aliases :: proc(fields: []Field, allocator := context.allocator) -> []Quest_Alias {
	out := make([dynamic]Quest_Alias, allocator)
	cur: Quest_Alias
	open := false
	near := false
	start := 0
	close :: proc(out: ^[dynamic]Quest_Alias, cur: ^Quest_Alias, near: bool) {
		if cur.fill == .None && (len(cur.match) > 0 || near || cur.event != {}) {cur.fill = .Matching}
		append(out, cur^)
	}
	for f, i in fields {
		switch f.type {
		case "ALST", "ALLS":
			if len(f.data) < 4 {continue}
			if open { // a missing ALED still closes the previous alias
				cur.body = fields[start:i]
				close(&out, &cur, near)
			}
			cur = Quest_Alias{id = rd32(f.data, 0), location = f.type == "ALLS", alias = -1, force_into = -1}
			open, near, start = true, false, i + 1
		case "ALED":
			if open {
				cur.body = fields[start:i]
				close(&out, &cur, near)
			}
			open = false
		case:
			if !open {continue} // the same tags appear outside aliases (objective FNAM, quest CTDA)
			n := len(f.data)
			switch f.type {
			case "ALID":
				cur.name = cstr(f.data)
			case "FNAM":
				if n >= 4 {cur.flags = rd32(f.data, 0)}
			case "ALFI":
				if n >= 4 {cur.force_into = i32(rd32(f.data, 0))}
			case "ALFR", "ALFL":
				if n >= 4 {cur.fill, cur.target = .Specific, rd32(f.data, 0)}
			case "ALUA":
				if n >= 4 {cur.fill, cur.target = .Unique_Actor, rd32(f.data, 0)}
			case "ALEQ":
				if n >= 4 {cur.fill, cur.target = .External, rd32(f.data, 0)}
			case "ALEA":
				if n >= 4 {cur.alias = i32(rd32(f.data, 0))}
			case "ALCO":
				if n >= 4 {cur.fill, cur.target = .Create_Ref, rd32(f.data, 0)}
			case "ALCA":
				if n >= 4 {cur.alias, cur.create_in = i32(i16(rd16(f.data, 0))), rd16(f.data, 2) & 0x8000 != 0}
			case "ALCL":
				if n >= 4 {cur.create_level = rd32(f.data, 0)}
			case "ALFA":
				if n >= 4 {cur.fill, cur.alias = .Location_Ref, i32(rd32(f.data, 0))}
			case "ALRT", "KNAM":
				if n >= 4 && cur.fill == .Location_Ref {cur.target = rd32(f.data, 0)}
			case "ALNA":
				if n >= 4 {cur.alias, near = i32(rd32(f.data, 0)), true}
			case "ALFE":
				if n >= 4 {copy(cur.event[:], f.data[:4])}
			case "ALFD":
				if n >= 4 {cur.event_member = rd32(f.data, 0)}
			case "CTDA":
				if len(cur.match) == 0 {cur.match = condition_run(fields, i)}
			}
		}
	}
	if open {
		cur.body = fields[start:]
		close(&out, &cur, near)
	}
	if len(out) == 0 {
		delete(out)
		return nil
	}
	return out[:]
}

// --- LCTN (location) ---------------------------------------------------------------------

// Special_Ref is one LCTN special ref: a ref of a location ref type (LCRT) in the location. Raw.
Special_Ref :: struct {
	ref_type, ref: u32,
}

// location_special_refs splits an LCTN's special refs into the master's list (LCSR), the ones a
// plugin adds (ACSR) and the refs it removes (RCSR). An override carries only ACSR and RCSR; they
// apply to the master's list. 16-byte entries (xEdit; all 10,497 in Skyrim.esm are an LCRT then a
// ref). The caller frees all three.
location_special_refs :: proc(fields: []Field, allocator := context.allocator) -> (master, added: []Special_Ref, removed: []u32) {
	m := make([dynamic]Special_Ref, allocator)
	a := make([dynamic]Special_Ref, allocator)
	r := make([dynamic]u32, allocator)
	for f in fields {
		switch f.type {
		case "LCSR", "ACSR":
			for k := 0; k + 16 <= len(f.data); k += 16 {
				append(&m if f.type == "LCSR" else &a, Special_Ref{rd32(f.data, k), rd32(f.data, k + 4)})
			}
		case "RCSR":
			for k := 0; k + 4 <= len(f.data); k += 4 {append(&r, rd32(f.data, k))}
		}
	}
	return m[:], a[:], r[:]
}

// location_parent reads an LCTN's PNAM — the location that contains this one ("Whiterun Hold"
// over "Whiterun"). ok=false for a root location. Raw/local until remapped. Locations form a
// tree, which is what Location.IsChild / HasCommonParent walk.
location_parent :: proc(fields: []Field) -> (u32, bool) {
	return subrecord_formid(fields, "PNAM")
}

// location_marker_color reads an LCTN's CNAM — the packed RGBA tint its map marker draws with.
// ok=false when absent (the map's default). (Validated vs RiftenMercerHouseInteriorLocation.)
location_marker_color :: proc(fields: []Field) -> (u32, bool) {
	if f, ok := find_field(fields, "CNAM"); ok && len(f.data) >= 4 {
		return rd32(f.data, 0), true
	}
	return 0, false
}

// --- WTHR (weather) ----------------------------------------------------------------------

// WTHR DATA classification bits — what kind of weather this is. The low four are mutually
// exclusive in practice and are what Weather.GetClassification reports; the aurora bits are
// independent. (Validated vs SovngardeDark: flags 0x12 = Cloudy | Permanent Aurora.)
WTHR_PLEASANT :: 0x01
WTHR_CLOUDY :: 0x02
WTHR_RAINY :: 0x04
WTHR_SNOW :: 0x08
WTHR_PERMANENT_AURORA :: 0x10
WTHR_AURORA_ALWAYS_VISIBLE :: 0x20

// WTHR_TIMES is how many times of day every weather colour / ambient / imagespace slot is
// authored for, in order: sunrise, day, sunset, night. (Confirmed empirically: the Stars colour
// is pure white in slot 3 and black in the rest, and Sunlight is warm in slots 0 and 2.)
WTHR_TIMES :: 4

// Named rows of a weather's NAM0 colour table. These indices were read off SkyrimClear_A rather
// than assumed — Stars (6) is white at night and black otherwise, Sunlight (4) is orange at
// sunrise/sunset and warm white at noon, and Ambient (3) tracks a plausible sky bounce. The
// unnamed rows (2, 9-11, 13, 14) stay raw; pin them when the lighting pass consumes the table.
WTHR_COLOR_SKY_UPPER :: 0
WTHR_COLOR_FOG_NEAR :: 1
WTHR_COLOR_AMBIENT :: 3
WTHR_COLOR_SUNLIGHT :: 4
WTHR_COLOR_SUN :: 5
WTHR_COLOR_STARS :: 6
WTHR_COLOR_SKY_LOWER :: 7
WTHR_COLOR_HORIZON :: 8
WTHR_COLOR_FOG_FAR :: 12
WTHR_COLOR_SUN_GLARE :: 15

// WTHR_COLOR_ROWS_MAX bounds the NAM0 table. The field is VARIABLE length — vanilla weathers
// carry 16 or 17 rows (SkyrimClear_A is 256 bytes = 16, SovngardeDark 272 = 17) — so callers
// must read `rows`, never assume a fixed count.
WTHR_COLOR_ROWS_MAX :: 17

// Weather_Fog is a weather's FNAM fog distances, split day/night. `power` shapes the falloff
// curve and `max` clamps how opaque fog gets.
Weather_Fog :: struct {
	day_near:   f32,
	day_far:    f32,
	night_near: f32,
	night_far:  f32,
	day_power:  f32,
	night_power: f32,
	day_max:    f32,
	night_max:  f32,
}

// Weather_Info is a WTHR's DATA block: its classification plus the scalars that drive sky
// motion and precipitation timing. Colours, fog and ambient come from the sibling decoders.
Weather_Info :: struct {
	wind_speed:           u8,
	trans_delta:          u8,
	sun_glare:            u8,
	sun_damage:           u8,
	precip_begin_fade_in: u8,
	precip_end_fade_out:  u8,
	thunder_begin_fade_in: u8,
	thunder_end_fade_out: u8,
	thunder_frequency:    u8,
	flags:                u8, // WTHR_* bits
	lightning_color:      [3]u8,
	wind_direction:       u8,
	wind_direction_range: u8,
}

// weather_info reads a WTHR's DATA (19 bytes): wind speed @0, transition delta @3, sun glare @4,
// sun damage @5, precipitation fade in/out @6/@7, thunder fade in/out @8/@9, thunder frequency
// @10, flags @11, lightning colour RGB @12, wind direction @17, wind direction range @18.
// ok=false when absent/short.
weather_info :: proc(fields: []Field) -> (wi: Weather_Info, ok: bool) {
	f, fok := find_field(fields, "DATA")
	if !fok || len(f.data) < 19 {
		return {}, false
	}
	d := f.data
	return Weather_Info {
			wind_speed = d[0],
			trans_delta = d[3],
			sun_glare = d[4],
			sun_damage = d[5],
			precip_begin_fade_in = d[6],
			precip_end_fade_out = d[7],
			thunder_begin_fade_in = d[8],
			thunder_end_fade_out = d[9],
			thunder_frequency = d[10],
			flags = d[11],
			lightning_color = {d[12], d[13], d[14]},
			wind_direction = d[17],
			wind_direction_range = d[18],
		},
		true
}

// weather_fog reads a WTHR's FNAM (32 bytes = 8 f32, in the order of Weather_Fog). ok=false
// when absent/short. (Validated vs SovngardeDark: day/night far 22500, power 0.335, max 0.9.)
weather_fog :: proc(fields: []Field) -> (Weather_Fog, bool) {
	f, ok := find_field(fields, "FNAM")
	if !ok || len(f.data) < 32 {
		return {}, false
	}
	d := f.data
	return Weather_Fog {
			day_near = rf32(d, 0),
			day_far = rf32(d, 4),
			night_near = rf32(d, 8),
			night_far = rf32(d, 12),
			day_power = rf32(d, 16),
			night_power = rf32(d, 20),
			day_max = rf32(d, 24),
			night_max = rf32(d, 28),
		},
		true
}

// weather_colors reads a WTHR's NAM0 colour table into `out` — one RGBA per (row, time of day),
// row-major, 4 bytes per entry. Returns how many rows were populated (0 when NAM0 is absent);
// the field is variable length, so callers iterate the returned count, not WTHR_COLOR_ROWS_MAX.
// Rows are indexed by the WTHR_COLOR_* constants where known.
weather_colors :: proc(
	fields: []Field,
	out: ^[WTHR_COLOR_ROWS_MAX][WTHR_TIMES][4]u8,
) -> int {
	f, ok := find_field(fields, "NAM0")
	if !ok {
		return 0
	}
	stride := WTHR_TIMES * 4
	rows := min(len(f.data) / stride, WTHR_COLOR_ROWS_MAX)
	for r in 0 ..< rows {
		for t in 0 ..< WTHR_TIMES {
			off := r * stride + t * 4
			out[r][t] = {f.data[off], f.data[off + 1], f.data[off + 2], f.data[off + 3]}
		}
	}
	return rows
}

// weather_imagespaces reads a WTHR's IMSP — the imagespace (IMGS) applied at each time of day,
// same sunrise/day/sunset/night order as the colour table. ok=false when absent/short. Raw/local
// until remapped. (Validated vs SovngardeDark: 16 bytes = 4 formIDs.)
weather_imagespaces :: proc(fields: []Field) -> ([WTHR_TIMES]u32, bool) {
	out: [WTHR_TIMES]u32
	f, ok := find_field(fields, "IMSP")
	if !ok || len(f.data) < WTHR_TIMES * 4 {
		return out, false
	}
	for i in 0 ..< WTHR_TIMES {
		out[i] = rd32(f.data, i * 4)
	}
	return out, true
}

// biped_slots reads an ARMO's body slot mask: BOD2 (SE) or BODT (LE), both a u32 first; bit 0 is
// slot 30 (Head).
biped_slots :: proc(fields: []Field) -> (u32, bool) {
	for tag in ([]string{"BOD2", "BODT"}) {
		if f, ok := find_field(fields, tag); ok && len(f.data) >= 4 {return rd32(f.data, 0), true}
	}
	return 0, false
}

// equip_type reads an EQUP: its parent slots (PNAM, raw formIDs, allocated) and whether an item of
// this type takes all of them (DATA; BothHands) or any one (EitherHand).
equip_type :: proc(fields: []Field, allocator := context.allocator) -> (parents: []u32, use_all: bool) {
	if f, ok := find_field(fields, "PNAM"); ok && len(f.data) >= 4 {
		parents = make([]u32, len(f.data) / 4, allocator)
		for &p, i in parents {p = rd32(f.data, i * 4)}
	}
	if f, ok := find_field(fields, "DATA"); ok && len(f.data) >= 4 {use_all = rd32(f.data, 0) != 0}
	return
}

LIGH_CAN_BE_CARRIED :: 0x02

// light_carried reads a LIGH's DATA flags (after time, radius and color): a carried light is a torch.
light_carried :: proc(fields: []Field) -> bool {
	f, ok := find_field(fields, "DATA")
	return ok && len(f.data) >= 16 && rd32(f.data, 12) & LIGH_CAN_BE_CARRIED != 0
}
