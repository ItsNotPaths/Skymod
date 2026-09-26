package dialogue

// Text replacement tags in game text (measured over Skyrim.esm: Alias 357, Global 153,
// Alias.ShortName 70, BribeCost 43, the Alias pronouns 13, CrimeGold 5). <Global=Edid> shows a
// global's value; <Alias=Name> the name of the ref in the quest's alias of that name. Tags with
// no '=' (<Laughter>) are stage directions and stay.

import "core:fmt"
import "core:strings"
import "../formats/esm"
import "../gamedb"
import "../script"
import "../worldstate"

// (hole alias-short-name :tags (dialogue records) :sev polish) <Alias.ShortName=...> shows the full name: NPC_ SHRT is not decoded.
// (hole text-tag-crime :tags (dialogue combat) :sev polish :needs (crime-reads)) <BribeCost> and <CrimeGold> show 0: there is no crime system.

// text is `raw` with its tags filled in for a line of `quest`.
text :: proc(c: ^script.Call, raw: string, quest: Form_ID) -> string {
	if strings.index_byte(raw, '<') < 0 {return raw}
	b := strings.builder_make(context.temp_allocator)
	rest := raw
	for {
		i := strings.index_byte(rest, '<')
		j := strings.index_byte(rest[max(i, 0):], '>')
		if i < 0 || j < 0 {break}
		strings.write_string(&b, rest[:i])
		tag := rest[i + 1:i + j]
		if value, ok := tag_value(c, tag, quest); ok {
			strings.write_string(&b, value)
		} else {
			strings.write_string(&b, rest[i:i + j + 1])
		}
		rest = rest[i + j + 1:]
	}
	strings.write_string(&b, rest)
	return strings.to_string(b)
}

@(private = "file")
tag_value :: proc(c: ^script.Call, tag: string, quest: Form_ID) -> (string, bool) {
	kind, _, arg := strings.partition(tag, "=")
	switch strings.to_lower(kind, context.temp_allocator) {
	case "global":
		g, ok := gamedb.global_by_editor_id(c.db, arg)
		if !ok {return "", false}
		v := worldstate.global_value(c.ws, c.db, g)
		return fmt.tprintf("%d", i64(v)) if v == f32(i64(v)) else fmt.tprintf("%.2f", v), true
	case "bribecost", "crimegold":
		return "0", true
	case "alias", "alias.shortname":
		ref, ok := alias_named(c, quest, arg)
		return worldstate.display_name(c.ws, c.db, ref) if ok else "", ok
	case "alias.cap":
		ref, ok := alias_named(c, quest, arg)
		name := worldstate.display_name(c.ws, c.db, ref)
		if !ok || name == "" {return "", ok}
		return strings.concatenate({strings.to_upper(name[:1], context.temp_allocator), name[1:]}, context.temp_allocator), true
	case "alias.pronoun", "alias.pronounobj", "alias.pronounpos", "alias.pronounposobj":
		ref, ok := alias_named(c, quest, arg)
		if !ok {return "", false}
		female := worldstate.actor_traits(c.ws, c.db, ref).flags & esm.ACBS_FEMALE != 0
		switch strings.to_lower(kind, context.temp_allocator) {
		case "alias.pronoun":       return "she" if female else "he", true
		case "alias.pronounobj":    return "her" if female else "him", true
		case "alias.pronounpos":    return "her" if female else "his", true
		case "alias.pronounposobj": return "hers" if female else "his", true
		}
	}
	return "", false
}

// alias_named is the ref in `quest`'s alias called `name`.
@(private = "file")
alias_named :: proc(c: ^script.Call, quest: Form_ID, name: string) -> (Form_ID, bool) {
	qb, ok := gamedb.quest_baseline_of(c.db, quest)
	if !ok {return 0, false}
	for a in qb.aliases {
		if strings.equal_fold(a.name, name) {return worldstate.alias_ref(c.ws, quest, i32(a.id)), true}
	}
	return 0, false
}
