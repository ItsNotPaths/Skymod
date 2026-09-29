package magictranslate

// ALCH to rt.item: a potion, food or poison used from the inventory, with its effects' numbers.

import "core:fmt"
import "core:strings"
import "../gamedb"

// item_lua writes a potion as an items/ file.
item_lua :: proc(src: ^Source, form: Form_ID, potion: gamedb.Potion) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "-- %s ALCH %s", src.files[u32(form >> 32)], src.edids[form])
	fmt.sbprintln(&b, "local rt = require('skymod.rt')")
	fmt.sbprintln(&b, "return rt.item {")
	fmt.sbprintfln(&b, "  form = %q,", form_ref(src, form))
	if potion.poison {fmt.sbprintln(&b, "  tags = { \"poison\" },")}
	write_applies(&b, src, potion.effects)
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
