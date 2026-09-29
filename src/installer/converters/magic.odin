package converters

// Magic: the base game's magic records become Lua in the core scripts mod (src/magictranslate).

import "../../magictranslate"

// convert_magic translates every magic record of `plugins` (file names in `data`).
convert_magic :: proc(data: string, plugins: []string, out_dir: string, progress: ^Progress = nil) -> (st: magictranslate.Stats, ok: bool) {
	return magictranslate.translate(data, plugins, nil, out_dir)
}
