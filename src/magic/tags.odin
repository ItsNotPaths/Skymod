package magic

// Tags are dotted names ("magic.fire", "school.destruction"). A pattern matches its own tag and
// every tag below it: "magic" matches "magic.fire".

// A form's keywords are its tags kw.<editor id>; an actor has its race's too. Content gives the
// rest (worldstate.set_tags). A seam asks plugin.World.has_tag.
matches :: proc "contextless" (tag, pattern: string) -> bool {
	if len(tag) < len(pattern) || tag[:len(pattern)] != pattern {return false}
	return len(tag) == len(pattern) || tag[len(pattern)] == '.'
}
