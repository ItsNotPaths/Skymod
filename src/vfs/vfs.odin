package vfs

// Virtual filesystem (ROADMAP Iteration 1, Milestone A): mount multiple BSAs + the
// loose-files folder with Skyrim's override precedence (loose > later archive >
// earlier), and resolve a Bethesda asset path -> bytes. The VFS is the path
// authority: it normalizes every path and owns the lookup index; `formats/bsa` is
// a dumb reader underneath.

import "core:os"
import "core:path/filepath"
import "core:strings"
import "../formats/bsa"

// Location points at one archive entry (which archive, which file in it).
Location :: struct {
	archive: int,
	entry:   int,
}

VFS :: struct {
	archives:    [dynamic]bsa.Archive,
	loose_roots: [dynamic]string,     // searched before archives (loose wins)
	index:       map[string]Location, // normalized path -> archive location
}

// mount_loose adds a loose-files root (e.g. "<Skyrim>/Data"). Loose files take
// precedence over everything in the archives. `root` is cloned.
mount_loose :: proc(v: ^VFS, root: string) {
	append(&v.loose_roots, strings.clone(root))
}

// mount_archive opens a BSA and folds its entries into the index. Mount in load
// order: a later mount overrides an earlier one for the same path.
mount_archive :: proc(v: ^VFS, path: string) -> bool {
	arc, ok := bsa.open(path)
	if !ok {
		return false
	}
	ai := len(v.archives)
	append(&v.archives, arc)

	for e, ei in arc.entries {
		key := normalize_path(e.path) // heap-owned candidate key
		if _, found := v.index[key]; found {
			v.index[key] = Location{ai, ei} // override; map keeps its existing key
			delete(key) // drop the duplicate we just made
		} else {
			v.index[key] = Location{ai, ei} // map now references key's bytes
		}
	}
	return true
}

// read resolves `path` to its bytes — loose files first, then archives (later
// mounts win). The result is freshly allocated in `allocator`; the caller owns it.
read :: proc(v: ^VFS, path: string, allocator := context.allocator) -> (data: []u8, ok: bool) {
	// Loose files win. Try reading each root's candidate directly (one syscall) rather
	// than stat-then-read; a miss falls through to the archives.
	if len(v.loose_roots) > 0 {
		rel, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
		for root in v.loose_roots {
			candidate, _ := filepath.join({root, rel}, context.temp_allocator)
			if d, err := os.read_entire_file(candidate, allocator); err == nil {
				return d, true
			}
		}
	}
	key := normalize_path(path, context.temp_allocator)
	if loc, found := v.index[key]; found {
		arc := &v.archives[loc.archive]
		return bsa.extract(arc, arc.entries[loc.entry], allocator)
	}
	return nil, false
}

// exists reports whether `path` resolves in any mount.
exists :: proc(v: ^VFS, path: string) -> bool {
	if _, found := loose_path(v, path); found {
		return true
	}
	key := normalize_path(path, context.temp_allocator)
	_, found := v.index[key]
	return found
}

destroy :: proc(v: ^VFS) {
	for &arc in v.archives {
		bsa.close(&arc)
	}
	delete(v.archives)
	for root in v.loose_roots {
		delete(root)
	}
	delete(v.loose_roots)
	for key, _ in v.index {
		delete(key)
	}
	delete(v.index)
	v^ = {}
}

// loose_path returns the on-disk path if `path` exists under any loose root. The
// returned string is in the temp allocator. Bethesda paths use backslashes; we
// swap to forward slashes for the host filesystem.
@(private)
loose_path :: proc(v: ^VFS, path: string) -> (full: string, ok: bool) {
	if len(v.loose_roots) == 0 {
		return "", false
	}
	rel, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	for root in v.loose_roots {
		candidate, _ := filepath.join({root, rel}, context.temp_allocator)
		if os.exists(candidate) {
			return candidate, true
		}
	}
	return "", false
}

// normalize_path canonicalizes a Bethesda-style asset path for case- and
// separator-insensitive lookup (ROADMAP 1a, step 3): backslashes -> forward
// slashes, ASCII-lowercased, leading/trailing slashes trimmed. Internal "//" runs
// are left intact — Bethesda lookups key on the literal (normalized) string.
// The returned string is freshly allocated; the caller owns it.
normalize_path :: proc(path: string, allocator := context.allocator) -> string {
	// Scratch the transform in temp; the single persistent allocation is the trimmed clone.
	b := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&b)
	for r in path {
		switch r {
		case '\\':
			strings.write_rune(&b, '/')
		case 'A' ..= 'Z':
			strings.write_rune(&b, r + ('a' - 'A'))
		case:
			strings.write_rune(&b, r)
		}
	}
	return strings.clone(strings.trim(strings.to_string(b), "/"), allocator)
}
