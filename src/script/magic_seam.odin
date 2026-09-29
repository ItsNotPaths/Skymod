package script

// The host side of the magic seam (src/magic).

import "../magic"
import "../worldhost"

magic_table := magic.BUILTIN // the built-in landing, or a plugin's

// hit_lands asks the on-hit stage whether `spell` lands on `target` at all.
@(private)
hit_lands :: proc(c: ^Call, hit: magic.Hit) -> bool {
	wd := worldhost.Data{context, c.ws, c.db}
	w := worldhost.world(&wd)
	h := magic.Host{&w}
	return magic_table.on_hit(&h, hit) == .Lands
}

// effect_numbers is an effect's magnitude and duration after the scales that match it.
@(private)
effect_numbers :: proc(c: ^Call, hit: magic.Hit, effect: Form_ID, m, d: f32) -> (f32, f32) {
	wd := worldhost.Data{context, c.ws, c.db}
	w := worldhost.world(&wd)
	h := magic.Host{&w}
	n := magic_table.scale(&h, hit, effect, {m, d})
	return n.m, n.d
}
