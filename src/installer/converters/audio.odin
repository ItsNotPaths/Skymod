package converters

// xWMA -> Ogg (Opus), once, at install. The engine reads only WAV and Ogg, interchangeably:
// WAV passes through untouched (its smpl loop points too), .xwm becomes .ogg, and .fuz splits
// into <base>.ogg + <base>.lip. Each source archive's converted entries repack into a same-named
// BSA in <content>/baseaudio/bethassets, a content mod.
//
// (hole mod-audio-convert :tags (audio mods) :sev gap) only the game install converts: a user mod that ships .xwm or .fuz, loose or in its BSA, plays nothing.
// (hole lip-converter :tags (animation assets unclaimed) :sev gap) .lip (FaceFX lip-sync curves) is copied raw; nothing turns it into a modern per-blendshape curve format beside the .ogg.

import "core:encoding/endian"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "../../formats/bsa"
import "../../formats/ffmpeg"

// OPUS_BITRATE is per channel: above the 32 kb/s mono xWMA of the voice lines, so the second
// lossy pass stays inaudible.
OPUS_BITRATE :: 48_000

Audio_Stats :: struct {
	converted: int,
	failed:    int, // decode or encode failures; the file is skipped
}

// convert_audio converts every .xwm and .fuz in `archives`, which are in mount order: a later
// archive's copy of a sound wins, so the output holds each sound once and its mount order cannot
// matter. An archive that will not open is skipped with a warning.
convert_audio :: proc(archives: []string, out_dir: string, progress: ^Progress = nil) -> (st: Audio_Stats, ok: bool) {
	os.make_directory_all(out_dir)
	if !os.is_dir(out_dir) {
		log.errorf("audio: could not create %q", out_dir)
		return st, false
	}

	opened := make([dynamic]bsa.Archive, 0, len(archives))
	defer {
		for &a in opened {bsa.close(&a)}
		delete(opened)
	}
	Source :: struct {arc, entry: int}
	winner := make(map[string]Source) // lowercased path without extension -> the copy that wins
	defer {
		for k in winner {delete(k)}
		delete(winner)
	}
	for path in archives {
		a, aok := bsa.open(path)
		if !aok {
			log.warnf("audio: skipping unreadable archive %q", path)
			continue
		}
		append(&opened, a)
		for e, i in a.entries {
			ext := strings.to_lower(filepath.ext(e.path), context.temp_allocator)
			if ext != ".xwm" && ext != ".fuz" {continue}
			key := strings.to_lower(e.path[:len(e.path) - len(ext)])
			_, found := winner[key]
			winner[key] = {len(opened) - 1, i} // an override keeps the map's existing key
			if found {delete(key)}
		}
	}

	progress_step(progress, "Converting sounds", len(winner))
	for &a, ai in opened {
		todo := make([dynamic]int, context.temp_allocator)
		for _, s in winner {
			if s.arc == ai {append(&todo, s.entry)}
		}
		if len(todo) == 0 {continue}
		out, _ := filepath.join({out_dir, filepath.base(a.path)}, context.temp_allocator)
		ast := convert_archive(&a, todo[:], out, progress) or_return
		st.converted += ast.converted
		st.failed += ast.failed
	}
	return st, true
}

@(private = "file")
Audio_Job :: struct {
	arc:     ^bsa.Archive,
	todo:    []int, // entry indices to convert
	next:    int,   // atomic: the next todo index a worker takes
	mu:      sync.Mutex,
	spool:   ^os.File,
	end:     u64,
	entries: [dynamic]bsa.Pack_Entry,
	stats:    Audio_Stats,
	progress: ^Progress,
}

// convert_archive converts the entries `todo` of one archive into a BSA at out, through a spool
// file beside it that pack reads memory-mapped.
@(private = "file")
convert_archive :: proc(arc: ^bsa.Archive, todo: []int, out: string, progress: ^Progress) -> (st: Audio_Stats, ok: bool) {
	spool_path := strings.concatenate({out, ".spool"}, context.temp_allocator)
	spool, err := os.open(spool_path, {.Write, .Create, .Trunc})
	if err != nil {
		log.errorf("audio: could not create %q: %v", spool_path, err)
		return st, false
	}
	defer os.remove(spool_path)

	j := Audio_Job{arc = arc, todo = todo, spool = spool, progress = progress}
	defer {
		for e in j.entries {delete(e.path)}
		delete(j.entries)
	}
	workers := make([]^thread.Thread, min(os.get_processor_core_count(), len(todo)), context.temp_allocator)
	for &w in workers {
		w = thread.create_and_start_with_poly_data(&j, audio_worker, init_context = context) // the logger; temp is per thread
	}
	for w in workers {
		thread.join(w)
		thread.destroy(w)
	}
	os.close(spool)

	progress_note(progress, strings.concatenate({"packing ", filepath.base(out)}, context.temp_allocator))
	if !bsa.pack(out, spool_path, j.entries[:]) {
		log.errorf("audio: could not pack %q", out)
		return j.stats, false
	}
	log.infof("audio: %s: %d converted, %d unreadable", filepath.base(out), j.stats.converted, j.stats.failed)
	return j.stats, true
}

@(private = "file")
audio_worker :: proc(j: ^Audio_Job) {
	for {
		k := sync.atomic_add(&j.next, 1)
		if k >= len(j.todo) {return}
		e := j.arc.entries[j.todo[k]]
		progress_note(j.progress, e.path)
		data, ok := bsa.extract(j.arc, e)
		if ok {ok = convert_sound(j, e.path, data)}
		delete(data)
		sync.guard(&j.mu)
		if ok {j.stats.converted += 1} else {j.stats.failed += 1}
		progress_done(j.progress)
		free_all(context.temp_allocator)
	}
}

// convert_sound emits one .xwm as <base>.ogg, or one .fuz as <base>.ogg (or .wav, if its audio
// is already PCM) + <base>.lip.
@(private = "file")
convert_sound :: proc(j: ^Audio_Job, path: string, data: []u8) -> bool {
	base := path[:len(path) - len(filepath.ext(path))]
	audio := data
	if strings.equal_fold(filepath.ext(path), ".fuz") {
		// FUZE, u32 version, u32 lip size, the lip, then the audio.
		if len(data) < 12 || string(data[:4]) != "FUZE" {
			log.warnf("audio: %s is not a FUZ", path)
			return false
		}
		lip_size, _ := endian.get_u32(data[8:12], .Little)
		if 12 + int(lip_size) > len(data) {
			log.warnf("audio: %s: lip runs past the file", path)
			return false
		}
		if lip_size > 0 && !emit(j, base, ".lip", data[12:][:lip_size]) {return false}
		audio = data[12 + lip_size:]
	}
	if is_pcm_wav(audio) {return emit(j, base, ".wav", audio)}
	ogg, err := ffmpeg.to_ogg(audio, OPUS_BITRATE)
	if err != "" {
		log.warnf("audio: %s: %s", path, err)
		return false
	}
	defer ffmpeg.free(ogg)
	return emit(j, base, ".ogg", ogg)
}

// is_pcm_wav reports a RIFF WAVE whose fmt chunk, the first chunk, is PCM (tag 1).
@(private = "file")
is_pcm_wav :: proc(b: []u8) -> bool {
	if len(b) < 22 || string(b[:4]) != "RIFF" || string(b[8:12]) != "WAVE" || string(b[12:16]) != "fmt " {return false}
	tag, _ := endian.get_u16(b[20:22], .Little)
	return tag == 1
}

// emit appends one output file to the spool.
@(private = "file")
emit :: proc(j: ^Audio_Job, base, ext: string, data: []u8) -> bool {
	sync.guard(&j.mu)
	if n, err := os.write_at(j.spool, data, i64(j.end)); err != nil || n != len(data) {
		log.errorf("audio: spool write failed: %v", err)
		return false
	}
	append(&j.entries, bsa.Pack_Entry{strings.clone_to_cstring(strings.concatenate({base, ext}, context.temp_allocator)), j.end, u64(len(data))})
	j.end += u64(len(data))
	return true
}
