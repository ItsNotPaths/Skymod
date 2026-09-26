package script_lua

// Transitions: OnCellAttach, OnLoad, OnCellLoad, OnUnload and OnCellDetach, derived each tick by
// comparing the cells attached to the player's scene, and each ref's enable state, with the last
// tick (docs/script-rewrite.md "Events: edges, transitions, timers").

import script ".."
import "../../gamedb"
import "../../worldstate"

// (hole cell-change-events :tags script :sev gap) OnAttachedToCell and OnDetachedFromCell never fire, and a scripted ref that MoveTo puts in another cell gets no load or cell events there.
// (hole alias-ref-events :tags script :sev gap) a ref ForceRefTo puts in an alias gets no load or cell events unless it has scripts or a static fill names it.

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

// (hole story-change-location :tags (quest world) :sev blocker :needs (story-manager)) the player moving to another location queues no CLOC story event (135 SMQN, the radiant quests).
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
// the exterior persistent refs over it, and the created refs in it. The caller owns the list.
@(private)
scripted_refs :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State, t: ^Transitions, cell: script.Form_ID) -> [dynamic]script.Form_ID {
	out := make([dynamic]script.Form_ID)
	for list in ([2][]gamedb.Ref{gamedb.refs_of(db, cell), gamedb.actors_of(db, cell)}) {
		for r in list {
			if has_scripts(db, r) {append(&out, r.form_id)}
		}
	}
	append(&out, ..t.persistent[cell][:])
	c := script.Call{ws = ws, db = db}
	for id, cr in ws.created {
		if len(gamedb.form_scripts(db, cr.base)) > 0 && script.ref_grid_cell(&c, id) == cell {append(&out, id)}
	}
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

// has_scripts reports whether a ref's events can reach a script: its own, or an alias's that a
// static fill puts it in.
@(private)
has_scripts :: proc(db: ^gamedb.DB, r: gamedb.Ref) -> bool {
	if r.deleted {return false}
	return len(gamedb.form_scripts(db, r.form_id)) > 0 || len(gamedb.form_scripts(db, r.base)) > 0 || r.form_id in db.alias_targets
}
