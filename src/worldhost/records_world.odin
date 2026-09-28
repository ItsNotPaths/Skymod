package worldhost

// The engine's record views: world (see records.odin).

import "../formats/esm"
import "../gamedb"
import "../plugin"

@(private)
view_cell :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Cell, ok: bool) {
	c := db.cells[form] or_return
	v = {
		form_id = c.form_id, editor_id = str(c.editor_id), interior = c.interior, public = c.public,
		world_form_id = c.world_form_id, gx = c.gx, gy = c.gy, has_grid = c.has_grid,
		water_height = c.water_height, water_type = c.water_type, location = c.location, zone = c.zone,
		acoustic = c.acoustic, music = c.music,
	}
	return v, true
}

@(private = "file")
location_refs :: proc(rs: []gamedb.Special_Ref) -> plugin.Span(plugin.Location_Special_Ref) {
	out := make([]plugin.Location_Special_Ref, len(rs), context.temp_allocator)
	for r, i in rs {out[i] = {r.ref_type, r.ref}}
	return plugin.span(out)
}

@(private)
view_location :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Location, ok: bool) {
	l := db.locations[form] or_return
	v = {
		parent = l.parent, marker_color = l.marker_color, has_marker_color = l.has_marker_color,
		special_refs = location_refs(l.special_refs), master_refs = location_refs(l.master_refs),
		crime_faction = l.crime_faction,
	}
	return v, true
}

@(private)
view_worldspace :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Worldspace, ok: bool) {
	editor_id := db.worlds[form] or_return
	v = {
		editor_id = str(editor_id), persistent = db.world_persist[form], water = db.world_water[form],
		location = db.world_location[form], music = db.world_music[form],
	}
	if cells, found := db.world_cells[form]; found {v.cells = forms(cells[:])}
	return v, true
}

@(private)
view_weather :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Weather, ok: bool) {
	w := db.weathers[form] or_return
	v = {info = w.info, fog = w.fog, has_fog = w.has_fog, colors = w.colors, color_rows = w.color_rows, imagespaces = w.imagespaces}
	return v, true
}

@(private)
view_placed_ref :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Placed_Ref, ok: bool) {
	r := db.ref_by_id[form] or_return
	v = {
		form_id = r.form_id, cell_form_id = r.cell_form_id, base = r.base, pos = r.pos, rot = r.rot,
		scale = r.scale, count = r.count, teleport = r.teleport, has_tp = r.has_tp, disabled = r.disabled,
		deleted = r.deleted, persistent = r.persistent, no_respawn = r.no_respawn,
		enable_parent = r.enable_parent, enable_opposite = r.enable_opposite, starts_dead = r.starts_dead,
	}
	return v, true
}

@(private)
view_lock :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Lock, ok: bool) {
	v.lock = db.locks[form] or_return
	return v, true
}

@(private)
view_trigger :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Trigger, ok: bool) {
	v.primitive = db.triggers[form] or_return
	return v, true
}

@(private)
view_linked_refs :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Linked_Refs, ok: bool) {
	links := db.linked_refs[form] or_return
	out := make([]plugin.Linked_Refs_Link, len(links), context.temp_allocator)
	for l, i in links {out[i] = {l.keyword, l.ref}}
	v.links = plugin.span(out)
	return v, true
}

@(private = "file")
form_scripts_prop :: proc(p: esm.Script_Prop) -> plugin.Form_Scripts_Prop {
	out := plugin.Form_Scripts_Prop{name = str(p.name), kind = p.kind, status = p.status}
	switch x in p.value {
	case esm.Prop_Object:   out.object = x
	case string:            out.text = str(x)
	case i32:               out.int_value = x
	case f32:               out.float_value = x
	case bool:              out.bool_value = x
	case []esm.Prop_Object: out.objects = plugin.span(x)
	case []i32:             out.ints = plugin.span(x)
	case []f32:             out.floats = plugin.span(x)
	case []bool:            out.bools = plugin.span(x)
	case []string:
		texts := make([]plugin.Span(u8), len(x), context.temp_allocator)
		for s, i in x {texts[i] = str(s)}
		out.texts = plugin.span(texts)
	}
	return out
}

@(private = "file")
form_scripts_attach :: proc(ss: []esm.Script_Attach) -> plugin.Span(plugin.Form_Scripts_Script) {
	out := make([]plugin.Form_Scripts_Script, len(ss), context.temp_allocator)
	for s, i in ss {
		props := make([]plugin.Form_Scripts_Prop, len(s.props), context.temp_allocator)
		for p, j in s.props {props[j] = form_scripts_prop(p)}
		out[i] = {str(s.name), s.status, plugin.span(props)}
	}
	return plugin.span(out)
}

@(private)
view_form_scripts :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Form_Scripts, ok: bool) {
	fs := db.form_scripts[form] or_return
	fragments := make([]plugin.Form_Scripts_Fragment, len(fs.fragments), context.temp_allocator)
	for f, i in fs.fragments {fragments[i] = {f.index, f.item, str(f.script), str(f.function)}}
	aliases := make([]plugin.Form_Scripts_Alias, len(fs.aliases), context.temp_allocator)
	for a, i in fs.aliases {aliases[i] = {a.owner, form_scripts_attach(a.scripts)}}
	v = {
		scripts = form_scripts_attach(fs.scripts), frag_file = str(fs.frag_file),
		fragments = plugin.span(fragments), aliases = plugin.span(aliases),
	}
	return v, true
}
