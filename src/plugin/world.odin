package plugin

// World is the read-only world every seam's Host embeds: what a plugin may ask of any ref, actor,
// faction, quest or setting. The first cut covers what the built-ins and the script natives read
// most, and record views of the game data (records.odin); writes go through each seam's own
// commands. Each proc gets `data` back.

World :: struct {
	data:          rawptr,
	player:        Form_ID, // the actor the player controls
	ref:           proc "c" (data: rawptr, ref: Form_ID) -> Ref,
	actor_value:   proc "c" (data: rawptr, actor: Form_ID, name: cstring, part: AV_Part) -> f32,
	level:         proc "c" (data: rawptr, actor: Form_ID) -> i32,
	faction_rank:  proc "c" (data: rawptr, actor, faction: Form_ID) -> i32, // -1 = not a member
	relation:      proc "c" (data: rawptr, a, b: Form_ID) -> Relation, // through their factions
	hostile:       proc "c" (data: rawptr, a, b: Form_ID) -> bool, // factions, crime and aggression
	has_keyword:   proc "c" (data: rawptr, form, keyword: Form_ID) -> bool, // the form, its base or an alias holding it
	in_list:       proc "c" (data: rawptr, list, form: Form_ID) -> bool, // a form list, with what scripts added
	item_count:    proc "c" (data: rawptr, container, item: Form_ID) -> i32,
	awareness:     proc "c" (data: rawptr, viewer, target: Form_ID) -> Awareness,
	quest_stage:   proc "c" (data: rawptr, quest: Form_ID) -> i32,
	quest_running: proc "c" (data: rawptr, quest: Form_ID) -> bool,
	stage_done:    proc "c" (data: rawptr, quest: Form_ID, stage: i32) -> bool,
	global:        proc "c" (data: rawptr, global: Form_ID) -> f32,
	setting:       proc "c" (data: rawptr, name: cstring, fallback: f32) -> f32, // a GMST
	game_hours:    proc "c" (data: rawptr) -> f64, // since day 0
	record:        proc "c" (data: rawptr, form: Form_ID, kind: Record_Kind, out: rawptr) -> bool, // see records.odin
}

// Ref is what the world says of one ref.
Ref :: struct {
	base:     Form_ID,
	cell:     Form_ID,
	space:    Form_ID, // its worldspace or interior cell; 0 = none
	location: Form_ID,
	pos:      [3]f32,
	rot:      [3]f32, // radians
	lo, hi:   [3]f32, // its bounds around pos, scaled
	scale:    f32,
	actor:    bool,
	dead:     bool,
	enabled:  bool,
	loaded:   bool, // its 3D is in the world
	interior: bool,
}

AV_Part :: enum u8 {
	Current,
	Base,
	Max,
}

Relation :: enum u8 {
	Neutral,
	Enemy,
	Ally,
	Friend,
}

Awareness :: struct {
	level:    f32,
	detected: bool,
}
