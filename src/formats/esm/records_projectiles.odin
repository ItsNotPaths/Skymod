package esm

// Projectile is a PROJ's flight. DATA is 92 bytes on 231 of 237 vanilla records; the rest end early,
// after the fields kept here.
Projectile :: struct {
	type:             Projectile_Type,
	flags:            u16, // PROJ_*
	gravity:          f32, // times world gravity: 0 dart, 0.35 iron arrow
	speed:            f32, // units per second
	range:            f32,
	explosion:        Form_ID, // raw; used only with PROJ_EXPLOSION
	impact_force:     f32,
	collision_radius: f32,
	lifetime:         f32, // seconds; 0 = until its range runs out
}

Projectile_Type :: enum u16 {
	Missile = 0x01,
	Lobber  = 0x02,
	Beam    = 0x04,
	Flame   = 0x08,
	Cone    = 0x10,
	Barrier = 0x20,
	Arrow   = 0x40,
}

PROJ_EXPLOSION :: 0x0002
PROJ_CAN_PICK_UP :: 0x0040

projectile :: proc(fields: []Field) -> (p: Projectile, ok: bool) {
	f := find_field(fields, "DATA") or_return
	if len(f.data) < 80 {return}
	d := f.data
	return {
		flags = rd16(d, 0),
		type = Projectile_Type(rd16(d, 2)),
		gravity = rf32(d, 4),
		speed = rf32(d, 8),
		range = rf32(d, 12),
		explosion = Form_ID(rd32(d, 36)),
		impact_force = rf32(d, 52),
		collision_radius = rf32(d, 72),
		lifetime = rf32(d, 76),
	}, true
}

// item_damage reads a WEAP's base damage (DATA u16) or an AMMO's (DATA f32) and the PROJ it flies
// as (raw). AMMO DATA is 16 bytes on LE and 20 on SE, which adds weight.
item_damage :: proc(rec_type: string, fields: []Field) -> (damage: f32, projectile: u32) {
	f, ok := find_field(fields, "DATA")
	switch {
	case !ok:
	case rec_type == "WEAP" && len(f.data) >= 10:
		damage = f32(rd16(f.data, 8))
	case rec_type == "AMMO" && len(f.data) >= 12:
		damage, projectile = rf32(f.data, 8), rd32(f.data, 0)
	}
	return
}
