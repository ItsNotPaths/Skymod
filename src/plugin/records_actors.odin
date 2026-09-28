package plugin

// Record views: actors (see records.odin for the rules every view obeys).

import "../formats/esm"

Actor_Base :: struct {
	using header:     Header,
	flags:            u32, // ACBS (esm.ACBS_*)
	level:            u16, // absolute, or x1000 player-level mult with ACBS_PC_LEVEL_MULT
	calc_min:         u16,
	calc_max:         u16,
	speed_mult:       u16,
	magicka_off:      i16, // on top of the race's starting values
	stamina_off:      i16,
	health_off:       i16,
	base_health:      u16,
	base_magicka:     u16,
	base_stamina:     u16,
	skills:           [esm.NPC_SKILLS]u8,
	skill_offsets:    [esm.NPC_SKILLS]u8,
	race:             Form_ID,
	bounds:           [2][3]f32,
	class:            Form_ID,
	voice:            Form_ID,
	outfit:           Form_ID,
	sleep_outfit:     Form_ID,
	gift_filter:      Form_ID, // an FLST
	template:         Form_ID, // an NPC_ or LVLN
	template_flags:   u16, // esm.ACBS_TEMPLATE_*
	ai:               [6]u8, // Aggression .. Assistance
	aggro:            esm.Aggro,
	spells:           Span(Form_ID),
	perks:            Span(Form_ID),
	packages:         Span(Form_ID),
	default_packages: Form_ID, // an FLST of packages
	overrides:        Override_Packages,
	inventory:        Span(Item_Count),
	factions:         Span(Actor_Base_Faction), // baseline ranks; the runtime overlay diverges
	crime_faction:    Form_ID,
}

Actor_Base_Faction :: struct {
	faction: Form_ID,
	rank:    i8,
}

Race :: struct {
	using header: Header,
	info:         esm.Race_Info,
	description:  Span(u8),
	spells:       Span(Form_ID),
	skeletons:    [2]Span(u8), // male, female .nif paths
	walk, run:    Form_ID, // movement types; 0 = the defaults
	voices:       [2]Form_ID, // male, female
}

Class :: struct {
	using header: Header,
	info:         esm.Class_Info,
	description:  Span(u8),
}

Faction :: struct {
	using header:  Header,
	flags:         u32, // esm.FACT_*
	relations:     Span(Faction_Relation),
	ranks:         Span(Faction_Rank),
	crime:         esm.Crime_Values,
	has_crime:     bool,
	vendor:        Faction_Vendor,
	jail:          Form_ID,
	follower_wait: Form_ID,
	stolen_chest:  Form_ID,
	player_chest:  Form_ID,
	crime_group:   Form_ID, // an FLST of factions sharing its bounties
	jail_outfit:   Form_ID,
}

Faction_Relation :: struct {
	faction:  Form_ID,
	modifier: i32,
	combat:   esm.Combat_Reaction,
}

Faction_Rank :: struct {
	index:        u32,
	male_title:   Span(u8),
	female_title: Span(u8),
}

Faction_Vendor :: struct {
	start, end: u16, // hours; an end before the start wraps past midnight
	conditions: Span(Condition),
}

Actor_Value_Info :: struct {
	using header: Header,
	index:        i32, // the engine ActorValue index when has_index
	has_index:    bool,
	editor_id:    Span(u8),
	description:  Span(u8),
	skill:        esm.Skill_XP, // the 18 skills only
	has_skill:    bool,
}

Perk :: struct {
	using header:    Header,
	name:            Span(u8),
	description:     Span(u8),
	next_rank:       Form_ID, // 0 at the last rank
	min_level:       u8,
	num_ranks:       u8, // as authored, unreliable
	trait:           bool,
	playable:        bool,
	hidden:          bool,
	take_conditions: Span(Condition), // whether the perk can be taken
	entries:         Span(Perk_Entry),
}

Perk_Entry :: struct {
	kind:           esm.Perk_Entry_Kind,
	rank, priority: u8,
	form:           Form_ID, // Quest: the quest. Ability: the spell. Entry point: its LVLI or SPEL
	stage:          u8,
	point:          u8, // gamedb.Entry_Point
	function:       u8, // gamedb.Perk_Function
	values:         [2]f32,
	text:           Span(u8),
	tabs:           Span(Perk_Tab),
}

Perk_Tab :: struct {
	tab:        u8, // 0 = the perk's owner
	conditions: Span(Condition),
}

Perk_Tree :: struct {
	using header: Header,
	nodes:        Span(Perk_Node),
}

Perk_Node :: struct {
	perk:        Form_ID, // 0 = the tree root
	index:       u32, // its id within the tree
	grid:        [2]u32,
	pos:         [2]f32,
	connections: Span(u32), // node indices
}

Package :: struct {
	using header:    Header,
	flags:           u32,
	type:            u8, // 19 template, 18 package
	interrupt:       u8, // gamedb.Package_Interrupt
	speed:           u8, // gamedb.Package_Speed
	interrupt_flags: u16,
	schedule:        Package_Schedule,
	conditions:      Span(Condition),
	idle:            Package_Idles,
	combat_style:    Form_ID,
	owner_quest:     Form_ID,
	template:        Form_ID, // 0 on a template or a self-contained package
	inputs:          Span(Package_Input), // an instance holds only its overrides
	tree:            Span(Package_Node), // empty on an instance
}

// Package_Schedule: -1 is any.
Package_Schedule :: struct {
	month, day_of_week, date, hour, minute: i8,
	duration:                               u32, // minutes
}

Package_Idles :: struct {
	flags: u8,
	timer: f32,
	idles: Span(Form_ID),
}

// Package_Input flattens gamedb's value union: only the field of its variant is set.
Package_Input :: struct {
	index:       u8,
	kind:        u8, // gamedb.Package_Input_Kind
	bool_value:  bool,
	int_value:   i32,
	float_value: f32, // Float and ObjectList
	location:    Package_Location,
	target:      Package_Target, // SingleRef and TargetSelector
	topic:       Package_Topic,
}

Package_Location :: struct {
	kind:   i32, // gamedb.Package_Location_Kind
	form:   Form_ID,
	value:  i32,
	radius: i32,
}

Package_Target :: struct {
	kind:  i32, // gamedb.Package_Target_Kind
	form:  Form_ID,
	value: i32,
	count: i32, // count or distance
}

Package_Topic :: struct {
	topic:   Form_ID,
	subtype: [4]u8,
}

// Package_Node is one tree node in pre-order: children start at i+1, each next one at the previous one's end.
Package_Node :: struct {
	branch:            u8, // gamedb.Package_Branch
	procedure:         Span(u8), // "" on a branch
	end:               u32, // one past this node's subtree
	flags:             u32,
	success_completes: bool,
	inputs:            Span(u8), // input indexes the procedure reads; 0xFF none
	conditions:        Span(Condition),
	override:          Package_Flag_Override, // set when has_override
	has_override:      bool,
}

Package_Flag_Override :: struct {
	set_flags, clear_flags:         u32,
	set_interrupt, clear_interrupt: u16,
	speed:                          u8, // gamedb.Package_Speed
}

Zone :: struct {
	using header:         Header,
	location:             Form_ID,
	min_level, max_level: i32, // max 0 = no cap
	flags:                u8, // esm.ECZN_*
}

Equip_Slot :: struct {
	using header: Header,
	kind:         u8, // gamedb.Equip_Kind
	biped:        u32, // bit 0 = slot 30; 0 = not armor
	etyp:         Form_ID,
	weapon_type:  u8,
	enchantment:  Form_ID,
	damage:       f32,
	projectile:   Form_ID,
}

Equip_Type :: struct {
	using header: Header,
	parents:      Span(Form_ID),
	use_all:      bool, // all parents (BothHands) rather than any one (EitherHand)
}

Movement :: struct {
	using header: Header,
	speed:        [2]f32, // forward walk, run
}
