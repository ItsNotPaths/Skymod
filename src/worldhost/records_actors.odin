package worldhost

// The engine's record views: actors (see records.odin).

import "../gamedb"
import "../plugin"

@(private)
view_actor_base :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Actor_Base, ok: bool) {
	a := db.actors[form] or_return
	factions := make([]plugin.Actor_Base_Faction, len(a.factions), context.temp_allocator)
	for f, i in a.factions {factions[i] = {f.faction, f.rank}}
	return {
		flags = a.flags, level = a.level, calc_min = a.calc_min, calc_max = a.calc_max, speed_mult = a.speed_mult,
		magicka_off = a.magicka_off, stamina_off = a.stamina_off, health_off = a.health_off,
		base_health = a.base_health, base_magicka = a.base_magicka, base_stamina = a.base_stamina,
		skills = a.skills, skill_offsets = a.skill_offsets, race = a.race, bounds = a.bounds, class = a.class,
		voice = a.voice, outfit = a.outfit, sleep_outfit = a.sleep_outfit, gift_filter = a.gift_filter,
		template = a.template, template_flags = a.template_flags, ai = a.ai, aggro = a.aggro,
		spells = forms(a.spells), perks = forms(a.perks), packages = forms(a.packages),
		default_packages = a.default_packages, overrides = override_packages(a.overrides),
		inventory = item_counts(a.inventory), factions = plugin.span(factions), crime_faction = a.crime_faction,
	}, true
}

@(private)
view_race :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Race, ok: bool) {
	r := db.races[form] or_return
	return {
		info = r.info, description = str(r.description), spells = forms(r.spells),
		skeletons = {str(r.skeletons[0]), str(r.skeletons[1])}, walk = r.walk, run = r.run, voices = r.voices,
	}, true
}

@(private)
view_class :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Class, ok: bool) {
	c := db.classes[form] or_return
	return {info = c.info, description = str(c.description)}, true
}

@(private)
view_faction :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Faction, ok: bool) {
	f := db.factions[form] or_return
	relations := make([]plugin.Faction_Relation, len(f.relations), context.temp_allocator)
	for r, i in f.relations {relations[i] = {r.faction, r.modifier, r.combat}}
	ranks := make([]plugin.Faction_Rank, len(f.ranks), context.temp_allocator)
	for r, i in f.ranks {ranks[i] = {r.index, str(r.male_title), str(r.female_title)}}
	return {
		flags = f.flags, relations = plugin.span(relations), ranks = plugin.span(ranks),
		crime = f.crime, has_crime = f.has_crime,
		vendor = {f.vendor.start, f.vendor.end, conditions(f.vendor.conditions)},
		jail = f.jail, follower_wait = f.follower_wait, stolen_chest = f.stolen_chest,
		player_chest = f.player_chest, crime_group = f.crime_group, jail_outfit = f.jail_outfit,
	}, true
}

@(private)
view_actor_value_info :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Actor_Value_Info, ok: bool) {
	a := db.actor_value_info[form] or_return
	return {
		index = a.index, has_index = a.has_index, editor_id = str(a.editor_id),
		description = str(a.description), skill = a.skill, has_skill = a.has_skill,
	}, true
}

@(private)
view_perk :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Perk, ok: bool) {
	p := db.perks[form] or_return
	entries := make([]plugin.Perk_Entry, len(p.entries), context.temp_allocator)
	for e, i in p.entries {
		tabs := make([]plugin.Perk_Tab, len(e.tabs), context.temp_allocator)
		for t, j in e.tabs {tabs[j] = {t.tab, conditions(t.conditions)}}
		entries[i] = {e.kind, e.rank, e.priority, e.form, e.stage, u8(e.point), u8(e.function), e.values, str(e.text), plugin.span(tabs)}
	}
	return {
		name = str(p.name), description = str(p.description), next_rank = p.next_rank,
		min_level = p.min_level, num_ranks = p.num_ranks, trait = p.trait, playable = p.playable, hidden = p.hidden,
		take_conditions = conditions(p.take_conditions), entries = plugin.span(entries),
	}, true
}

@(private)
view_perk_tree :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Perk_Tree, ok: bool) {
	tree := db.perk_trees[form] or_return
	nodes := make([]plugin.Perk_Node, len(tree), context.temp_allocator)
	for n, i in tree {nodes[i] = {n.perk, n.index, n.grid, n.pos, plugin.span(n.connections)}}
	return {nodes = plugin.span(nodes)}, true
}

@(private)
view_package :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Package, ok: bool) {
	p := db.packages[form] or_return
	inputs := make([]plugin.Package_Input, len(p.inputs), context.temp_allocator)
	for in_, i in p.inputs {inputs[i] = package_input(in_)}
	tree := make([]plugin.Package_Node, len(p.tree), context.temp_allocator)
	for n, i in p.tree {
		o, has_override := n.override.?
		tree[i] = {
			u8(n.branch), str(n.procedure), n.end, n.flags, n.success_completes, plugin.span(n.inputs),
			conditions(n.conditions), {o.set_flags, o.clear_flags, o.set_interrupt, o.clear_interrupt, u8(o.speed)}, has_override,
		}
	}
	s := p.schedule
	return {
		flags = p.flags, type = p.type, interrupt = u8(p.interrupt), speed = u8(p.speed), interrupt_flags = p.interrupt_flags,
		schedule = {s.month, s.day_of_week, s.date, s.hour, s.minute, s.duration},
		conditions = conditions(p.conditions), idle = {p.idle.flags, p.idle.timer, forms(p.idle.idles)},
		combat_style = p.combat_style, owner_quest = p.owner_quest, template = p.template,
		inputs = plugin.span(inputs), tree = plugin.span(tree),
	}, true
}

@(private = "file")
package_input :: proc(in_: gamedb.Package_Input) -> (out: plugin.Package_Input) {
	out.index = in_.index
	out.kind = u8(in_.kind)
	switch x in in_.value {
	case bool: out.bool_value = x
	case i32:  out.int_value = x
	case f32:  out.float_value = x
	case gamedb.Package_Location: out.location = {i32(x.kind), x.form, x.value, x.radius}
	case gamedb.Package_Target:   out.target = {i32(x.kind), x.form, x.value, x.count}
	case gamedb.Package_Topic:    out.topic = {x.topic, x.subtype}
	}
	return
}

@(private)
view_zone :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Zone, ok: bool) {
	z := db.zones[form] or_return
	return {location = z.location, min_level = z.min_level, max_level = z.max_level, flags = z.flags}, true
}

@(private)
view_equip_slot :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Equip_Slot, ok: bool) {
	e := db.equip_slots[form] or_return
	return {
		kind = u8(e.kind), biped = e.biped, etyp = e.etyp, weapon_type = e.weapon_type,
		enchantment = e.enchantment, damage = e.damage, projectile = e.projectile,
	}, true
}

@(private)
view_equip_type :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Equip_Type, ok: bool) {
	e := db.equip_types[form] or_return
	return {parents = forms(e.parents), use_all = e.use_all}, true
}

@(private)
view_movement :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Movement, ok: bool) {
	speed := db.movement[form] or_return
	return {speed = speed}, true
}
