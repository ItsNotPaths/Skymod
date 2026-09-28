package unit_tests

import "core:testing"
import "../../src/gamedb"
import "../../src/plugin"
import "../../src/worldhost"
import "../../src/worldstate"

@(test)
test_record_quest :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.quest_baseline)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	cond := []gamedb.Condition{{function = 72, value = 1}}
	q := gamedb.Quest_Baseline{priority = 60, event = {'K', 'I', 'L', 'L'}, dialogue_conditions = cond}
	q.stages[20] = {flags = gamedb.STAGE_SHUT_DOWN, items = {{flags = gamedb.ITEM_COMPLETE_QUEST, conditions = cond}}}
	q.stages[10] = {flags = gamedb.STAGE_START_UP}
	q.objectives[5] = true
	q.stage_log[10] = "Begun."
	q.objective_targets[5] = {{alias = 3, conditions = cond}}
	q.aliases = {{id = 3, fill = .Specific, target = 0x1A, alias = -1, keywords = {0xB0}, overrides = {corpse = 0xC0}, items = {{0xD0, 2}}, name = "Boss"}}
	defer {delete(q.stages); delete(q.objectives); delete(q.stage_log); delete(q.objective_text); delete(q.objective_targets)}
	db.quest_baseline[0x10] = q

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Quest
	testing.expect(t, plugin.record(&w, 0x10, .Quest, &v), "found")
	testing.expect_value(t, v.priority, 60)
	testing.expect_value(t, v.event, [4]u8{'K', 'I', 'L', 'L'})
	testing.expect_value(t, v.dialogue_conditions.len, 1)
	stages := plugin.items(v.stages)
	testing.expect_value(t, len(stages), 2)
	testing.expect_value(t, stages[0].key, 10)
	testing.expect_value(t, stages[1].key, 20)
	testing.expect_value(t, plugin.items(stages[1].value.items)[0].flags, gamedb.ITEM_COMPLETE_QUEST)
	testing.expect_value(t, string(plugin.items(plugin.items(v.stage_log)[0].value)), "Begun.")
	targets := plugin.items(v.objective_targets)
	testing.expect_value(t, targets[0].key, 5)
	testing.expect_value(t, plugin.items(targets[0].value)[0].alias, 3)
	a := plugin.items(v.aliases)[0]
	testing.expect_value(t, a.fill, q.aliases[0].fill)
	testing.expect_value(t, a.overrides.corpse, 0xC0)
	testing.expect_value(t, plugin.items(a.items)[0].count, 2)
	testing.expect_value(t, string(plugin.items(a.name)), "Boss")
	testing.expect(t, !plugin.record(&w, 0x11, .Quest, &v), "no such quest")
}

@(test)
test_record_story_node :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.story_nodes)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.story_nodes[0x20] = {kind = .Quest, parent = 0x1F, quests = {{quest = 0x10, reset_hours = 24}}, children = {0x21}, edid = "node"}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Story_Node
	testing.expect(t, plugin.record(&w, 0x20, .Story_Node, &v), "found")
	testing.expect_value(t, v.kind, u8(gamedb.Story_Node_Kind.Quest))
	testing.expect_value(t, v.parent, 0x1F)
	testing.expect_value(t, plugin.items(v.quests)[0].reset_hours, 24)
	testing.expect_value(t, plugin.items(v.children)[0], 0x21)
	testing.expect_value(t, string(plugin.items(v.edid)), "node")
	testing.expect(t, !plugin.record(&w, 0x21, .Story_Node, &v), "no such node")
}

@(test)
test_record_topic :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.topics)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.topics[0x30] = {priority = 50, quest = 0x10, subtype_name = {'H', 'E', 'L', 'O'}, infos = {0x31, 0x32}}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Topic
	testing.expect(t, plugin.record(&w, 0x30, .Topic, &v), "found")
	testing.expect_value(t, v.priority, 50)
	testing.expect_value(t, v.subtype_name, [4]u8{'H', 'E', 'L', 'O'})
	testing.expect_value(t, plugin.items(v.infos)[1], 0x32)
	testing.expect(t, !plugin.record(&w, 0x31, .Topic, &v), "no such topic")
}

@(test)
test_record_branch :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.branches)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.branches[0x40] = {quest = 0x10, flags = gamedb.BRANCH_TOP_LEVEL, start = 0x30}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Branch
	testing.expect(t, plugin.record(&w, 0x40, .Branch, &v), "found")
	testing.expect_value(t, v.flags, gamedb.BRANCH_TOP_LEVEL)
	testing.expect_value(t, v.start, 0x30)
	testing.expect(t, !plugin.record(&w, 0x41, .Branch, &v), "no such branch")
}

@(test)
test_record_info :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.infos)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.infos[0x31] = {topic = 0x30, flags = gamedb.INFO_GOODBYE, links = {0x33}, responses = {{number = 1, text = "Hello."}}, prompt = "Hi"}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Info
	testing.expect(t, plugin.record(&w, 0x31, .Info, &v), "found")
	testing.expect_value(t, v.topic, 0x30)
	testing.expect_value(t, v.flags, gamedb.INFO_GOODBYE)
	testing.expect_value(t, plugin.items(v.links)[0], 0x33)
	testing.expect_value(t, string(plugin.items(plugin.items(v.responses)[0].text)), "Hello.")
	testing.expect_value(t, string(plugin.items(v.prompt)), "Hi")
	testing.expect(t, !plugin.record(&w, 0x32, .Info, &v), "no such info")
}

@(test)
test_record_scene :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.scenes)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	cond := []gamedb.Condition{{function = 72}}
	db.scenes[0x50] = {
		quest   = 0x10,
		phases  = {{completion = cond}},
		actors  = {{alias = 2, behavior = gamedb.SCENE_DEATH_END}},
		actions = {{kind = .Package, alias = 2, end = 1, packages = {0x51}}},
	}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Scene
	testing.expect(t, plugin.record(&w, 0x50, .Scene, &v), "found")
	testing.expect_value(t, v.quest, 0x10)
	testing.expect_value(t, plugin.items(v.phases)[0].completion.len, 1)
	testing.expect_value(t, plugin.items(v.actors)[0].behavior, gamedb.SCENE_DEATH_END)
	act := plugin.items(v.actions)[0]
	testing.expect_value(t, act.kind, u16(gamedb.Scene_Action_Kind.Package))
	testing.expect_value(t, act.end, 1)
	testing.expect_value(t, plugin.items(act.packages)[0], 0x51)
	testing.expect(t, !plugin.record(&w, 0x51, .Scene, &v), "no such scene")
}

@(test)
test_record_message :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.messages)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.messages[0x60] = {title = "Title", body = "Body", buttons = {"Yes", "No"}, message_box = true}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Message
	testing.expect(t, plugin.record(&w, 0x60, .Message, &v), "found")
	testing.expect_value(t, string(plugin.items(v.body)), "Body")
	testing.expect_value(t, string(plugin.items(plugin.items(v.buttons)[1])), "No")
	testing.expect(t, v.message_box, "message box")
	testing.expect(t, !plugin.record(&w, 0x61, .Message, &v), "no such message")
}

@(test)
test_record_sound :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.sounds)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.sounds[0x70] = {files = {"sound\\fx\\a.wav"}, category = 0x71, loop = .Envelope_Fast, attenuation = 6}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Sound
	testing.expect(t, plugin.record(&w, 0x70, .Sound, &v), "found")
	testing.expect_value(t, string(plugin.items(plugin.items(v.files)[0])), "sound\\fx\\a.wav")
	testing.expect_value(t, v.category, 0x71)
	testing.expect_value(t, v.loop, u8(gamedb.Sound_Loop.Envelope_Fast))
	testing.expect_value(t, v.attenuation, 6)
	testing.expect(t, !plugin.record(&w, 0x71, .Sound, &v), "no such sound")
}

@(test)
test_record_sound_category :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.sound_categories)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.sound_categories[0x71] = {parent = 0x72, volume = 0.5}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Sound_Category
	testing.expect(t, plugin.record(&w, 0x71, .Sound_Category, &v), "found")
	testing.expect_value(t, v.parent, 0x72)
	testing.expect_value(t, v.volume, 0.5)
	testing.expect(t, !plugin.record(&w, 0x72, .Sound_Category, &v), "no such category")
}

@(test)
test_record_sound_output :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.sound_outputs)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.sound_outputs[0x73] = {min = 100, max = 2000, curve = {1, 0.5, 0.25, 0.1, 0}, attenuates = true}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Sound_Output
	testing.expect(t, plugin.record(&w, 0x73, .Sound_Output, &v), "found")
	testing.expect_value(t, v.max, 2000)
	testing.expect_value(t, v.curve[1], 0.5)
	testing.expect(t, v.attenuates, "attenuates")
	testing.expect(t, !plugin.record(&w, 0x74, .Sound_Output, &v), "no such output")
}

@(test)
test_record_music_type :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.music_types)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.music_types[0x80] = {flags = gamedb.MUSIC_CYCLES, priority = 3, tracks = {0x81, 0x82}}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Music_Type
	testing.expect(t, plugin.record(&w, 0x80, .Music_Type, &v), "found")
	testing.expect_value(t, v.priority, 3)
	testing.expect_value(t, plugin.items(v.tracks)[1], 0x82)
	testing.expect(t, !plugin.record(&w, 0x81, .Music_Type, &v), "no such music type")
}

@(test)
test_record_music_track :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.music_tracks)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.music_tracks[0x81] = {kind = .Palette, file = "music\\a.wav", children = {0x83}}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Music_Track
	testing.expect(t, plugin.record(&w, 0x81, .Music_Track, &v), "found")
	testing.expect_value(t, v.kind, u8(gamedb.Music_Track_Kind.Palette))
	testing.expect_value(t, string(plugin.items(v.file)), "music\\a.wav")
	testing.expect_value(t, plugin.items(v.children)[0], 0x83)
	testing.expect(t, !plugin.record(&w, 0x82, .Music_Track, &v), "no such track")
}

@(test)
test_record_base_sounds :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.base_sounds)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.base_sounds[0x90] = {use = 0x91, defaults = {"PUSW", "PDSW"}, loop = 0x92}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Base_Sounds
	testing.expect(t, plugin.record(&w, 0x90, .Base_Sounds, &v), "found")
	testing.expect_value(t, v.use, 0x91)
	testing.expect_value(t, string(plugin.items(v.defaults[1])), "PDSW")
	testing.expect_value(t, v.loop, 0x92)
	testing.expect(t, !plugin.record(&w, 0x91, .Base_Sounds, &v), "no such base")
}

@(test)
test_record_acoustic_space :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.acoustic_loops)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.acoustic_loops[0xA0] = 0x70

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Acoustic_Space
	testing.expect(t, plugin.record(&w, 0xA0, .Acoustic_Space, &v), "found")
	testing.expect_value(t, v.loop, 0x70)
	testing.expect(t, !plugin.record(&w, 0xA1, .Acoustic_Space, &v), "no such space")
}
