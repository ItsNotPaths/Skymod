package formid

// Rules for the Form_ID space that more than one package reads: a Form_ID is slot << 32 | local.

Form_ID :: u64

// CREATED_SLOT is the high word of runtime-created forms (PlaceAtMe / spawn): no load order reaches
// it, so a created ref never collides with a plugin's, and it is the same on every install, so a save
// passes it through its remap untouched. Locals are handed out in sequence from CREATED_FORM_BASE.
CREATED_SLOT :: u32(0xFFFF_FFFF)
CREATED_FORM_BASE :: Form_ID(CREATED_SLOT) << 32

// An effect handle addresses one active magic effect (an effect on a target) as a form, so its
// script instance, registrations and saved members key like any other form's. High word
// EFFECT_SLOT, low word a counter. No load order reaches the slot, so a save passes it through.
EFFECT_SLOT :: u32(0x8000_0000)

effect_handle :: proc(n: u32) -> Form_ID {return Form_ID(EFFECT_SLOT) << 32 | Form_ID(n)}

is_effect :: proc(h: Form_ID) -> bool {return u32(h >> 32) == EFFECT_SLOT}

// A script faction is a faction a script made (rt.faction): high word SCRIPT_FACTION_SLOT, low word
// a counter. No load order reaches the slot, so a save passes it through.
SCRIPT_FACTION_SLOT :: u32(0x8000_0001)

script_faction :: proc(n: u32) -> Form_ID {return Form_ID(SCRIPT_FACTION_SLOT) << 32 | Form_ID(n)}

is_script_faction :: proc(f: Form_ID) -> bool {return u32(f >> 32) == SCRIPT_FACTION_SLOT}

// A Lua form is one that content defines by name with no record behind it (rt.effect, rt.spell):
// high word LUA_FORM_SLOT, low word a hash of its kind and lower-cased name, so it is the same in
// every session and install and a save passes it through.
LUA_FORM_SLOT :: u32(0x8000_0003)

lua_form :: proc(kind, name: string) -> Form_ID {
	h := u32(2166136261) // FNV-1a over "kind/name", so an effect and a spell may share a name
	for part in ([]string{kind, "/", name}) {
		for c in transmute([]u8)part {
			h = (h ~ u32(c | 0x20 if c >= 'A' && c <= 'Z' else c)) * 16777619
		}
	}
	return Form_ID(LUA_FORM_SLOT) << 32 | Form_ID(h)
}

is_lua_form :: proc(f: Form_ID) -> bool {return u32(f >> 32) == LUA_FORM_SLOT}

// START_CHARACTER is the character a new game gives the player to control (base PLAYER_BASE). The
// engine makes it, no plugin holds it, and no load order reaches its slot.
START_CHARACTER :: Form_ID(0x8000_0002) << 32 | 1

// An alias handle addresses one quest alias as a form, so its scripts, registrations and filters key
// like any other form's. High word ALIAS_TAG | alias id << 16 | the quest's slot, low word the quest's
// local id: the slot stays where a save's remap finds it.
ALIAS_TAG :: u32(0x4000_0000)

alias_handle :: proc(quest: Form_ID, id: u32) -> (Form_ID, bool) {
	slot := u32(quest >> 32)
	if slot > 0xFFFF || id > 0x3FFF {return 0, false}
	return Form_ID(ALIAS_TAG | id << 16 | slot) << 32 | (quest & 0xFFFF_FFFF), true
}

// alias_key splits an alias handle into its quest and alias id; ok=false for any other form.
alias_key :: proc(h: Form_ID) -> (quest: Form_ID, id: u32, ok: bool) {
	hi := u32(h >> 32)
	if hi & 0xC000_0000 != ALIAS_TAG {return}
	return Form_ID(hi & 0xFFFF) << 32 | (h & 0xFFFF_FFFF), (hi >> 16) & 0x3FFF, true
}
