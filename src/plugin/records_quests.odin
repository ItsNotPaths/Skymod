package plugin

// Record views: quests (see records.odin for the rules every view obeys).

import "../formats/esm"

// Quest_Pair is one entry of a quest's map keyed by stage or objective index, the pairs sorted by key.
Quest_Pair :: struct($T: typeid) {
	key:   u16,
	value: T,
}

Quest :: struct {
	using header:        Header,
	start_game_enabled:  bool,
	run_once:            bool,
	priority:            u8,
	event:               [4]u8, // ENAM ("KILL"), zero when none
	dialogue_conditions: Span(Condition),
	event_conditions:    Span(Condition),
	stages:              Span(Quest_Pair(Quest_Stage)),
	objectives:          Span(Quest_Pair(bool)), // defined objective indices; value always true
	stage_log:           Span(Quest_Pair(Span(u8))), // only stages with a log entry
	objective_text:      Span(Quest_Pair(Span(u8))),
	objective_targets:   Span(Quest_Pair(Span(Quest_Objective_Target))),
	aliases:             Span(Quest_Alias), // declaration order; index by id, not position
}

Quest_Stage :: struct {
	flags: u8, // STAGE_START_UP 0x2, STAGE_SHUT_DOWN 0x4
	items: Span(Quest_Stage_Item),
}

Quest_Stage_Item :: struct {
	flags:      u8, // ITEM_COMPLETE_QUEST 0x1, ITEM_FAIL_QUEST 0x2
	conditions: Span(Condition),
}

Quest_Objective_Target :: struct {
	alias:      i32,
	flags:      u8, // TARGET_IGNORES_LOCKS 0x1
	conditions: Span(Condition),
}

Quest_Alias :: struct {
	id:           u32,
	location:     bool,
	flags:        u32, // esm.ALIAS_*
	fill:         esm.Alias_Fill,
	target:       Form_ID,
	alias:        i32, // -1 = none
	force_into:   i32, // -1 = none
	event_member: i32,
	create_in:    bool,
	create_level: u32,
	conditions:   Span(Condition),
	factions:     Span(Form_ID),
	keywords:     Span(Form_ID),
	packages:     Span(Form_ID),
	overrides:    Override_Packages,
	spells:       Span(Form_ID),
	items:        Span(Item_Count),
	display_name: Form_ID, // MESG
	name:         Span(u8),
}

Story_Node :: struct {
	using header:   Header,
	kind:           u8, // gamedb.Story_Node_Kind: 0 branch, 1 quest, 2 event
	parent:         Form_ID,
	previous:       Form_ID, // 0 for the first sibling
	flags:          u32, // STORY_*
	max_concurrent: u32, // 0 = no limit
	conditions:     Span(Condition),
	event:          [4]u8,
	quests:         Span(Story_Node_Quest),
	quests_to_run:  u32,
	children:       Span(Form_ID), // sibling order
	edid:           Span(u8), // lower case
}

Story_Node_Quest :: struct {
	quest:       Form_ID,
	reset_hours: f32, // 0 = no wait
}

Topic :: struct {
	using header: Header,
	priority:     f32,
	branch:       Form_ID,
	quest:        Form_ID,
	category:     u8, // 0 player, 1 favor, 2 scene, 3 combat, 4 favors, 5 detection, 6 service, 7 misc
	subtype:      u16,
	subtype_name: [4]u8, // "HELO", "CUST"
	do_all:       bool,
	infos:        Span(Form_ID), // in PNAM order
}

Branch :: struct {
	using header: Header,
	quest:        Form_ID,
	category:     u32, // 0 player, 1 favor
	flags:        u32, // BRANCH_*
	start:        Form_ID, // the starting topic
}

Info :: struct {
	using header: Header,
	topic:        Form_ID,
	previous:     Form_ID,
	flags:        u16, // INFO_*
	reset_hours:  f32,
	favor_level:  u8,
	links:        Span(Form_ID),
	shared:       Form_ID,
	responses:    Span(Info_Response),
	conditions:   Span(Condition),
	prompt:       Span(u8),
	speaker:      Form_ID,
	walk_away:    Form_ID,
}

Info_Response :: struct {
	emotion:       u32,
	emotion_value: u32,
	number:        u8,
	sound:         Form_ID,
	text:          Span(u8),
	speaker_idle:  Form_ID,
	listener_idle: Form_ID,
}

Scene :: struct {
	using header: Header,
	quest:        Form_ID,
	flags:        u32, // SCENE_*
	phases:       Span(Scene_Phase),
	actors:       Span(Scene_Actor),
	actions:      Span(Scene_Action),
	conditions:   Span(Condition), // the repeat conditions
}

Scene_Phase :: struct {
	start, completion: Span(Condition),
}

Scene_Actor :: struct {
	alias:    i32,
	flags:    u32,
	behavior: u32,
}

Scene_Action :: struct {
	kind:               u16, // gamedb.Scene_Action_Kind: 0 dialogue, 1 package, 2 timer
	alias:              i32,
	index:              u32,
	flags:              u32,
	start, end:         u32, // phases, from 0
	topic:              Form_ID,
	loop_min, loop_max: f32,
	packages:           Span(Form_ID),
	seconds:            f32,
}

Message :: struct {
	using header: Header,
	title:        Span(u8),
	body:         Span(u8),
	buttons:      Span(Span(u8)), // empty = one default button
	quest:        Form_ID,
	display_time: u32, // 0 = the menu decides
	message_box:  bool,
	auto_display: bool,
}

Sound :: struct {
	using header:  Header,
	files:         Span(Span(u8)), // one picked per play
	category:      Form_ID,
	output:        Form_ID,
	loop:          u8, // gamedb.Sound_Loop: 0 none, 1 loop, 2 envelope fast, 3 envelope slow
	freq_shift:    f32,
	freq_variance: f32,
	priority:      u8,
	db_variance:   f32,
	attenuation:   f32,
	conditions:    Span(Condition),
}

Sound_Category :: struct {
	using header: Header,
	parent:       Form_ID,
	volume:       f32,
}

Sound_Output :: struct {
	using header: Header,
	min, max:     f32,
	curve:        [5]f32,
	attenuates:   bool,
	pans:         bool,
}

Music_Type :: struct {
	using header: Header,
	flags:        u32, // MUSIC_*
	priority:     u16,
	fade:         f32,
	tracks:       Span(Form_ID),
}

Music_Track :: struct {
	using header: Header,
	kind:         u8, // gamedb.Music_Track_Kind: 0 single, 1 palette, 2 silent
	file:         Span(u8),
	duration:     f32,
	children:     Span(Form_ID),
	conditions:   Span(Condition),
}

Base_Sounds :: struct {
	using header:   Header,
	use, done:      Form_ID,
	defaults:       [2]Span(u8), // DOBJ keys for use and done
	equip, unequip: Form_ID,
	loop:           Form_ID,
}

Acoustic_Space :: struct {
	using header: Header,
	loop:         Form_ID,
}
