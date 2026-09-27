package audio

// Output device, voices and sound decode. The engine reads WAV and Ogg (Opus) only, either one in
// any sound slot: the installer converts xWMA, and a mod ships whichever it likes. SDL mixes:
// each playing sound is an audio stream bound to the one device, which SDL's audio thread asks for
// stereo samples as it plays (feed). Any thread can play and stop; update, once a frame, places
// the sounds around the listener and releases the finished ones.

import "base:runtime"
import "core:c"
import "core:encoding/endian"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:sync"
import sdl "vendor:sdl3"
import "../formats/ffmpeg"
import "../gamedb"
import "../vfs"

// Sound is one decoded file: interleaved samples, and the smpl loop region in frames (0, 0 = none).
Sound :: struct {
	samples:  []f32,
	rate:     int,
	channels: int,
	loop:     [2]int,
}

// Handle names a playing sound; 0 is none.
Handle :: distinct u32

// Placement puts a sound in the world: its position (game units) and its output model.
Placement :: struct {
	pos:    [3]f32,
	output: gamedb.Sound_Output,
}

Voice :: struct {
	stream:  ^sdl.AudioStream,
	sound:   Sound, // owned; read by feed
	handle:  Handle,
	gain:    f32, // before placement
	volume:  f32, // a script's (SetInstanceVolume)
	ratio:   f32, // speed and pitch, before its categories'
	chain:   [4]gamedb.Form_ID, // its category and that category's parents
	at:      Maybe(Placement), // nil: flat, as for UI sounds and the player's own voice
	// Shared with feed on SDL's audio thread, which alone moves cursor.
	cursor:  int,
	looping: bool, // atomic: stop clears it, and the tail past the loop region plays out
	paused:  bool, // atomic: its category is paused; feed holds the cursor
	done:    bool, // atomic: feed gave the last sample
	gains:   [2]u32, // atomic f32 bits: the left and right level
}

// Category_State is what scripts set on a sound category (SoundCategory natives). It applies to
// the category's sounds and to its child categories'.
Category_State :: struct {
	volume, frequency: f32,
	muted, paused:     bool,
}

Audio :: struct {
	device:     sdl.AudioDeviceID, // 0: no output, every play is silent
	spec:       sdl.AudioSpec, // the device's format, every stream's output
	mu:         sync.Mutex, // voices, last, listener, categories
	voices:     [dynamic]^Voice,
	last:       Handle,
	listener:   [2][3]f32, // position, right
	categories: map[gamedb.Form_ID]Category_State,
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
	for v in a.voices {release(v)}
	delete(a.voices)
	delete(a.categories)
	if a.device != 0 {sdl.CloseAudioDevice(a.device)}
	sdl.QuitSubSystem({.AUDIO})
	a^ = {}
}

// play starts s, which it owns from now; 0 when there is no device. ratio scales its speed and
// pitch. A looping sound plays up to its loop end, then repeats the loop region until stopped.
play :: proc(a: ^Audio, s: Sound, gain: f32 = 1, ratio: f32 = 1, loop := false, at: Maybe(Placement) = nil, chain: [4]gamedb.Form_ID = {}) -> Handle {
	if a.device == 0 || len(s.samples) == 0 {
		delete(s.samples)
		return 0
	}
	src := sdl.AudioSpec{format = .F32, channels = 2, freq = i32(s.rate)}
	st := sdl.CreateAudioStream(&src, &a.spec)
	if st == nil {
		log.warnf("audio: %s", sdl.GetError())
		delete(s.samples)
		return 0
	}
	v := new(Voice)
	v^ = {stream = st, sound = s, gain = gain, volume = 1, ratio = ratio, chain = chain, at = at, looping = loop}
	sync.guard(&a.mu)
	store_gains(v, levels(a, v))
	sdl.SetAudioStreamFrequencyRatio(st, ratio * frequency(a, v))
	sdl.SetAudioStreamGetCallback(st, feed, v)
	a.last += 1
	v.handle = a.last
	append(&a.voices, v)
	sdl.BindAudioStream(a.device, st)
	return v.handle
}

// play_descriptor plays one of a sound descriptor's files (SNDR) at its category's volume and
// static attenuation, with a random part of its dB and frequency variance; placed at `at` under
// its output model, else flat. 0 when it has none.
play_descriptor :: proc(a: ^Audio, v: ^vfs.VFS, db: ^gamedb.DB, sndr: gamedb.Form_ID, at: Maybe([3]f32) = nil) -> Handle {
	d, ok := db.sounds[sndr]
	if !ok || len(d.files) == 0 || a.device == 0 {return 0}
	if pos, placed := at.?; placed && d.loop == .None && gamedb.output_level(db.sound_outputs[d.output], distance(a, pos)) == 0 {
		return 0 // out of earshot: a one-shot is never heard, so never decoded
	}
	s, found := open(v, rand.choice(d.files))
	if !found {return 0}
	down := d.attenuation + rand.float32() * d.db_variance
	gain := gamedb.sound_volume(db, d.category) * math.pow(10, -down / 20)
	ratio := 1 + d.freq_shift + (rand.float32() * 2 - 1) * d.freq_variance
	place: Maybe(Placement)
	if pos, placed := at.?; placed {place = Placement{pos, db.sound_outputs[d.output]}}
	chain: [4]gamedb.Form_ID
	for c, i := d.category, 0; c != 0 && i < len(chain); c, i = db.sound_categories[c].parent, i + 1 {chain[i] = c}
	return play(a, s, gain, max(ratio, 0.01), d.loop != .None, place, chain)
}

playing :: proc(a: ^Audio, h: Handle) -> bool {
	sync.guard(&a.mu)
	for v in a.voices {
		if v.handle == h {return true}
	}
	return false
}

// set_volume sets a playing sound's script volume (Sound.SetInstanceVolume), 0..1.
set_volume :: proc(a: ^Audio, h: Handle, volume: f32) {
	sync.guard(&a.mu)
	for v in a.voices {
		if v.handle == h {v.volume = clamp(volume, 0, 1)}
	}
}

// category_set changes the given parts of a sound category's script state (SoundCategory natives).
category_set :: proc(a: ^Audio, c: gamedb.Form_ID, volume: Maybe(f32) = nil, frequency: Maybe(f32) = nil, muted: Maybe(bool) = nil, paused: Maybe(bool) = nil) {
	sync.guard(&a.mu)
	st := a.categories[c] or_else Category_State{volume = 1, frequency = 1}
	st.volume = volume.? or_else st.volume
	st.frequency = frequency.? or_else st.frequency
	st.muted = muted.? or_else st.muted
	st.paused = paused.? or_else st.paused
	a.categories[c] = st
}

// stop ends a sound: at once, or for a looping one with a loop region, after its tail (the part
// past the region) plays.
stop :: proc(a: ^Audio, h: Handle) {
	gone: ^Voice
	{
		sync.guard(&a.mu)
		for v, i in a.voices {
			if v.handle != h {continue}
			if sync.atomic_load(&v.looping) && region(v.sound)[1] < len(v.sound.samples) {
				sync.atomic_store(&v.looping, false)
			} else {
				gone = v
				ordered_remove(&a.voices, i)
			}
			break
		}
	}
	if gone != nil {release(gone)} // outside mu: destroying a stream waits for its feed
}

// update places the sounds around the listener (its position and facing, game units) and
// releases the ones that played to their end.
update :: proc(a: ^Audio, pos, forward: [3]f32) {
	gone := make([dynamic]^Voice, context.temp_allocator)
	{
		sync.guard(&a.mu)
		a.listener = {pos, linalg.normalize0(linalg.cross(forward, [3]f32{0, 0, 1}))}
		#reverse for v, i in a.voices {
			if sync.atomic_load(&v.done) && sdl.GetAudioStreamQueued(v.stream) == 0 && sdl.GetAudioStreamAvailable(v.stream) == 0 {
				append(&gone, v)
				ordered_remove(&a.voices, i)
				continue
			}
			store_gains(v, levels(a, v))
			sdl.SetAudioStreamFrequencyRatio(v.stream, v.ratio * frequency(a, v))
		}
	}
	for v in gone {release(v)}
}

// frequency is the product of a voice's categories' script frequencies.
@(private = "file")
frequency :: proc(a: ^Audio, v: ^Voice) -> f32 {
	f := f32(1)
	for c in v.chain {
		if st, ok := a.categories[c]; ok && c != 0 {f *= st.frequency}
	}
	return f
}

// levels are a voice's left and right levels now: its gain, times its output model's level at its
// distance from the listener, panned by which side of the listener it is on when the model pans.
@(private = "file")
levels :: proc(a: ^Audio, v: ^Voice) -> [2]f32 {
	g := v.gain * v.volume
	paused := false
	for c in v.chain {
		st, ok := a.categories[c]
		if !ok || c == 0 {continue}
		g *= 0 if st.muted else st.volume
		paused ||= st.paused
	}
	sync.atomic_store(&v.paused, paused)
	at, placed := v.at.?
	if !placed {return g}
	to := at.pos - a.listener[0]
	g *= gamedb.output_level(at.output, linalg.length(to))
	if !at.output.pans {return g}
	p := linalg.dot(linalg.normalize0(to), a.listener[1]) // -1 left .. 1 right
	return {g * min(1, 1 - p), g * min(1, 1 + p)}
}

@(private = "file")
distance :: proc(a: ^Audio, pos: [3]f32) -> f32 {
	sync.guard(&a.mu)
	return linalg.length(pos - a.listener[0])
}

@(private = "file")
store_gains :: proc(v: ^Voice, g: [2]f32) {
	sync.atomic_store(&v.gains[0], transmute(u32)g[0])
	sync.atomic_store(&v.gains[1], transmute(u32)g[1])
}

@(private = "file")
release :: proc(v: ^Voice) {
	sdl.DestroyAudioStream(v.stream)
	delete(v.sound.samples)
	free(v)
}

// feed is SDL's audio thread asking a voice's stream for more: stereo frames at the sound's rate,
// at the voice's current levels, looping while it loops.
@(private = "file")
feed :: proc "c" (userdata: rawptr, stream: ^sdl.AudioStream, additional, total: c.int) {
	context = runtime.default_context()
	v := (^Voice)(userdata)
	s := v.sound
	ch := max(s.channels, 1)
	gl := transmute(f32)sync.atomic_load(&v.gains[0])
	gr := transmute(f32)sync.atomic_load(&v.gains[1])
	if sync.atomic_load(&v.paused) {return}
	buf: [2048]f32
	need := int(additional) / (2 * size_of(f32)) + 1
	for need > 0 && !sync.atomic_load(&v.done) {
		n := 0
		for n < len(buf) / 2 && n < need {
			r := region(s)
			if sync.atomic_load(&v.looping) && v.cursor >= r[1] {v.cursor = r[0]}
			if v.cursor >= len(s.samples) {
				sync.atomic_store(&v.done, true)
				break
			}
			l := s.samples[v.cursor]
			buf[2 * n], buf[2 * n + 1] = l * gl, (s.samples[v.cursor + 1] if ch > 1 else l) * gr
			v.cursor += ch
			n += 1
		}
		sdl.PutAudioStreamData(stream, &buf[0], i32(2 * n * size_of(f32)))
		need -= n
		if n == 0 {break}
	}
}

// region is a sound's loop region in samples: its smpl loop, else the whole file.
@(private = "file")
region :: proc(s: Sound) -> [2]int {
	frames := len(s.samples) / max(s.channels, 1)
	if 0 <= s.loop[0] && s.loop[0] < s.loop[1] && s.loop[1] <= frames {return s.loop * s.channels}
	return {0, len(s.samples)}
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
