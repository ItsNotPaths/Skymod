package magictranslate

// Magic records to Lua: SPEL, SCRL, ENCH, ALCH, INGR, SHOU, MGEF, HAZD and the magic perk entry
// points become rt.spell, rt.effect and zone calls, one file per record named by its editor ID,
// with form references as "Plugin.esm:012FCD" (ws.md Workstream M). The installer runs it once over
// the base game; tools/magic2lua runs it for a mod, which then ships the Lua. The runtime never reads
// magic records.

Stats :: struct {
	spells, effects: int,
}

// translate reads the winning version of each magic record over `plugins` (load order, in
// `data_dir`) and writes the ones that a plugin in `only` defines or overrides (all when empty)
// into `out_dir`.
// (hole magic-translate :tags (magic records) :sev gap :needs (spell-shapes other-archetypes)) nothing is translated, at install or by tools/magic2lua. Wanted: castable SPEL and ENCH as rt.spell, powers and SHOU as rt.power, SCRL, ALCH and INGR as rt.item (hand for scrolls, inventory for the rest, the ALCH poison flag as a poison tag), abilities as effects given with ApplyEffect (one effect per ability family, its stage or strength as m: vampirism, not AbVampire01..04), the vanilla scripts that AddSpell them patched to match (use from spell type and cast type; GetLevel tier copies dropped, shape from PROJ, EXPL and area in feet, `hits = "direct"` for area 0 entries), MGEF as rt.effect files in effects/ (archetype to formula or wrapper script, Recover to capacity or amount, taper, CTDA to `when`, Power Affects Duration to `d = "m"`-style landing, spell-side CTDAs to a moment script that calls SetActive each second, Peak Value Modifier keywords to nostack groups, No Recast to `stack = "keep"`), HAZD and rune projectiles as zones; each keeps its form ID, keywords and VMAD scripts.
// (hole magic-tags-derive :tags (magic records) :sev gap :needs (magic-translate)) the translator must write tags on purpose: kw.<editor id> for each keyword, an element tag from the resist AV too (80 of 88 fire effects agree; 48 poison effects have no keyword), school and tier from the MGEF skill and perk, a `status` tag on lasting harmful effects (burns, slows, drains), and role tags for the combat brain (hostile, restore, summon).
// (hole perk-translate :tags (magic records player) :sev gap :needs (magic-translate)) the 607 magic perk entry points are not translated: each becomes Lua in a landing or cost hook (Multiply, Add, Set and `1 + AV * k` are plain code, entry priority is hook order), Apply_Combat_Hit_Spell and Select_Spell become event scripts. Measure first which fit (build/out/wsM/edges.md section 1).
// (hole rider-rules :tags magic :sev gap :needs (magic-translate)) perk riders (93 MGEFs: Intense Flames, Deep Freeze, Disintegrate, Impact) are copied into spells unevenly: none on scrolls, staffs, weapon enchantments or runes, and 34 test the player ref. Wanted: each rider stays an entry of the items that carry it (a spell names all its effects), with its per-spell values (Impact 0.05/0.25/0.5), its perk gate in the rider effect's land; decide per item whether scrolls, staves and runes get the entries vanilla forgot.
translate :: proc(data_dir: string, plugins, only: []string, out_dir: string) -> (st: Stats, ok: bool) {
	return {}, true
}
