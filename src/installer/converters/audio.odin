package converters

// xWMA -> Ogg (Opus), once, at install. The engine reads only WAV and Ogg, interchangeably:
// WAV passes through untouched (its smpl loop points too), .xwm becomes .ogg, and .fuz splits
// into <base>.ogg + <base>.lip. Each source archive's converted entries repack into a same-named
// BSA in <content>/baseaudio/bethassets, a content mod.
//
// (hole voice-converter :tags audio :sev gap) no xWMA converter: voice (.fuz) and music (.xwm) stay unreadable, and no .lip is split out for a face.
// (hole mod-audio-convert :tags (audio mods) :sev gap :needs voice-converter) only the game install converts: a user mod that ships .xwm or .fuz, loose or in its BSA, plays nothing.
// (hole lip-converter :tags (animation assets unclaimed) :sev gap :needs voice-converter) .lip (FaceFX lip-sync curves) is copied raw; nothing turns it into a modern per-blendshape curve format beside the .ogg.

Audio_Stats :: struct {
	converted: int,
	failed:    int, // decode or encode failures; the file is skipped
}

convert_audio :: proc(archives: []string, out_dir: string) -> (st: Audio_Stats, ok: bool) {
	return {}, true
}
