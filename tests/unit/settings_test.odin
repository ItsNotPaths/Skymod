package unit_tests

// Unit tests for the settings.txt store: default backfill, hand-edit parsing, the
// save -> reload round-trip, and the "add missing keys without clobbering values"
// merge that boot (and release.sh) rely on. Hermetic: a temp dir, cleaned up.

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../../src/settings"

@(test)
test_settings_defaults_and_roundtrip :: proc(t: ^testing.T) {
	dir := temp_settings_dir(t, "roundtrip")
	defer os.remove_all(dir)
	defer delete(dir)

	// No file yet: load() backfills every DEFAULTS key (and never writes on its own).
	cfg := settings.load(dir)
	testing.expect(t, settings.get(&cfg, "source_game") == "", "source_game defaults empty")
	testing.expect(t, !settings.get_bool(&cfg, "persist_logs"), "persist_logs defaults false")
	path, _ := filepath.join({dir, settings.FILE_NAME}, context.allocator)
	defer delete(path)
	testing.expect(t, !os.exists(path), "load() does not create the file")

	// Set + save, then reload: the value survives.
	settings.set(&cfg, "source_game", "/games/Skyrim")
	testing.expect(t, settings.save(&cfg), "save succeeds")
	settings.destroy(&cfg)

	again := settings.load(dir)
	defer settings.destroy(&again)
	testing.expect(t, settings.get(&again, "source_game") == "/games/Skyrim", "source_game persisted")
}

@(test)
test_settings_merge_keeps_values :: proc(t: ^testing.T) {
	dir := temp_settings_dir(t, "merge")
	defer os.remove_all(dir)
	defer delete(dir)

	// A hand-written file that has source_game but is MISSING persist_logs, plus a
	// comment and an unknown key. load() must keep the user's value and add the
	// missing default — the same merge release.sh performs.
	path, _ := filepath.join({dir, settings.FILE_NAME}, context.allocator)
	defer delete(path)
	contents := "# my notes\nsource_game = /my/skyrim\ncustom_key = 7\n"
	testing.expect(t, os.write_entire_file(path, transmute([]byte)contents) == nil, "seed file")

	cfg := settings.load(dir)
	defer settings.destroy(&cfg)
	testing.expect(t, settings.get(&cfg, "source_game") == "/my/skyrim", "kept hand-edited value")
	testing.expect(t, settings.get(&cfg, "custom_key") == "7", "kept unknown key")
	testing.expect(t, settings.get(&cfg, "persist_logs") == "false", "backfilled missing default")

	// Saving keeps everything; the file is re-readable.
	testing.expect(t, settings.save(&cfg), "save merged config")
	data, err := os.read_entire_file(path, context.allocator)
	testing.expect(t, err == nil, "reread saved file")
	defer delete(data)
	s := string(data)
	testing.expect(t, strings.contains(s, "source_game = /my/skyrim"), "source line present")
	testing.expect(t, strings.contains(s, "custom_key = 7"), "unknown key survives save")
	testing.expect(t, strings.contains(s, "persist_logs = false"), "default written out")
}

@(test)
test_settings_overlay :: proc(t: ^testing.T) {
	root_dir := temp_settings_dir(t, "overlay_root")
	defer os.remove_all(root_dir)
	defer delete(root_dir)
	child_dir := temp_settings_dir(t, "overlay_child")
	defer os.remove_all(child_dir)
	defer delete(child_dir)

	// Root (vanilla) baseline: render_distance defaults to 3, plus a game path.
	root := settings.load(root_dir)
	defer settings.destroy(&root)
	settings.set(&root, "source_game", "/games/Skyrim")
	testing.expect(t, settings.get(&root, "render_distance") == "3", "root default rd")

	// A profile overlay overrides only render_distance; game path inherits from root.
	child := settings.load_child(child_dir, &root)
	defer settings.destroy(&child)
	testing.expect(t, settings.get(&child, "source_game") == "/games/Skyrim", "inherits root game path")
	testing.expect(t, settings.get(&child, "render_distance") == "3", "inherits root rd before override")

	settings.set(&child, "render_distance", "12")
	testing.expect(t, settings.get(&child, "render_distance") == "12", "override wins")
	testing.expect(t, settings.get(&root, "render_distance") == "3", "root unchanged by child override")

	// root() reaches the baseline from the child, for root-only keys.
	settings.set(settings.root(&child), "active_profile", "modlistB")
	testing.expect(t, settings.get(&root, "active_profile") == "modlistB", "root() targets baseline")

	// Saving the child writes ONLY its own overrides (sparse) — not the inherited keys.
	testing.expect(t, settings.save(&child), "save child")
	path, _ := filepath.join({child_dir, settings.FILE_NAME}, context.allocator)
	defer delete(path)
	data, err := os.read_entire_file(path, context.allocator)
	testing.expect(t, err == nil, "reread child file")
	defer delete(data)
	s := string(data)
	testing.expect(t, strings.contains(s, "render_distance = 12"), "override persisted")
	testing.expect(t, !strings.contains(s, "source_game"), "inherited key NOT written to overlay")
}

// temp_settings_dir makes a fresh, empty dir under the OS temp root, unique per
// `name` so tests running in parallel don't stomp each other. Caller frees the
// returned path and removes the dir.
@(private = "file")
temp_settings_dir :: proc(t: ^testing.T, name: string) -> string {
	base, terr := os.temp_dir(context.allocator)
	testing.expect(t, terr == nil, "temp_dir")
	defer delete(base)
	dir, _ := filepath.join({base, strings.concatenate({"skymod_settings_test_", name}, context.temp_allocator)}, context.allocator)
	os.remove_all(dir) // start clean even if a prior run left it behind
	_ = os.make_directory(dir)
	return dir
}
