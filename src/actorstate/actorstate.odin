package actorstate

// What each actor does with its body: standing, sitting, a swing, drinking a potion, a mod's dodge
// roll. AI, scripts, conditions and the player's controller ask for states by name and read them;
// the host drains `changes` for what follows a change (an outfit now, animation and events later).
// Only plain data crosses, so the model's owner can rebuild everything behind these procs. Not a
// plugin seam (ws.md Workstream H): mods add states through the model's own API.

import "core:strings"
import "../formid"

Form_ID :: formid.Form_ID

State_ID :: distinct u32 // fixed for the session; saves and mods use the name

// The engine's own states, in the order init names them.
STAND :: State_ID(0)
SIT :: State_ID(1)
SLEEP :: State_ID(2)
IDLE_MARKER :: State_ID(3) // held at an idle marker
SNEAK :: State_ID(4)

@(private = "file")
ENGINE_STATES := [?]string{"Stand", "Sit", "Sleep", "IdleMarker", "Sneak"}

// SEATED is GetSitState and GetSleepState "in the furniture".
SEATED :: 3

// Change is an actor leaving one state for another.
Change :: struct {
	actor:    Form_ID,
	from, to: State_ID,
}

// Saved is one actor's state in a save.
Saved :: struct {
	actor: Form_ID,
	state: string,
}

// (hole actor-states :tags (animation ai unclaimed) :sev blocker) the model is a stub: one state per actor, granted on request, with no properties or transitions. Wanted: one model that AI, scripts and conditions write and read and animation plays, not a copy of Havok behaviour graphs or Nemesis/Pandora patching. Swinging, drinking a potion, a dodge roll, paragliding are states; a mod adds one through the model's own clean API (not a native plugin seam), and the combat brain and scripts ask for states by name. A state carries its own properties (Sleep has speed 0) and transitions (moving while asleep enters a WakeUp state for the get-out-of-bed clip).
// (hole paralysis-read :tags (animation ai unclaimed) :sev gap :needs (actor-states)) the Paralysis AV is written by its effects and read by nothing: a paralyzed actor moves and acts.
Model :: struct {
	ids:     map[string]State_ID,
	names:   [dynamic]string, // by State_ID
	states:  map[Form_ID]State_ID, // an actor not here stands
	changes: [dynamic]Change, // since the host last drained them
}

init :: proc(m: ^Model) {
	for name in ENGINE_STATES {state_id(m, name)}
}

// state_id is the ID of a state name, made on first use.
state_id :: proc(m: ^Model, name: string) -> State_ID {
	if id, ok := m.ids[name]; ok {return id}
	id := State_ID(len(m.names))
	owned := strings.clone(name)
	append(&m.names, owned)
	m.ids[owned] = id
	return id
}

state_name :: proc(m: ^Model, id: State_ID) -> string {
	return m.names[id] if int(id) < len(m.names) else ""
}

current :: proc(m: ^Model, actor: Form_ID) -> State_ID {
	return m.states[actor]
}

// (hole actor-states :tags (animation ai unclaimed) :sev blocker) every request is granted at once: nothing checks that the actor can enter the state, and no transition runs between the two (sitting down, waking up).
// (hole actor-state-overlap :tags (animation ai unclaimed) :sev gap :needs (actor-states)) one state per actor: Sneak replaces a seat and a seat replaces Sneak, so sneaking while seated or swinging is lost.
// request asks for the actor to enter a state. False = refused.
request :: proc(m: ^Model, actor: Form_ID, id: State_ID) -> bool {
	set(m, actor, id)
	return true
}

// leave ends a state the actor is in, back to standing.
leave :: proc(m: ^Model, actor: Form_ID, id: State_ID) {
	if current(m, actor) == id {set(m, actor, STAND)}
}

// reset stands the actor up whatever it was doing (death, a disable).
reset :: proc(m: ^Model, actor: Form_ID) {
	set(m, actor, STAND)
}

// drain moves the changes since the last drain into `into` (cleared first).
drain :: proc(m: ^Model, into: ^[dynamic]Change) {
	clear(into)
	append(into, ..m.changes[:])
	clear(&m.changes)
}

// sit_state is GetSitState and GetSitting; sleep_state is GetSleepState and GetSleeping.
// (hole actor-state-sit-steps :tags (animation unclaimed) :sev polish :needs (actor-states)) only 0 and SEATED: the getting in and out steps (1, 2, 4) are transitions the stub does not have.
sit_state :: proc(m: ^Model, actor: Form_ID) -> i32 {
	return SEATED if current(m, actor) == SIT else 0
}

sleep_state :: proc(m: ^Model, actor: Form_ID) -> i32 {
	return SEATED if current(m, actor) == SLEEP else 0
}

// saved is every actor that does not stand, for a save. Temp-allocated.
saved :: proc(m: ^Model) -> []Saved {
	out := make([dynamic]Saved, 0, len(m.states), context.temp_allocator)
	for actor, id in m.states {append(&out, Saved{actor, state_name(m, id)})}
	return out[:]
}

// restore puts back a saved state; no change is recorded, since what follows it was saved too.
restore :: proc(m: ^Model, s: Saved) {
	if id := state_id(m, s.state); id != STAND {m.states[s.actor] = id}
}

destroy :: proc(m: ^Model) {
	for n in m.names {delete(n)}
	delete(m.names)
	delete(m.ids)
	delete(m.states)
	delete(m.changes)
}

@(private = "file")
set :: proc(m: ^Model, actor: Form_ID, id: State_ID) {
	was := current(m, actor)
	if was == id {return}
	if id == STAND {delete_key(&m.states, actor)} else {m.states[actor] = id}
	append(&m.changes, Change{actor, was, id})
}
