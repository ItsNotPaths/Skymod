package worldstate

import "core:math"
import "core:math/linalg"
import "../combat"
import "../gamedb"

// Flight is a projectile in the air: its created ref (a PROJ base), who shot it, the weapon whose
// enchantment it carries, and the damage it deals. pos is the body origin and vel its velocity, as
// of the last tick. It ends in a live actor, or embedded where it lands.
Flight :: struct {
	ref, shooter, weapon: Form_ID,
	damage:               f32,
	pos, vel:             [3]f32,
	travelled:            f32,
	launched:             bool, // its body got pos and vel (not saved: a load launches it again)
}

in_flight :: proc(ws: ^World_State, ref: Form_ID) -> bool {
	for f in ws.projectiles {if f.ref == ref {return true}}
	return false
}

// Hit is an attack that landed, for OnHit: `source` is the weapon or spell, `projectile` the PROJ.
Hit :: struct {
	target, aggressor, source, projectile: Form_ID,
	kind:                                  combat.Attack_Kind,
}

// strike records that `attacker` hit `victim`, for the victim's combat to answer.
strike :: proc(ws: ^World_State, victim, attacker: Form_ID) {
	if attacker != 0 && attacker != victim {ws.struck[victim] = attacker}
}

// (hole friend-hit-reset :tags combat :sev polish) unsourced: whether a friend's count of hits ever resets; it never does.
// friend_hit counts a hit by `attacker` on a friend that is not fighting it (a faction ally or
// friend, or a relationship rank above acquaintance): true while the friend lets it go, for
// iFriendHitCombatAllowed hits. GetFriendHit reads the count.
friend_hit :: proc(ws: ^World_State, db: ^gamedb.DB, victim, attacker: Form_ID) -> bool {
	if ws.ai.fighting[victim] == attacker {return false}
	if faction_relation(ws, db, victim, attacker) < .Ally && rel_rank(ws, db, victim, attacker) < 1 {return false}
	n := ws.friend_hits[{victim, attacker}] + 1
	ws.friend_hits[{victim, attacker}] = n
	return n <= gamedb.setting_int(db, "iFriendHitCombatAllowed", 4)
}

// take_struck is who last hit `victim`, once.
take_struck :: proc(ws: ^World_State, victim: Form_ID) -> (Form_ID, bool) {
	by, ok := ws.struck[victim]
	if ok {delete_key(&ws.struck, victim)}
	return by, ok
}

// set_alarmed is whom `actor` fights or confronts; 0 calms it.
set_alarmed :: proc(ws: ^World_State, actor, at: Form_ID) {
	if at == 0 {delete_key(&ws.alarmed, actor)} else {ws.alarmed[actor] = at}
}

// Fire is a Weapon.Fire the app has not resolved yet: the source ref's ProjectileNode is in its model.
Fire :: struct {
	source, weapon, ammo: Form_ID,
}

request_fire :: proc(ws: ^World_State, source, weapon, ammo: Form_ID) {
	append(&ws.fires, Fire{source, weapon, ammo})
}

// Critical is an actor's death in progress (SetCriticalStage): its stage, and the ash pile it
// leaves at DisintegrateEnd (AttachAshPile).
Critical :: struct {
	stage: Critical_Stage,
	ash:   Form_ID,
}

Critical_Stage :: enum i32 {
	None,
	Goo_Start,
	Goo_End,
	Disintegrate_Start,
	Disintegrate_End,
}

// cause is whom a hit from `ref` counts as: its SetActorCause actor, else itself.
cause :: proc(ws: ^World_State, ref: Form_ID) -> Form_ID {
	return ws.causes[ref] or_else ref
}

// Swing is an actor swinging its weapon; the app lands it on what is in reach.
Swing :: struct {
	attacker: Form_ID,
	kind:     combat.Attack_Kind,
	hand:     gamedb.Slot,
}

request_swing :: proc(ws: ^World_State, attacker: Form_ID, kind: combat.Attack_Kind, hand := gamedb.Slot.RightHand) {
	append(&ws.swings, Swing{attacker, kind, hand})
}

// launch creates a projectile's ref at pos, pointing along dir, and starts its flight.
launch :: proc(ws: ^World_State, db: ^gamedb.DB, proj, cell: Form_ID, pos, dir: [3]f32, shooter, weapon: Form_ID, damage: f32) {
	p, ok := gamedb.projectile_of(db, proj)
	if !ok {return}
	ref := create_ref(ws, proj, cell, pos, heading_rot(dir), 1)
	mark_scene_dirty(ws, ref)
	append(&ws.projectiles, Flight{ref = ref, shooter = shooter, weapon = weapon, damage = damage, pos = pos, vel = linalg.normalize(dir) * p.speed})
}

// heading_rot is a REFR rotation whose +Y points along dir. smath.trs turns +Y to
// (sin z, cos z cos x, -cos z sin x).
heading_rot :: proc(dir: [3]f32) -> [3]f32 {
	d := linalg.normalize(dir)
	return {math.atan2(-d.z, d.y), 0, math.atan2(d.x, math.sqrt(d.y * d.y + d.z * d.z))}
}
