package main

// The UI loader: the table→node walker + file-source resolution shared by the substrate. It turns a
// Lua declarative table (on the VM stack) into a ui.Node tree, and resolves a UI file from
// content/baseui/lua (disk) with an #load-embedded fallback. The persistent VM + interaction runtime
// that drive these per frame live in ui_vm.odin; the imgui --uitest fallback in ui_backend.odin.

import "core:c"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import lua "vendor:lua/5.4"
import "../ui"

@(private = "file")
UI_PRELUDE :: #load("../ui/lua/lib/ui.lua", string)
@(private = "file")
UI_BUTTON :: #load("../ui/lua/widget/button.lua", string)
@(private = "file")
UI_BOX :: #load("../ui/lua/widget/box.lua", string)
@(private = "file")
MAIN_MENU :: #load("../ui/lua/main_menu.lua", string)

// UI_FRAMEWORK is the framework files (relative paths under the UI root) run before any screen, in
// order — they install the constructor globals (container/text/button/box/…). They live both
// #load-embedded (regenerated into content/baseui/lua/ every boot — the synthesized built-in UI mod,
// where a deep mod can override one file). See ui_embedded for the embedded fallback bytes.
@(private)
UI_FRAMEWORK := [?]string{"lib/ui.lua", "widget/button.lua", "widget/box.lua"}

// ui_embedded returns the #load-embedded bytes for a built-in UI file (relative to the UI lua root),
// used as the fallback when content/baseui/ has no copy on disk. Keeps the engine bootable with no
// install (the imgui menu is the final fallback if even this fails).
ui_embedded :: proc(rel: string) -> (string, bool) {
	switch rel {
	case "lib/ui.lua":
		return UI_PRELUDE, true
	case "widget/button.lua":
		return UI_BUTTON, true
	case "widget/box.lua":
		return UI_BOX, true
	case "main_menu.lua":
		return MAIN_MENU, true
	}
	return "", false
}

// ui_source reads a UI lua file from `dir` (disk), falling back to the embedded copy. The returned
// string is temp-allocated (valid for the load) when read from disk, or the embedded literal.
@(private)
ui_source :: proc(dir: string, rel: string) -> (string, bool) {
	if dir != "" {
		path, _ := filepath.join({dir, rel}, context.temp_allocator)
		if data, err := os.read_entire_file(path, context.temp_allocator); err == nil && len(data) > 0 {
			return string(data), true
		}
	}
	return ui_embedded(rel)
}

@(private)
ui_run_chunk :: proc(L: ^lua.State, code: string, name: string) -> bool {
	cs := strings.clone_to_cstring(code, context.temp_allocator)
	if lua.L_dostring(L, cs) != 0 {
		log.errorf("ui: %s: %s", name, ui_lua_str(L, -1))
		lua.settop(L, -2)
		return false
	}
	return true
}

// ui_parse_node walks the Lua table at absolute stack index `idx` into a ui.Node. The array part is
// children (tables) or, for Text, the [1] string. Properties come from the hash part.
@(private)
ui_parse_node :: proc(L: ^lua.State, idx: c.int) -> ui.Node {
	n: ui.Node
	n.children = make([dynamic]ui.Node)

	if k, ok := ui_field_str(L, idx, "_kind"); ok {
		n.kind = ui_kind(k)
	}
	if a, ok := ui_field_anchor(L, idx, "anchor"); ok {
		n.anchor = a
		n.pivot = a // auto-pivot = anchor
	}
	if pv, ok := ui_field_vec2(L, idx, "pivot"); ok {n.pivot = pv}
	if o, ok := ui_field_vec2(L, idx, "offset"); ok {n.offset = o}
	if s, ok := ui_field_vec2(L, idx, "size"); ok {n.size = s}
	if g, ok := ui_field_num(L, idx, "gap"); ok {n.gap = g}
	if pd, ok := ui_field_num(L, idx, "pad"); ok {n.pad = pd}
	if s, ok := ui_field_num(L, idx, "scale"); ok {n.scale = s}
	if w, ok := ui_field_num(L, idx, "wrap"); ok {n.wrap = w}
	if col, ok := ui_field_color(L, idx, "color"); ok {n.color = col}
	if f, ok := ui_field_str(L, idx, "fill"); ok {
		switch f {
		case "x":
			n.stretch = {true, false}
		case "y":
			n.stretch = {false, true}
		case "both":
			n.stretch = {true, true}
		}
	}
	if s, ok := ui_field_str(L, idx, "id"); ok {n.id = strings.clone(s)}
	if s, ok := ui_field_str(L, idx, "action"); ok {n.action = strings.clone(s)}
	if s, ok := ui_field_str(L, idx, "source"); ok {n.image = strings.clone(s)}
	if s, ok := ui_field_str(L, idx, "align"); ok {n.align = ui_align(s)}
	if ui_field_bool(L, idx, "modal") {n.modal = true}
	ui_read_enabled(L, idx, &n)

	cnt := int(lua.rawlen(L, idx))
	for i in 1 ..= cnt {
		lua.geti(L, idx, lua.Integer(i))
		ci := lua.gettop(L)
		#partial switch lua.type(L, ci) {
		case .TABLE:
			append(&n.children, ui_parse_node(L, ci))
		case .STRING:
			if n.kind == .Text && len(n.text) == 0 {
				n.text = strings.clone(string(lua.tolstring(L, ci, nil)))
			}
		}
		lua.settop(L, ci - 1) // pop the element
	}
	return n
}

// ── field readers (each pushes the field, reads, pops; net stack-neutral) ─────────────────────

@(private = "file")
ui_field_str :: proc(L: ^lua.State, idx: c.int, key: cstring) -> (string, bool) {
	lua.getfield(L, idx, key)
	out: string
	ok: bool
	if lua.type(L, -1) == .STRING {
		// Cloned into temp (survives the pop below) — used for immediate interpretation only.
		out = strings.clone(string(lua.tolstring(L, -1, nil)), context.temp_allocator)
		ok = true
	}
	lua.settop(L, -2)
	return out, ok
}

// ui_field_bool reads a boolean field (true only when present and boolean-true).
@(private = "file")
ui_field_bool :: proc(L: ^lua.State, idx: c.int, key: cstring) -> bool {
	lua.getfield(L, idx, key)
	v := lua.type(L, -1) == .BOOLEAN && bool(lua.toboolean(L, -1))
	lua.settop(L, -2)
	return v
}

@(private = "file")
ui_field_num :: proc(L: ^lua.State, idx: c.int, key: cstring) -> (f32, bool) {
	lua.getfield(L, idx, key)
	out: f32
	ok: bool
	if lua.type(L, -1) == .NUMBER {
		out = f32(lua.tonumber(L, -1))
		ok = true
	}
	lua.settop(L, -2)
	return out, ok
}

@(private = "file")
ui_field_vec2 :: proc(L: ^lua.State, idx: c.int, key: cstring) -> ([2]f32, bool) {
	lua.getfield(L, idx, key)
	out: [2]f32
	ok: bool
	if lua.type(L, -1) == .TABLE {
		ti := lua.gettop(L)
		out[0] = ui_elem_num(L, ti, 1)
		out[1] = ui_elem_num(L, ti, 2)
		ok = true
	}
	lua.settop(L, -2)
	return out, ok
}

@(private = "file")
ui_field_anchor :: proc(L: ^lua.State, idx: c.int, key: cstring) -> ([2]f32, bool) {
	lua.getfield(L, idx, key)
	out: [2]f32
	ok: bool
	#partial switch lua.type(L, -1) {
	case .STRING:
		out = ui_anchor_point(string(lua.tolstring(L, -1, nil)))
		ok = true
	case .TABLE:
		ti := lua.gettop(L)
		out[0] = ui_elem_num(L, ti, 1)
		out[1] = ui_elem_num(L, ti, 2)
		ok = true
	}
	lua.settop(L, -2)
	return out, ok
}

@(private = "file")
ui_field_color :: proc(L: ^lua.State, idx: c.int, key: cstring) -> (ui.Color, bool) {
	lua.getfield(L, idx, key)
	out: ui.Color
	ok: bool
	#partial switch lua.type(L, -1) {
	case .STRING:
		out = ui_hex_color(string(lua.tolstring(L, -1, nil)))
		ok = true
	case .TABLE:
		ti := lua.gettop(L)
		out[3] = 1 // default opaque so a 3-element {r,g,b} table stays visible (alpha optional)
		cnt := min(int(lua.rawlen(L, ti)), 4)
		for i in 0 ..< cnt {
			out[i] = ui_elem_num(L, ti, c.int(i + 1))
		}
		ok = true
	}
	lua.settop(L, -2)
	return out, ok
}

// ui_elem_num reads numeric array element n of the table at absolute index `ti` (0 if absent).
@(private = "file")
ui_elem_num :: proc(L: ^lua.State, ti: c.int, n: c.int) -> f32 {
	lua.geti(L, ti, lua.Integer(n))
	v: f32
	if lua.type(L, -1) == .NUMBER {
		v = f32(lua.tonumber(L, -1))
	}
	lua.settop(L, -2)
	return v
}

@(private = "file")
ui_align :: proc(s: string) -> ui.Align {
	switch s {
	case "center":
		return .Center
	case "right", "bottom", "end":
		return .End
	}
	return .Start
}

// ui_read_enabled interprets a node's `enabled` property: a bind marker `{ _bind = "path" }` is
// stored as the node's bind path (resolved per-frame by the app); a literal `false` disables it
// immediately. Absent / `true` leaves the node enabled.
@(private = "file")
ui_read_enabled :: proc(L: ^lua.State, idx: c.int, n: ^ui.Node) {
	lua.getfield(L, idx, "enabled")
	#partial switch lua.type(L, -1) {
	case .TABLE:
		lua.getfield(L, -1, "_bind")
		if lua.type(L, -1) == .STRING {
			n.bind = strings.clone(string(lua.tolstring(L, -1, nil)))
		}
		lua.settop(L, -2)
	case .BOOLEAN:
		if !lua.toboolean(L, -1) {
			n.disabled = true
		}
	}
	lua.settop(L, -2)
}

@(private = "file")
ui_kind :: proc(s: string) -> ui.Kind {
	switch s {
	case "column":
		return .Column
	case "row":
		return .Row
	case "rect":
		return .Rect
	case "text":
		return .Text
	case "image":
		return .Image
	case "effect":
		return .Effect
	}
	return .Container
}

@(private = "file")
ui_anchor_point :: proc(name: string) -> [2]f32 {
	switch name {
	case "top_left":
		return {0, 0}
	case "top":
		return {0.5, 0}
	case "top_right":
		return {1, 0}
	case "left":
		return {0, 0.5}
	case "center":
		return {0.5, 0.5}
	case "right":
		return {1, 0.5}
	case "bottom_left":
		return {0, 1}
	case "bottom":
		return {0.5, 1}
	case "bottom_right":
		return {1, 1}
	}
	return {0, 0}
}

@(private = "file")
ui_hex_color :: proc(s: string) -> ui.Color {
	h := s
	if len(h) > 0 && h[0] == '#' {
		h = h[1:]
	}
	out := ui.Color{1, 1, 1, 1}
	if len(h) >= 6 {
		out[0] = ui_hex_byte(h[0:2])
		out[1] = ui_hex_byte(h[2:4])
		out[2] = ui_hex_byte(h[4:6])
		out[3] = ui_hex_byte(h[6:8]) if len(h) >= 8 else 1
	}
	return out
}

@(private = "file")
ui_hex_byte :: proc(s: string) -> f32 {
	v, _ := strconv.parse_int(s, 16)
	return f32(v) / 255.0
}

@(private)
ui_lua_str :: proc(L: ^lua.State, idx: c.int) -> string {
	s := lua.tolstring(L, idx, nil)
	return string(s) if s != nil else ""
}
