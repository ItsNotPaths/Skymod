package script

// Faction relations and crime. Vanilla names the crime natives for the player: a Faction's crime
// gold is ref 0x14's bounty.

import "../formats/esm"
import "../formid"
import "../gamedb"
import "../worldstate"

register_crime :: proc(reg: ^Registry) {
	register(reg, "Faction", "GetReaction", n_get_reaction)
	register(reg, "Faction", "SetReaction", n_set_reaction)
	register(reg, "Faction", "ModReaction", n_mod_reaction)
	register(reg, "Faction", "SetEnemy", n_set_enemy)
	register(reg, "Faction", "SetAlly", n_set_ally)
	register(reg, "Faction", "GetCrimeGold", n_get_crime_gold)
	register(reg, "Faction", "GetCrimeGoldViolent", n_get_crime_gold_violent)
	register(reg, "Faction", "GetCrimeGoldNonViolent", n_get_crime_gold_nonviolent)
	register(reg, "Faction", "SetCrimeGold", n_set_crime_gold)
	register(reg, "Faction", "SetCrimeGoldViolent", n_set_crime_gold_violent)
	register(reg, "Faction", "ModCrimeGold", n_mod_crime_gold)
	register(reg, "Faction", "CanPayCrimeGold", n_can_pay_crime_gold)
	register(reg, "Faction", "PlayerPayCrimeGold", n_player_pay_crime_gold)
	register(reg, "Faction", "SetPlayerEnemy", n_set_player_enemy)
	register(reg, "Game", "SetPlayerReportCrime", n_set_player_report_crime)
	register(reg, "Faction", "SendPlayerToJail", n_send_player_to_jail)
	register(reg, "Game", "ServeTime", n_serve_time)
	register(reg, "Actor", "SendAssaultAlarm", n_send_assault_alarm)
	register(reg, "Actor", "StopCombatAlarm", n_stop_combat_alarm)
	register(reg, "Faction", "SendAssaultAlarm", n_faction_send_assault_alarm)
	register(reg, "Actor", "SetPlayerResistingArrest", n_set_player_resisting_arrest)
	register(reg, "Actor", "IsTrespassing", n_is_trespassing)
	register(reg, "ObjectReference", "SendStealAlarm", n_send_steal_alarm)
}

n_get_reaction :: proc(c: ^Call, args: []Value) -> Value {
	r, _ := worldstate.relation(c.ws, c.db, c.self, arg_form(c, args, 0))
	return r.modifier
}

n_set_reaction :: proc(c: ^Call, args: []Value) -> Value {
	other := arg_form(c, args, 0)
	r, _ := worldstate.relation(c.ws, c.db, c.self, other)
	r.modifier = arg_i32(args, 1, 0)
	worldstate.set_relation(c.ws, c.self, other, r)
	return nil
}

n_mod_reaction :: proc(c: ^Call, args: []Value) -> Value {
	other := arg_form(c, args, 0)
	r, _ := worldstate.relation(c.ws, c.db, c.self, other)
	r.modifier += arg_i32(args, 1, 0)
	worldstate.set_relation(c.ws, c.self, other, r)
	return nil
}

// SetEnemy(akOther, abSelfIsNeutralToOther = false, abOtherIsNeutralToSelf = false)
n_set_enemy :: proc(c: ^Call, args: []Value) -> Value {
	set_combat_both(c, arg_form(c, args, 0), .Neutral if arg_bool(args, 1, false) else .Enemy, .Neutral if arg_bool(args, 2, false) else .Enemy)
	return nil
}

// SetAlly(akOther, abSelfIsFriendToOther = false, abOtherIsFriendToSelf = false)
n_set_ally :: proc(c: ^Call, args: []Value) -> Value {
	set_combat_both(c, arg_form(c, args, 0), .Friend if arg_bool(args, 1, false) else .Ally, .Friend if arg_bool(args, 2, false) else .Ally)
	return nil
}

// set_combat_both sets how this faction treats `other` and how `other` treats it, keeping each
// direction's modifier.
@(private = "file")
set_combat_both :: proc(c: ^Call, other: Form_ID, mine, theirs: esm.Combat_Reaction) {
	r, _ := worldstate.relation(c.ws, c.db, c.self, other)
	r.combat = mine
	worldstate.set_relation(c.ws, c.self, other, r)
	back, _ := worldstate.relation(c.ws, c.db, other, c.self)
	back.combat = theirs
	worldstate.set_relation(c.ws, other, c.self, back)
}

@(private = "file")
player_bounty :: proc(c: ^Call) -> worldstate.Bounty {
	return worldstate.wanted(c.ws, c.ws.player, c.self).bounty
}

n_get_crime_gold :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.total(player_bounty(c))
}

n_get_crime_gold_violent :: proc(c: ^Call, args: []Value) -> Value {
	return player_bounty(c).violent
}

n_get_crime_gold_nonviolent :: proc(c: ^Call, args: []Value) -> Value {
	return player_bounty(c).nonviolent
}

n_set_crime_gold :: proc(c: ^Call, args: []Value) -> Value {
	b := player_bounty(c)
	b.nonviolent = arg_i32(args, 0, 0)
	worldstate.set_faction_bounty(c.ws, c.ws.player, c.self, b)
	return nil
}

n_set_crime_gold_violent :: proc(c: ^Call, args: []Value) -> Value {
	b := player_bounty(c)
	b.violent = arg_i32(args, 0, 0)
	worldstate.set_faction_bounty(c.ws, c.ws.player, c.self, b)
	return nil
}

// ModCrimeGold(aiAmount, abViolent = false)
n_mod_crime_gold :: proc(c: ^Call, args: []Value) -> Value {
	b := player_bounty(c)
	if arg_bool(args, 1, false) {b.violent += arg_i32(args, 0, 0)} else {b.nonviolent += arg_i32(args, 0, 0)}
	worldstate.set_faction_bounty(c.ws, c.ws.player, c.self, b)
	return nil
}

n_can_pay_crime_gold :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.inv_count(c.ws, c.db, c.ws.player, formid.GOLD) >= worldstate.total(player_bounty(c))
}

// PlayerPayCrimeGold(abRemoveStolenItems = true, abGoToJail = true): the gold goes, the bounty
// clears and the stolen things go to the jail's evidence chest (UESP: "all stolen items in your
// possession will be seized"); abGoToJail takes the player outside the faction's jail (UESP:
// "transport outside the nearest jail").
n_player_pay_crime_gold :: proc(c: ^Call, args: []Value) -> Value {
	move_items(c, {base = formid.GOLD, from = c.ws.player, count = worldstate.total(player_bounty(c))})
	worldstate.pay_bounty(c.ws, c.db, c.ws.player, c.self)
	if arg_bool(args, 0, true) {
		f, _ := worldstate.faction(c.ws, c.db, c.self)
		for s in worldstate.inv_stacks(c.ws, c.db, c.ws.player) {
			if s.stolen {move_items(c, {base = s.item, from = c.ws.player, to = f.stolen_chest, count = s.count, stolen = true})}
		}
	}
	if _, outside, ok := worldstate.jail_spots(c.ws, c.db, c.self); ok && arg_bool(args, 1, true) {
		worldstate.relocate(c.ws, c.ws.player, outside.cell, outside.pos, outside.rot)
	}
	return nil
}

// SendPlayerToJail(abRemoveInventory = true, abRealJail = true): the guard the player talks to
// takes it in.
n_send_player_to_jail :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.send_to_jail(c.ws, c.db, c.ws.player, c.self, c.ws.talking)
	return nil
}

n_serve_time :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.serve_time(c.ws, c.ws.player)
	return nil
}

n_set_player_enemy :: proc(c: ^Call, args: []Value) -> Value {
	w := worldstate.wanted(c.ws, c.ws.player, c.self)
	w.enemy = arg_bool(args, 0, true)
	worldstate.set_wanted(c.ws, c.ws.player, c.self, w)
	return nil
}

n_set_player_report_crime :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_reports_crime(c.ws, c.ws.player, arg_bool(args, 0, true))
	return nil
}

// SendAssaultAlarm: this actor was assaulted by the player; it reports it and fights back.
n_send_assault_alarm :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.report_crime(c.ws, c.db, c.ws.player, c.self, .Assault, 0)
	worldstate.strike(c.ws, c.self, c.ws.player)
	return nil
}

// StopCombatAlarm: this actor and everyone fighting it stop.
n_stop_combat_alarm :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.ask_combat(c.ws, c.self, 0)
	for actor, target in c.ws.ai.fighting {
		if target == c.self {worldstate.ask_combat(c.ws, actor, 0)}
	}
	return nil
}

// Faction.SendAssaultAlarm: every loaded member of this faction attacks the player.
n_faction_send_assault_alarm :: proc(c: ^Call, args: []Value) -> Value {
	for actor in c.ws.ai.loaded {
		if actor != c.ws.player && worldstate.in_faction(c.ws, c.db, actor, c.self) {worldstate.ask_combat(c.ws, actor, c.ws.player)}
	}
	return nil
}

// SendStealAlarm(akThief): akThief stole this ref (an item or a container) from its owner.
n_send_steal_alarm :: proc(c: ^Call, args: []Value) -> Value {
	thief := arg_form(c, args, 0)
	victim := worldstate.robbed(c.ws, c.db, thief, c.self)
	if victim == 0 {victim = worldstate.owner(c.ws, c.db, c.self)}
	value, _ := gamedb.value_of(c.db, worldstate.ref_base(c.ws, c.db, c.self))
	worldstate.report_crime(c.ws, c.db, thief, victim, .Steal, value)
	return nil
}

// SetPlayerResistingArrest: the player resists this guard; its crime faction attacks the player.
n_set_player_resisting_arrest :: proc(c: ^Call, args: []Value) -> Value {
	faction := worldstate.crime_faction(c.ws, c.db, c.self)
	if faction == 0 {return nil}
	w := worldstate.wanted(c.ws, c.ws.player, faction)
	w.enemy = true
	worldstate.set_wanted(c.ws, c.ws.player, faction, w)
	return nil
}

n_is_trespassing :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.is_trespassing(c.ws, c.db, c.self)
}
