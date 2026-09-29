package magic

// Magic landing: what a spell does to each actor it reaches. This is a seam (ws.md Workstream M):
// the on-hit stage runs once per spell and target (absorption, ward, reflection) and may stop the
// whole spell; then each effect's numbers go through the scales that match its tags, in phases
// (base, add, mul, set). A plugin replaces entries of Table.

import "../plugin"

Form_ID :: plugin.Form_ID

SEAM :: "skymod_magic"
VERSION :: u32(1)

// Hit is one spell reaching one actor.
Hit :: struct {
	spell, caster, target: Form_ID,
	direct:                bool, // the shape struck it; false = only its area reached it
}

// Verdict is what the on-hit stage makes of a hit.
Verdict :: enum u8 {
	Lands,
	Absorbed, // nothing lands; the target gains the spell's cost as Magicka
	Warded,
	Reflected,
}

// Numbers are an effect's tunables as it lands: m its power, d its duration in seconds.
Numbers :: struct {
	m, d: f32,
}

// Host is what the engine answers.
Host :: struct {
	world: ^plugin.World, // a pointer, so World grows without moving this Host's fields
}

Table :: struct {
	on_hit: proc "c" (h: ^Host, hit: Hit) -> Verdict,
	scale:  proc "c" (h: ^Host, hit: Hit, effect: Form_ID, n: Numbers) -> Numbers,
}

BUILTIN :: Table{on_hit_builtin, scale_builtin}

// (hole spell-absorption :tags magic :sev gap) Spell Absorption (AbsorbChance, rolled first, once per spell; the spell is nullified and its cost restores the target's Magicka; not for self-delivered spells) is not rolled.
// (hole wards :tags magic :sev gap) a ward blocks nothing: WardPower does not absorb a hostile spell, no ward breaks, and Mod_Ward_Magic_Absorption_Percent is unread.
@(private = "file")
on_hit_builtin :: proc "c" (h: ^Host, hit: Hit) -> Verdict {
	return .Lands
}

// (hole effect-scales :tags magic :sev gap :needs (av-scales)) no scale reaches an effect here: its m and d should go through every AV scale whose tags match, in phases base, add, mul, set (mul multiplies, so 50% magic and 50% fire leave 25%). Resistance and perks are still code in worldstate.resisted and script.perk_value.
@(private = "file")
scale_builtin :: proc "c" (h: ^Host, hit: Hit, effect: Form_ID, n: Numbers) -> Numbers {
	return n
}
