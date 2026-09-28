package worldhost

// The engine's record views: quests (see records.odin).

import "../gamedb"
import "../plugin"

@(private)
view_quest :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Quest, ok: bool) {
	return
}

@(private)
view_story_node :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Story_Node, ok: bool) {
	return
}

@(private)
view_topic :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Topic, ok: bool) {
	return
}

@(private)
view_branch :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Branch, ok: bool) {
	return
}

@(private)
view_info :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Info, ok: bool) {
	return
}

@(private)
view_scene :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Scene, ok: bool) {
	return
}

@(private)
view_message :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Message, ok: bool) {
	return
}

@(private)
view_sound :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Sound, ok: bool) {
	return
}

@(private)
view_sound_category :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Sound_Category, ok: bool) {
	return
}

@(private)
view_sound_output :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Sound_Output, ok: bool) {
	return
}

@(private)
view_music_type :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Music_Type, ok: bool) {
	return
}

@(private)
view_music_track :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Music_Track, ok: bool) {
	return
}

@(private)
view_base_sounds :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Base_Sounds, ok: bool) {
	return
}

@(private)
view_acoustic_space :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Acoustic_Space, ok: bool) {
	return
}
