package worldstate

// Powers content defines (rt.power): lesser powers, powers and shouts, one kind (user, 2026-09-28).
// A power has words, its variants in order (a lesser or greater power has one); each applies its
// effects like a spell's entries and sets a cooldown instead of costing Magicka. The cooldown runs
// on a timer AV: game hours for a power, real seconds for a shout ("24h", "15s"). Shouts share
// one AV (Voice), a power has its own, a lesser power none. Not saved, like spells.

import "core:log"
import "core:strconv"
import "core:strings"
import "../formid"
import "../gamedb"

Power_Def :: struct {
	name:     string, // owned
	display:  string, // owned
	shape:    string, // owned
	cooldown: string, // owned: the timer AV its words set; "" for none
	mult:     string, // owned: an AV multiplying each cooldown (ShoutRecoveryMult); "" for none
	words:    [dynamic]Power_Word,
}

// Power_Word is one variant: what it applies and how long it keeps the power from being used.
Power_Word :: struct {
	entries:  [dynamic]Spell_Entry,
	cooldown: f32, // in the cooldown AV's clock: hours on a game timer, else seconds
}

Power_Def_Src :: struct {
	name, form, display, shape: string,
	cooldown, mult:             string, // cooldown: the AV; "" uses the power's name when a word has one
	words:                      []Power_Word_Src,
}

Power_Word_Src :: struct {
	entries:  []Spell_Entry_Src,
	cooldown: string, // "15s" real seconds, "24h" game hours, "" none
}

// set_power_def makes a definition the one for its form and creates its cooldown AV, a timer on
// the clock its words' cooldowns name.
set_power_def :: proc(ws: ^World_State, db: ^gamedb.DB, src: Power_Def_Src) -> (Form_ID, bool) {
	form := formid.lua_form("power", src.name)
	if src.form != "" {
		f, ok := form_by_name(ws, db, src.form)
		if !ok {
			log.warnf("rt.power %s: no form %q", src.name, src.form)
			return 0, false
		}
		form = f
	}
	d := Power_Def{name = strings.clone(src.name), display = strings.clone(src.display), shape = strings.clone(src.shape), mult = strings.clone(src.mult)}
	game, timed := false, false
	for w in src.words {
		word := Power_Word{}
		if w.cooldown != "" {
			v, g, ok := parse_cooldown(w.cooldown)
			if !ok {
				log.warnf("rt.power %s: cooldown %q is not \"15s\" or \"24h\"", src.name, w.cooldown)
				continue
			}
			if timed && g != game {log.warnf("rt.power %s: its words' cooldowns mix game hours and seconds", src.name)}
			word.cooldown, game, timed = v, g, true
		}
		for e in w.entries {
			effect, ok := effect_by_name(ws, db, e.effect)
			dur, dok := parse_duration(e.d)
			if ok && dok {append(&word.entries, Spell_Entry{effect, e.m, dur, e.area, e.hits == "direct"})} else {log.warnf("rt.power %s: no effect %q, or a bad d", src.name, e.effect)}
		}
		append(&d.words, word)
	}
	if timed {
		d.cooldown = strings.clone(src.cooldown if src.cooldown != "" else src.name)
		if _, engine := gamedb.actor_value_name(d.cooldown); !engine {av_create(ws, d.cooldown, 0, .Game_Timer if game else .Timer)}
	}
	db.form_kinds[form] = .Spell // `as Spell`; Spell.Cast casts its first word with no cooldown

	if old, ok := &ws.power_defs[form]; ok {
		free_power_def(old)
		old^ = d
	} else {
		ws.power_defs[form] = d
	}
	return form, true
}

// parse_cooldown reads "15s" (real seconds) or "24h" (game hours).
parse_cooldown :: proc(s: string) -> (v: f32, game, ok: bool) {
	switch {
	case strings.has_suffix(s, "h"): v, ok = strconv.parse_f32(s[:len(s) - 1]); return v, true, ok
	case strings.has_suffix(s, "s"): v, ok = strconv.parse_f32(s[:len(s) - 1]); return v, false, ok
	}
	return
}

// power_ready is how long `actor` still waits to use `power`: 0 when it may.
power_ready :: proc(ws: ^World_State, db: ^gamedb.DB, actor, power: Form_ID) -> f32 {
	d, ok := ws.power_defs[power]
	if !ok || d.cooldown == "" {return 0}
	return max(av_current(ws, db, actor, d.cooldown), 0)
}

// power_word picks the word used with `words` words (1 = the first), within the ones it has, and
// starts its cooldown on `actor`. False while it cools down.
power_word :: proc(ws: ^World_State, db: ^gamedb.DB, actor, power: Form_ID, words: int) -> (entries: []gamedb.Magic_Effect_Ref, ok: bool) {
	d := ws.power_defs[power] or_return
	if len(d.words) == 0 || power_ready(ws, db, actor, power) > 0 {return}
	w := d.words[clamp(words, 1, len(d.words)) - 1]
	if d.cooldown != "" {
		mult := av_current(ws, db, actor, d.mult) if d.mult != "" else 1
		av_set_base(ws, actor, d.cooldown, w.cooldown * mult)
	}
	return entry_refs(w.entries[:]), true
}

// entry_refs is spell or word entries as effect refs, in the temp allocator.
entry_refs :: proc(entries: []Spell_Entry) -> []gamedb.Magic_Effect_Ref {
	out := make([]gamedb.Magic_Effect_Ref, len(entries), context.temp_allocator)
	for e, i in entries {out[i] = {effect = e.effect, magnitude = e.m, duration = e.d, area = u32(e.area)}}
	return out
}

@(private)
free_power_def :: proc(d: ^Power_Def) {
	delete(d.name)
	delete(d.display)
	delete(d.shape)
	delete(d.cooldown)
	delete(d.mult)
	for w in d.words {delete(w.entries)}
	delete(d.words)
}
