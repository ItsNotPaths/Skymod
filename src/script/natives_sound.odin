package script

// Sound (a SOUN form), SoundCategory (SNCT) and MusicType (MUSC). Instance ids are audio handles. A wait on a sound
// polls Sound.IsPlaying(id) (docs/script-api.md section 4).

import "../audio"
import "../worldstate"

register_sound :: proc(reg: ^Registry) {
	register(reg, "Sound", "Play", n_sound_play)
	register(reg, "Sound", "IsPlaying", n_sound_is_playing)
	register(reg, "Sound", "StopInstance", n_sound_stop_instance)
	register(reg, "Sound", "SetInstanceVolume", n_sound_set_instance_volume)
	register(reg, "MusicType", "Add", proc(c: ^Call, args: []Value) -> Value {
		if c.audio != nil {audio.music_add(c.audio, c.self)}
		return nil
	})
	register(reg, "MusicType", "Remove", proc(c: ^Call, args: []Value) -> Value {
		if c.audio != nil {audio.music_remove(c.audio, c.self)}
		return nil
	})
	register(reg, "SoundCategory", "Mute", proc(c: ^Call, args: []Value) -> Value {return category(c, muted = true)})
	register(reg, "SoundCategory", "UnMute", proc(c: ^Call, args: []Value) -> Value {return category(c, muted = false)})
	register(reg, "SoundCategory", "Pause", proc(c: ^Call, args: []Value) -> Value {return category(c, paused = true)})
	register(reg, "SoundCategory", "UnPause", proc(c: ^Call, args: []Value) -> Value {return category(c, paused = false)})
	register(reg, "SoundCategory", "SetVolume", proc(c: ^Call, args: []Value) -> Value {return category(c, volume = arg_f32(args, 0, 1))})
	register(reg, "SoundCategory", "SetFrequency", proc(c: ^Call, args: []Value) -> Value {return category(c, frequency = arg_f32(args, 0, 1))})
}

// n_sound_play plays the sound's descriptor at akSource, flat when None; its instance id, 0 when
// nothing plays.
n_sound_play :: proc(c: ^Call, args: []Value) -> Value {
	if c.audio == nil {return i32(0)}
	at: Maybe([3]f32)
	if src := arg_form(args, 0); src != 0 {at = worldstate.ref_pos(c.ws, c.db, src)}
	return i32(audio.play_descriptor(c.audio, c.vfs, c.db, c.db.sound_markers[c.self], at))
}

n_sound_is_playing :: proc(c: ^Call, args: []Value) -> Value {
	return c.audio != nil && audio.playing(c.audio, audio.Handle(arg_i32(args, 0, 0)))
}

n_sound_stop_instance :: proc(c: ^Call, args: []Value) -> Value {
	if c.audio != nil {audio.stop(c.audio, audio.Handle(arg_i32(args, 0, 0)))}
	return nil
}

n_sound_set_instance_volume :: proc(c: ^Call, args: []Value) -> Value {
	if c.audio != nil {audio.set_volume(c.audio, audio.Handle(arg_i32(args, 0, 0)), arg_f32(args, 1, 1))}
	return nil
}

@(private = "file")
category :: proc(c: ^Call, volume: Maybe(f32) = nil, frequency: Maybe(f32) = nil, muted: Maybe(bool) = nil, paused: Maybe(bool) = nil) -> Value {
	if c.audio != nil {audio.category_set(c.audio, c.self, volume, frequency, muted, paused)}
	return nil
}
