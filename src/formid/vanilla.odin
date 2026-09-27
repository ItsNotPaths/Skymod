package formid

// Skyrim.esm forms the engine names directly. Skyrim.esm is slot 0, so the Form_ID is its local id.

PLAYER :: Form_ID(0x14)
PLAYER_BASE :: Form_ID(0x7) // the NPC_ the player ref places
GOLD :: Form_ID(0xF) // Gold001
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
