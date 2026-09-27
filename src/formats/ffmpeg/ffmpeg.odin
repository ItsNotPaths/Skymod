package ffmpeg

// The vendored ffmpeg (build/build-ffmpeg.sh), through the C glue in build/ffmpeg_glue.c.

import "core:fmt"

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
	skyff_free :: proc(p: [^]u8) ---
	skyff_error :: proc(code: i32, buf: [^]u8, size: i64) ---
}

// to_ogg transcodes one audio file (xWMA, WAV, Ogg) to Ogg Opus at bitrate bits/s per channel.
// The result is ffmpeg's memory: release it with free. err is ffmpeg's message on failure.
to_ogg :: proc(data: []u8, bitrate: int) -> (ogg: []u8, err: string) {
	out: [^]u8
	n: i64
	if code := skyff_to_ogg(raw_data(data), i64(len(data)), i32(bitrate), &out, &n); code < 0 {
		buf: [256]u8
		skyff_error(code, &buf[0], len(buf))
		return nil, fmt.tprintf("%s", cstring(&buf[0]))
	}
	return out[:n], ""
}

free :: proc(ogg: []u8) {
	skyff_free(raw_data(ogg))
}
