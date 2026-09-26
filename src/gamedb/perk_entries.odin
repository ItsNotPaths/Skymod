package gamedb

// Perk entries: what a perk does (UESP Mod File Format/PERK). A quest entry sets a stage when the
// perk is taken, an ability entry gives a spell, and an entry point changes a value the engine asks
// for (worldstate/perk_values.odin).

import "core:strings"
import "../formats/esm"

// Entry_Point is a perk entry point id (UESP; the base game uses 66 of the 91).
Entry_Point :: enum u8 {
	Calculate_Weapon_Damage, Calculate_My_Critical_Hit_Chance, Calculate_My_Critical_Hit_Damage,
	Calculate_Mine_Explode_Chance, Adjust_Limb_Damage, Adjust_Book_Skill_Points, Mod_Recovered_Health,
	Get_Should_Attack, Mod_Buy_Prices, Add_Leveled_List_On_Death, Get_Max_Carry_Weight,
	Mod_Addiction_Chance, Mod_Positive_Chem_Duration, Mod_Positive_Chem_Duration_2, Activate,
	Ignore_Running_During_Detection, Ignore_Broken_Lock, Mod_Enemy_Critical_Hit_Chance,
	Mod_Sneak_Attack_Mult, Mod_Max_Placeable_Mines, Mod_Bow_Zoom, Mod_Recover_Arrow_Chance,
	Mod_Skill_Use, Mod_Telekinesis_Distance, Mod_Telekinesis_Damage_Mult, Mod_Telekinesis_Damage,
	Mod_Bashing_Damage, Mod_Power_Attack_Stamina, Mod_Power_Attack_Damage, Mod_Spell_Magnitude,
	Mod_Spell_Duration, Mod_Secondary_Value_Weight, Mod_Armor_Weight, Mod_Incoming_Stagger,
	Mod_Target_Stagger, Mod_Attack_Damage, Mod_Incoming_Damage, Mod_Target_Damage_Resistance,
	Mod_Spell_Cost, Mod_Percent_Blocked, Mod_Shield_Deflect_Arrow_Chance,
	Mod_Incoming_Spell_Magnitude, Mod_Incoming_Spell_Duration, Mod_Player_Intimidation,
	Mod_Player_Reputation, Mod_Favor_Points, Mod_Bribe_Amount, Mod_Detection_Light,
	Mod_Detection_Movement, Mod_Soul_Gem_Recharge, Set_Sweep_Attack, Apply_Combat_Hit_Spell,
	Apply_Bashing_Spell, Apply_Reanimate_Spell, Set_Boolean_Graph_Variable,
	Mod_Spell_Casting_Sound_Event, Mod_Pickpocket_Chance, Mod_Detection_Sneak_Skill,
	Mod_Falling_Damage, Mod_Lockpick_Sweet_Spot, Mod_Sell_Prices, Can_Pickpocket_Equipped_Item,
	Mod_Lockpick_Level_Allowed, Set_Lockpick_Start_Position, Set_Progression_Picking,
	Make_Lockpicks_Unbreakable, Mod_Alchemy_Effectiveness, Apply_Weapon_Swing_Spell,
	Mod_Commanded_Actor_Limit, Apply_Sneaking_Spell, Mod_Player_Magic_Slowdown,
	Mod_Ward_Magic_Absorption_Percent, Mod_Ingredient_Effects_Learned, Purify_Alchemy_Ingredients,
	Filter_Activation, Can_Dual_Cast_Spell, Mod_Tempering_Health, Mod_Enchantment_Power,
	Mod_Soul_Percent_Captured_To_Weapon, Mod_Soul_Gem_Enchanting, Mod_Number_Of_Enchantments_Allowed,
	Set_Activate_Label, Mod_Shout_OK, Mod_Poison_Dose_Count, Should_Apply_Placed_Item,
	Mod_Armor_Rating, Mod_Lockpick_Crime_Chance, Mod_Ingredients_Harvested,
	Mod_Spell_Range_To_Location, Mod_Potions_Created, Mod_Lockpick_Key_Reward_Chance,
}

// Perk_Function is how an entry point entry changes its value (UESP).
Perk_Function :: enum u8 {
	None, Set_Value, Add_Value, Multiply_Value, Add_Range_To_Value, Add_AV_Mult, Absolute_Value,
	Negative_Absolute_Value, Add_Leveled_List, Add_Activate_Choice, Select_Spell, Select_Text,
	Set_AV_Mult, Multiply_AV_Mult, Multiply_1_Plus_AV_Mult, Set_Text,
}

Perk_Entry :: struct {
	kind:           esm.Perk_Entry_Kind,
	rank, priority: u8,
	form:           Form_ID, // Quest: the quest. Ability: the spell. Entry point: its LVLI or SPEL
	stage:          u8,
	point:          Entry_Point,
	function:       Perk_Function,
	values:         [2]f32, // EPFT 1: the value; EPFT 2: an AV index and its factor
	text:           string, // owned: a GMST editor id, a text, or an activate label
	tabs:           []Perk_Tab, // owned
}

// Perk_Tab is one condition tab of an entry: `tab` picks the object its conditions run on (0 is
// the perk's owner; the rest depend on the entry point).
Perk_Tab :: struct {
	tab:        u8,
	conditions: []Condition, // owned
}

// (hole perk-template :tags (player records) :sev polish) a templated NPC_'s perks follow its spell-list template (Use Spell List); which template flag carries PRKR is unsourced: no page says, and the CK keeps stale PRKR under either flag, so the data cannot tell (measured 2026-09-26: 484 of 723 Use Spell List NPC_ with a template still carry PRKR).
// record_perks is an NPC_'s PRKR perks, through its spell-list template.
record_perks :: proc(db: ^DB, form: Form_ID, pick: Form_ID = 0) -> []Form_ID {
	if db == nil {return nil}
	base := form
	if r, ok := db.ref_by_id[form]; ok {base = r.base}
	return template_part(db, base, esm.ACBS_TEMPLATE_SPELLS, pick).perks
}

@(private)
index_perk_entries :: proc(db: ^DB, fl: []esm.Field, fm: ^esm.Form_Map) -> []Perk_Entry {
	raw := esm.perk_entries(fl, context.temp_allocator)
	if len(raw) == 0 {return nil}
	out := make([]Perk_Entry, len(raw), db.allocator)
	for r, i in raw {
		e := Perk_Entry {
			kind     = r.kind,
			rank     = r.rank,
			priority = r.priority,
			stage    = r.stage,
			point    = Entry_Point(r.point),
			function = Perk_Function(r.function),
			values   = r.values,
		}
		if r.form != 0 {e.form = esm.remap_form(fm, r.form)}
		if r.has_text {
			text := esm.cstr(r.text.data) if r.param_type == 6 else resolve_lstring(db, r.text, db.cur_strings)
			e.text = strings.clone(text, db.allocator)
		}
		tabs := make([]Perk_Tab, len(r.tabs), db.allocator)
		for t, j in r.tabs {tabs[j] = {t.tab, index_conditions(db, t.fields, fm)}}
		e.tabs = tabs
		out[i] = e
	}
	return out
}

@(private)
free_perk_entries :: proc(db: ^DB, entries: []Perk_Entry) {
	for e in entries {
		delete(e.text, db.allocator)
		for t in e.tabs {free_conditions(db, t.conditions)}
		delete(e.tabs, db.allocator)
	}
	delete(entries, db.allocator)
}
