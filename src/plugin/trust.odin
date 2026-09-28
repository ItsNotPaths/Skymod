package plugin

// Native code has full access to the computer, so a plugin loads only once the user allowed it in
// the mod manager. Trust is per file, by path and SHA-256: a changed file is untrusted again.

import "core:crypto/hash"
import "core:encoding/hex"
import "core:os"
import "core:strings"

TRUST_FILE :: "trusted_plugins.txt" // in the base dir: one "<sha256 hex>\t<path>" per line

Trust :: struct {
	file:   string,
	hashes: map[string]string, // plugin path -> the hash the user allowed
}

trust_load :: proc(t: ^Trust, file: string) {
	t.file = strings.clone(file)
	data, err := os.read_entire_file(file, context.temp_allocator)
	if err != nil {return}
	for line in strings.split_lines(string(data), context.temp_allocator) {
		sum, _, path := strings.partition(line, "\t")
		if path != "" {t.hashes[strings.clone(path)] = strings.clone(sum)}
	}
}

trust_save :: proc(t: ^Trust) -> bool {
	b := strings.builder_make(context.temp_allocator)
	for path, sum in t.hashes {strings.write_string(&b, sum);strings.write_byte(&b, '\t');strings.write_string(&b, path);strings.write_byte(&b, '\n')}
	return os.write_entire_file(t.file, b.buf[:]) == nil
}

// trusted: the user allowed this file, and it has not changed since.
trusted :: proc(t: ^Trust, path: string) -> bool {
	sum, ok := t.hashes[path]
	return ok && sum == file_hash(path)
}

// set_trust allows the file as it is now, or stops allowing it.
set_trust :: proc(t: ^Trust, path: string, on: bool) {
	if key, sum := delete_key(&t.hashes, path); key != "" {
		delete(key)
		delete(sum)
	}
	if on {t.hashes[strings.clone(path)] = strings.clone(file_hash(path))}
}

trust_destroy :: proc(t: ^Trust) {
	for path, sum in t.hashes {delete(path);delete(sum)}
	delete(t.hashes)
	delete(t.file)
}

// file_hash is the file's SHA-256 in hex; "" when it cannot be read. Temp-allocated.
@(private = "file")
file_hash :: proc(path: string) -> string {
	sum, err := hash.hash_file_by_name(.SHA256, path, allocator = context.temp_allocator)
	if err != nil {return ""}
	return string(hex.encode(sum, context.temp_allocator))
}
