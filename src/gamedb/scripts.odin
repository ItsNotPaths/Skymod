package gamedb

// Which scripts a form carries — the index over esm VMAD (src/formats/esm/records_scripts.odin).
// This is the link that makes a transpiled Papyrus script reachable: the record says a form runs
// `TrapBearScript`, and the runtime loads the file of that name.
//
// Indexed for the record types that carry scripts AND have something to dispatch on. PACK carries
// plenty but AI packages do not exist yet, so indexing it would only hold memory. `esmdump --vmad`
// still surveys it.

import "base:runtime"
import "core:strings"
import "../formats/esm"

// carries_scripts reports whether a record signature is one we index VMAD for. Measured over
// Skyrim.esm, the DLC and 1,326 mod plugins: 22 signatures carry a VMAD at all, and these are the
// ones whose forms something can dispatch to today.
carries_scripts :: proc(s: string) -> bool {
	switch s {
	case "REFR", "ACHR", "QUST", "NPC_", "MGEF", "PERK", "PHZD", "TACT", "INFO", "SCEN":
		return true
	}
	return is_base_type(s) // ACTI, CONT, DOOR, FURN, MISC, WEAP, ARMO, BOOK, KEYM, FLOR, INGR, LIGH …
}

// index_scripts records a form's VMAD. A later plugin overriding the record replaces the WHOLE
// attachment list rather than merging into it, because the Creation Kit rewrites the full list on
// every override and marks what it dropped (see esm.Script_Attach status).
@(private)
index_scripts :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	fs, decoded := esm.decode_vmad(rec.type, fl, fm, db.allocator)
	if !decoded {
		return // no VMAD, or a malformed one — decode_vmad leaves nothing to free
	}
	if old, had := db.form_scripts[rec.form_id]; had {
		esm.free_form_scripts(old, db.allocator)
	}
	db.form_scripts[rec.form_id] = fs
}

// form_scripts returns the scripts attached to one form exactly as its own record declares them,
// with no base-form inheritance applied. For a placed reference use effective_scripts instead.
form_scripts :: proc(db: ^DB, form: Form_ID) -> []esm.Script_Attach {
	if db == nil {
		return nil
	}
	return db.form_scripts[form].scripts
}

// (hole leveled-template-scripts :tags (script mods) :sev polish) a Use Script chain through a leveled list takes the pick's scripts only when the pick was rolled before the ref's scripts attached; a persistent actor attaches at game start, before its roll. No vanilla, DLC or CC pick carries scripts (3,887 NPC_ entries under the 223 lists such chains reach).
// base_scripts are the scripts a ref of `base` inherits: its own, and for an NPC_ with Use Script
// its template's too (through `pick` at a leveled list); its own win a name both carry. The union
// is unsourced: 136 vanilla NPC_s with Use Script carry scripts their template lacks
// (DLC2MiraakScript on Miraak), so own scripts stay.
base_scripts :: proc(db: ^DB, base: Form_ID, pick: Form_ID = 0, allocator := context.temp_allocator) -> []esm.Script_Attach {
	own := form_scripts(db, base)
	from := template_form(db, base, esm.ACBS_TEMPLATE_SCRIPT, pick)
	if from == base {return own}
	out := make([dynamic]esm.Script_Attach, 0, len(own), allocator)
	append(&out, ..own)
	for a in form_scripts(db, from) {
		if !attach_named(own, a.name) {append(&out, a)}
	}
	return out[:]
}

// form_fragments returns a form's compiler-generated fragments — a quest's stage snippets, a
// perk entry's — and the generated script file they live on. Empty for everything else.
form_fragments :: proc(db: ^DB, form: Form_ID) -> (file: string, fragments: []esm.Script_Fragment) {
	if db == nil {
		return "", nil
	}
	fs := db.form_scripts[form]
	return fs.frag_file, fs.fragments
}

// quest_alias_scripts returns the scripts a quest attaches to one of its aliases, addressed by the
// alias id the quest's own records use. Vanilla hangs most behaviour here rather than on base
// forms — 2,529 alias scripts in Skyrim.esm alone.
quest_alias_scripts :: proc(db: ^DB, quest: Form_ID, alias: i16) -> []esm.Script_Attach {
	if db == nil {
		return nil
	}
	for a in (db.form_scripts[quest] or_else {}).aliases {
		if a.owner.alias == alias {
			return a.scripts
		}
	}
	return nil
}

// effective_scripts resolves what a PLACED REFERENCE actually runs: its base form's scripts, plus
// the ones the reference declares itself, minus any the reference marks removed. A script both
// carry takes the base's property values with the ref's on top: an "inherited and modified"
// attachment lists only the properties it changes (DLC1VQ06ReadingTriggerScript: base 20, ref 1).
//
// Names fold case, because Papyrus identifiers do. The result, and any merged property list, is
// allocated with `allocator`; the other Script_Attach values stay owned by the DB.
effective_scripts :: proc(
	db: ^DB,
	ref: Form_ID,
	base: Form_ID,
	allocator := context.allocator,
	pick: Form_ID = 0,
) -> []esm.Script_Attach {
	if db == nil {
		return nil
	}
	own := db.form_scripts[ref].scripts
	inherited := base_scripts(db, base, pick, allocator)
	if len(own) == 0 {
		return clone_attachments(inherited, allocator) // nothing to override or remove
	}

	out := make([dynamic]esm.Script_Attach, 0, len(own) + len(inherited), allocator)
	for a in own {
		if esm.script_attach_removed(a) {continue}
		merged := a
		if base, ok := attach_find(inherited, a.name); ok {merged.props = merge_props(base.props, a.props, allocator)}
		append(&out, merged)
	}
	for a in inherited {
		if !attach_named(own, a.name) {
			append(&out, a) // the reference says nothing about this one, so it inherits
		}
	}
	return out[:]
}

@(private)
clone_attachments :: proc(list: []esm.Script_Attach, allocator: runtime.Allocator) -> []esm.Script_Attach {
	if len(list) == 0 {
		return nil
	}
	out := make([]esm.Script_Attach, len(list), allocator)
	copy(out, list)
	return out
}

@(private)
attach_named :: proc(list: []esm.Script_Attach, name: string) -> bool {
	_, ok := attach_find(list, name)
	return ok
}

@(private)
attach_find :: proc(list: []esm.Script_Attach, name: string) -> (esm.Script_Attach, bool) {
	for a in list {
		if strings.equal_fold(a.name, name) {
			return a, true
		}
	}
	return {}, false
}

// merge_props is `base` with each property `top` also sets replaced by top's value, plus top's own.
@(private)
merge_props :: proc(base, top: []esm.Script_Prop, allocator: runtime.Allocator) -> []esm.Script_Prop {
	out := make([dynamic]esm.Script_Prop, 0, len(base) + len(top), allocator)
	for p in base {
		if !prop_named(top, p.name) {append(&out, p)}
	}
	append(&out, ..top)
	return out[:]
}

@(private)
prop_named :: proc(list: []esm.Script_Prop, name: string) -> bool {
	for p in list {
		if strings.equal_fold(p.name, name) {return true}
	}
	return false
}

// archetype_class is the class that plays an archetype's moment: a script in the core scripts mod
// (src/script/effects), which a mod replaces like any script. "" for one no class plays: the
// numeric and status archetypes are formulas the translator writes into each effect.
// (hole visual-archetypes :tags (magic vfx unclaimed) :sev gap) Light, Detect Life, Night Eye and Guide do nothing: they are art (a light, a shader, a trail).
// (hole slow-time :tags (magic unclaimed) :sev gap) Slow Time does nothing: the sim has no time scale for the world around the player.
// (hole telekinesis :tags (magic physics unclaimed) :sev gap) Telekinesis and Grab Actor do nothing: nothing holds a body or an actor in front of the caster.
archetype_class :: proc(a: esm.Effect_Archetype) -> string {
	#partial switch a {
	case .Value_Modifier:      return "archetypevaluemodifier"
	case .Peak_Value_Modifier: return "archetypepeakvaluemodifier"
	case .Dual_Value_Modifier: return "archetypedualvaluemodifier"
	case .Absorb:              return "archetypeabsorb"
	case .Spawn_Hazard:        return "archetypespawnhazard"
	case .Summon_Creature:     return "archetypesummoncreature"
	case .Reanimate:           return "archetypereanimate"
	case .Command_Summoned:    return "archetypecommandsummoned"
	case .Banish:              return "archetypebanish"
	case .Bound_Weapon:        return "archetypeboundweapon"
	case .Cloak:               return "archetypecloak"
	case .Stagger:             return "archetypestagger"
	case .Disarm:              return "archetypedisarm"
	case .Etherealize:         return "archetypeetherealize"
	case .Soul_Trap:           return "archetypesoultrap"
	case .Cure_Disease:        return "archetypecuredisease"
	case .Cure_Poison:         return "archetypecurepoison"
	}
	return ""
}
