package gamedb

// Condition storage. The decode is esm.conditions; this file remaps the parameters that are forms
// into global space (esm.condition_param_is_form, from xEdit's function table) and owns the strings.

import "core:strings"
import "../formats/esm"

// index_conditions decodes a record's conditions and remaps the parameters that are forms. Returns
// a slice owned by the DB (free it with free_conditions), or nil when the record carries none.
// `stop_at` ends the scan at that tag — PERK passes "PRKE" to take only the conditions that gate
// whether the perk can be taken.
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
			flags    = c.flags,
			value    = c.value,
			global   = esm.remap_form(fm, c.global),
			param1   = param(c, 0, c.param1, fm),
			param2   = param(c, 1, c.param2, fm),
			run_on   = c.run_on,
			param3   = c.param3,
			text     = strings.clone(c.text, db.allocator) if c.text != "" else "",
		}
		if c.run_on == .Reference {
			out[i].reference = esm.remap_form(fm, c.reference)
		}
	}
	return out
}

@(private = "file")
param :: proc(c: esm.Condition, i: int, raw: u32, fm: ^esm.Form_Map) -> u64 {
	return u64(esm.remap_form(fm, raw)) if esm.condition_param_is_form(c, i) else u64(raw)
}

// free_conditions releases a slice from index_conditions.
free_conditions :: proc(db: ^DB, conds: []Condition) {
	for c in conds {
		delete(c.text, db.allocator)
	}
	delete(conds, db.allocator)
}

// Condition is a decoded CTDA with its form parameters remapped into global space. Mirrors
// esm.Condition, except the parameters widen to hold a Form_ID for the functions that take one.
Condition :: struct {
	function:  u16,
	op:        esm.Condition_Op,
	flags:     esm.Condition_Flags,
	value:     f32,
	global:    Form_ID, // the GLOB the comparison reads, when Use_Global
	param1:    u64, // a Form_ID when esm.condition_param_is_form, otherwise the raw number
	param2:    u64,
	run_on:    esm.Condition_Run_On,
	reference: Form_ID, // set only when run_on == .Reference
	param3:    i32, // the alias (QuestAlias) or event member (EventData); -1 otherwise
	text:      string, // a String parameter; owned
}

// condition_param1_form reads param1 as a Form_ID. Only meaningful for a function whose param1 is a form.
condition_param1_form :: proc(c: Condition) -> Form_ID {
	return Form_ID(c.param1)
}

// condition_param2_form reads param2 as a Form_ID. Only meaningful for a function whose param2 is a form.
condition_param2_form :: proc(c: Condition) -> Form_ID {
	return Form_ID(c.param2)
}
