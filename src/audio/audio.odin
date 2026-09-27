package audio

// Output device, voices and sound decode. The engine reads WAV and Ogg (Opus) only, either one in
// any sound slot: the installer converts xWMA, and a mod ships whichever it likes. SDL mixes:
// each playing sound is an audio stream bound to the one device.

import "core:encoding/endian"
import "core:log"
import "core:math"
import "core:math/rand"
import sdl "vendor:sdl3"
import "../formats/ffmpeg"
import "../gamedb"
import "../vfs"

// LOOP_AHEAD_S is how much of a looping sound stays queued: update tops it up every frame.
LOOP_AHEAD_S :: 0.25

// Sound is one decoded file: interleaved samples, and the smpl loop region in frames (0, 0 = none).
Sound :: struct {
	samples:  []f32,
	rate:     int,
	channels: int,
	loop:     [2]int,
}

// Handle names a playing sound; 0 is none.
Handle :: distinct u32

Voice :: struct {
	stream:  ^sdl.AudioStream,
	sound:   Sound, // owned
	handle:  Handle,
	looping: bool, // repeats its loop region (or the whole file) until stopped
}

// (hole script-audio :tags (audio script) :sev gap) Audio is the main thread's: its voice list is unguarded, so the script thread (Sound natives, scene and bark lines) cannot play a sound.
Audio :: struct {
	device: sdl.AudioDeviceID, // 0: no output, every play is silent
	spec:   sdl.AudioSpec, // the device's format, every stream's output
	voices: [dynamic]Voice,
	last:   Handle,
}

// init opens the default output device. Without one the game runs silent.
init :: proc(a: ^Audio) -> bool {
	if !sdl.InitSubSystem({.AUDIO}) {
		log.warnf("audio: no audio subsystem: %s", sdl.GetError())
		return false
	}
	a.device = sdl.OpenAudioDevice(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, nil)
	if a.device == 0 || !sdl.GetAudioDeviceFormat(a.device, &a.spec, nil) {
		log.warnf("audio: no output device: %s", sdl.GetError())
		a.device = 0
		return false
	}
	log.infof("audio: %s, %d Hz, %d channel(s)", sdl.GetAudioDeviceName(a.device), a.spec.freq, a.spec.channels)
	return true
}

shutdown :: proc(a: ^Audio) {
	for v in a.voices {
		sdl.DestroyAudioStream(v.stream)
		delete(v.sound.samples)
	}
	delete(a.voices)
	if a.device != 0 {sdl.CloseAudioDevice(a.device)}
	sdl.QuitSubSystem({.AUDIO})
	a^ = {}
}

// play starts s, which it owns from now; 0 when there is no device. ratio scales its speed and
// pitch. A looping sound plays up to its loop end, then repeats the loop region until stopped.
play :: proc(a: ^Audio, s: Sound, gain: f32 = 1, ratio: f32 = 1, loop := false) -> Handle {
	if a.device == 0 || len(s.samples) == 0 {
		delete(s.samples)
		return 0
	}
	src := sdl.AudioSpec{format = .F32, channels = i32(s.channels), freq = i32(s.rate)}
	st := sdl.CreateAudioStream(&src, &a.spec)
	if st == nil {
		log.warnf("audio: %s", sdl.GetError())
		delete(s.samples)
		return 0
	}
	if loop {
		put(st, s.samples[:region(s)[1]])
	} else {
		put(st, s.samples)
		sdl.FlushAudioStream(st)
	}
	sdl.SetAudioStreamGain(st, gain)
	sdl.SetAudioStreamFrequencyRatio(st, ratio)
	sdl.BindAudioStream(a.device, st)
	a.last += 1
	append(&a.voices, Voice{st, s, a.last, loop})
	return a.last
}

// (hole sound-3d :tags audio :sev gap) every sound plays flat, at full level wherever it is: no distance attenuation (SOPM output models, 86, are not decoded), no panning, no listener. So only the player's own activations make a sound.
// play_descriptor plays one of a sound descriptor's files (SNDR) at its category's volume and
// static attenuation, with a random part of its dB and frequency variance; 0 when it has none.
play_descriptor :: proc(a: ^Audio, v: ^vfs.VFS, db: ^gamedb.DB, sndr: gamedb.Form_ID) -> Handle {
	d, ok := db.sounds[sndr]
	if !ok || len(d.files) == 0 || a.device == 0 {return 0}
	s, found := open(v, rand.choice(d.files))
	if !found {return 0}
	down := d.attenuation + rand.float32() * d.db_variance
	gain := gamedb.sound_volume(db, d.category) * math.pow(10, -down / 20)
	ratio := 1 + d.freq_shift + (rand.float32() * 2 - 1) * d.freq_variance
	return play(a, s, gain, max(ratio, 0.01), d.loop != .None)
}

// region is a sound's loop region in samples: its smpl loop, else the whole file.
@(private = "file")
region :: proc(s: Sound) -> [2]int {
	frames := len(s.samples) / max(s.channels, 1)
	if 0 <= s.loop[0] && s.loop[0] < s.loop[1] && s.loop[1] <= frames {return s.loop * s.channels}
	return {0, len(s.samples)}
}

@(private = "file")
put :: proc(st: ^sdl.AudioStream, samples: []f32) {
	sdl.PutAudioStreamData(st, raw_data(samples), i32(len(samples) * size_of(f32)))
}

playing :: proc(a: ^Audio, h: Handle) -> bool {
	for v in a.voices {
		if v.handle == h {return true}
	}
	return false
}

// stop ends a sound: at once, or for a looping one with a loop region, after its tail (the part
// past the region) plays.
stop :: proc(a: ^Audio, h: Handle) {
	for &v, i in a.voices {
		if v.handle != h {continue}
		end := region(v.sound)[1]
		if !v.looping || end == len(v.sound.samples) {
			release(a, i)
			return
		}
		put(v.stream, v.sound.samples[end:])
		sdl.FlushAudioStream(v.stream)
		v.looping = false
		return
	}
}

// update keeps looping sounds queued and releases the ones that played to their end.
update :: proc(a: ^Audio) {
	#reverse for v, i in a.voices {
		queued := sdl.GetAudioStreamQueued(v.stream)
		if v.looping {
			ahead := i32(LOOP_AHEAD_S * f32(v.sound.rate * v.sound.channels * size_of(f32)))
			for r := region(v.sound); queued < ahead; queued = sdl.GetAudioStreamQueued(v.stream) {
				put(v.stream, v.sound.samples[r[0]:r[1]])
			}
		} else if queued == 0 && sdl.GetAudioStreamAvailable(v.stream) == 0 {
			release(a, i)
		}
	}
}

@(private = "file")
release :: proc(a: ^Audio, i: int) {
	sdl.DestroyAudioStream(a.voices[i].stream)
	delete(a.voices[i].sound.samples)
	ordered_remove(&a.voices, i)
}

seconds :: proc(s: Sound) -> f32 {
	return f32(len(s.samples) / max(s.channels, 1)) / f32(max(s.rate, 1))
}

// open resolves a sound path to <base>.wav or <base>.ogg, whatever extension it names, and
// decodes it. When both exist the higher-priority mount wins, so a mod's .wav overrides the
// vanilla .ogg and a mod's .ogg the vanilla .wav.
open :: proc(v: ^vfs.VFS, path: string, allocator := context.allocator) -> (s: Sound, ok: bool) {
	base := path
	for i := len(path) - 1; i >= 0 && path[i] != '\\' && path[i] != '/'; i -= 1 {
		if path[i] == '.' {
			base = path[:i]
			break
		}
	}
	best, best_rank := "", -1
	for ext in ([]string{".wav", ".ogg"}) {
		candidate := concat(base, ext)
		if r, found := vfs.rank(v, candidate); found && r > best_rank {best, best_rank = candidate, r}
	}
	if best == "" {return}
	data := vfs.read(v, best, context.temp_allocator) or_return
	samples, rate, channels, err := ffmpeg.decode(data, allocator)
	if err != "" {
		log.warnf("audio: %s: %s", best, err)
		return
	}
	return {samples, rate, channels, wav_loop(data)}, true
}

@(private = "file")
concat :: proc(a, b: string) -> string {
	buf := make([]u8, len(a) + len(b), context.temp_allocator)
	copy(buf, a)
	copy(buf[len(a):], b)
	return string(buf)
}

// wav_loop reads the first loop of a WAV's smpl chunk, in frames; {0, 0} for none or not a WAV.
@(private = "file")
wav_loop :: proc(b: []u8) -> [2]int {
	if len(b) < 12 || string(b[:4]) != "RIFF" || string(b[8:12]) != "WAVE" {return {}}
	for i := 12; i + 8 <= len(b); {
		size, _ := endian.get_u32(b[i + 4:], .Little)
		body := b[i + 8:min(i + 8 + int(size), len(b))]
		// smpl: 36 bytes of sampler data (loop count at 28), then 24-byte loops (start at 8, end at 12)
		if string(b[i:i + 4]) == "smpl" && len(body) >= 60 {
			if n, _ := endian.get_u32(body[28:], .Little); n > 0 {
				start, _ := endian.get_u32(body[44:], .Little)
				end, _ := endian.get_u32(body[48:], .Little)
				return {int(start), int(end)}
			}
		}
		i += 8 + int(size) + int(size & 1)
	}
	return {}
}
