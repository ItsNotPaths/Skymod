package ui

// Generic input routing against a laid-out tree: the app translates raw platform events into a
// per-frame Nav intent + cursor state, and route_input turns those into "which focusable is
// focused / which action fired". No knowledge of specific buttons or screens.

// Nav is the per-frame edge-triggered navigation intent (keys pressed this pump, not held).
Nav :: struct {
	up:     bool,
	down:   bool,
	accept: bool,
	back:   bool,
}

// route_input is the generic focus model: mouse hover sets focus; arrows/W-S step over enabled
// focusables; click activates the hovered item; accept activates the focused one. Returns the
// activated action ("" if none) and the (id-based) focus for next frame. BOTH strings borrow `fs`
// (and thus the tree) — the caller must consume them before destroying the tree.
route_input :: proc(
	fs: []Focusable,
	cur_focus: string,
	nav: Nav,
	mx, my: f32,
	click: bool,
) -> (
	activated: string,
	focus: string,
) {
	if len(fs) == 0 {
		return "", ""
	}
	cur := index_of_id(fs, cur_focus)

	hovered := -1
	for f, i in fs {
		if !f.disabled && contains(f.rect, mx, my) {
			hovered = i
		}
	}
	if hovered >= 0 {
		cur = hovered
	}
	if nav.up {
		cur = step_enabled(fs, cur, -1)
	}
	if nav.down {
		cur = step_enabled(fs, cur, +1)
	}
	if cur < 0 || cur >= len(fs) || fs[cur].disabled {
		cur = first_enabled(fs)
	}
	focus = fs[cur].id if cur >= 0 else ""

	if click && hovered >= 0 {
		return fs[hovered].action, focus
	}
	if nav.accept && cur >= 0 && !fs[cur].disabled {
		return fs[cur].action, focus
	}
	return "", focus
}

@(private = "file")
index_of_id :: proc(fs: []Focusable, id: string) -> int {
	if id == "" {
		return -1
	}
	for f, i in fs {
		if f.id == id {
			return i
		}
	}
	return -1
}

// step_enabled moves `dir` from `cur` (wrapping), skipping disabled focusables.
@(private = "file")
step_enabled :: proc(fs: []Focusable, cur, dir: int) -> int {
	n := len(fs)
	if n == 0 {
		return -1
	}
	i := cur if cur >= 0 else (0 if dir > 0 else n - 1)
	for _ in 0 ..< n {
		i = (i + dir + n) % n
		if !fs[i].disabled {
			return i
		}
	}
	return cur
}

@(private = "file")
first_enabled :: proc(fs: []Focusable) -> int {
	for f, i in fs {
		if !f.disabled {
			return i
		}
	}
	return -1
}
