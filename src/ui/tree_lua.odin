package ui

// The Lua table → Node walker: turns a declarative Lua table (on a VM stack) into a Node tree.
// VM-agnostic — it only walks a ^lua.State, so the pre-world UI VM (runtime.odin) and, later, the
// gameplay VM's in-world UI reuse it with zero duplication.

import "core:c"
import "core:strconv"
import "core:strings"
import lua "../../vendor/lua"

// parse_node walks the Lua table at absolute stack index `idx` into a Node. The array part is
// children (tables) or, for Text, the [1] string. Properties come from the hash part.
parse_node :: proc(L: ^lua.State, idx: c.int) -> Node {
	n: Node
	n.children = make([dynamic]Node)

	if k, ok := field_str(L, idx, "_kind"); ok {
		n.kind = node_kind(k)
	}
	if a, ok := field_anchor(L, idx, "anchor"); ok {
		n.anchor = a
		n.pivot = a // auto-pivot = anchor
	}
	if pv, ok := field_vec2(L, idx, "pivot"); ok {n.pivot = pv}
	if o, ok := field_vec2(L, idx, "offset"); ok {n.offset = o}
	if s, ok := field_vec2(L, idx, "size"); ok {n.size = s}
	if g, ok := field_num(L, idx, "gap"); ok {n.gap = g}
	if pd, ok := field_num(L, idx, "pad"); ok {n.pad = pd}
	if s, ok := field_num(L, idx, "scale"); ok {n.scale = s}
	if w, ok := field_num(L, idx, "wrap"); ok {n.wrap = w}
	if v, ok := field_num(L, idx, "value"); ok {n.value = v}
	if col, ok := field_color(L, idx, "color"); ok {n.color = col}
	if f, ok := field_str(L, idx, "fill"); ok {
		switch f {
		case "x":
			n.stretch = {true, false}
		case "y":
			n.stretch = {false, true}
		case "both":
			n.stretch = {true, true}
		}
	}
	if s, ok := field_str(L, idx, "id"); ok {n.id = strings.clone(s)}
	if s, ok := field_str(L, idx, "action"); ok {n.action = strings.clone(s)}
	if s, ok := field_str(L, idx, "source"); ok {n.image = strings.clone(s)}
	if s, ok := field_str(L, idx, "align"); ok {n.align = node_align(s)}
	if s, ok := field_str(L, idx, "from"); ok {n.from = node_align(s)}
	if field_bool(L, idx, "modal") {n.modal = true}
	if field_bool(L, idx, "flip_x") {n.flip_x = true}
	if v, ok := field_vec2(L, idx, "crop"); ok {n.crop = v}
	// `slice` = the horizontal 3-slice cap widths (source px): a number → symmetric {n,n}, or {l,r}.
	if s, ok := field_num(L, idx, "slice"); ok {
		n.slice = {s, s}
	} else if v, vok := field_vec2(L, idx, "slice"); vok {
		n.slice = v
	}
	read_enabled(L, idx, &n)

	cnt := int(lua.rawlen(L, idx))
	for i in 0 ..< cnt {
		lua.geti(L, idx, lua.Integer(i))
		ci := lua.gettop(L)
		#partial switch lua.type(L, ci) {
		case .TABLE:
			append(&n.children, parse_node(L, ci))
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
field_str :: proc(L: ^lua.State, idx: c.int, key: cstring) -> (string, bool) {
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

// field_bool reads a boolean field (true only when present and boolean-true).
@(private = "file")
field_bool :: proc(L: ^lua.State, idx: c.int, key: cstring) -> bool {
	lua.getfield(L, idx, key)
	v := lua.type(L, -1) == .BOOLEAN && bool(lua.toboolean(L, -1))
	lua.settop(L, -2)
	return v
}

@(private = "file")
field_num :: proc(L: ^lua.State, idx: c.int, key: cstring) -> (f32, bool) {
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
field_vec2 :: proc(L: ^lua.State, idx: c.int, key: cstring) -> ([2]f32, bool) {
	lua.getfield(L, idx, key)
	out: [2]f32
	ok: bool
	if lua.type(L, -1) == .TABLE {
		ti := lua.gettop(L)
		out[0] = elem_num(L, ti, 0)
		out[1] = elem_num(L, ti, 1)
		ok = true
	}
	lua.settop(L, -2)
	return out, ok
}

@(private = "file")
field_anchor :: proc(L: ^lua.State, idx: c.int, key: cstring) -> ([2]f32, bool) {
	lua.getfield(L, idx, key)
	out: [2]f32
	ok: bool
	#partial switch lua.type(L, -1) {
	case .STRING:
		out = anchor_point(string(lua.tolstring(L, -1, nil)))
		ok = true
	case .TABLE:
		ti := lua.gettop(L)
		out[0] = elem_num(L, ti, 0)
		out[1] = elem_num(L, ti, 1)
		ok = true
	}
	lua.settop(L, -2)
	return out, ok
}

@(private = "file")
field_color :: proc(L: ^lua.State, idx: c.int, key: cstring) -> (Color, bool) {
	lua.getfield(L, idx, key)
	out: Color
	ok: bool
	#partial switch lua.type(L, -1) {
	case .STRING:
		out = hex_color(string(lua.tolstring(L, -1, nil)))
		ok = true
	case .TABLE:
		ti := lua.gettop(L)
		out[3] = 1 // default opaque so a 3-element {r,g,b} table stays visible (alpha optional)
		cnt := min(int(lua.rawlen(L, ti)), 4)
		for i in 0 ..< cnt {
			out[i] = elem_num(L, ti, c.int(i))
		}
		ok = true
	}
	lua.settop(L, -2)
	return out, ok
}

// elem_num reads numeric array element n of the table at absolute index `ti` (0 if absent).
@(private = "file")
elem_num :: proc(L: ^lua.State, ti: c.int, n: c.int) -> f32 {
	lua.geti(L, ti, lua.Integer(n))
	v: f32
	if lua.type(L, -1) == .NUMBER {
		v = f32(lua.tonumber(L, -1))
	}
	lua.settop(L, -2)
	return v
}

@(private = "file")
node_align :: proc(s: string) -> Align {
	switch s {
	case "center":
		return .Center
	case "right", "bottom", "end":
		return .End
	}
	return .Start
}

// read_enabled interprets a node's `enabled` property: a bind marker `{ _bind = "path" }` is
// stored as the node's bind path (resolved per-frame by the app); a literal `false` disables it
// immediately. Absent / `true` leaves the node enabled.
@(private = "file")
read_enabled :: proc(L: ^lua.State, idx: c.int, n: ^Node) {
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
node_kind :: proc(s: string) -> Kind {
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
	case "bar":
		return .Bar
	}
	return .Container
}

@(private = "file")
anchor_point :: proc(name: string) -> [2]f32 {
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
hex_color :: proc(s: string) -> Color {
	h := s
	if len(h) > 0 && h[0] == '#' {
		h = h[1:]
	}
	out := Color{1, 1, 1, 1}
	if len(h) >= 6 {
		out[0] = hex_byte(h[0:2])
		out[1] = hex_byte(h[2:4])
		out[2] = hex_byte(h[4:6])
		out[3] = hex_byte(h[6:8]) if len(h) >= 8 else 1
	}
	return out
}

@(private = "file")
hex_byte :: proc(s: string) -> f32 {
	v, _ := strconv.parse_int(s, 16)
	return f32(v) / 255.0
}
