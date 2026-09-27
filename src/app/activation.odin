package main

// The activation target resolver: each frame, work out what the crosshair (screen centre) is
// pointing at and turn it into the neutral facts the HUD prompt needs — a kind ("door"/"container"/
// …), the display name, a door's destination place name, and whether it's locked. This is the Odin
// "grunt work" half; the wording ("Open"/"Talk") and styling live in Lua (hud.lua via
// engine.activation()), so a mod can restyle the whole prompt without touching the engine.
//
// Doors: a load door with a MESH (house doors, city gates) is picked by the crosshair like anything
// else and gets an "Open <place>" prompt. Cave/auto-load entrances are invisible AutoLoadMarkers —
// the ray never hits them, so they get NO prompt and stay proximity-only (frame_traversal), exactly
// as before.

import "../gamedb"
import "../physics"
import "../render"
import "../world"
import "../worldstate"

// ACTIVATE_RANGE is how far down the crosshair ray an object can be and still be activatable
// (world units; the ray-hit distance, so it works for big meshes whose origin is far off).
ACTIVATE_RANGE :: f32(220)

// Activate_Kind classifies what the crosshair is on, so Lua can pick the verb. Kept neutral —
// Odin decides WHAT it is, Lua decides how to SAY it (see the VERB table in hud.lua).
Activate_Kind :: enum {
	None,
	Door,
	Container,
	Actor,
	Body, // a dead actor: searched like a container
	Item,
	Activator,
	Flora,
	Book,
}

// activate_kind_tag is the lowercase string handed to Lua for each kind. Keep the tags in sync with
// the VERB table keys in hud.lua.
activate_kind_tag := [Activate_Kind]string {
	.None      = "",
	.Door      = "door",
	.Container = "container",
	.Actor     = "actor",
	.Body      = "body",
	.Item      = "item",
	.Activator = "activator",
	.Flora     = "flora",
	.Book      = "book",
}

// Activation_Target is the resolved crosshair target for one frame. `present` false = nothing
// activatable is targeted (the HUD shows just the reticle). `name` is the object's own FULL name;
// `dest` is a door's destination place name ("Riverwood Trader"). `form` is the targeted REFR, for
// the activate action / future menus. `dyn_body` is the movable-clutter physics body carrying the
// target (0 = static/none) — non-zero means it can be picked up / manoeuvred (frame_interact).
Activation_Target :: struct {
	present:  bool,
	kind:     Activate_Kind,
	name:     string,
	dest:     string,
	locked:   bool,
	form:     gamedb.Form_ID,
	dyn_body: physics.Body, // movable-clutter body under the crosshair (0 = not grabbable)
}

// classify_base maps a base form to an activation kind from the gamedb type indexes. Door is handled
// by the caller (via the ref's teleport) before this; here a bare DOOR base (a non-teleport door
// panel) still classifies as Door. Anything unrecognised is a generic Activator ("Activate").
classify_base :: proc(db: ^gamedb.DB, base: gamedb.Form_ID) -> Activate_Kind {
	switch {
	case gamedb.is_door(db, base):
		return .Door
	case gamedb.is_container(db, base):
		return .Container
	case gamedb.is_actor(db, base):
		return .Actor
	case gamedb.is_tree(db, base), base in db.produce:
		return .Flora
	case base in db.books:
		return .Book
	case gamedb.is_item(db, base):
		return .Item
	}
	return .Activator
}

// resolve_activation casts a ray down the screen centre and resolves what it hits into an
// Activation_Target for this frame. No world state is mutated (uses world.probe_ray). Names come
// from gamedb; strings are borrowed (valid for the DB's lifetime) — no allocation.
resolve_activation :: proc(g: ^Game) -> Activation_Target {
	scene := g.fr.active_scene
	if scene == nil {
		return {}
	}
	ro, rd := camera_ray(g.cam, render.aspect(&g.r), {0, 0}) // {0,0} = screen centre (the crosshair)
	inst, dist, ok := world.probe_ray(scene, ro, rd)
	if actor, adist, aok := pick_actor(g, ro, rd); aok && adist <= ACTIVATE_RANGE && (!ok || adist < dist) {
		name := worldstate.display_name(&g.ws, &g.db, actor)
		kind := Activate_Kind.Body if worldstate.is_dead(&g.ws, &g.db, actor) else .Actor
		return {kind = kind, name = name, form = actor, present = name != ""}
	}
	if !ok || dist > ACTIVATE_RANGE || inst.disabled {
		return {}
	}

	ref_form := gamedb.Form_ID(inst.form_id)
	t := Activation_Target {
		kind     = .Door if inst.has_tp else classify_base(&g.db, gamedb.Form_ID(inst.base)),
		name     = gamedb.name_of(&g.db, ref_form),
		locked   = worldstate.is_locked(&g.ws, &g.db, ref_form),
		form     = ref_form,
		dyn_body = inst.dyn_body, // non-zero → this REFR is carried by a movable clutter body (grabbable)
	}
	if inst.has_tp {
		// A load door with a mesh (manual door / city gate). Its destination place name is the prompt
		// subject ("Open Riverwood Trader"). Auto/cave markers have no mesh → never picked → no prompt.
		t.dest = door_dest_label(&g.trav, gamedb.Form_ID(inst.tp_door))
	}
	// Only surface a prompt for something worth naming: a door always (it has a destination), else
	// an object with an actual FULL name. Unnamed clutter/activators show nothing (just the reticle).
	t.present = t.kind == .Door || t.name != ""
	return t
}
