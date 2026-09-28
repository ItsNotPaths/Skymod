package formid

// Skyrim.esm forms the engine names directly. Skyrim.esm is slot 0, so the Form_ID is its local id.

// PLAYER (PlayerRef) is not one actor: it means the actor the player controls, ws.player.
// worldstate.resolve turns it into that actor's real ref where a record or script value enters the engine.
// (hole playerref-lua-keys :tags (player script) :sev gap) Lua `==` resolves PlayerRef, but a Lua table keyed by ref holds ref(0x14) and the controlled actor's own ref as two keys. Wanted: a transpiler guard that keys refs by their resolved form.
// (hole playerref-stored-by-natives :tags (player script) :sev gap) script.call resolves every form argument, so ForceRefTo(Game.GetPlayer()) and other storing natives keep the actor controlled at that moment, not PlayerRef. Wanted: storing natives keep 0x14 so the stored value follows a takeover.
PLAYER :: Form_ID(0x14)
PLAYER_BASE :: Form_ID(0x7) // the NPC_ a new game's character places
GOLD :: Form_ID(0xF) // Gold001
PRISON_MARKER :: Form_ID(0x4) // a DOOR base whose refs mark a jail's way in and out; its teleport is data, not a door
IS_GUARD_FACTION :: Form_ID(0x86EEE) // IsGuardFaction: its members are guards (IsGuard)
ATTACK_ON_SIGHT_VIOLENT :: Form_ID(0xE9C) // CrimeArrestOnSightViolentThreshold (999)
ATTACK_ON_SIGHT_NONVIOLENT :: Form_ID(0xE9D) // CrimeArrestOnSightNonViolentThreshold (1000)
LOC_REF_BOSS :: Form_ID(0x130F7) // the Boss LocationRefType: its death clears the location
ASSOC_PARENT_CHILD :: Form_ID(0x142C6) // the ParentChild AssociationType (HasParentRelationship)

// The time globals. The game clock writes them; it is their source.
GAME_YEAR :: Form_ID(0x35)
GAME_MONTH :: Form_ID(0x36) // counted from 0
GAME_DAY :: Form_ID(0x37)
GAME_HOUR :: Form_ID(0x38)
GAME_DAYS_PASSED :: Form_ID(0x39)
TIMESCALE :: Form_ID(0x3A)
