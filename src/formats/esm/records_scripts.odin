package esm

// VMAD — the scripts a record carries, the property values they were authored with, and the
// compiler-generated fragments on QUST / INFO / SCEN / PACK / PERK. Decoding this is what makes
// a transpiled script addressable: without it the engine never learns that a form runs code.
//
// Layout (little-endian). Every offset here was read off the real plugins, then proved by
// parsing to the EXACT byte — 78,000+ VMAD fields and 31,000+ fragment tails across Skyrim.esm,
// the four DLC masters and 1,326 mod plugins, with zero records left short and zero with bytes
// over. Any layout error shows up immediately as a tail that does not land on the field end.
//
//   header:   version:i16  objFormat:i16  scriptCount:u16
//   script:   name:wstring  [status:u8 if version>=4]  propCount:u16  property[propCount]
//   property: name:wstring  kind:u8  [status:u8 if version>=4]  value
//   wstring:  len:u16 then len bytes, NOT null-terminated
//   array:    count:u32 then count values of the element kind
//
// An object value is 8 bytes whose field ORDER depends on objFormat, and both formats are live:
// format 2 is (unused:u16, alias:i16, formID:u32), format 1 is (formID:u32, alias:i16,
// unused:u16). Skyrim.esm alone holds 2,705 format-1 records, so neither branch is dead code.
//
// Unlike the view-returning decoders in records.odin, Form_Scripts is FULLY OWNED — every
// consumer keeps it long after the plugin buffer is freed, so one owner and one free_form_scripts
// beats making each of them clone name by name.

import "base:runtime"
import "core:strings"

// Prop_Kind is a property's declared Papyrus type (the `kind` byte). The array kinds are their
// element kind plus 10. All ten appear in the corpus; the single-object kind is 87% of all
// properties, and arrays together are under 2%.
Prop_Kind :: enum u8 {
	Object       = 1,
	String       = 2,
	Int          = 3,
	Float        = 4,
	Bool         = 5,
	Object_Array = 11,
	String_Array = 12,
	Int_Array    = 13,
	Float_Array  = 14,
	Bool_Array   = 15,
}

// Prop_Object is an object-typed value: the form it names (already global when decoded with a
// Form_Map) and the quest ALIAS index it resolves through.
//
// alias == -1 means the property names `form` directly, which is the common case. Anything >= 0
// is a real alias id, NOT a "none" sentinel — 0 is as ordinary an id as any. Measured on
// Skyrim.esm: 29,989 object properties name a form and 12,896 resolve through an alias, with ids
// running 0..555 and thinning out smoothly, and id 0 alone used 655 times.
Prop_Object :: struct {
	form:  Form_ID,
	alias: i16,
}

// Prop_Value is a property's decoded value. The variant always matches Script_Prop.kind.
Prop_Value :: union {
	Prop_Object,
	string,
	i32,
	f32,
	bool,
	[]Prop_Object,
	[]string,
	[]i32,
	[]f32,
	[]bool,
}

// Script_Prop is one authored property on one attached script — the value the Creation Kit
// filled an auto-property with, which the runtime refills from here rather than from a save.
//
// `status` (version>=4) is 1 for a normal authored property and 3 for one the record REMOVES;
// 3 is rare (57 across every plugin surveyed) and carries no value worth keeping.
Script_Prop :: struct {
	name:   string,
	kind:   Prop_Kind,
	status: u8,
	value:  Prop_Value,
}

// Script_Attach is one script bound to a record, with the properties it was authored with.
//
// `status` (version>=4) describes inheritance FROM THE BASE FORM, not from a plugin master:
// 0 = declared on this record, 1 = inherited from the base form and modified here, 3 = inherited
// and REMOVED here. MEASURED on Skyrim.esm by joining every placed ref against its base form's
// script set: all 253 status-3 attachments name a script the base carries, 3,838 of 4,052
// status-1 ones do, and only 30 of 2,338 status-0 ones do. So a placed reference's effective
// script set is its base form's set, plus its own, minus what it marks removed — see
// script_attach_removed.
Script_Attach :: struct {
	name:   string,
	status: u8,
	props:  []Script_Prop,
}

// Script_Fragment is one compiler-generated fragment body. Papyrus written inline in the Creation
// Kit (a quest stage's snippet, a dialogue response's end script) is compiled into a function
// named `Fragment_<n>` on a generated script named after the record, and this is the link from
// the record's own numbering to that function.
//
// `index` is the quest STAGE (QUST), the scene PHASE (SCEN), the perk ENTRY (PERK), or the
// fragment's bit slot in the flags byte (INFO/PACK, where slot 0 is begin and 1 is end). `item` is
// the stage's log entry (QUST), or for a scene PHASE fragment which end of the phase it runs at
// (PHASE_ON_START / PHASE_ON_COMPLETION; 0 on the scene's begin and end fragments).
PHASE_ON_START :: 1
PHASE_ON_COMPLETION :: 2

Script_Fragment :: struct {
	index:    u16,
	item:     u16,
	script:   string,
	function: string,
}

// Alias_Scripts is the script list a quest attaches to one of its ALIASES. `owner.alias` is the
// alias id the quest addresses it by; `owner.form` is the quest itself. Alias scripts are a large
// share of the real dispatch surface — 18,029 of them across the corpus, against 2,529 in
// Skyrim.esm alone — because vanilla quests hang behaviour on aliases rather than on base forms.
Alias_Scripts :: struct {
	owner:   Prop_Object,
	scripts: []Script_Attach,
}

// Form_Scripts is everything one record's VMAD declares. `fragments`, `frag_file` and `aliases`
// are empty for every record type that carries no fragment tail, which is all but the five.
Form_Scripts :: struct {
	scripts:   []Script_Attach,
	frag_file: string, // generated fragment script, no extension ("" when the record has none)
	fragments: []Script_Fragment,
	aliases:   []Alias_Scripts, // QUST only
}

// script_attach_removed reports whether this attachment REMOVES a script inherited from the base
// form rather than adding one. See the Script_Attach note for the evidence behind status 3.
script_attach_removed :: proc(a: Script_Attach) -> bool {
	return a.status == 3
}

// decode_vmad decodes a record's VMAD field. `rec_type` selects the fragment tail layout (it is
// the record's 4-char signature; a type with no tail simply has none to read). `fm` remaps every
// object-property FormID into global space, nil = raw passthrough, exactly as walk does.
//
// ok=false means the field is malformed and NOTHING is returned to free — a partial decode is
// freed here rather than handed back half-built. A record with no VMAD returns ok=false too;
// callers test for the field first when they want to tell those apart.
decode_vmad :: proc(
	rec_type: string,
	fields: []Field,
	fm: ^Form_Map = nil,
	allocator := context.allocator,
) -> (
	out: Form_Scripts,
	ok: bool,
) {
	f := find_field(fields, "VMAD") or_return
	c := Vmad_Cur {
		b = f.data,
	}

	version := vm_i16(&c)
	obj_format := vm_i16(&c)
	out.scripts = vm_scripts(&c, version, obj_format, fm, allocator)
	vm_fragments(&c, rec_type, version, obj_format, fm, allocator, &out)

	if c.bad {
		free_form_scripts(out, allocator)
		return {}, false
	}
	return out, true
}

// free_form_scripts releases everything decode_vmad allocated.
free_form_scripts :: proc(fs: Form_Scripts, allocator := context.allocator) {
	free_attachments(fs.scripts, allocator)
	for a in fs.aliases {
		free_attachments(a.scripts, allocator)
	}
	for fr in fs.fragments {
		delete(fr.script, allocator)
		delete(fr.function, allocator)
	}
	delete(fs.aliases, allocator)
	delete(fs.fragments, allocator)
	delete(fs.frag_file, allocator)
}

@(private)
free_attachments :: proc(list: []Script_Attach, allocator: runtime.Allocator) {
	for s in list {
		for p in s.props {
			delete(p.name, allocator)
			free_prop_value(p.value, allocator)
		}
		delete(s.props, allocator)
		delete(s.name, allocator)
	}
	delete(list, allocator)
}

@(private)
free_prop_value :: proc(v: Prop_Value, allocator: runtime.Allocator) {
	#partial switch val in v {
	case string:
		delete(val, allocator)
	case []Prop_Object:
		delete(val, allocator)
	case []i32:
		delete(val, allocator)
	case []f32:
		delete(val, allocator)
	case []bool:
		delete(val, allocator)
	case []string:
		for s in val {
			delete(s, allocator)
		}
		delete(val, allocator)
	}
}

// --- the byte cursor ---
//
// Every read is bounds-checked and sets `bad` instead of faulting, so a truncated or hostile
// field stops the walk rather than running off the end. Once bad is set every later read is a
// no-op, which lets the parse loops stay linear with one check at the end.

@(private)
Vmad_Cur :: struct {
	b:   []u8,
	p:   int,
	bad: bool,
}

@(private)
vm_need :: proc(c: ^Vmad_Cur, n: int) -> bool {
	if c.bad || n < 0 || c.p + n > len(c.b) {
		c.bad = true
		return false
	}
	return true
}

@(private)
vm_u8 :: proc(c: ^Vmad_Cur) -> u8 {
	if !vm_need(c, 1) {
		return 0
	}
	v := c.b[c.p]
	c.p += 1
	return v
}

@(private)
vm_u16 :: proc(c: ^Vmad_Cur) -> u16 {
	if !vm_need(c, 2) {
		return 0
	}
	v := rd16(c.b, c.p)
	c.p += 2
	return v
}

@(private)
vm_i16 :: proc(c: ^Vmad_Cur) -> i16 {return i16(vm_u16(c))}

@(private)
vm_u32 :: proc(c: ^Vmad_Cur) -> u32 {
	if !vm_need(c, 4) {
		return 0
	}
	v := rd32(c.b, c.p)
	c.p += 4
	return v
}

@(private)
vm_f32 :: proc(c: ^Vmad_Cur) -> f32 {
	if !vm_need(c, 4) {
		return 0
	}
	v := rf32(c.b, c.p)
	c.p += 4
	return v
}

// vm_wstr reads a length-prefixed, NON-terminated string as a VIEW into the field bytes.
@(private)
vm_wstr :: proc(c: ^Vmad_Cur) -> string {
	n := int(vm_u16(c))
	if !vm_need(c, n) {
		return ""
	}
	s := string(c.b[c.p:c.p + n])
	c.p += n
	return s
}

@(private)
vm_str_owned :: proc(c: ^Vmad_Cur, allocator: runtime.Allocator) -> string {
	return strings.clone(vm_wstr(c), allocator)
}

@(private)
vm_skip :: proc(c: ^Vmad_Cur, n: int) {
	if vm_need(c, n) {
		c.p += n
	}
}

// vm_object reads the 8-byte object value. objFormat 1 puts the formID first, format 2 puts it
// last; both are in the wild, so the branch is load-bearing.
@(private)
vm_object :: proc(c: ^Vmad_Cur, obj_format: i16, fm: ^Form_Map) -> Prop_Object {
	if !vm_need(c, 8) {
		return {}
	}
	local, alias: u32
	if obj_format == 1 {
		local = rd32(c.b, c.p)
		alias = u32(rd16(c.b, c.p + 4))
	} else {
		alias = u32(rd16(c.b, c.p + 2))
		local = rd32(c.b, c.p + 4)
	}
	c.p += 8
	return {form = remap_form(fm, local), alias = i16(alias)}
}

// --- the script block ---

@(private)
vm_scripts :: proc(
	c: ^Vmad_Cur,
	version, obj_format: i16,
	fm: ^Form_Map,
	allocator: runtime.Allocator,
) -> []Script_Attach {
	count := int(vm_u16(c))
	if c.bad || count == 0 {
		return nil
	}
	list := make([dynamic]Script_Attach, 0, count, allocator)
	for _ in 0 ..< count {
		if c.bad {
			break
		}
		a: Script_Attach
		a.name = vm_str_owned(c, allocator)
		if version >= 4 {
			a.status = vm_u8(c)
		}
		a.props = vm_props(c, version, obj_format, fm, allocator)
		append(&list, a)
	}
	return list[:]
}

@(private)
vm_props :: proc(
	c: ^Vmad_Cur,
	version, obj_format: i16,
	fm: ^Form_Map,
	allocator: runtime.Allocator,
) -> []Script_Prop {
	count := int(vm_u16(c))
	if c.bad || count == 0 {
		return nil
	}
	list := make([dynamic]Script_Prop, 0, count, allocator)
	for _ in 0 ..< count {
		if c.bad {
			break
		}
		p: Script_Prop
		p.name = vm_str_owned(c, allocator)
		p.kind = Prop_Kind(vm_u8(c))
		if version >= 4 {
			p.status = vm_u8(c)
		}
		p.value = vm_value(c, p.kind, obj_format, fm, allocator)
		append(&list, p)
	}
	return list[:]
}

// vm_elem_size is an array element's MINIMUM encoded size, used to reject an absurd count before
// allocating for it. A string element is 2 (its own length prefix) plus its bytes.
@(private)
vm_elem_size :: proc(kind: Prop_Kind) -> int {
	#partial switch kind {
	case .Object:
		return 8
	case .String:
		return 2
	case .Int, .Float:
		return 4
	case .Bool:
		return 1
	}
	return 0
}

// vm_count reads an array's count and rejects one the remaining bytes could not possibly hold —
// the guard that keeps a corrupt length from turning into a huge allocation.
@(private)
vm_count :: proc(c: ^Vmad_Cur, elem: Prop_Kind) -> int {
	n := int(vm_u32(c))
	size := vm_elem_size(elem)
	if c.bad || size == 0 || n < 0 || n > (len(c.b) - c.p) / size {
		c.bad = true
		return 0
	}
	return n
}

@(private)
vm_value :: proc(
	c: ^Vmad_Cur,
	kind: Prop_Kind,
	obj_format: i16,
	fm: ^Form_Map,
	allocator: runtime.Allocator,
) -> Prop_Value {
	switch kind {
	case .Object:
		return vm_object(c, obj_format, fm)
	case .String:
		return vm_str_owned(c, allocator)
	case .Int:
		return i32(vm_u32(c))
	case .Float:
		return vm_f32(c)
	case .Bool:
		return vm_u8(c) != 0
	case .Object_Array:
		n := vm_count(c, .Object)
		out := make([]Prop_Object, n, allocator)
		for i in 0 ..< n {
			out[i] = vm_object(c, obj_format, fm)
		}
		return out
	case .String_Array:
		n := vm_count(c, .String)
		out := make([]string, n, allocator)
		for i in 0 ..< n {
			out[i] = vm_str_owned(c, allocator)
		}
		return out
	case .Int_Array:
		n := vm_count(c, .Int)
		out := make([]i32, n, allocator)
		for i in 0 ..< n {
			out[i] = i32(vm_u32(c))
		}
		return out
	case .Float_Array:
		n := vm_count(c, .Float)
		out := make([]f32, n, allocator)
		for i in 0 ..< n {
			out[i] = vm_f32(c)
		}
		return out
	case .Bool_Array:
		n := vm_count(c, .Bool)
		out := make([]bool, n, allocator)
		for i in 0 ..< n {
			out[i] = vm_u8(c) != 0
		}
		return out
	}
	c.bad = true // an unknown kind makes every later byte meaningless
	return nil
}

// --- the fragment tail ---
//
// Only five record types carry one, and each spells its header differently. PERK puts its file
// name BEFORE the fragment count while QUST puts it after; INFO, PACK and SCEN count their
// fragments as set bits in a flags byte rather than storing a count at all. These are not
// stylistic choices we can normalise away — they are what the bytes say.

@(private)
vm_fragments :: proc(
	c: ^Vmad_Cur,
	rec_type: string,
	version, obj_format: i16,
	fm: ^Form_Map,
	allocator: runtime.Allocator,
	out: ^Form_Scripts,
) {
	if c.bad || c.p >= len(c.b) {
		return // no tail: the common case, and every type outside the five
	}

	switch rec_type {
	case "INFO", "PACK":
		vm_u8(c) // fragment-block version
		flags := vm_u8(c)
		out.frag_file = vm_str_owned(c, allocator)
		out.fragments = vm_flag_fragments(c, flags, allocator)
	case "SCEN":
		vm_u8(c)
		flags := vm_u8(c)
		out.frag_file = vm_str_owned(c, allocator)
		begin_end := vm_flag_fragments(c, flags, allocator)

		// … then one fragment per scene PHASE, which the begin/end flags do not count.
		phases := int(vm_u16(c))
		list := make([dynamic]Script_Fragment, 0, len(begin_end) + max(phases, 0), allocator)
		append(&list, ..begin_end)
		delete(begin_end, allocator)
		for _ in 0 ..< phases {
			if c.bad {
				break
			}
			flag := vm_u8(c) // PHASE_ON_START or PHASE_ON_COMPLETION
			index := vm_u32(c)
			fr := vm_fragment(c, u16(index), allocator)
			fr.item = u16(flag)
			append(&list, fr)
		}
		out.fragments = list[:]
	case "PERK":
		vm_u8(c)
		out.frag_file = vm_str_owned(c, allocator)
		count := int(vm_u16(c))
		list := make([dynamic]Script_Fragment, 0, max(count, 0), allocator)
		for _ in 0 ..< count {
			if c.bad {
				break
			}
			index := vm_u16(c) // perk entry
			vm_i16(c) // unknown
			append(&list, vm_fragment(c, index, allocator))
		}
		out.fragments = list[:]
	case "QUST":
		vm_u8(c)
		count := int(vm_u16(c))
		out.frag_file = vm_str_owned(c, allocator)
		list := make([dynamic]Script_Fragment, 0, max(count, 0), allocator)
		for _ in 0 ..< count {
			if c.bad {
				break
			}
			index := vm_u16(c) // quest stage
			vm_i16(c) // unknown
			item := vm_u32(c) // log entry this fragment belongs to
			fr := vm_fragment(c, index, allocator)
			fr.item = u16(item)
			append(&list, fr)
		}
		out.fragments = list[:]
		out.aliases = vm_aliases(c, obj_format, fm, allocator)
	}
}

// vm_flag_fragments reads one fragment per SET BIT of a flags byte — how INFO, PACK and SCEN say
// how many follow. The bit position is the fragment's slot (0 = begin, 1 = end).
@(private)
vm_flag_fragments :: proc(c: ^Vmad_Cur, flags: u8, allocator: runtime.Allocator) -> []Script_Fragment {
	list := make([dynamic]Script_Fragment, 0, 4, allocator)
	for bit in u16(0) ..< 8 {
		if c.bad {
			break
		}
		if flags & (1 << bit) == 0 {
			continue
		}
		append(&list, vm_fragment(c, bit, allocator))
	}
	return list[:]
}

// vm_fragment reads the <version:u8, scriptName:wstring, functionName:wstring> body shared by
// every fragment entry, whatever the header in front of it looked like.
@(private)
vm_fragment :: proc(c: ^Vmad_Cur, index: u16, allocator: runtime.Allocator) -> Script_Fragment {
	vm_u8(c) // entry version
	script := vm_str_owned(c, allocator)
	function := vm_str_owned(c, allocator)
	return {index = index, script = script, function = function}
}

// vm_aliases reads a quest's per-alias script lists. Each alias restates its own version and
// objFormat, so an alias block is NOT required to match the record header it sits inside.
@(private)
vm_aliases :: proc(
	c: ^Vmad_Cur,
	obj_format: i16,
	fm: ^Form_Map,
	allocator: runtime.Allocator,
) -> []Alias_Scripts {
	count := int(vm_u16(c))
	if c.bad || count == 0 {
		return nil
	}
	list := make([dynamic]Alias_Scripts, 0, count, allocator)
	for _ in 0 ..< count {
		if c.bad {
			break
		}
		a: Alias_Scripts
		a.owner = vm_object(c, obj_format, fm)
		alias_version := vm_i16(c)
		alias_format := vm_i16(c)
		a.scripts = vm_scripts(c, alias_version, alias_format, fm, allocator)
		append(&list, a)
	}
	return list[:]
}
