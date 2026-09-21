package gamedb

// Condition storage. The decode is esm.conditions; this file owns the one thing the DB must decide
// at index time — whether a condition's param1 is a formID that needs remapping into global space.
//
// GREP `CTDA-FN` for every place a condition function index is named. Every identity below was
// INFERRED from the real Skyrim.esm (which record types use it, and what its parameters resolve to)
// rather than read from documentation, because the data carries numbers and no names. The census
// and the reasoning are in docs/conditions.md. Confirm each against the Creation Kit before
// treating it as settled, and keep the naming here in sync with src/conditions/functions.odin.

import "../formats/esm"

// condition_param1_is_form reports whether a condition function's first parameter is a formID.
// This CANNOT be assumed: function 448's param1 is a PERK, but function 277's is an actor value
// INDEX and function 77's is unused. Remapping a non-form would corrupt it.
//
// An unregistered function keeps its param1 RAW. That is safe because an unimplemented function
// evaluates true (see src/conditions), so nothing reads the parameter. It does mean that ADDING a
// function here is a two-step job: give it a body, and register its parameter kind below.
@(private)
condition_param1_is_form :: proc(function: u16) -> bool {
	switch function {
	case 448: // CTDA-FN 448 has-perk (INFERRED) — param1 is a PERK
		return true
	case 47: // CTDA-FN 47 item count (INFERRED) — param1 is the item form
		return true
	case 277: // CTDA-FN 277 actor value by index (INFERRED) — param1 is an INDEX, not a form
		return false
	case 659: // CTDA-FN 659 tempering target is enchanted (INFERRED) — param1 unused, always 0
		return false
	}
	return false // unregistered: keep it raw, since nothing evaluates it
}

// index_conditions decodes a record's conditions and remaps the parameters that are forms. Returns
// a slice owned by the DB, or nil when the record carries none. `stop_at` ends the scan at that
// tag — PERK passes "PRKE" to take only the conditions that gate whether the perk can be taken.
@(private)
index_conditions :: proc(
	db: ^DB,
	fl: []esm.Field,
	fm: ^esm.Form_Map,
	stop_at := "",
) -> []Condition {
	raw := esm.conditions(fl, context.allocator, stop_at) // walk has no temp reset — explicit free
	if raw == nil {
		return nil
	}
	defer delete(raw, context.allocator)

	out := make([]Condition, len(raw), db.allocator)
	for c, i in raw {
		out[i] = Condition {
			function = c.function,
			op       = c.op,
			or_next  = c.or_next,
			value    = c.value,
			param2   = c.param2,
			run_on   = c.run_on,
		}
		out[i].param1 = condition_param1_is_form(c.function) \
			? u64(esm.remap_form(fm, c.param1)) \
			: u64(c.param1)
		if c.run_on == .Reference {
			out[i].reference = esm.remap_form(fm, c.reference)
		}
	}
	return out
}

// Condition is a decoded CTDA with its form parameters remapped into global space. Mirrors
// esm.Condition, except param1 widens to hold a Form_ID for the functions that take one.
Condition :: struct {
	function:  u16,
	op:        esm.Condition_Op,
	or_next:   bool, // OR with the NEXT condition; a list is otherwise an AND
	value:     f32,
	param1:    u64, // a Form_ID when condition_param1_is_form, otherwise the raw number
	param2:    u32,
	run_on:    esm.Condition_Run_On,
	reference: Form_ID, // set only when run_on == .Reference
}

// param1_form reads param1 as a Form_ID. Only meaningful for a function whose param1 is a form.
condition_param1_form :: proc(c: Condition) -> Form_ID {
	return Form_ID(c.param1)
}
