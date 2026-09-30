package mods

// The mod profile (mydocs/mods.md layer 4) — the MO2-style mod layer. A profile is an ORDERED
// list of mods (top → bottom = priority; lower entries override higher), where each item is a
// real mod (a folder under mods/), a user-created empty mod, or a named separator. Enabling a
// mod = it's checked in the list. The plugin (load) order is DERIVED from this mod order (see
// task #6) with a sparse, explicit divergence overlay — never an independent second list.
//
// This file is the data model + persistence only (no filesystem scanning of mod contents, no
// VFS) so it's unit-testable in isolation. modlist.txt format (order = priority, top→bottom):
//   # comment
//   :Separator Label        ← a separator
//   +SomeMod                ← enabled mod
//   -DisabledMod            ← present but disabled
// The base game is implicit (a locked entry the profile guarantees at the top) and not written.

import "base:runtime"
import "core:log"
import "core:os"
import "core:strings"

// BASE_MOD is the implicit, always-on, locked entry representing the vanilla base game (Skyrim.esm +
// its BSAs). It's the first of the "system" rows (see profile_set_system) — DLCs and the forced UI
// baseline sit below it, also locked. Pinned at the top, never persisted, never a mods/ folder (the
// mount/load code provides vanilla from Data directly). Displayed as just "Skyrim".
BASE_MOD :: "Skyrim"

Mod_Kind :: enum {
	Mod,       // a folder under mods/ (or the locked base game)
	Separator, // a named organizational divider; no enable/plugins
}

Mod :: struct {
	name:    string, // owned: folder name (Mod) or label (Separator)
	kind:    Mod_Kind,
	enabled: bool,
	locked:  bool, // the base game: can't be disabled, removed, or moved off the top
}

Profile :: struct {
	mods:      [dynamic]Mod, // ordered top → bottom
	allocator: runtime.Allocator,
}

profile_init :: proc(p: ^Profile, allocator := context.allocator) {
	p.allocator = allocator
	p.mods = make([dynamic]Mod, allocator)
}

profile_destroy :: proc(p: ^Profile) {
	for m in p.mods {delete(m.name, p.allocator)}
	delete(p.mods)
}

// profile_index returns the index of the mod named `name` (case-insensitive, Mod kind only), or
// -1 if absent.
profile_index :: proc(p: ^Profile, name: string) -> int {
	for m, i in p.mods {
		if m.kind == .Mod && strings.equal_fold(m.name, name) {return i}
	}
	return -1
}

// profile_add appends a mod (a folder name). No-op if it already exists.
profile_add :: proc(p: ^Profile, name: string, enabled := true) {
	if profile_index(p, name) >= 0 {return}
	append(&p.mods, Mod{name = strings.clone(name, p.allocator), kind = .Mod, enabled = enabled})
}

// profile_add_separator appends a named separator (always allowed; labels needn't be unique).
profile_add_separator :: proc(p: ^Profile, label: string) {
	append(&p.mods, Mod{name = strings.clone(label, p.allocator), kind = .Separator})
}

// profile_remove deletes item i (no-op on the locked base). Separators and disabled mods are
// removable; removing a mod here only drops it from the list — the folder is the caller's call.
profile_remove :: proc(p: ^Profile, i: int) {
	if i < 0 || i >= len(p.mods) || p.mods[i].locked {return}
	delete(p.mods[i].name, p.allocator)
	ordered_remove(&p.mods, i)
}

// profile_toggle flips a mod's enabled flag (no-op on the locked base or a separator).
profile_toggle :: proc(p: ^Profile, i: int) {
	if i < 0 || i >= len(p.mods) {return}
	m := &p.mods[i]
	if m.locked || m.kind == .Separator {return}
	m.enabled = !m.enabled
}

// profile_move shifts item i by `dir` (±1), swapping with its neighbour. The base stays pinned at
// the top: index 0 never moves and nothing slides above it.
profile_move :: proc(p: ^Profile, i, dir: int) {
	j := i + dir
	if i <= 0 || j <= 0 || i >= len(p.mods) || j >= len(p.mods) {return}
	p.mods[i], p.mods[j] = p.mods[j], p.mods[i]
}

// profile_move_to moves item `from` to sit at index `to` (drag-reorder), shifting the rest. The
// locked system rows stay pinned at the top: a locked source is refused and the destination is
// clamped to at/after the first non-locked row, so nothing lands above the base/DLC/UI prefix. No-op
// on out-of-range or a no-move.
profile_move_to :: proc(p: ^Profile, from, to: int) {
	if from < 0 || from >= len(p.mods) || p.mods[from].locked {return}
	lo := 0
	for lo < len(p.mods) && p.mods[lo].locked {lo += 1} // first movable slot (below the locked prefix)
	dst := clamp(to, lo, len(p.mods) - 1)
	if dst == from {return}
	m := p.mods[from]
	ordered_remove(&p.mods, from)
	// dst now indexes the post-removal array: dragging UP (dst < from) inserts before the target
	// row, dragging DOWN (dst > from) inserts after it (the removal shifted the target down one).
	dst = clamp(dst, lo, len(p.mods)) // len == append at the end
	inject_at(&p.mods, dst, m)
}

// profile_enabled_mods returns the names of enabled USER mods (Mod kind, not locked) in priority
// order — the ones the VFS/plugin loader treats as mods/ folders. Locked "system" rows (base game,
// DLCs, the UI baseline) are EXCLUDED: vanilla/DLC come from Data and the UI from content/, provided
// by the loader directly, not as mods/ folders. Slice allocated in `allocator`; names borrowed.
profile_enabled_mods :: proc(p: ^Profile, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, len(p.mods), allocator)
	for m in p.mods {
		if m.kind == .Mod && m.enabled && !m.locked {append(&out, m.name)}
	}
	return out[:]
}

// profile_set_system makes `names` the locked, enabled, top-of-list "system" rows (the vanilla base,
// each installed DLC, then the forced UI baseline) in the given order, replacing any previous locked
// rows; user mods + separators keep their order below. The APP supplies the list — which DLCs/UI are
// present is filesystem knowledge this pure data model doesn't have — and calls this after
// profile_reconcile. Idempotent (safe every launch). These rows are display + ordering only; they're
// never persisted (profile_save skips locked) and never mounted as folders (profile_enabled_mods
// skips locked).
profile_set_system :: proc(p: ^Profile, names: []string) {
	// Peel off the current locked rows (freeing their names); keep the user tail in order.
	tail := make([dynamic]Mod, 0, len(p.mods), p.allocator)
	for m in p.mods {
		if m.locked {
			delete(m.name, p.allocator)
		} else {
			append(&tail, m) // move: the name pointer transfers to the rebuilt list
		}
	}
	delete(p.mods)
	p.mods = make([dynamic]Mod, 0, len(names) + len(tail), p.allocator)
	for n in names {
		append(&p.mods, Mod{name = strings.clone(n, p.allocator), kind = .Mod, enabled = true, locked = true})
	}
	append(&p.mods, ..tail[:])
	delete(tail)
}

// profile_reconcile aligns the profile with the mod folders actually under mods/: drops mod
// entries whose folder is gone (keeping separators), appends newly-discovered folders (enabled),
// and guarantees the locked base entry sits at the top.
profile_reconcile :: proc(p: ^Profile, discovered: []string) {
	keep := make([dynamic]Mod, 0, len(p.mods), p.allocator)
	for m in p.mods {
		if m.kind == .Separator || m.locked || name_in(discovered, m.name) {
			append(&keep, m)
		} else {
			delete(m.name, p.allocator)
		}
	}
	delete(p.mods)
	p.mods = keep

	ensure_base(p)

	for d in discovered {
		if profile_index(p, d) < 0 {
			append(&p.mods, Mod{name = strings.clone(d, p.allocator), kind = .Mod, enabled = true})
		}
	}
}

// profile_load reads modlist.txt into `p` (already profile_init'd). Missing file → false (caller
// then reconciles). Lines: ':' separator, '+'/'-' enabled/disabled mod; blanks and '#' ignored.
profile_load :: proc(p: ^Profile, path: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return false}
	it := string(data)
	for raw in strings.split_lines_iterator(&it) {
		s := strings.trim_space(raw)
		if s == "" || s[0] == '#' {continue}
		switch s[0] {
		case ':':
			label := strings.trim_space(s[1:])
			if label != "" {profile_add_separator(p, label)}
		case '+', '-':
			name := strings.trim_space(s[1:])
			if name != "" && profile_index(p, name) < 0 {
				append(
					&p.mods,
					Mod{name = strings.clone(name, p.allocator), kind = .Mod, enabled = s[0] == '+'},
				)
			}
		}
	}
	return true
}

// profile_save writes the user mods + separators to modlist.txt (the locked base is implicit and
// skipped). Returns false (and logs) on a write error.
profile_save :: proc(p: ^Profile, path: string) -> bool {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "# SkyMod mod list — order = priority (top → bottom; lower overrides).\n")
	for m in p.mods {
		if m.locked {continue} // base game is implicit
		switch m.kind {
		case .Separator:
			strings.write_byte(&b, ':')
			strings.write_string(&b, m.name)
		case .Mod:
			strings.write_byte(&b, '+' if m.enabled else '-')
			strings.write_string(&b, m.name)
		}
		strings.write_byte(&b, '\n')
	}
	if os.write_entire_file(path, transmute([]byte)strings.to_string(b)) != nil {
		log.errorf("mods: failed to write %s", path)
		return false
	}
	return true
}

// ensure_base guarantees the locked base entry exists, is enabled, and is at index 0.
@(private)
ensure_base :: proc(p: ^Profile) {
	for &m, i in p.mods {
		if m.locked {
			m.enabled = true
			if i != 0 {
				base := p.mods[i]
				ordered_remove(&p.mods, i)
				inject_at(&p.mods, 0, base)
			}
			return
		}
	}
	inject_at(&p.mods, 0, Mod{name = strings.clone(BASE_MOD, p.allocator), kind = .Mod, enabled = true, locked = true})
}

@(private)
name_in :: proc(names: []string, name: string) -> bool {
	for n in names {
		if strings.equal_fold(n, name) {return true}
	}
	return false
}
