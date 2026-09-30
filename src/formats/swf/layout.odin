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
	at:     []Label_Rect, // where the instance itself sits at each label of its parent (the parent moves it)
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
		e := Layout_Entry{path = path, rect = to_px(bounds(mv, p.id, "", pm)), at = at_labels(mv, s, p, m, allocator)}
		sp, is_sprite := mv.chars[p.id].(Sprite)
		if is_sprite {e.moving = moving(mv, sp, pm, allocator)}
		append(out, e)
		if is_sprite {layout_walk(mv, sp, path, pm, out, allocator)}
	}
}

// at_labels is, per label of the parent `s`, the box of the child named like `p` at that frame.
@(private)
at_labels :: proc(mv: ^Movie, s: Sprite, p: Place, m: Matrix, allocator: Allocator) -> []Label_Rect {
	if len(s.labels) == 0 {return nil}
	out := make([dynamic]Label_Rect, allocator)
	for label in s.labels {
		for q in frame_list(s, label) {
			if q.name == p.name {append(&out, Label_Rect{label, to_px(bounds(mv, q.id, "", mat_mul(m, q.mat)))})}
		}
	}
	slice.sort_by(out[:], proc(a, b: Label_Rect) -> bool {return a.label < b.label})
	return out[:]
}

// moving is, per label, the box of the children whose placement changes across the sprite's frames:
// a fill that slides or scales, or the clip layer that scales over a still fill.
@(private)
moving :: proc(mv: ^Movie, s: Sprite, m: Matrix, allocator: Allocator) -> []Label_Rect {
	if len(s.labels) == 0 {return nil}
	varies := varying_depths(s)
	if len(varies) == 0 {return nil}
	out := make([dynamic]Label_Rect, allocator)
	for label, frame in s.labels {
		r := EMPTY_RECT
		clip, until := Rect{}, u16(0)
		for p in s.frames[clamp(frame, 0, len(s.frames) - 1)] {
			b := bounds(mv, p.id, label, mat_mul(m, p.mat))
			if p.clip != 0 {
				clip, until = b, p.clip
				if varies[p.depth] {r = rect_union(r, b)} // a scaling clip layer's box is what it shows
				continue
			}
			if !varies[p.depth] {continue}
			if p.depth <= until {b = rect_intersect(b, clip)} // a fill sliding under a still mask
			r = rect_union(r, b)
		}
		append(&out, Label_Rect{label, to_px(r)})
	}
	slice.sort_by(out[:], proc(a, b: Label_Rect) -> bool {return a.label < b.label})
	return out[:]
}

// varying_depths is the depths whose child changes across a sprite's frames: another character or
// another matrix. A child that only leaves (the enemy bar at "Empty") does not count.
varying_depths :: proc(s: Sprite) -> map[u16]bool {
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
	return varies
}

// still_skip is what to leave out to draw only the part of a sprite that never moves: the varying
// depths, and every depth an animated clip layer masks.
still_skip :: proc(s: Sprite) -> map[u16]bool {
	skip := varying_depths(s)
	for f in s.frames {
		for p in f {
			if p.clip == 0 || !skip[p.depth] {continue}
			for g in s.frames {
				for q in g {if q.depth > p.depth && q.depth <= p.clip {skip[q.depth] = true}}
			}
		}
	}
	return skip
}

@(private)
to_px :: proc(r: Rect) -> Rect {
	return {r.x0 / 20, r.y0 / 20, r.x1 / 20, r.y1 / 20} if !rect_empty(r) else r
}
