package magictranslate

// PERK records to Lua: what a perk does becomes rt.hook functions gated on its rank
// (actor.av.<Perk>.value), one hook kind per engine moment (ws.md Order step 2).

// (hole perk-translator :tags (combat records player) :sev gap) no PERK becomes Lua. Wanted: the damage entries as hook parts (Calculate_Weapon_Damage, Mod_Attack_Damage, Mod_Incoming_Damage to hit's damage; Mod_Target_Damage_Resistance to armor_pen; Mod_Armor_Rating to armor's rating; crit, sneak, power and bash when those parts exist), each gated on the owner's rank, its tabs as Lua (gate_lua; tab 0 the owner, then the entry point's args); Set, Add, Multiply and 1 + AV x k to set, add and mult. Open: where the hooks register (a perks/ content folder loaded like effects/, or a start script). Measured: build/out/wsK/perkshape.py (847 entries, 68 points), dmgperks.py.
// (hole perk-translate :tags (magic records player) :sev gap :needs (magic-translate perk-translator)) the 607 magic perk entry points are not translated: each becomes Lua in a landing or cost hook (Multiply, Add, Set and `1 + AV * k` are plain code, entry priority is hook order), Apply_Combat_Hit_Spell and Select_Spell become event scripts. Measure first which fit (build/out/wsM/edges.md section 1).
// perk_lua is the Lua for one perk's hooks; "" when it has none.
@(private)
perk_lua :: proc(src: ^Source, form: Form_ID) -> (text: string, ok: bool) {
	return "", true
}
