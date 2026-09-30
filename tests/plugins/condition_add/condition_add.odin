package condition_add

// A test plugin: adds condition function 4000 (the subject's Health) and passes every other
// function on to the table it was given.

import "../../../src/condfn"

prev: condfn.Table

@(export)
skymod_conditions :: proc "c" (version: u32, table: rawptr) -> b32 {
	if version != condfn.VERSION {return false}
	t := (^condfn.Table)(table)
	prev = t^
	t.eval = eval
	return true
}

eval :: proc "c" (h: ^condfn.Host, c: condfn.Call) -> condfn.Answer {
	if c.function == 4000 {return {h.world.actor_value(h.world.data, c.on, "Health", .Value), true}}
	return prev.eval(h, c)
}
