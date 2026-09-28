package seam_test

// A test plugin: skymod_test knows version 1 only, and sets the table's value to 7.

@(export)
skymod_test :: proc "c" (version: u32, table: rawptr) -> b32 {
	if version != 1 {return false}
	(^u32)(table)^ = 7
	return true
}
