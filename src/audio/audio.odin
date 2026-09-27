package audio

// Output device, mixer and sound decode. The engine reads WAV and Ogg (Opus) only, either one in
// any sound slot: the installer converts xWMA, and a mod ships whichever it likes.

import "../vfs"

// (hole audio-output :tags audio :sev blocker) no audio output: no device, no mixer, no voice bus. The engine is silent.
// (hole sound-loop-markers :tags audio :sev gap :needs (audio-output audio-decode)) a looping sound repeats the whole file; the WAV smpl loop region (start, loop while held, tail on stop) is ignored. 117 vanilla _lpm files have a partial region.

// Sound is one decoded file: interleaved samples, and the smpl loop region in frames (0, 0 = none).
Sound :: struct {
	samples:  []f32,
	rate:     int,
	channels: int,
	loop:     [2]int,
}

init :: proc() -> bool {
	return false
}

// (hole audio-decode :tags audio :sev gap) nothing decodes a sound. A record's path names .wav, .xwm or .fuz; open must find <base>.wav or <base>.ogg; when both exist, the higher-priority mount wins, so a mod's .wav overrides the vanilla .ogg. The game mounts only the mesh, texture and interface archives and plugin archives (game_archive_names), so Skyrim - Sounds.bsa, which holds the WAVs, is not mounted.

// open resolves a sound path to <base>.wav or <base>.ogg, whatever extension it names, and decodes it.
open :: proc(v: ^vfs.VFS, path: string) -> (s: Sound, ok: bool) {
	return {}, false
}
