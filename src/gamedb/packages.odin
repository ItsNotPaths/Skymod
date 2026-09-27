package gamedb

// AI packages (PACK, xEdit). A template (PKDT type 19) holds the procedure tree and default
// inputs; an instance names its template (PKCU) and stores only the inputs it overrides.

import "core:encoding/endian"
import "core:strings"
import "../formats/esm"

// (hole package-unknowns :tags (records ai) :sev polish) unsourced PACK fields kept raw: general flag names (only bits 10 and 13 read), PSDT day-of-week values 7-10 (31 packs), IDLF bits, PRCB bit 1, the ObjectList CNAM float (0 or 350), location types 10/11 (9 BYOHUrchin_AlesanRunner*), and which of PatrolAndHunt's two PFO2 wins (the last is kept).
PACK_ONCE_PER_DAY :: 1 << 10 // once finished, not picked again that day
PACK_PREFERRED_SPEED :: 1 << 13 // `speed` counts only with this general flag
PACK_TEMPLATE :: 19 // PKDT type; 18 is a package

Package_Interrupt :: enum u8 {
	None,
	Spectator,
	ObserveDead,
	GuardWarn,
	Combat,
}

Package_Speed :: enum u8 {
	Walk,
	Jog,
	Run,
	FastWalk,
}

Package :: struct {
	flags:           u32, // PKDT general flags
	type:            u8, // PACK_TEMPLATE or 18
	interrupt:       Package_Interrupt,
	speed:           Package_Speed,
	interrupt_flags: u16,
	schedule:        Package_Schedule,
	conditions:      []Condition, // owned
	idle:            Package_Idles,
	combat_style:    Form_ID, // CNAM
	owner_quest:     Form_ID, // QNAM
	template:        Form_ID, // PKCU; 0 on a template or a self-contained package
	inputs:          []Package_Input, // owned; an instance holds only its overrides
	tree:            []Package_Node, // owned; empty on an instance
}

// Package_Schedule is PSDT; -1 is any. Month and date are never set in vanilla.
Package_Schedule :: struct {
	month, day_of_week, date, hour, minute: i8,
	duration:                               u32, // minutes
}

Package_Idles :: struct {
	flags: u8, // IDLF
	timer: f32, // IDLT
	idles: []Form_ID, // IDLA (owned)
}

Package_Input_Kind :: enum u8 {
	Unknown,
	Bool,
	Int,
	Float,
	ObjectList,
	Location,
	SingleRef,
	TargetSelector,
	Topic,
}

Package_Input :: struct {
	index: u8, // UNAM: the slot tree nodes (PKC2) and instances name
	kind:  Package_Input_Kind,
	value: Package_Value,
}

Package_Value :: union {
	bool,
	i32,
	f32, // Float and ObjectList
	Package_Location,
	Package_Target, // SingleRef and TargetSelector
	Package_Topic,
}

Package_Location_Kind :: enum i32 {
	NearRef,
	InCell,
	NearPackageStart,
	NearEditorLoc,
	ObjectID,
	ObjectType,
	NearLinkedRef,
	AtPackageLoc,
	AliasRef,
	AliasLoc,
	Unknown10,
	Unknown11,
	NearSelf,
}

// Package_Location is PLDT. `form` for NearRef, InCell, ObjectID, NearLinkedRef (a keyword);
// `value` for ObjectType and the alias kinds.
Package_Location :: struct {
	kind:   Package_Location_Kind,
	form:   Form_ID,
	value:  i32,
	radius: i32,
}

Package_Target_Kind :: enum i32 {
	SpecificRef,
	ObjectID,
	ObjectType,
	LinkedRef,
	RefAlias,
	Unknown5,
	Self,
}

// Package_Target is PTDA. `form` for SpecificRef, ObjectID, LinkedRef (a keyword); `value` for
// ObjectType and RefAlias.
Package_Target :: struct {
	kind:  Package_Target_Kind,
	form:  Form_ID,
	value: i32,
	count: i32, // count or distance
}

// Package_Topic is PDTO or TPIC: a topic, or a 4-char topic subtype.
Package_Topic :: struct {
	topic:   Form_ID,
	subtype: [4]u8,
}

Package_Branch :: enum u8 {
	Procedure,
	Sequence,
	Stacked,
	Simultaneous,
	Random,
}

PACK_BRANCH_REPEAT :: 0x1 // PRCB: repeat when complete

// Package_Node is one tree node in pre-order: its children start at i+1 and each next child starts
// at the previous one's `end`.
Package_Node :: struct {
	branch:            Package_Branch,
	procedure:         string, // PNAM (owned); "" on a branch
	end:               u32, // one past this node's subtree
	flags:             u32, // PRCB
	success_completes: bool, // FNAM
	inputs:            []u8, // PKC2: the input indexes the procedure reads, in its order; 0xFF none (owned)
	conditions:        []Condition, // owned
	override:          Maybe(Package_Flag_Override), // PFO2
}

Package_Flag_Override :: struct {
	set_flags, clear_flags:         u32,
	set_interrupt, clear_interrupt: u16,
	speed:                          Package_Speed,
}

@(private = "file")
Pack_Section :: enum {
	Head,
	Inputs, // after PKCU
	Tree, // after XNAM
	Names, // the template's UNAM/BNAM/PNAM input names
	Events, // POBA and after: begin, end and change idles and topics
}

@(private)
index_package :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	index_edid(db, rec.form_id, fl)

	p: Package
	inputs := make([dynamic]Package_Input, db.allocator)
	tree := make([dynamic]Package_Node, db.allocator)
	children := make([dynamic]u32) // PRCB branch counts, parallel to tree
	defer delete(children)
	pkc2 := make([dynamic]u8)
	defer delete(pkc2)
	section := Pack_Section.Head
	unam := 0 // input UNAMs read so far
	for f, i in fl {
		d := f.data
		switch f.type {
		case "PKCU":
			section = .Inputs
			if len(d) >= 8 {p.template = esm.remap_form(fm, u32_at(d, 4))}
		case "XNAM":
			section = .Tree
		case "POBA":
			section = .Events
		}
		switch section {
		case .Head:
			switch f.type {
			case "PKDT":
				if len(d) < 10 {break}
				p.flags, p.type = u32_at(d, 0), d[4]
				p.interrupt, p.speed = Package_Interrupt(d[5]), Package_Speed(d[6])
				p.interrupt_flags = u16_at(d, 8)
			case "PSDT":
				if len(d) < 12 {break}
				p.schedule = {i8(d[0]), i8(d[1]), i8(d[2]), i8(d[3]), i8(d[4]), u32_at(d, 8)}
			case "CTDA":
				if p.conditions == nil {p.conditions = index_conditions(db, esm.condition_run(fl, i), fm)}
			case "IDLF":
				if len(d) >= 1 {p.idle.flags = d[0]}
			case "IDLT":
				p.idle.timer, _ = esm.field_f32(f)
			case "IDLA":
				p.idle.idles = make([]Form_ID, len(d) / 4, db.allocator)
				for &idle, k in p.idle.idles {idle = esm.remap_form(fm, u32_at(d, k * 4))}
			case "CNAM":
				if c, cok := esm.field_u32(f); cok {p.combat_style = esm.remap_form(fm, c)}
			case "QNAM":
				if q, qok := esm.field_u32(f); qok {p.owner_quest = esm.remap_form(fm, q)}
			}
		case .Inputs:
			if f.type == "ANAM" {
				append(&inputs, Package_Input{kind = input_kind(esm.cstr(d))})
			} else if f.type == "UNAM" {
				if unam < len(inputs) && len(d) >= 1 {inputs[unam].index = d[0]}
				unam += 1
			} else if len(inputs) > 0 {
				decode_input_value(&inputs[len(inputs) - 1], f, fm)
			}
		case .Tree:
			if f.type == "UNAM" {
				section = .Names
				break
			}
			if f.type == "ANAM" {
				flush_node_inputs(db, tree[:], &pkc2)
				append(&tree, Package_Node{branch = branch_kind(esm.cstr(d))})
				append(&children, 0)
				break
			}
			if len(tree) == 0 {break}
			n := &tree[len(tree) - 1]
			switch f.type {
			case "CTDA":
				if n.conditions == nil {n.conditions = index_conditions(db, esm.condition_run(fl, i), fm)}
			case "PRCB":
				if len(d) >= 8 {children[len(children) - 1], n.flags = u32_at(d, 0), u32_at(d, 4)}
			case "PNAM":
				n.procedure = strings.clone(esm.cstr(d), db.allocator)
			case "FNAM":
				n.success_completes = len(d) >= 1 && d[0] != 0
			case "PKC2":
				if len(d) >= 1 {append(&pkc2, d[0])}
			case "PFO2":
				if len(d) >= 13 {
					n.override = Package_Flag_Override{u32_at(d, 0), u32_at(d, 4), u16_at(d, 8), u16_at(d, 10), Package_Speed(d[12])}
				}
			}
		case .Names, .Events:
		}
	}
	flush_node_inputs(db, tree[:], &pkc2)
	for i := 0; i < len(tree); i = close_subtree(tree[:], children[:], i) {}
	p.inputs, p.tree = inputs[:], tree[:]

	if old, existed := db.packages[rec.form_id]; existed {free_package(db, old)}
	db.packages[rec.form_id] = p
}

@(private = "file")
input_kind :: proc(s: string) -> Package_Input_Kind {
	switch s {
	case "Bool":           return .Bool
	case "Int":            return .Int
	case "Float":          return .Float
	case "ObjectList":     return .ObjectList
	case "Location":       return .Location
	case "SingleRef":      return .SingleRef
	case "TargetSelector": return .TargetSelector
	case "Topic":          return .Topic
	}
	return .Unknown
}

@(private = "file")
branch_kind :: proc(s: string) -> Package_Branch {
	switch s {
	case "Sequence":     return .Sequence
	case "Stacked":      return .Stacked
	case "Simultaneous": return .Simultaneous
	case "Random":       return .Random
	}
	return .Procedure
}

@(private = "file")
decode_input_value :: proc(input: ^Package_Input, f: esm.Field, fm: ^esm.Form_Map) {
	d := f.data
	switch f.type {
	case "CNAM":
		#partial switch input.kind {
		case .Bool:
			if len(d) >= 1 {input.value = d[0] != 0}
		case .Int:
			if len(d) >= 4 {input.value = i32(u32_at(d, 0))}
		case .Float, .ObjectList:
			if v, ok := esm.field_f32(f); ok {input.value = v}
		}
	case "PLDT":
		if len(d) < 12 {break}
		l := Package_Location{kind = Package_Location_Kind(u32_at(d, 0)), radius = i32(u32_at(d, 8))}
		#partial switch l.kind {
		case .NearRef, .InCell, .ObjectID, .NearLinkedRef:
			l.form = esm.remap_form(fm, u32_at(d, 4))
		case:
			l.value = i32(u32_at(d, 4))
		}
		input.value = l
	case "PTDA":
		if len(d) < 12 {break}
		t := Package_Target{kind = Package_Target_Kind(u32_at(d, 0)), count = i32(u32_at(d, 8))}
		#partial switch t.kind {
		case .SpecificRef, .ObjectID, .LinkedRef:
			t.form = esm.remap_form(fm, u32_at(d, 4))
		case:
			t.value = i32(u32_at(d, 4))
		}
		input.value = t
	case "PDTO":
		if len(d) < 8 {break}
		t: Package_Topic
		if u32_at(d, 0) == 0 {t.topic = esm.remap_form(fm, u32_at(d, 4))} else {copy(t.subtype[:], d[4:8])}
		input.value = t
	case "TPIC":
		if v, ok := esm.field_u32(f); ok {input.value = Package_Topic{topic = esm.remap_form(fm, v)}}
	}
}

// flush_node_inputs gives the last tree node the PKC2 indexes read since its ANAM.
@(private = "file")
flush_node_inputs :: proc(db: ^DB, tree: []Package_Node, pkc2: ^[dynamic]u8) {
	if len(tree) == 0 || len(pkc2) == 0 {return}
	n := &tree[len(tree) - 1]
	n.inputs = make([]u8, len(pkc2), db.allocator)
	copy(n.inputs, pkc2[:])
	clear(pkc2)
}

// close_subtree sets `end` on node i and its subtree; returns that end.
@(private = "file")
close_subtree :: proc(tree: []Package_Node, children: []u32, i: int) -> int {
	next := i + 1
	for _ in 0 ..< children[i] {
		if next >= len(tree) {break}
		next = close_subtree(tree, children, next)
	}
	tree[i].end = u32(next)
	return next
}

@(private = "file")
u32_at :: proc(d: []u8, off: int) -> u32 {return endian.unchecked_get_u32le(d[off:])}

@(private = "file")
u16_at :: proc(d: []u8, off: int) -> u16 {return endian.unchecked_get_u16le(d[off:])}

package_of :: proc(db: ^DB, pack: Form_ID) -> (Package, bool) {
	return db.packages[pack]
}

package_template_of :: proc(db: ^DB, pack: Form_ID) -> Form_ID {
	return db.packages[pack].template
}

// package_tree is the procedure tree a package runs: its template's, else its own.
package_tree :: proc(db: ^DB, pack: Form_ID) -> []Package_Node {
	p := db.packages[pack]
	if p.template != 0 {return db.packages[p.template].tree}
	return p.tree
}

// package_input is a package's input `index`: its own override, else its template's default.
package_input :: proc(db: ^DB, pack: Form_ID, index: u8) -> (Package_Input, bool) {
	p := db.packages[pack]
	for input in p.inputs {
		if input.index == index {return input, true}
	}
	for input in db.packages[p.template].inputs {
		if input.index == index {return input, true}
	}
	return {}, false
}

// actor_packages is an actor base's own PKID list and its DPLT default package list, each through
// its template flag; `pick` stands in for a leveled template.
actor_packages :: proc(db: ^DB, base: Form_ID, pick: Form_ID = 0) -> (own, defaults: []Form_ID) {
	own = template_part(db, base, esm.ACBS_TEMPLATE_AI_PACKAGES, pick).packages
	defaults, _ = form_list_of(db, template_part(db, base, esm.ACBS_TEMPLATE_DEF_PACK_LIST, pick).default_packages)
	return
}

@(private)
free_package :: proc(db: ^DB, p: Package) {
	free_conditions(db, p.conditions)
	delete(p.idle.idles, db.allocator)
	delete(p.inputs, db.allocator)
	for n in p.tree {
		delete(n.procedure, db.allocator)
		delete(n.inputs, db.allocator)
		free_conditions(db, n.conditions)
	}
	delete(p.tree, db.allocator)
}

@(private)
free_packages :: proc(db: ^DB) {
	for _, p in db.packages {free_package(db, p)}
	delete(db.packages)
}
