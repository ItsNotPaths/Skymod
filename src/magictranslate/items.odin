package magictranslate

// ALCH and INGR to rt.item: a potion, food, poison or ingredient used from the inventory, with its
// effects' numbers. An eaten ingredient applies only its first effect, in record order.

import "core:fmt"
import "core:strings"
import "../gamedb"

// item_lua writes an item used from the inventory as an items/ file; `record` is ALCH or INGR.
item_lua :: proc(src: ^Source, form: Form_ID, record: string, applies: []gamedb.Magic_Effect_Ref, poison: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "-- %s %s %s", src.files[u32(form >> 32)], record, src.edids[form])
	fmt.sbprintln(&b, "local rt = require('skymod.rt')")
	fmt.sbprintln(&b, "return rt.item {")
	fmt.sbprintfln(&b, "  form = %q,", form_ref(src, form))
	if poison {fmt.sbprintln(&b, "  tags = { \"poison\" },")}
	write_applies(&b, src, applies)
	fmt.sbprintln(&b, "}")
	return strings.to_string(b)
}

// write_applies writes the effects a source applies, each by its name with its numbers.
@(private)
write_applies :: proc(b: ^strings.Builder, src: ^Source, refs: []gamedb.Magic_Effect_Ref) {
	fmt.sbprintln(b, "  applies = {")
	for r in refs {
		fmt.sbprintf(b, "    {{ %q, m = %v", form_name(src, r.effect), r.magnitude)
		if r.duration != 0 {fmt.sbprintf(b, ", d = \"%vs\"", r.duration)}
		if r.area != 0 {fmt.sbprintf(b, ", area = %v", r.area)}
		fmt.sbprintln(b, " },")
	}
	fmt.sbprintln(b, "  },")
}
