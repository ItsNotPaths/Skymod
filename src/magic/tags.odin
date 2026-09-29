package magic

// Tags are dotted names ("magic.fire", "school.destruction"). A pattern matches its own tag and
// every tag below it: "magic" matches "magic.fire".

// (hole magic-tags :tags magic :sev gap) nothing carries tags: an effect's keywords are not tags yet (kw.<editor id>), a spell's school and tier are not derived, race and NPC keywords are not actor tags, and no scale or rule matches by tag.
matches :: proc "contextless" (tag, pattern: string) -> bool {
	if len(tag) < len(pattern) || tag[:len(pattern)] != pattern {return false}
	return len(tag) == len(pattern) || tag[len(pattern)] == '.'
}
