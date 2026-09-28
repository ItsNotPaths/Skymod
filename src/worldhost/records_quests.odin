package worldhost

// The engine's record views: quests (see records.odin).

import "core:slice"
import "../gamedb"
import "../plugin"

// quests_pairs flattens a map keyed by stage or objective index into pairs sorted by key.
@(private = "file")
quests_pairs :: proc(m: map[u16]$V, conv: proc(v: V) -> $W) -> plugin.Span(plugin.Quest_Pair(W)) {
	out := make([]plugin.Quest_Pair(W), len(m), context.temp_allocator)
	i := 0
	for k, v in m {
		out[i] = {k, conv(v)}
		i += 1
	}
	slice.sort_by(out, proc(a, b: plugin.Quest_Pair(W)) -> bool {return a.key < b.key})
	return plugin.span(out)
}

@(private = "file")
quests_strs :: proc(ss: []string) -> plugin.Span(plugin.Span(u8)) {
	out := make([]plugin.Span(u8), len(ss), context.temp_allocator)
	for s, i in ss {out[i] = str(s)}
	return plugin.span(out)
}

@(private = "file")
quests_stage :: proc(s: gamedb.Quest_Stage) -> plugin.Quest_Stage {
	items := make([]plugin.Quest_Stage_Item, len(s.items), context.temp_allocator)
	for it, i in s.items {items[i] = {it.flags, conditions(it.conditions)}}
	return {s.flags, plugin.span(items)}
}

@(private = "file")
quests_targets :: proc(ts: []gamedb.Objective_Target) -> plugin.Span(plugin.Quest_Objective_Target) {
	out := make([]plugin.Quest_Objective_Target, len(ts), context.temp_allocator)
	for t, i in ts {out[i] = {t.alias, t.flags, conditions(t.conditions)}}
	return plugin.span(out)
}

@(private = "file")
quests_alias :: proc(a: gamedb.Quest_Alias) -> plugin.Quest_Alias {
	return {
		id = a.id, location = a.location, flags = a.flags, fill = a.fill, target = a.target, alias = a.alias,
		force_into = a.force_into, event_member = a.event_member, create_in = a.create_in, create_level = a.create_level,
		conditions = conditions(a.conditions), factions = forms(a.factions), keywords = forms(a.keywords),
		packages = forms(a.packages), overrides = override_packages(a.overrides),
		spells = forms(a.spells), items = item_counts(a.items), display_name = a.display_name, name = str(a.name),
	}
}

@(private)
view_quest :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Quest, ok: bool) {
	q := db.quest_baseline[form] or_return
	aliases := make([]plugin.Quest_Alias, len(q.aliases), context.temp_allocator)
	for a, i in q.aliases {aliases[i] = quests_alias(a)}
	v = {
		start_game_enabled = q.start_game_enabled, run_once = q.run_once, priority = q.priority, event = q.event,
		dialogue_conditions = conditions(q.dialogue_conditions), event_conditions = conditions(q.event_conditions),
		stages = quests_pairs(q.stages, quests_stage),
		objectives = quests_pairs(q.objectives, proc(b: bool) -> bool {return b}),
		stage_log = quests_pairs(q.stage_log, str),
		objective_text = quests_pairs(q.objective_text, str),
		objective_targets = quests_pairs(q.objective_targets, quests_targets),
		aliases = plugin.span(aliases),
	}
	return v, true
}

@(private)
view_story_node :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Story_Node, ok: bool) {
	n := db.story_nodes[form] or_return
	quests := make([]plugin.Story_Node_Quest, len(n.quests), context.temp_allocator)
	for q, i in n.quests {quests[i] = {q.quest, q.reset_hours}}
	v = {
		kind = u8(n.kind), parent = n.parent, previous = n.previous, flags = n.flags, max_concurrent = n.max_concurrent,
		conditions = conditions(n.conditions), event = n.event, quests = plugin.span(quests),
		quests_to_run = n.quests_to_run, children = forms(n.children), edid = str(n.edid),
	}
	return v, true
}

@(private)
view_topic :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Topic, ok: bool) {
	t := db.topics[form] or_return
	v = {
		priority = t.priority, branch = t.branch, quest = t.quest, category = t.category, subtype = t.subtype,
		subtype_name = t.subtype_name, do_all = t.do_all, infos = forms(t.infos),
	}
	return v, true
}

@(private)
view_branch :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Branch, ok: bool) {
	b := db.branches[form] or_return
	return {quest = b.quest, category = b.category, flags = b.flags, start = b.start}, true
}

@(private)
view_info :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Info, ok: bool) {
	n := db.infos[form] or_return
	responses := make([]plugin.Info_Response, len(n.responses), context.temp_allocator)
	for r, i in n.responses {
		responses[i] = {r.emotion, r.emotion_value, r.number, r.sound, str(r.text), r.speaker_idle, r.listener_idle}
	}
	v = {
		topic = n.topic, previous = n.previous, flags = n.flags, reset_hours = n.reset_hours, favor_level = n.favor_level,
		links = forms(n.links), shared = n.shared, responses = plugin.span(responses), conditions = conditions(n.conditions),
		prompt = str(n.prompt), speaker = n.speaker, walk_away = n.walk_away,
	}
	return v, true
}

@(private)
view_scene :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Scene, ok: bool) {
	s := db.scenes[form] or_return
	phases := make([]plugin.Scene_Phase, len(s.phases), context.temp_allocator)
	for p, i in s.phases {phases[i] = {conditions(p.start), conditions(p.completion)}}
	actors := make([]plugin.Scene_Actor, len(s.actors), context.temp_allocator)
	for a, i in s.actors {actors[i] = {a.alias, a.flags, a.behavior}}
	actions := make([]plugin.Scene_Action, len(s.actions), context.temp_allocator)
	for a, i in s.actions {
		actions[i] = {
			kind = u16(a.kind), alias = a.alias, index = a.index, flags = a.flags, start = a.start, end = a.end,
			topic = a.topic, loop_min = a.loop_min, loop_max = a.loop_max, packages = forms(a.packages), seconds = a.seconds,
		}
	}
	v = {
		quest = s.quest, flags = s.flags, phases = plugin.span(phases), actors = plugin.span(actors),
		actions = plugin.span(actions), conditions = conditions(s.conditions),
	}
	return v, true
}

@(private)
view_message :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Message, ok: bool) {
	m := db.messages[form] or_return
	v = {
		title = str(m.title), body = str(m.body), buttons = quests_strs(m.buttons), quest = m.quest,
		display_time = m.display_time, message_box = m.message_box, auto_display = m.auto_display,
	}
	return v, true
}

@(private)
view_sound :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Sound, ok: bool) {
	s := db.sounds[form] or_return
	v = {
		files = quests_strs(s.files), category = s.category, output = s.output, loop = u8(s.loop),
		freq_shift = s.freq_shift, freq_variance = s.freq_variance, priority = s.priority,
		db_variance = s.db_variance, attenuation = s.attenuation, conditions = conditions(s.conditions),
	}
	return v, true
}

@(private)
view_sound_category :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Sound_Category, ok: bool) {
	c := db.sound_categories[form] or_return
	return {parent = c.parent, volume = c.volume}, true
}

@(private)
view_sound_output :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Sound_Output, ok: bool) {
	o := db.sound_outputs[form] or_return
	return {min = o.min, max = o.max, curve = o.curve, attenuates = o.attenuates, pans = o.pans}, true
}

@(private)
view_music_type :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Music_Type, ok: bool) {
	t := db.music_types[form] or_return
	return {flags = t.flags, priority = t.priority, fade = t.fade, tracks = forms(t.tracks)}, true
}

@(private)
view_music_track :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Music_Track, ok: bool) {
	t := db.music_tracks[form] or_return
	v = {
		kind = u8(t.kind), file = str(t.file), duration = t.duration, children = forms(t.children),
		conditions = conditions(t.conditions),
	}
	return v, true
}

@(private)
view_base_sounds :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Base_Sounds, ok: bool) {
	b := db.base_sounds[form] or_return
	v = {use = b.use, done = b.done, equip = b.equip, unequip = b.unequip, loop = b.loop}
	for d, i in b.defaults {v.defaults[i] = str(d)}
	return v, true
}

@(private)
view_acoustic_space :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Acoustic_Space, ok: bool) {
	loop := db.acoustic_loops[form] or_return
	return {loop = loop}, true
}
