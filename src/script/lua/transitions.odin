package script_lua

// Transitions: OnCellAttach, OnLoad, OnCellLoad, OnUnload and OnCellDetach, derived each tick by
// comparing the cells attached to the player's scene, and each ref's enable state, with the last
// tick (docs/script-rewrite.md "Events: edges, transitions, timers").

import script ".."
import "../../gamedb"
import "../../worldstate"
import "../../formid"
import "core:slice"

// Transitions is what the tick remembers between ticks, besides ws.attached: the scripted refs
// whose OnLoad fired without an OnUnload yet, the exterior persistent refs by the grid cell they
// attach with (indexed once), and the player's location (none after a load: no event for it).
Transitions :: struct {
	loaded:     map[script.Form_ID]bool,
	persistent: map[script.Form_ID][dynamic]script.Form_ID,
	indexed:    bool,
	location:   Maybe(script.Form_ID),
}

transitions_destroy :: proc(t: ^Transitions) {
	delete(t.loaded)
	for _, &refs in t.persistent {
		delete(refs)
	}
	delete(t.persistent)
}

// (hole npc-change-location :tags (quest ai) :sev polish) only the player sends CLOC; 7 vanilla CLOC conditions run on actor 1, so an NPC's move may be meant to send it too (unsourced).
// tick_location sends OnLocationChange(old, new) to the player and its aliases, and queues a
// Change Location story event (actor 1 the player, location 1 the old, location 2 the new), when
// the player's location differs from the last tick's.
tick_location :: proc(vm: ^VM, ws: ^worldstate.World_State, t: ^Transitions, now: script.Form_ID) {
	if old, known := t.location.?; known && old != now {
		send(vm, formid.PLAYER, "OnLocationChange", old, now)
		worldstate.queue_story_event(ws, {type = worldstate.STORY_CHANGE_LOCATION, ref1 = formid.PLAYER, location1 = old, location2 = now})
	}
	t.location = now
}

// tick_transitions compares `now`, the cells attached this tick, with ws.attached and queues the
// events. A cell that detaches: OnUnload for its loaded refs, then OnCellDetach. A cell that stays:
// OnLoad / OnUnload for refs a script enabled or disabled. A cell that attaches: OnCellAttach for
// every scripted ref (disabled ones too), OnLoad for the enabled ones, then OnCellLoad.
tick_transitions :: proc(vm: ^VM, db: ^gamedb.DB, ws: ^worldstate.World_State, t: ^Transitions, now: []script.Form_ID) {
	if !t.indexed {index_persistent(db, t)}

	still := make(map[script.Form_ID]bool, len(now), context.temp_allocator)
	for cell in now {still[cell] = true}
	gone := make([dynamic]script.Form_ID, context.temp_allocator)
	for cell in ws.attached {
		if cell not_in still {append(&gone, cell)}
	}
	for cell in gone {
		refs := ws.attached[cell]
		for r in refs {
			if r in t.loaded {send(vm, r, "OnUnload")}
			delete_key(&t.loaded, r)
			send(vm, r, "OnCellDetach")
		}
		delete(refs)
		delete_key(&ws.attached, cell)
		worldstate.delete_detached(ws, cell)
		worldstate.leave_cell(ws, cell)
	}

	for f in ws.refiles {refile(vm, db, ws, t, still, f)}
	clear(&ws.refiles)

	for _, refs in ws.attached {
		for r in refs {sync_loaded(vm, db, ws, t, r)}
	}

	for cell in now {
		if cell in ws.attached {continue}
		script.enter_cell(db, ws, cell)
		sync_refs(vm)
		refs := scripted_refs(db, ws, t, cell)
		ws.attached[cell] = refs
		for r in refs {send(vm, r, "OnCellAttach")}
		for r in refs {sync_loaded(vm, db, ws, t, r)}
		for r in refs {send(vm, r, "OnCellLoad")}
	}
	if len(gone) > 0 {script.settle_moves(db, ws)}
}

// sync_loaded sends OnLoad or OnUnload when a ref's enable state differs from what its scripts
// were last told.
@(private)
sync_loaded :: proc(vm: ^VM, db: ^gamedb.DB, ws: ^worldstate.World_State, t: ^Transitions, r: script.Form_ID) {
	enabled := worldstate.ref_enabled(ws, db, r)
	if enabled == (r in t.loaded) {return}
	if enabled {
		t.loaded[r] = true
		send(vm, r, "OnLoad")
	} else {
		delete_key(&t.loaded, r)
		send(vm, r, "OnUnload")
	}
}

// refile moves a ref between the attached cells' lists after it moved or an alias took it. A move
// from a detached cell to an attached one sends OnAttachedToCell (OnLoad follows in sync_loaded),
// the reverse OnUnload and OnDetachedFromCell. A ref an alias takes where it stands counts as loaded
// already. A cell attaching this tick (in `still`, not yet in ws.attached) lists the ref itself. The
// player sends neither (CK wiki).
@(private)
refile :: proc(vm: ^VM, db: ^gamedb.DB, ws: ^worldstate.World_State, t: ^Transitions, still: map[script.Form_ID]bool, f: worldstate.Refile) {
	r := f.ref
	if r == formid.PLAYER {return}
	was := listed_cell(ws, r)
	now := worldstate.ref_grid_cell(ws, db, r)
	if now not_in still {now = 0}
	if was == now {return}
	if was != 0 {
		refs := &ws.attached[was]
		if i, found := slice.linear_search(refs[:], r); found {ordered_remove(refs, i)}
	}
	if now != 0 && now not_in ws.attached {return}
	if now != 0 && tracked(db, ws, r) {
		append(&ws.attached[now], r)
		if !f.moved && worldstate.ref_enabled(ws, db, r) {t.loaded[r] = true}
		if f.moved && was == 0 {send(vm, r, "OnAttachedToCell")}
	} else if now == 0 && was != 0 {
		if r in t.loaded {send(vm, r, "OnUnload")}
		delete_key(&t.loaded, r)
		send(vm, r, "OnDetachedFromCell")
	}
}

@(private)
listed_cell :: proc(ws: ^worldstate.World_State, r: script.Form_ID) -> script.Form_ID {
	for cell, refs in ws.attached {
		if slice.contains(refs[:], r) {return cell}
	}
	return 0
}

// scripted_refs lists the refs in `cell` whose events reach a script: its refs and actors and the
// exterior persistent refs over it, less those moved away, then the refs moved in, created in it or
// held by an alias. A ref is listed once. The caller owns the list.
@(private)
scripted_refs :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State, t: ^Transitions, cell: script.Form_ID) -> [dynamic]script.Form_ID {
	out := make([dynamic]script.Form_ID)
	seen := make(map[script.Form_ID]bool, context.temp_allocator)
	add :: proc(out: ^[dynamic]script.Form_ID, seen: ^map[script.Form_ID]bool, ws: ^worldstate.World_State, db: ^gamedb.DB, cell, r: script.Form_ID) {
		if r in seen^ || worldstate.ref_grid_cell(ws, db, r) != cell {return}
		seen[r] = true
		append(out, r)
	}
	for list in ([2][]gamedb.Ref{gamedb.refs_of(db, cell), gamedb.actors_of(db, cell)}) {
		for r in list {
			if has_scripts(db, r) {add(&out, &seen, ws, db, cell, r.form_id)}
		}
	}
	persistent, _ := t.persistent[cell]
	for r in persistent {add(&out, &seen, ws, db, cell, r)}
	placed := len(out)
	defer slice.sort(out[placed:]) // the rest come from maps; form order keeps a run reproducible
	for id, d in ws.ref_deltas {
		if .Moved in d.live && id != formid.PLAYER && tracked(db, ws, id) {add(&out, &seen, ws, db, cell, id)}
	}
	for id, cr in ws.created {
		if len(gamedb.base_scripts(db, cr.base)) > 0 {add(&out, &seen, ws, db, cell, id)}
	}
	for id in ws.alias_holders {
		if id != formid.PLAYER {add(&out, &seen, ws, db, cell, id)}
	}
	return out
}

// tracked reports whether a ref's events reach a script now: its own or its base's, or an alias's.
@(private)
tracked :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State, id: script.Form_ID) -> bool {
	if id in ws.alias_holders || id in db.alias_targets || len(gamedb.form_scripts(db, id)) > 0 {return true}
	return len(gamedb.base_scripts(db, worldstate.ref_base(ws, db, id))) > 0
}

// index_persistent buckets every worldspace's persistent scripted refs and actors by the grid cell
// they attach with (gamedb.ref_attach_cell).
@(private)
index_persistent :: proc(db: ^gamedb.DB, t: ^Transitions) {
	t.indexed = true
	for _, pcell in db.world_persist {
		for list in ([2][]gamedb.Ref{gamedb.refs_of(db, pcell), gamedb.actors_of(db, pcell)}) {
			for r in list {
				if !has_scripts(db, r) {continue}
				cell := gamedb.ref_attach_cell(db, r)
				if cell == 0 {continue}
				bucket := t.persistent[cell]
				append(&bucket, r.form_id)
				t.persistent[cell] = bucket
			}
		}
	}
}

// has_scripts reports whether a ref's events can reach a script: its own, or an alias's that a
// static fill puts it in.
@(private)
has_scripts :: proc(db: ^gamedb.DB, r: gamedb.Ref) -> bool {
	if r.deleted {return false}
	return len(gamedb.form_scripts(db, r.form_id)) > 0 || len(gamedb.base_scripts(db, r.base)) > 0 || r.form_id in db.alias_targets
}
