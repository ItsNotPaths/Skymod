package gamedb

// Dialogue records (xEdit): topics (DIAL), the branches that start player topic trees (DLBR), and
// the responses (INFO) a topic offers, each with its conditions and the lines an actor says. A
// topic's INFOs are tried top to bottom; their order is the previous-INFO (PNAM) chain.

import "core:slice"
import "core:strings"
import "../formats/esm"

Topic :: struct {
	priority:     f32, // PNAM
	branch:       Form_ID, // BNAM
	quest:        Form_ID, // QNAM
	category:     u8, // DATA: 0 player, 1 favor, 2 scene, 3 combat, 4 favors, 5 detection, 6 service, 7 misc
	subtype:      u16, // DATA: 0 custom, 14 scene... (SNAM names it: "HELO", "CUST")
	subtype_name: [4]u8,
	do_all:       bool, // DATA: Do All Before Repeating
	infos:        []Form_ID, // in PNAM order, built once every plugin is read (owned)
}

// Branch flags (DNAM).
BRANCH_TOP_LEVEL :: 0x1
BRANCH_BLOCKING :: 0x2
BRANCH_EXCLUSIVE :: 0x4

Branch :: struct {
	quest:    Form_ID,
	category: u32, // TNAM: 0 player, 1 favor
	flags:    u32,
	start:    Form_ID, // SNAM: the starting topic
}

// Info flags (ENAM).
INFO_GOODBYE :: 0x0001
INFO_RANDOM :: 0x0002
INFO_SAY_ONCE :: 0x0004
INFO_REQUIRES_PLAYER_ACTIVATION :: 0x0008
INFO_REFUSAL :: 0x0010
INFO_RANDOM_END :: 0x0020
INFO_INVISIBLE_CONTINUE :: 0x0040
INFO_WALK_AWAY :: 0x0080
INFO_WALK_AWAY_INVISIBLE :: 0x0100
INFO_FORCE_SUBTITLE :: 0x0200

Info :: struct {
	topic:       Form_ID,
	previous:    Form_ID, // PNAM: the INFO above it in its topic
	flags:       u16,
	reset_hours: f32, // ENAM: stored as hours × 2730.625 (xEdit)
	favor_level: u8, // CNAM
	links:       []Form_ID, // TCLT: the topics it opens next (owned)
	shared:      Form_ID, // DNAM: an INFO whose responses it says
	responses:   []Response, // owned
	conditions:  []Condition, // owned
	prompt:      string, // RNAM: the player's line, in place of the topic's text (owned)
	speaker:     Form_ID, // ANAM
	walk_away:   Form_ID, // TWAT
}

Response :: struct {
	emotion:       u32, // TRDT
	emotion_value: u32,
	number:        u8,
	sound:         Form_ID,
	text:          string, // NAM1 (owned)
	speaker_idle:  Form_ID, // SNAM
	listener_idle: Form_ID, // LNAM
}

@(private)
index_topic :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	index_name(db, rec.form_id, fl) // FULL: the topic's text
	t := Topic{priority = 50}
	for f in fl {
		switch f.type {
		case "PNAM":
			t.priority, _ = esm.field_f32(f)
		case "BNAM":
			if v, vok := esm.field_u32(f); vok {t.branch = esm.remap_form(fm, v)}
		case "QNAM":
			if v, vok := esm.field_u32(f); vok {t.quest = esm.remap_form(fm, v)}
		case "DATA":
			if len(f.data) >= 4 {
				t.do_all = f.data[0] != 0
				t.category = f.data[1]
				t.subtype = u16(f.data[2]) | u16(f.data[3]) << 8
			}
		case "SNAM":
			if len(f.data) >= 4 {copy(t.subtype_name[:], f.data[:4])}
		}
	}
	if old, existed := db.topics[rec.form_id]; existed {delete(old.infos, db.allocator)}
	db.topics[rec.form_id] = t
}

@(private)
index_branch :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	b: Branch
	for f in fl {
		v, vok := esm.field_u32(f)
		if !vok {continue}
		switch f.type {
		case "QNAM":
			b.quest = esm.remap_form(fm, v)
		case "TNAM":
			b.category = v
		case "DNAM":
			b.flags = v
		case "SNAM":
			b.start = esm.remap_form(fm, v)
		}
	}
	db.branches[rec.form_id] = b
}

@(private)
index_info :: proc(db: ^DB, rec: esm.Record, topic: Form_ID, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	info := Info{topic = topic}
	links := make([dynamic]Form_ID, db.allocator)
	responses := make([dynamic]Response, db.allocator)
	conds_at := -1
	for f, i in fl {
		form :: proc(f: esm.Field, fm: ^esm.Form_Map) -> Form_ID {
			v, _ := esm.field_u32(f)
			return esm.remap_form(fm, v)
		}
		switch f.type {
		case "ENAM":
			if len(f.data) >= 4 {
				info.flags = u16(f.data[0]) | u16(f.data[1]) << 8
				info.reset_hours = f32(u16(f.data[2]) | u16(f.data[3]) << 8) / 2730.625
			}
		case "PNAM":
			info.previous = form(f, fm)
		case "CNAM":
			if len(f.data) >= 1 {info.favor_level = f.data[0]}
		case "TCLT":
			append(&links, form(f, fm))
		case "DNAM":
			info.shared = form(f, fm)
		case "TRDT":
			r: Response
			if len(f.data) >= 20 {
				r.emotion, r.emotion_value = u32_at(f.data, 0), u32_at(f.data, 4)
				r.number = f.data[12]
				r.sound = esm.remap_form(fm, u32_at(f.data, 16))
			}
			append(&responses, r)
		case "NAM1":
			if len(responses) > 0 {
				responses[len(responses) - 1].text = strings.clone(resolve_lstring(db, f, db.cur_ilstrings), db.allocator)
			}
		case "SNAM":
			if len(responses) > 0 {responses[len(responses) - 1].speaker_idle = form(f, fm)}
		case "LNAM":
			if len(responses) > 0 {responses[len(responses) - 1].listener_idle = form(f, fm)}
		case "CTDA":
			if conds_at < 0 {conds_at = i}
		case "RNAM":
			info.prompt = strings.clone(resolve_lstring(db, f, db.cur_strings), db.allocator)
		case "ANAM":
			info.speaker = form(f, fm)
		case "TWAT":
			info.walk_away = form(f, fm)
		}
	}
	if conds_at >= 0 {info.conditions = index_conditions(db, esm.condition_run(fl, conds_at), fm)}
	info.links, info.responses = links[:], responses[:]
	if old, existed := db.infos[rec.form_id]; existed {free_info(db, old)}
	db.infos[rec.form_id] = info
}

// order_topic_infos gives each topic its INFOs in PNAM order. Runs once every plugin is read.
@(private)
order_topic_infos :: proc(db: ^DB) {
	previous := make(map[Form_ID]Form_ID, len(db.infos), context.temp_allocator)
	by_topic := make(map[Form_ID][dynamic]Form_ID, len(db.topics), context.temp_allocator)
	for form, info in db.infos {
		previous[form] = info.previous
		if info.topic not_in by_topic {by_topic[info.topic] = make([dynamic]Form_ID, context.temp_allocator)}
		append(&by_topic[info.topic], form)
	}
	for topic, &kids in by_topic {
		slice.sort(kids[:])
		if t, ok := &db.topics[topic]; ok {t.infos = chain_order(kids[:], previous, db.allocator)}
	}
}

topic_of :: proc(db: ^DB, topic: Form_ID) -> (Topic, bool) {
	return db.topics[topic]
}

info_of :: proc(db: ^DB, info: Form_ID) -> (Info, bool) {
	return db.infos[info]
}

branch_of :: proc(db: ^DB, branch: Form_ID) -> (Branch, bool) {
	return db.branches[branch]
}

@(private)
free_info :: proc(db: ^DB, info: Info) {
	delete(info.links, db.allocator)
	for r in info.responses {delete(r.text, db.allocator)}
	delete(info.responses, db.allocator)
	free_conditions(db, info.conditions)
	delete(info.prompt, db.allocator)
}

@(private)
free_dialogue :: proc(db: ^DB) {
	for _, t in db.topics {delete(t.infos, db.allocator)}
	delete(db.topics)
	delete(db.branches)
	for _, info in db.infos {free_info(db, info)}
	delete(db.infos)
}

@(private = "file")
u32_at :: proc(b: []u8, off: int) -> u32 {
	return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24
}
