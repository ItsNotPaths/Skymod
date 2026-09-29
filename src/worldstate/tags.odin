package worldstate

// A form's tags (magic.Tags): the ones content gave it (set_tags), and kw.<editor id> for each
// keyword it has (has_keyword: its base's, an actor's race's and its aliases' too).

import "core:strings"
import "../gamedb"
import "../magic"

// set_tags gives `form` its authored tags, replacing any it had. Not saved: content sets them as
// it loads.
set_tags :: proc(ws: ^World_State, form: Form_ID, tags: []string) {
	if old, ok := ws.tags[form]; ok {free_tags(old)}
	own := make([]string, len(tags))
	for t, i in tags {own[i] = strings.clone(t)}
	ws.tags[form] = own
}

// has_tag reports whether a tag of `form` or of a ref's base matches `pattern`. A kw.<editor id>
// pattern names one keyword.
has_tag :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID, pattern: string) -> bool {
	if strings.has_prefix(pattern, "kw.") {
		kw, ok := gamedb.keyword_id(db, pattern[3:])
		return ok && has_keyword(ws, db, form, kw)
	}
	for f in ([]Form_ID{form, ref_base(ws, db, form)}) {
		for t in ws.tags[f] {
			if magic.matches(t, pattern) {return true}
		}
	}
	return false
}

@(private)
free_tags :: proc(tags: []string) {
	for t in tags {delete(t)}
	delete(tags)
}
