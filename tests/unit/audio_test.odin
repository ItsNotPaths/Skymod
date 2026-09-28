package unit_tests

// The decode thread, on SDL's dummy audio driver: a queued sound is named at once, starts once
// decoded, and stops; one stopped while it decodes is freed by the decode thread.

import "core:os"
import "core:sync"
import "core:testing"
import "core:time"
import "../../src/audio"
import "../../src/formats/ffmpeg"
import "../../src/gamedb"

@(test)
test_audio_queue :: proc(t: ^testing.T) {
	os.set_env("SDL_AUDIO_DRIVER", "dummy")
	a: audio.Audio
	testing.expect(t, audio.init(&a), "dummy device")
	defer audio.shutdown(&a)

	h := audio.queue(&a, nil, synthetic_wav(44100))
	testing.expect(t, h != 0 && audio.playing(&a, h), "named and playing while it decodes")
	started := false
	for _ in 0 ..< 200 {
		{
			sync.guard(&a.mu)
			started = len(a.voices) == 1 && a.voices[0].stream != nil
		}
		if started {break}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, started, "the decode thread started its stream")
	audio.stop(&a, h)
	testing.expect(t, !audio.playing(&a, h), "stopped")

	cancelled := audio.queue(&a, nil, synthetic_wav(44100))
	audio.stop(&a, cancelled) // most likely still decoding
	testing.expect(t, !audio.playing(&a, cancelled), "cancelled")
	time.sleep(100 * time.Millisecond)
	testing.expect_value(t, len(a.voices), 0)

	// A sound on a ref follows it, `lift` above its origin; one on a ref not in `emitters` stays put.
	on_ref := audio.queue(&a, nil, synthetic_wav(44100), at = audio.Placement{pos = {0, 0, 0}, ref = 7, lift = 10})
	still := audio.queue(&a, nil, synthetic_wav(44100), at = audio.Placement{pos = {5, 0, 0}, ref = 8})
	for _ in 0 ..< 200 {
		{
			sync.guard(&a.mu)
			started = len(a.voices) == 2 && a.voices[0].stream != nil && a.voices[1].stream != nil
		}
		if started {break}
		time.sleep(10 * time.Millisecond)
	}
	emitters: map[gamedb.Form_ID][3]f32
	defer delete(emitters)
	emitters[7] = {100, 0, 0}
	audio.update(&a, {}, {0, 1, 0}, 0, emitters)
	{
		sync.guard(&a.mu)
		for v in a.voices {
			at := v.at.?
			if v.handle == on_ref {testing.expect_value(t, at.pos, [3]f32{100, 0, 10})}
			if v.handle == still {testing.expect_value(t, at.pos, [3]f32{5, 0, 0})}
		}
	}
	audio.stop(&a, on_ref)
	audio.stop(&a, still)

	secs, ok := ffmpeg.probe(synthetic_wav(22050, context.temp_allocator))
	testing.expect(t, ok && abs(secs - 0.5) < 0.01, "probe reads the length")
}
