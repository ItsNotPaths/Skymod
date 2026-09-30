package swf

// Where each named instance sits on the stage (root first frame), in stage px. A sprite with frame
// labels also gives the box of its animated children at each label: for a meter, the fill at "Full"
// and at "Empty".

import "core:slice"
import "core:strings"

Layout_Entry :: struct {
	path:   string, // dotted instance names from the root
	rect:   Rect,
	moving: []Label_Rect,
}

Label_Rect :: struct {
	label: string,
	rect:  Rect,
}

layout :: proc(mv: ^Movie, allocator := context.allocator) -> []Layout_Entry {
	out := make([dynamic]Layout_Entry, allocator)
	layout_walk(mv, mv.root, "", IDENTITY, &out, allocator)
	return out[:]
}

@(private)
layout_walk :: proc(mv: ^Movie, s: Sprite, prefix: string, m: Matrix, out: ^[dynamic]Layout_Entry, allocator: Allocator) {
	for p in frame_list(s, "") {
		if p.name == "" {continue}
		path := p.name if prefix == "" else strings.concatenate({prefix, ".", p.name}, allocator)
		pm := mat_mul(m, p.mat)
		e := Layout_Entry{path = path, rect = to_px(bounds(mv, p.id, "", pm))}
		sp, is_sprite := mv.chars[p.id].(Sprite)
		if is_sprite {e.moving = moving(mv, sp, pm, allocator)}
		append(out, e)
		if is_sprite {layout_walk(mv, sp, path, pm, out, allocator)}
	}
}

// moving is, per label, the box of the children whose placement changes across the sprite's frames.
@(private)
moving :: proc(mv: ^Movie, s: Sprite, m: Matrix, allocator: Allocator) -> []Label_Rect {
	if len(s.labels) == 0 {return nil}
	varies := make(map[u16]bool, allocator = context.temp_allocator)
	first := make(map[u16]Place, allocator = context.temp_allocator)
	for f in s.frames {
		for p in f {
			if q, seen := first[p.depth]; !seen {
				first[p.depth] = p
			} else if q.id != p.id || q.mat != p.mat {
				varies[p.depth] = true
			}
		}
	}
	for f in s.frames { // a child missing from some frame comes and goes
		for depth in first {
			found := false
			for p in f {if p.depth == depth {found = true;break}}
			if !found {varies[depth] = true}
		}
	}
	if len(varies) == 0 {return nil}
	out := make([dynamic]Label_Rect, allocator)
	for label, frame in s.labels {
		r := EMPTY_RECT
		for p in s.frames[clamp(frame, 0, len(s.frames) - 1)] {
			if varies[p.depth] && p.clip == 0 {r = rect_union(r, bounds(mv, p.id, label, mat_mul(m, p.mat)))}
		}
		append(&out, Label_Rect{label, to_px(r)})
	}
	slice.sort_by(out[:], proc(a, b: Label_Rect) -> bool {return a.label < b.label})
	return out[:]
}

@(private)
to_px :: proc(r: Rect) -> Rect {
	return {r.x0 / 20, r.y0 / 20, r.x1 / 20, r.y1 / 20} if !rect_empty(r) else r
}
