package ffmpeg

// The vendored ffmpeg (build/build-ffmpeg.sh), through the C glue in build/ffmpeg_glue.c.

import "core:fmt"
import "core:slice"

foreign import ff {
	"../../../vendor/ffmpeg/lib/libskyff.a",
	"../../../vendor/ffmpeg/lib/libavformat.a",
	"../../../vendor/ffmpeg/lib/libavcodec.a",
	"../../../vendor/ffmpeg/lib/libswresample.a",
	"../../../vendor/ffmpeg/lib/libavutil.a",
	"../../../vendor/ffmpeg/lib/libopus.a",
	"system:m",
}

@(default_calling_convention = "c")
foreign ff {
	skyff_to_ogg :: proc(data: [^]u8, size: i64, bitrate: i32, out: ^[^]u8, out_size: ^i64) -> i32 ---
	skyff_decode :: proc(data: [^]u8, size: i64, out: ^[^]f32, frames: ^i64, rate, channels: ^i32) -> i32 ---
	skyff_free :: proc(p: rawptr) ---
	skyff_error :: proc(code: i32, buf: [^]u8, size: i64) ---
}

// decode decodes one audio file (WAV, Ogg) to interleaved float samples at its own rate.
decode :: proc(data: []u8, allocator := context.allocator) -> (samples: []f32, rate, channels: int, err: string) {
	out: [^]f32
	frames: i64
	r, ch: i32
	if code := skyff_decode(raw_data(data), i64(len(data)), &out, &frames, &r, &ch); code < 0 {
		return nil, 0, 0, message(code)
	}
	defer skyff_free(out)
	return slice.clone(out[:frames * i64(ch)], allocator), int(r), int(ch), ""
}

// to_ogg transcodes one audio file (xWMA, WAV, Ogg) to Ogg Opus at bitrate bits/s per channel.
// The result is ffmpeg's memory: release it with free. err is ffmpeg's message on failure.
to_ogg :: proc(data: []u8, bitrate: int) -> (ogg: []u8, err: string) {
	out: [^]u8
	n: i64
	if code := skyff_to_ogg(raw_data(data), i64(len(data)), i32(bitrate), &out, &n); code < 0 {
		return nil, message(code)
	}
	return out[:n], ""
}

free :: proc(ogg: []u8) {
	skyff_free(raw_data(ogg))
}

@(private = "file")
message :: proc(code: i32) -> string {
	buf: [256]u8
	skyff_error(code, &buf[0], len(buf))
	return fmt.tprintf("%s", cstring(&buf[0]))
}
