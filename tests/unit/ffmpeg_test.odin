package unit_tests

// ffmpeg glue test. Hermetic: a synthetic PCM WAV goes through the same transcode path as the
// installer's xWMA; the real wmav2 decode is proven by converting the installs.

import "core:encoding/endian"
import "core:math"
import "core:testing"
import "../../src/formats/ffmpeg"

@(test)
test_ffmpeg_wav_to_ogg :: proc(t: ^testing.T) {
	RATE :: 44100
	wav := make([]u8, 44 + RATE * 2)
	defer delete(wav)
	copy(wav[0:], "RIFF")
	endian.put_u32(wav[4:], .Little, u32(len(wav) - 8))
	copy(wav[8:], "WAVEfmt ")
	endian.put_u32(wav[16:], .Little, 16)
	endian.put_u16(wav[20:], .Little, 1) // PCM
	endian.put_u16(wav[22:], .Little, 1) // mono
	endian.put_u32(wav[24:], .Little, RATE)
	endian.put_u32(wav[28:], .Little, RATE * 2)
	endian.put_u16(wav[32:], .Little, 2)
	endian.put_u16(wav[34:], .Little, 16)
	copy(wav[36:], "data")
	endian.put_u32(wav[40:], .Little, RATE * 2)
	for i in 0 ..< RATE { 	// one second of 440 Hz
		endian.put_i16(wav[44 + 2 * i:], .Little, i16(8000 * math.sin(2 * math.PI * 440 * f64(i) / RATE)))
	}

	ogg, err := ffmpeg.to_ogg(wav, 48_000)
	testing.expectf(t, err == "", "to_ogg: %s", err)
	defer ffmpeg.free(ogg)
	testing.expect(t, len(ogg) > 1000 && string(ogg[:4]) == "OggS", "an Ogg stream")

	_, bad := ffmpeg.to_ogg(transmute([]u8)string("not audio at all"), 48_000)
	testing.expect(t, bad != "", "garbage fails with a message")
}
