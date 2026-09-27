package audio

// What starts a sound. Records name the sound; these say when.

import "../formid"
import "../gamedb"
import "../vfs"
import "../worldstate"

// (hole music-system :tags audio :sev gap :needs (music-records)) no music: nothing picks a MUSC type (DOBJ battle BTMS, death, success, level-up, dungeon-cleared; cell XCMO, worldspace ZNAM; script MusicType.Add by priority) or plays its MUST tracks.
music_update :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State) {}

// (hole ambient-sounds :tags (audio world) :sev gap) no ambient sound: placed SOUN markers (997 in Skyrim.esm), acoustic spaces (ASPC loop + reverb, cell XCAS) and region sounds (REGN RDSA, by weather and hour) are silent. ASPC and RDSA are not decoded.
ambient_update :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State) {}

// (hole form-sounds :tags audio :sev gap) equipping, drinking and putting an item down make no sound, and an activator's or light's loop sound (ACTI, LIGH SNAM) does not play.
// activate_sound plays the sound of a ref's base where the ref is, when it is used (a door or
// container opens, an item is picked up), or with done when done with (a container closes).
activate_sound :: proc(a: ^Audio, v: ^vfs.VFS, db: ^gamedb.DB, ws: ^worldstate.World_State, ref: formid.Form_ID, done := false) {
	play_descriptor(a, v, db, gamedb.base_sound(db, worldstate.ref_base(ws, db, ref), done), worldstate.ref_pos(ws, db, ref))
}

// (hole impact-sounds :tags (audio combat) :sev gap) a hit makes no sound: IPDS (220) and IPCT (515) are not decoded, and no surface material picks the row. Melee hits wait on combat-damage.
impact_sound :: proc(db: ^gamedb.DB, source, target: formid.Form_ID, pos: [3]f32) {}

// (hole anim-sounds :tags (audio animation unclaimed) :sev gap :needs (hkx-porter)) no animation plays a sound: SoundPlay/SoundStop/SoundPlayAt annotations (727 SNDR names over 800 SE clips; 90 of 183 dragon clips), weaponSwing (the WEAP attack sound) and FootLeft/FootRight (FSTS/FSTP footstep sets, by gait and ground material; not decoded) have no animation to fire them.
anim_sound :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State, actor: formid.Form_ID, event: string) {}

// (hole ui-sounds :tags (audio ui) :sev gap) menus are silent: Skyrim's menus play SNDRs by editor ID (UIMenuOK...), and the Lua UI has no call to play one.
ui_sound :: proc(db: ^gamedb.DB, edid: string) {}
