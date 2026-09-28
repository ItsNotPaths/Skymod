package plugin

// Record views: items (see records.odin for the rules every view obeys).

import "../formats/esm"

Enchantment :: struct {
	using header:      Header,
	info:              esm.Enchant_Info,
	base_enchantment:  Form_ID,
	worn_restrictions: Form_ID, // a FLST of slots
	effects:           Span(Effect_Item),
}

Potion :: struct {
	using header: Header,
	effects:      Span(Effect_Item),
	poison:       bool,
}

Ingredient :: struct {
	using header: Header,
	effects:      Span(Effect_Item),
}

Projectile :: struct {
	using header: Header,
	info:         esm.Projectile,
}

Book :: struct {
	using header: Header,
	skill:        i32, // an actor value index; < 0 = teaches `spell`
	spell:        Form_ID,
}

Recipe :: struct {
	using header: Header,
	ingredients:  Span(Item_Count),
	result:       Form_ID,
	bench:        Form_ID, // the workbench KEYWORD
	quantity:     u16,
	conditions:   Span(Condition),
}

Leveled_List_Entry :: struct {
	level: u16,
	form:  Form_ID, // may be another leveled list
	count: u16,
}

Leveled_List :: struct {
	using header:  Header,
	chance_none:   u8,
	chance_global: Form_ID, // a GLOB replacing chance_none; 0 = none
	flags:         u8, // esm.LVLI_*
	entries:       Span(Leveled_List_Entry),
}

Container :: struct {
	using header: Header,
	contents:     Span(Item_Count),
}

Outfit :: struct {
	using header: Header,
	items:        Span(Form_ID),
}

Form_List :: struct {
	using header: Header,
	forms:        Span(Form_ID),
}
