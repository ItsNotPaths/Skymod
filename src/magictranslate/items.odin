package magictranslate

// ALCH and INGR to rt.item: a potion, food, poison or ingredient used from the inventory, with its
// effects' numbers. An eaten ingredient applies only its first effect, in record order.

import "core:fmt"
import "core:strings"
import "../gamedb"

// item_lua writes an item used from the inventory as an items/ file; `record` is ALCH or INGR.
item_lua :: proc(src: ^Source, form: Form_ID, record: string, applies: []gamedb.Magic_Effect_Ref, poison: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	write_head(&b, src, form, fmt.tprintf("%s %s", record, src.edids[form]), "item")
	if poison {write_tags(&b, {"poison"})}
	write_applies(&b, src, applies)
	fmt.sbprintln(&b, "}")
	return strings.to_string(b)
}

// write_applies writes the effects a source applies, each by its name (`names`, else the effect's)
// with its numbers. Where some entries have an area, one without hits only what the shape struck.
@(private)
write_applies :: proc(b: ^strings.Builder, src: ^Source, refs: []gamedb.Magic_Effect_Ref, names: []string = nil) {
	area := false
	for r in refs {area ||= r.area != 0}
	fmt.sbprintln(b, "  applies = {")
	for r, i in refs {
		fmt.sbprintf(b, "    {{ %q, m = %v", names[i] if names != nil else form_name(src, r.effect), r.magnitude)
		if r.duration != 0 {fmt.sbprintf(b, ", d = \"%vs\"", r.duration)}
		if r.area != 0 {fmt.sbprintf(b, ", area = %v", r.area)}
		if area && r.area == 0 {fmt.sbprint(b, ", hits = \"direct\"")}
		fmt.sbprintln(b, " },")
	}
	fmt.sbprintln(b, "  },")
}
