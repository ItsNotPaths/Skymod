package actorstate

// What each actor does with its body: standing, a swing, drinking a potion, a mod's dodge roll. AI,
// scripts and conditions ask for states by name and read them; animation plays them. Only plain
// data crosses, so the model's owner can rebuild everything behind these procs. Not a plugin seam
// (ws.md Workstream H): mods add states through the model's own API.

import "core:strings"
import "../formid"

Form_ID :: formid.Form_ID

State_ID :: distinct u32 // fixed for the session; saves and mods use the name

STAND :: State_ID(0)

// State is an actor's current state.
State :: struct {
	id:   State_ID,
	time: f32, // seconds in it
}

// (hole actor-states :tags (animation ai unclaimed) :sev blocker) the stub: every actor stands and every request is refused. Seated, sleeping, mounted, leaning, attacking and in-an-action live in scattered sets or nowhere. Wanted: one model that AI, scripts and conditions write and read and animation plays, not a copy of Havok behaviour graphs or Nemesis/Pandora patching. Swinging, drinking a potion, a dodge roll, paragliding are states; a mod adds one through the model's own clean API (user 2026-09-28: not a native plugin seam), and the combat brain and scripts ask for states by name.
Model :: struct {
	ids:   map[string]State_ID,
	names: [dynamic]string, // by State_ID
}

init :: proc(m: ^Model) {
	state_id(m, "Stand")
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

// request asks for the actor to enter a state; the model decides whether it can.
request :: proc(m: ^Model, actor: Form_ID, id: State_ID) -> bool {
	return false
}

current :: proc(m: ^Model, actor: Form_ID) -> State {
	return {STAND, 0}
}

destroy :: proc(m: ^Model) {
	for n in m.names {delete(n)}
	delete(m.names)
	delete(m.ids)
}
