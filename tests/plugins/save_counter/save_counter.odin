package save_counter

// A test plugin with saved state: one counter, saved as 4 bytes.

count: i32

@(export)
skymod_id :: proc "c" () -> cstring {return "save_counter.5b0f2c1e"}

@(export)
skymod_save :: proc "c" (out: [^]u8, cap: int) -> int {
	if cap >= size_of(count) {(^i32)(out)^ = count}
	return size_of(count)
}

@(export)
skymod_load :: proc "c" (data: [^]u8, len: int) {
	count = (^i32)(data)^ if len == size_of(count) else 0
}
