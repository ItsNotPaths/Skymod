package worldstate

// Leveling (sources: build/out/wsP/formulas/lvl_uesp_Skyrim_Leveling.txt). Skill XP raises a skill
// up to its cap; each raise gives the actor XP; enough XP makes a level-up ready, and it happens when
// the skills menu opens (level_up), with a choice and OnLevelUp. Every actor has this; only acts give
// XP. All the math is named formulas (formulas.odin).

import "core:log"
import "core:strings"
import "../formats/esm"
import "../formid"
import "../formula"
import "../gamedb"

// (hole skill-use-xp :tags (player combat) :sev gap :needs (combat-damage crafting-screen container-screen lockpicking persuasion)) only casts, AdvanceSkill and IncrementSkill give skill XP: hits, blocks and armor (combat), smithing, alchemy and enchanting (crafting), trade and pickpocketing (container screen), sneaking, lockpicking and persuasion call advance_skill when their systems exist.

Level_State :: struct {
	level:       i32, // 0 = the records' level
	xp:          f32,
	perk_points: i32,
	legendary:   [esm.NPC_SKILLS]i32, // times each skill (AV_NAMES[6:24] order) was made legendary
}

// Level_Choice is one answer to a level-up: formulas of `level` (the new level), each added to an
// actor value's capacity for good.
Level_Choice :: struct {
	changes: [dynamic]Level_Change,
}

Level_Change :: struct {
	av:     string, // owned; resolved when the choice is taken
	amount: formula.Formula,
}

// Level_Up is a level-up that happened, for OnLevelUp.
Level_Up :: struct {
	actor:  Form_ID,
	level:  i32,
	choice: string, // owned; the VM frees it once sent
}

LEVEL_CHOICE_VARS := []string{"level"}

// actor_level is an actor's level: what leveling made it, else its records' level, which for a PC
// Level Mult NPC_ follows the player's.
actor_level :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) -> i32 {
	if s, ok := ws.levels[actor]; ok && s.level > 0 {return s.level}
	player := 1 if actor == formid.PLAYER else int(player_level(ws, db))
	return gamedb.record_level(db, record_of(ws, actor), actor_pick(ws, db, actor), player)
}

// advance_skill gives a skill `xp` points of use; the skill rises while its XP covers the next
// level's cost, up to its cap.
advance_skill :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, skill: string, xp: f32) {
	rates, ok := gamedb.skill_xp_of(db, skill)
	advance, aok := gamedb.skill_advance_av(skill)
	if !ok || !aok {return}
	progress := av_current(ws, db, actor, advance) + f32(calc(ws, .SkillUseXP, f64(xp), f64(rates.use_mult), f64(rates.use_offset)))
	for {
		cost, open := skill_level_cost(ws, db, actor, skill)
		if !open {
			progress = 0
			break
		}
		if progress < cost {break}
		progress -= cost
		raise_skill(ws, db, actor, skill, 1)
	}
	av_set_base(ws, actor, advance, progress)
}

// skill_level_cost is the XP a skill needs to rise from its trained level; open=false at its cap or
// for a form with no skill rates.
skill_level_cost :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, skill: string) -> (cost: f32, open: bool) {
	rates := gamedb.skill_xp_of(db, skill) or_return
	level := av_base(ws, db, actor, skill)
	if level >= av_train_cap(ws, db, actor, skill) {return}
	curve := f64(gamedb.setting_float(db, "fSkillUseCurve", 1.95))
	return f32(calc(ws, .SkillXPToNext, f64(level), f64(rates.improve_mult), f64(rates.improve_offset), curve)), true
}

// raise_skill trains a skill up `points` levels, never past its cap, and gives the actor XP for
// each. Returns how many it rose.
raise_skill :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, skill: string, points: i32) -> i32 {
	per_rank := f64(gamedb.setting_float(db, "fXPPerSkillRank", 1))
	rose: i32
	for ; rose < points; rose += 1 {
		level := av_base(ws, db, actor, skill)
		if level >= av_train_cap(ws, db, actor, skill) {break}
		av_set_base(ws, actor, skill, level + 1)
		level_state(ws, actor).xp += f32(calc(ws, .PlayerXPFromSkill, f64(level + 1), per_rank))
		if i, ok := skill_index(skill); ok && actor == formid.PLAYER {queue_story_event(ws, {type = STORY_SKILL, value1 = i32(6 + i)})}
	}
	return rose
}

// make_legendary resets a skill at its cap to fLegendarySkillResetValue, refunds the perks the
// actor holds in its tree and marks it legendary. Level and XP stay. False below the cap.
make_legendary :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, skill: string) -> bool {
	i, ok := skill_index(skill)
	if !ok || av_base(ws, db, actor, skill) < av_train_cap(ws, db, actor, skill) {return false}
	av_set_base(ws, actor, skill, gamedb.setting_float(db, "fLegendarySkillResetValue", 15))
	s := level_state(ws, actor)
	s.perk_points += refund_perks(ws, db, actor, skill)
	s.legendary[i] += 1
	return true
}

// (hole perk-refund-hook :tags (player mods) :sev wish) the refund is engine code: a mod cannot change which perks come back or what a refund gives.
// refund_perks removes every rank the actor holds in a skill's perk tree and returns the count.
@(private)
refund_perks :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, skill: string) -> (n: i32) {
	i, _ := skill_index(skill)
	for node in gamedb.perk_tree_of(db, db.actor_value_by_index[i32(i + 6)]) {
		perk := node.perk
		for _ in 0 ..< gamedb.perk_ranks(db, node.perk) {
			if perk_has(ws, db, actor, perk) {
				perk_remove(ws, actor, perk)
				n += 1
			}
			p, _ := gamedb.perk_of(db, perk)
			perk = p.next_rank
		}
	}
	return
}

@(private)
skill_index :: proc(skill: string) -> (int, bool) {
	for name, i in gamedb.AV_NAMES[6:24] {
		if name == skill {return i, true}
	}
	return 0, false
}

// read_book is `actor` reading `book`: a skill book raises its skill by one the first time, a
// spell tome teaches its spell. True when the book is used up (a tome whose spell was new).
read_book :: proc(ws: ^World_State, db: ^gamedb.DB, actor, book: Form_ID) -> (used_up: bool) {
	b, ok := db.books[book]
	if !ok {return false}
	if b.skill < 0 {return give_spell(ws, db, actor, b.spell)}
	if book in ws.books_read || b.skill < 6 || b.skill >= 24 {return false}
	ws.books_read[book] = true
	raise_skill(ws, db, actor, gamedb.AV_NAMES[b.skill], 1)
	return false
}

add_perk_points :: proc(ws: ^World_State, actor: Form_ID, n: i32) {
	level_state(ws, actor).perk_points += n
}

// level_up_cost is the XP `actor` needs to go up from its level.
level_up_cost :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) -> f32 {
	base := f64(gamedb.setting_float(db, "fXPLevelUpBase", 75))
	mult := f64(gamedb.setting_float(db, "fXPLevelUpMult", 25))
	return f32(calc(ws, .PlayerXPToNext, f64(actor_level(ws, db, actor)), base, mult))
}

// level_up spends one ready level-up with a choice: the level rises, the choice's changes land on
// capacities, a perk point comes, and OnLevelUp goes out. False when no level-up is ready or there
// is no such choice.
level_up :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, choice: string) -> bool {
	key, c, found := level_choice(ws, choice)
	cost := level_up_cost(ws, db, actor)
	if !found || level_state(ws, actor).xp < cost {return false}
	level := actor_level(ws, db, actor) + 1
	s := level_state(ws, actor)
	s.xp -= cost
	s.level = level
	s.perk_points += 1
	for ch in c.changes {
		av, ok := av_name(ws, ch.av)
		if !ok {log.warnf("level up %q: no actor value %q", key, ch.av); continue}
		av_mod(ws, actor, av, f32(formula.eval(ch.amount, {f64(level)})))
	}
	append(&ws.level_ups, Level_Up{actor, level, strings.clone(key)})
	if actor == formid.PLAYER {queue_story_event(ws, {type = STORY_LEVEL, value1 = level})}
	return true
}

// set_level_choice adds or replaces a level-up choice (rt.level_up_choice): `changes` maps actor
// value names to formulas of `level`. On a bad formula it warns and keeps the old choice.
set_level_choice :: proc(ws: ^World_State, name: string, changes: map[string]string) -> bool {
	return put_level_choice(&ws.level_choices, name, changes)
}

@(private)
put_level_choice :: proc(choices: ^map[string]Level_Choice, name: string, changes: map[string]string) -> bool {
	c: Level_Choice
	for av, src in changes {
		f, err := formula.compile(src, LEVEL_CHOICE_VARS)
		if err != "" {
			log.warnf("script: level up choice %q, %s = %q: %s (variables %v)", name, av, src, err, LEVEL_CHOICE_VARS)
			free_choice(&c)
			return false
		}
		append(&c.changes, Level_Change{strings.clone(av), f})
	}
	if old, ok := &choices[name]; ok {
		free_choice(old)
		old^ = c
		return true
	}
	choices[strings.clone(name)] = c
	return true
}

@(private)
level_choice :: proc(ws: ^World_State, name: string) -> (key: string, c: Level_Choice, ok: bool) {
	for k, v in ws.level_choices {
		if strings.equal_fold(k, name) {return k, v, true}
	}
	return
}

@(private)
level_state :: proc(ws: ^World_State, actor: Form_ID) -> ^Level_State {
	if actor not_in ws.levels {ws.levels[actor] = {}}
	return &ws.levels[actor]
}

@(private)
free_choices :: proc(choices: ^map[string]Level_Choice) {
	for k, &c in choices {
		delete(k)
		free_choice(&c)
	}
	delete(choices^)
}

@(private)
free_choice :: proc(c: ^Level_Choice) {
	for &ch in c.changes {
		delete(ch.av)
		formula.destroy(&ch.amount)
	}
	delete(c.changes)
}

// Vanilla's choices (UESP Skyrim:Leveling): +10 to one attribute; Stamina also gives
// fLevelUpCarryWeightMod (5) carry weight.
@(private)
init_level_choices :: proc(o: ^Overlay) {
	o.level_choices = make(map[string]Level_Choice)
	defaults := [?]struct {
		name:    string,
		changes: [2][2]string,
	}{{"Health", {{"Health", "10"}, {}}}, {"Magicka", {{"Magicka", "10"}, {}}}, {"Stamina", {{"Stamina", "10"}, {"CarryWeight", "5"}}}}
	for d in defaults {
		changes := make(map[string]string, context.temp_allocator)
		for ch in d.changes {
			if ch[0] != "" {changes[ch[0]] = ch[1]}
		}
		put_level_choice(&o.level_choices, d.name, changes)
	}
}

// player_level is the level rolls start from.
player_level :: proc(ws: ^World_State, db: ^gamedb.DB) -> i32 {
	return max(actor_level(ws, db, formid.PLAYER), 1)
}
