package script_lua

// Transitions: OnCellAttach, OnLoad, OnCellLoad, OnUnload and OnCellDetach, derived each tick by
// comparing the cells attached to the player's scene, and each ref's enable state, with the last
// tick (docs/script-rewrite.md "Events: edges, transitions, timers").

import "core:slice"
import script ".."
import "../../gamedb"
import "../../worldstate"

// HOLE(script, gap): OnAttachedToCell and OnDetachedFromCell never fire; nothing moves a ref from one cell to another yet.

// Transitions is what the tick remembers between ticks, besides ws.attached: the scripted refs
// whose OnLoad fired without an OnUnload yet, and the exterior persistent refs by the grid cell
// they attach with (indexed once).
Transitions :: struct {
	loaded:     map[script.Form_ID]bool,
	persistent: map[script.Form_ID][dynamic]script.Form_ID,
	indexed:    bool,
}

transitions_destroy :: proc(t: ^Transitions) {
	delete(t.loaded)
	for _, &refs in t.persistent {
		delete(refs)
	}
	delete(t.persistent)
}

// tick_transitions compares `now`, the cells attached this tick, with ws.attached and queues the
// events. A cell that detaches: OnUnload for its loaded refs, then OnCellDetach. A cell that stays:
// OnLoad / OnUnload for refs a script enabled or disabled. A cell that attaches: OnCellAttach for
// every scripted ref (disabled ones too), OnLoad for the enabled ones, then OnCellLoad.
tick_transitions :: proc(vm: ^VM, db: ^gamedb.DB, ws: ^worldstate.World_State, t: ^Transitions, now: []script.Form_ID) {
	if !t.indexed {index_persistent(db, t)}

	gone := make([dynamic]script.Form_ID, context.temp_allocator)
	for cell in ws.attached {
		if !slice.contains(now, cell) {append(&gone, cell)}
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
	}

	for _, refs in ws.attached {
		for r in refs {sync_loaded(vm, db, ws, t, r)}
	}

	for cell in now {
		if cell in ws.attached {continue}
		refs := scripted_refs(db, t, cell)
		ws.attached[cell] = refs
		for r in refs {send(vm, r, "OnCellAttach")}
		for r in refs {sync_loaded(vm, db, ws, t, r)}
		for r in refs {send(vm, r, "OnCellLoad")}
	}
}

// sync_loaded sends OnLoad or OnUnload when a ref's enable state differs from what its scripts
// were last told.
@(private)
sync_loaded :: proc(vm: ^VM, db: ^gamedb.DB, ws: ^worldstate.World_State, t: ^Transitions, r: script.Form_ID) {
	enabled := script.ref_enabled(ws, db, r)
	if enabled == (r in t.loaded) {return}
	if enabled {
		t.loaded[r] = true
		send(vm, r, "OnLoad")
	} else {
		delete_key(&t.loaded, r)
		send(vm, r, "OnUnload")
	}
}

// scripted_refs lists the refs that attach with `cell` and carry scripts: its refs and actors,
// plus the exterior persistent refs over it. The caller owns the list.
@(private)
scripted_refs :: proc(db: ^gamedb.DB, t: ^Transitions, cell: script.Form_ID) -> [dynamic]script.Form_ID {
	out := make([dynamic]script.Form_ID)
	for list in ([2][]gamedb.Ref{gamedb.refs_of(db, cell), gamedb.actors_of(db, cell)}) {
		for r in list {
			if has_scripts(db, r) {append(&out, r.form_id)}
		}
	}
	append(&out, ..t.persistent[cell][:])
	return out
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

@(private)
has_scripts :: proc(db: ^gamedb.DB, r: gamedb.Ref) -> bool {
	return !r.deleted && (len(gamedb.form_scripts(db, r.form_id)) > 0 || len(gamedb.form_scripts(db, r.base)) > 0)
}
