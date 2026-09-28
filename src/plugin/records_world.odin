package plugin

// Record views: world (see records.odin for the rules every view obeys).

Cell :: struct {
	using header: Header,
}

Location :: struct {
	using header: Header,
}

Worldspace :: struct {
	using header: Header,
}

Weather :: struct {
	using header: Header,
}

Placed_Ref :: struct {
	using header: Header,
}

Lock :: struct {
	using header: Header,
}

Trigger :: struct {
	using header: Header,
}

Linked_Refs :: struct {
	using header: Header,
}

Form_Scripts :: struct {
	using header: Header,
}
