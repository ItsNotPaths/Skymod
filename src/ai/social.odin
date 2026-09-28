package ai

// Actors among others, once per tick over the loaded actors, as the running package's interrupt
// flags allow: Hellos to the player, idle chatter, random conversations (ADIA story event), hellos
// between actors (AHEL) and finding bodies (DEAD). Timers, chances and radii are game settings.

import "core:math/linalg"
import "core:math/rand"
import "../formid"
import "../gamedb"
import "../sighthost"
import "../worldstate"

// PKDT interrupt flags (xEdit wbPKDTInterruptFlags).
INTERRUPT_HELLO :: 0x1
INTERRUPT_CONVERSATION :: 0x2
INTERRUPT_GREET_CORPSE :: 0x8
INTERRUPT_IDLE_CHATTER :: 0x80

SOCIAL_TIMER :: [2]f32{10, 30} // fAISocialTimerForConversationsMin/Max
CONVERSATION_CHANCE :: f32(0.1) // fAISocialChanceForConversation (10)
CONVERSATION_RADIUS :: f32(500) // fAISocialRadiusToTriggerConversation
SOCIAL_EVENT_DISTANCE :: f32(200) // iAISocialDistanceToTriggerEvent
CHATTER_TIMER :: [2]f32{10, 20} // fIdleChatterCommentTimer/Max

HELO :: [4]u8{'H', 'E', 'L', 'O'}
IDLE :: [4]u8{'I', 'D', 'L', 'E'}

// (hole combat-barks :tags (dialogue combat) :sev gap :needs (detection-events)) no combat or detection lines (Attack, Taunt, Flee, Block, AlertIdle, LostToNormal...): nothing sends the moments they belong to. Hit (from projectiles) and death cries are said.
// (hole social-timing :tags (ai dialogue) :sev polish) unsourced: a Hello fires once as the player comes within iAISocialDistanceToTriggerEvent and re-arms at twice that; one idle line per fIdleChatterCommentTimer among the actors within CONVERSATION_RADIUS of the player; conversations, AHEL and body finds are checked on each actor's social timer, bodies within CONVERSATION_RADIUS in sight, AHEL between NPCs only.
tick_social :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, loaded: map[Form_ID]bool, dt: f32) {
	player := worldstate.ref_pos(ws, db, ws.player)
	chatty := make([dynamic]Form_ID, context.temp_allocator)
	for actor in loaded {
		a, ok := &w.agents[actor]
		if !ok || actor == ws.player || worldstate.is_dead(ws, db, actor) || busy(ws, db, actor, a) {continue} // input, not its AI, drives the player
		flags := interrupt_flags(db, a.pack)
		feet := worldstate.ref_pos(ws, db, actor)
		to_player := apart(ws, db, actor, ws.player, feet, player)
		if flags & INTERRUPT_HELLO != 0 {hello(ws, db, actor, a, to_player)}
		if flags & INTERRUPT_IDLE_CHATTER != 0 && to_player <= CONVERSATION_RADIUS {append(&chatty, actor)}
		a.social_in -= dt
		if a.social_in > 0 {continue}
		a.social_in = rand.float32_range(SOCIAL_TIMER[0], SOCIAL_TIMER[1])
		look_around(w, ws, db, loaded, actor, flags, feet)
	}
	w.chatter_in -= dt
	if w.chatter_in > 0 {return}
	w.chatter_in = rand.float32_range(CHATTER_TIMER[0], CHATTER_TIMER[1])
	if len(chatty) > 0 {append(&ws.barks, worldstate.Bark{speaker = rand.choice(chatty[:]), subtype = IDLE})}
}

// hello greets the player once as they come near and in sight.
@(private = "file")
hello :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID, a: ^Agent, to_player: f32) {
	if to_player > 2 * SOCIAL_EVENT_DISTANCE {a.greeted = false}
	if a.greeted || to_player > SOCIAL_EVENT_DISTANCE || !sighthost.has_los(ws, db, actor, ws.player) {return}
	a.greeted = true
	append(&ws.barks, worldstate.Bark{speaker = actor, to = ws.player, subtype = HELO})
}

// look_around reports the bodies the actor sees, then may start a conversation with the nearest
// free actor who may talk too, else says hello to one passing close.
@(private = "file")
look_around :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, loaded: map[Form_ID]bool, actor: Form_ID, flags: u16, feet: [3]f32) {
	loc := worldstate.ref_location(ws, db, actor)
	partner, partner_d := Form_ID(0), CONVERSATION_RADIUS
	for other in loaded {
		if other == actor {continue}
		d := apart(ws, db, actor, other, feet, worldstate.ref_pos(ws, db, other))
		if d > CONVERSATION_RADIUS {continue}
		if worldstate.is_dead(ws, db, other) {
			if flags & INTERRUPT_GREET_CORPSE != 0 && !w.found[{actor, other}] && sighthost.has_los(ws, db, actor, other) {
				w.found[{actor, other}] = true
				worldstate.queue_story_event(ws, {type = worldstate.STORY_DEAD_BODY, ref1 = actor, ref2 = other, location1 = loc})
			}
			continue
		}
		o, ok := &w.agents[other]
		if ok && d < partner_d && !busy(ws, db, other, o) {partner, partner_d = other, d}
	}
	if partner == 0 {return}
	talks := flags & INTERRUPT_CONVERSATION != 0 && interrupt_flags(db, w.agents[partner].pack) & INTERRUPT_CONVERSATION != 0
	if talks && rand.float32() < CONVERSATION_CHANCE {
		worldstate.queue_story_event(ws, {type = worldstate.STORY_DIALOGUE, ref1 = actor, ref2 = partner, location1 = loc})
	} else if partner_d <= SOCIAL_EVENT_DISTANCE {
		worldstate.queue_story_event(ws, {type = worldstate.STORY_HELLO, ref1 = actor, ref2 = partner, location1 = loc})
	}
}

// busy: talking to the player, in a scene or a fight, or saying a line.
@(private = "file")
busy :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID, a: ^Agent) -> bool {
	return ws.talking == actor || a.combat.state != .None || worldstate.speaking(ws, actor) || worldstate.scene_of_actor(ws, db, actor) != 0
}

// interrupt_flags are the running package's; an actor with none allows everything.
@(private = "file")
interrupt_flags :: proc(db: ^gamedb.DB, pack: Form_ID) -> u16 {
	p, ok := gamedb.package_of(db, pack)
	return p.interrupt_flags if ok else max(u16)
}

// apart is the flat distance between two refs in the same interior or worldspace; max(f32) otherwise.
@(private = "file")
apart :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, a, b: Form_ID, pa, pb: [3]f32) -> f32 {
	if space(db, worldstate.ref_grid_cell(ws, db, a)) != space(db, worldstate.ref_grid_cell(ws, db, b)) {return max(f32)}
	return linalg.length(pa.xy - pb.xy)
}
