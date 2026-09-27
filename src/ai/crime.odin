package ai

import "../gamedb"
import "../worldstate"

// confront is a guard's turn to go after a wanted actor it has detected.
// (hole crime-arrest :tags (ai combat dialogue) :sev gap) no guard confronts anyone: wanted a guard that knows a bounty on an actor it detects (worldstate.bounty) walking up (PURS) and asking. The controller answers: the player's force-greets DialogueCrimeGuards (PFGT; pay, jail, resist, bribe, persuade), an NPC's AI pays if it can, else goes to jail or resists. SetPlayerResistingArrest (15 calls) has nothing to set.
confront :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, guard: Form_ID) {
}
