package worldhost

// The engine's record views (plugin/records.odin), from gamedb. A view_* proc builds one view;
// nested lists are copied into the tick's temp memory, strings and form lists point into gamedb.

import "core:mem"
import "core:reflect"
import "../gamedb"
import "../plugin"

@(private)
record :: proc "c" (data: rawptr, form: Form_ID, kind: plugin.Record_Kind, out: rawptr) -> bool {
	d := (^Data)(data)
	context = d.ctx
	db := d.db
	switch kind {
	case .Form:             return put(out, view_form(db, form))
	case .Spell:            return put(out, view_spell(db, form))
	case .Magic_Effect:     return put(out, view_magic_effect(db, form))
	case .Actor_Base:       return put(out, view_actor_base(db, form))
	case .Race:             return put(out, view_race(db, form))
	case .Class:            return put(out, view_class(db, form))
	case .Faction:          return put(out, view_faction(db, form))
	case .Actor_Value_Info: return put(out, view_actor_value_info(db, form))
	case .Perk:             return put(out, view_perk(db, form))
	case .Perk_Tree:        return put(out, view_perk_tree(db, form))
	case .Package:          return put(out, view_package(db, form))
	case .Zone:             return put(out, view_zone(db, form))
	case .Equip_Slot:       return put(out, view_equip_slot(db, form))
	case .Equip_Type:       return put(out, view_equip_type(db, form))
	case .Movement:         return put(out, view_movement(db, form))
	case .Enchantment:      return put(out, view_enchantment(db, form))
	case .Potion:           return put(out, view_potion(db, form))
	case .Ingredient:       return put(out, view_ingredient(db, form))
	case .Projectile:       return put(out, view_projectile(db, form))
	case .Book:             return put(out, view_book(db, form))
	case .Recipe:           return put(out, view_recipe(db, form))
	case .Leveled_List:     return put(out, view_leveled_list(db, form))
	case .Container:        return put(out, view_container(db, form))
	case .Outfit:           return put(out, view_outfit(db, form))
	case .Form_List:        return put(out, view_form_list(db, form))
	case .Cell:             return put(out, view_cell(db, form))
	case .Location:         return put(out, view_location(db, form))
	case .Worldspace:       return put(out, view_worldspace(db, form))
	case .Weather:          return put(out, view_weather(db, form))
	case .Placed_Ref:       return put(out, view_placed_ref(db, form))
	case .Lock:             return put(out, view_lock(db, form))
	case .Trigger:          return put(out, view_trigger(db, form))
	case .Linked_Refs:      return put(out, view_linked_refs(db, form))
	case .Form_Scripts:     return put(out, view_form_scripts(db, form))
	case .Quest:            return put(out, view_quest(db, form))
	case .Story_Node:       return put(out, view_story_node(db, form))
	case .Topic:            return put(out, view_topic(db, form))
	case .Branch:           return put(out, view_branch(db, form))
	case .Info:             return put(out, view_info(db, form))
	case .Scene:            return put(out, view_scene(db, form))
	case .Message:          return put(out, view_message(db, form))
	case .Sound:            return put(out, view_sound(db, form))
	case .Sound_Category:   return put(out, view_sound_category(db, form))
	case .Sound_Output:     return put(out, view_sound_output(db, form))
	case .Music_Type:       return put(out, view_music_type(db, form))
	case .Music_Track:      return put(out, view_music_track(db, form))
	case .Base_Sounds:      return put(out, view_base_sounds(db, form))
	case .Acoustic_Space:   return put(out, view_acoustic_space(db, form))
	}
	return false
}

// put copies as much of the view as the plugin's `out` holds, its header saying how much.
@(private = "file")
put :: proc(out: rawptr, v: $T, ok: bool) -> bool {
	if !ok {return false}
	v := v
	want := (^plugin.Header)(out).size
	n := min(int(want), size_of(T))
	mem.copy(out, &v, n)
	(^plugin.Header)(out).size = u32(n)
	return true
}

// str, forms and items hand gamedb's memory over as spans; conditions and effects copy.
@(private)
str :: proc(s: string) -> plugin.Span(u8) {
	return plugin.span(transmute([]u8)s)
}

@(private)
forms :: proc(ids: []Form_ID) -> plugin.Span(Form_ID) {
	return plugin.span(ids)
}

@(private)
conditions :: proc(cs: []gamedb.Condition) -> plugin.Span(plugin.Condition) {
	out := make([]plugin.Condition, len(cs), context.temp_allocator)
	for c, i in cs {out[i] = {c.function, c.op, c.flags, c.value, c.global, c.param1, c.param2, c.run_on, c.reference, c.param3, str(c.text)}}
	return plugin.span(out)
}

@(private)
effects :: proc(es: []gamedb.Magic_Effect_Ref) -> plugin.Span(plugin.Effect_Item) {
	out := make([]plugin.Effect_Item, len(es), context.temp_allocator)
	for e, i in es {out[i] = {e.effect, e.magnitude, e.area, u32(e.duration), conditions(e.conditions)}}
	return plugin.span(out)
}

@(private)
item_counts :: proc(es: []gamedb.Content_Entry) -> plugin.Span(plugin.Item_Count) {
	out := make([]plugin.Item_Count, len(es), context.temp_allocator)
	for e, i in es {out[i] = {e.item, e.count}}
	return plugin.span(out)
}

@(private)
override_packages :: proc(o: gamedb.Override_Packages) -> plugin.Override_Packages {
	return {o.combat, o.spectator, o.corpse, o.guard_warn}
}

@(private = "file")
view_form :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Form, ok: bool) {
	kind := db.form_kinds[form]
	v.kind = u8(kind)
	v.kind_name = str(reflect.enum_string(kind))
	v.name = str(gamedb.name_of(db, form))
	model, _ := gamedb.model_of(db, form)
	v.model = str(model)
	v.value = db.base_value[form]
	v.weight = db.base_weight[form]
	v.bounds = db.base_box[form]
	v.keywords = forms(gamedb.keywords_of(db, form))
	return v, true
}

@(private = "file")
view_spell :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Spell, ok: bool) {
	s := db.spells[form] or_return
	return {info = s.info, half_cost_perk = s.half_cost_perk, scroll = s.scroll, effects = effects(s.effects)}, true
}

@(private = "file")
view_magic_effect :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Magic_Effect, ok: bool) {
	e := db.magic_effects[form] or_return
	v = {info = e.info, projectile = e.projectile, explosion = e.explosion, related = e.related, description = str(e.description), conditions = conditions(e.conditions)}
	for id, i in e.sounds {v.sounds[i] = id}
	return v, true
}
