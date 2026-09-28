package plugin

// Record views: a plugin reads the engine's decoded game data through World.record, one view per
// record type, with templates followed, mod overrides merged and form IDs remapped. Every view
// starts with a Header. The plugin sets its size to the view as it was built against; the host
// fills that many bytes, so views grow at the end without breaking older plugins. Fields are only
// ever appended, never removed or reordered. Spans point into engine memory, are valid until the
// end of the tick, and are never written through.

import "../formats/esm"

Record_Kind :: enum u16 {
	Form, // any form: its kind, name, model, value, weight, bounds and keywords
	Spell, // SPEL, SCRL
	Magic_Effect, // MGEF
	// actors (records_actors.odin)
	Actor_Base, // NPC_
	Race,
	Class,
	Faction,
	Actor_Value_Info, // AVIF
	Perk,
	Perk_Tree, // a skill AVIF's perk constellation
	Package, // PACK
	Zone, // ECZN
	Equip_Slot, // where an ARMO, WEAP, SPEL... equips, and a weapon's or ammo's damage
	Equip_Type, // EQUP
	Movement, // MOVT
	// items (records_items.odin)
	Enchantment,
	Potion, // ALCH
	Ingredient, // INGR
	Projectile, // PROJ
	Book,
	Recipe, // COBJ
	Leveled_List, // LVLI
	Container, // CONT: its baseline inventory
	Outfit, // OTFT
	Form_List, // FLST
	// world (records_world.odin)
	Cell,
	Location, // LCTN
	Worldspace, // WRLD
	Weather, // WTHR
	Placed_Ref, // REFR, ACHR: the placement as the plugins author it
	Lock, // a ref's XLOC baseline lock
	Trigger, // a ref's XPRM volume
	Linked_Refs, // a ref's XLKR links
	Form_Scripts, // a form's VMAD scripts and properties
	// quests, dialogue and audio (records_quests.odin)
	Quest, // QUST baseline
	Story_Node, // SMBN, SMQN, SMEN
	Topic, // DIAL
	Branch, // DLBR
	Info, // INFO
	Scene, // SCEN
	Message, // MESG
	Sound, // SNDR
	Sound_Category, // SNCT
	Sound_Output, // SOPM
	Music_Type, // MUSC
	Music_Track, // MUST
	Base_Sounds, // a DOOR, CONT, ACTI, FLOR or item base's use and done sounds
	Acoustic_Space, // ASPC: its ambient loop
}

Header :: struct {
	size: u32, // the view's size as the plugin knows it (record sets it)
}

// record fills `out` with the record of `form`; false when the form has no record of that kind.
record :: proc "contextless" (w: ^World, form: Form_ID, kind: Record_Kind, out: ^$T) -> bool {
	out.size = u32(size_of(T))
	return w.record(w.data, form, kind, out)
}

// Condition is one CTDA.
Condition :: struct {
	function:  u16,
	op:        esm.Condition_Op,
	flags:     esm.Condition_Flags,
	value:     f32,
	global:    Form_ID, // the GLOB the comparison reads, when Use_Global
	param1:    u64, // a Form_ID when the function's parameter is a form, otherwise the raw number
	param2:    u64,
	run_on:    esm.Condition_Run_On,
	reference: Form_ID, // set only when run_on is Reference
	param3:    i32, // the alias or event member; -1 = none
	text:      Span(u8), // a String parameter
}

// Effect_Item is one effect of a spell, enchantment, potion or ingredient.
Effect_Item :: struct {
	effect:     Form_ID, // its MGEF
	magnitude:  f32,
	area:       u32,
	duration:   u32,
	conditions: Span(Condition),
}

// Item_Count is one item and how many: a container line, a recipe ingredient, an inventory entry.
Item_Count :: struct {
	item:  Form_ID,
	count: i32,
}

// Override_Packages are an actor's or alias's override package lists (FLSTs).
Override_Packages :: struct {
	combat:     Form_ID, // ECOR
	spectator:  Form_ID, // SPOR
	corpse:     Form_ID, // OCOR
	guard_warn: Form_ID, // GWOR
}

Form :: struct {
	using header: Header,
	kind:         u8, // the form's Papyrus class, as kind_name spells it
	kind_name:    Span(u8), // "Weapon", "Spell", "ActorBase"...; "Unknown" for a ref or other form
	name:         Span(u8), // FULL
	model:        Span(u8), // its mesh path
	value:        i32, // gold; 0 = not a valued item
	weight:       f32,
	bounds:       [2][3]f32, // OBND at scale 1
	keywords:     Span(Form_ID),
}

Spell :: struct {
	using header:   Header,
	info:           esm.Spell_Info,
	half_cost_perk: Form_ID,
	scroll:         bool,
	effects:        Span(Effect_Item),
}

Magic_Effect :: struct {
	using header: Header,
	info:         esm.Magic_Effect_Info,
	projectile:   Form_ID,
	explosion:    Form_ID,
	related:      Form_ID,
	sounds:       [6]Form_ID, // sheathe/draw, charge, ready, release, cast loop, on hit
	description:  Span(u8),
	conditions:   Span(Condition),
}
