package plugin

// Record views: world (see records.odin for the rules every view obeys).

import "../formats/esm"

Cell :: struct {
	using header:  Header,
	form_id:       Form_ID,
	editor_id:     Span(u8),
	interior:      bool,
	public:        bool,
	world_form_id: Form_ID, // 0 for interiors
	gx, gy:        i32,
	has_grid:      bool,
	water_height:  f32, // esm.WATER_NONE = no water
	water_type:    Form_ID,
	location:      Form_ID,
	zone:          Form_ID,
	acoustic:      Form_ID,
	music:         Form_ID,
}

Location_Special_Ref :: struct {
	ref_type, ref: Form_ID,
}

Location :: struct {
	using header:     Header,
	parent:           Form_ID, // 0 = a root location
	marker_color:     u32, // packed RGBA
	has_marker_color: bool,
	special_refs:     Span(Location_Special_Ref), // master_refs with the winning override's edits
	master_refs:      Span(Location_Special_Ref),
	crime_faction:    Form_ID,
}

Worldspace :: struct {
	using header: Header,
	editor_id:    Span(u8),
	cells:        Span(Form_ID), // its exterior cells
	persistent:   Form_ID, // its PERSISTENT cell
	water:        f32, // default water height
	location:     Form_ID, // XLCN
	music:        Form_ID, // ZNAM
}

Weather :: struct {
	using header: Header,
	info:         esm.Weather_Info,
	fog:          esm.Weather_Fog,
	has_fog:      bool,
	colors:       [esm.WTHR_COLOR_ROWS_MAX][esm.WTHR_TIMES][4]u8, // first color_rows rows are set
	color_rows:   int,
	imagespaces:  [esm.WTHR_TIMES]Form_ID, // 0 = none
}

Placed_Ref :: struct {
	using header:    Header,
	form_id:         Form_ID,
	cell_form_id:    Form_ID,
	base:            Form_ID,
	pos:             [3]f32,
	rot:             [3]f32,
	scale:           f32,
	count:           i32,
	teleport:        esm.Teleport,
	has_tp:          bool,
	disabled:        bool,
	deleted:         bool,
	persistent:      bool,
	no_respawn:      bool,
	enable_parent:   Form_ID, // 0 = none
	enable_opposite: bool,
	starts_dead:     bool,
}

Lock :: struct {
	using header: Header,
	using lock:   esm.Lock_Data,
}

Trigger :: struct {
	using header:    Header,
	using primitive: esm.Primitive,
}

Linked_Refs_Link :: struct {
	keyword: Form_ID, // 0 = the default link
	ref:     Form_ID,
}

Linked_Refs :: struct {
	using header: Header,
	links:        Span(Linked_Refs_Link),
}

// Form_Scripts_Prop is esm.Script_Prop with its value union flattened: kind says which field is set.
Form_Scripts_Prop :: struct {
	name:        Span(u8),
	kind:        esm.Prop_Kind,
	status:      u8,
	object:      esm.Prop_Object,
	text:        Span(u8),
	int_value:   i32,
	float_value: f32,
	bool_value:  bool,
	objects:     Span(esm.Prop_Object),
	texts:       Span(Span(u8)),
	ints:        Span(i32),
	floats:      Span(f32),
	bools:       Span(bool),
}

Form_Scripts_Script :: struct {
	name:   Span(u8),
	status: u8,
	props:  Span(Form_Scripts_Prop),
}

Form_Scripts_Fragment :: struct {
	index:    u16,
	item:     u16,
	script:   Span(u8),
	function: Span(u8),
}

Form_Scripts_Alias :: struct {
	owner:   esm.Prop_Object,
	scripts: Span(Form_Scripts_Script),
}

Form_Scripts :: struct {
	using header: Header,
	scripts:      Span(Form_Scripts_Script),
	frag_file:    Span(u8),
	fragments:    Span(Form_Scripts_Fragment),
	aliases:      Span(Form_Scripts_Alias), // QUST only
}
