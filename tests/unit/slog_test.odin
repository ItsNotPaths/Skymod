package unit_tests

// Unit test for the runtime "persist this run's log" path (slog.persist_run),
// which backs the dev-UI button. Hermetic: writes into a temp dir, cleaned up
// after. The test runner's memory tracking also confirms slog frees cleanly.

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import slog "../../src/log"

@(test)
test_persist_run :: proc(t: ^testing.T) {
	// Hermetic temp dir for the log files.
	base, terr := os.temp_dir(context.allocator)
	testing.expect(t, terr == nil, "temp_dir")
	defer delete(base)
	dir, _ := filepath.join({base, "skymod_slog_test"}, context.allocator)
	defer delete(dir)
	_ = os.make_directory(dir)
	defer os.remove_all(dir)

	old_logger := context.logger

	// Default mode: a single skymod.log, not yet persisting.
	lg := slog.init(dir, false)
	context.logger = lg.logger
	testing.expect(t, !lg.persisting, "starts not persisting")

	log.info("PRE_PERSIST_LINE")

	testing.expect(t, slog.persist_run(&lg), "persist_run succeeds")
	testing.expect(t, lg.persisting, "now persisting")
	context.logger = lg.logger // persist_run added a sink
	testing.expect(t, !slog.persist_run(&lg), "second persist_run is a no-op")

	log.info("POST_PERSIST_LINE")

	// Read both files (content is on disk — the file loggers write unbuffered).
	primary_path, _ := filepath.join({dir, "skymod.log"}, context.allocator)
	defer delete(primary_path)
	primary, perr := os.read_entire_file(primary_path, context.allocator)
	testing.expect(t, perr == nil, "read primary")
	defer delete(primary)
	persist, qerr := os.read_entire_file(lg.persist_path, context.allocator)
	testing.expect(t, qerr == nil, "read persist copy")
	defer delete(persist)

	ps, qs := string(primary), string(persist)
	// Primary holds both lines.
	testing.expect(t, strings.contains(ps, "PRE_PERSIST_LINE"), "primary has pre-persist line")
	testing.expect(t, strings.contains(ps, "POST_PERSIST_LINE"), "primary has post-persist line")
	// Persist copy was SEEDED with the run so far, and then written to as well.
	testing.expect(t, strings.contains(qs, "PRE_PERSIST_LINE"), "persist copy seeded with pre-persist line")
	testing.expect(t, strings.contains(qs, "POST_PERSIST_LINE"), "persist copy got post-persist line")

	slog.shutdown(&lg)
	context.logger = old_logger
}
