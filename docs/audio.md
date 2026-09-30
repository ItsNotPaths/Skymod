# Audio

Skyrim: XAudio2, xWMA/FUZ, SNDR/SNCT/SOPM, MUSC/MUST, ASPC/REVB, REGN RDSA, MGEF SNDD, FSTS,
IPDS, Havok annotations. We transcode xWMA/FUZ to Ogg Opus at install and read only WAV/Ogg at run
time (open formats only; mods ship either). Records are read raw into `gamedb` and played by our
own mixer. Now: a temporary SDL3 mixer (one stream per voice, whole-file f32 decode on a worker,
linear pan + SOPM curve) with music, ambient loops, voice, use/equip/release/on-hit sounds.
Goal: vanilla trigger coverage, SOPM/REVB fidelity, streaming, voice limiting, saved instances.

Related: [animation.md](animation.md), [magic.md](magic.md), [detection.md](detection.md).

## Code map

| File | Role |
|---|---|
| [audio/audio.odin](../src/audio/audio.odin) | Device, voices, decode worker, `play_descriptor`, placement, SDL `feed` |
| [audio/triggers.odin](../src/audio/triggers.odin) | Music, ambient loops, voice lines, use/UI sounds; `impact_sound`/`anim_sound` stubs |
| [formats/ffmpeg/ffmpeg.odin](../src/formats/ffmpeg/ffmpeg.odin), [ffmpeg_glue.c](../build/ffmpeg_glue.c) | `skyff_decode/probe/to_ogg` over trimmed static LGPL FFmpeg + libopus ([build-ffmpeg.sh](../build/build-ffmpeg.sh)) |
| [installer/converters/audio.odin](../src/installer/converters/audio.odin) | xWMA → Opus 48 kb/s/ch; FUZ → `.ogg` + raw `.lip`; BSAs into `content/baseaudio` |
| [gamedb/sounds.odin](../src/gamedb/sounds.odin), [gamedb/music.odin](../src/gamedb/music.odin) | SNDR, SOUN, SNCT, SOPM, ASPC, DOBJ, base-form sounds; MUSC, MUST |
| [script/natives_sound.odin](../src/script/natives_sound.odin) | `Sound`, `SoundCategory`, `MusicType` natives |
| [script/casting.odin:68](../src/script/casting.odin#L68) | MGEF Release/On Hit sounds |
| [plugin/records_quests.odin:176](../src/plugin/records_quests.odin#L176) | Read-only sound record views for plugins |

## Boundary

Core package, not a native seam ([native-plugins.md](native-plugins.md)). Odin procs taking
`^vfs.VFS`, `^gamedb.DB`, `^worldstate.World_State`; no C ABI.

| Thread | Calls |
|---|---|
| Any (locks `Audio.mu`, non-blocking) | `queue`, `play_descriptor`, `playing`, `stop(h, fade)`, `set_volume`, `category_set`, `music_add/remove` |
| Sim, 60 Hz | `music_update`, `ambient_update` after weather ([game_frame.odin:196](../src/app/game_frame.odin#L196)); every play that reads world state (CTDA, same-space gate): natives, casts, equip, activation, `say` |
| Main, per frame | `update(camera, emitters)` ([game_frame.odin:123](../src/app/game_frame.odin#L123)), emitters from the sim snapshot, alpha-blended; UI sounds |
| Decode worker / SDL audio thread | Decode + stream bind / `feed` (atomics only) |

- Saved: nothing. Handles restart at 1; `MusicType.Add` list, category state, `Music`/`Ambient` reset.
- Menus park the sim; voices keep playing.
- A C ABI would need: commands above as `u32` handles; CTDA resolved on the sim before crossing;
  per-frame listener + `Span({Form_ID, pos})`; per-tick cell/ASPC/weather/combat; out: per-speaker
  handle + playback time, save blob.

## Holes

| id | gap | needs | mark |
|---|---|---|---|
| `region-sounds` | REGN RDSA/RDMO and ASPC RDAT (interior region) unread | - | [triggers.odin:80](../src/audio/triggers.odin#L80) |
| `anim-sounds` | No `SoundPlay.*`/`weaponSwing`/`FootLeft` sounds; FSTS/FSTP, WEAP attack sounds, NPC_ CSDT unread | `hkx-porter` | [triggers.odin:151](../src/audio/triggers.odin#L151) |
| `effect-sounds` | MGEF Sheathe/Draw, Charge, Ready, Cast Loop never play (casts are instant) | `cast-animation`, `concentration` | [natives_magic.odin:8](../src/script/natives_magic.odin#L8) |
| `music-events` | No SCMS/DTMS push | - | [triggers.odin:17](../src/audio/triggers.odin#L17) |
| `music-fades` | No fade-in; type-change fade-out inaudible | - | [triggers.odin:19](../src/audio/triggers.odin#L19) |
| `acoustic-reverb` | No REVB | - | [triggers.odin:81](../src/audio/triggers.odin#L81) |
| `impact-sounds` | Hits silent; no surface material | `havok-materials` | [triggers.odin:148](../src/audio/triggers.odin#L148) |
| `drop-sounds` | No put-down sound | - | [triggers.odin:141](../src/audio/triggers.odin#L141) |
| `ui-button-sounds` | No menu button/focus sounds | - | [triggers.odin:154](../src/audio/triggers.odin#L154) |
| `alternate-sounds` | SNDR SNAM unread | - | [sounds.odin:8](../src/gamedb/sounds.odin#L8) |
| `mod-audio-convert` | Mod `.xwm`/`.fuz` not transcoded | - | [converters/audio.odin:8](../src/installer/converters/audio.odin#L8) |
| `lip-sync-voice-map` | No speaker → handle + playback time for the face sampler | `lip-converter` | [scenes.odin:238](../src/script/lua/scenes.odin#L238) |
| `cut-line-voice` | Cut scene lines keep playing | - | [scenes.odin:230](../src/script/lua/scenes.odin#L230) |
| `voice-stale-names` | 117 SE voice files with stale quest/topic names | - | [dialogue.odin:76](../src/gamedb/dialogue.odin#L76) |
| (unmarked) | WTHR SNAM sounds, EFSH ambient sound, saved instances | - | - |

- `anim-sounds`: annotations fire on the sim in the crossing tick (`anim-events-sim`,
  [events.odin:75](../src/script/lua/events.odin#L75)); `hkx-porter` must preserve them.
- `effect-sounds`: the cast state ([magic.md](magic.md), `spell-use`) owns the phase sounds and their handles.
- `acoustic-reverb`: the mark and [sounds.odin:210](../src/gamedb/sounds.odin#L210) swap fields; reverb is ASPC BNAM, RDAT is the region.
- `impact-sounds`: note is stale; IPDS/IPCT are indexed ([gamedb.odin:219](../src/gamedb/gamedb.odin#L219)).
- Deviations now: no voice cap (SNDR priority unused), envelope loops play as plain loops, no
  HRTF/occlusion/SOPM ONAM, whole-file decode (no streaming).

## Decisions

- Audio is a service: any thread plays/stops/queries; world-state reads on the sim; main plays UI sounds only.
- Audio is core, not a native seam.
- Run time reads WAV/Ogg only, interchangeable in any slot, highest mount wins; xWMA/FUZ transcode at install.
- `Sound.Play` returns a plain saved int; audio saves playing instances and restarts them from the top on load (unbuilt).
- Scripts poll `Sound.IsPlaying`; `PlayAndWait` is not a native.
- The sim owns the animation clock; annotations never come from main's sampler.
- Lip sync translates `.lip` to our own curves; no FaceFX port.

## Open questions

- RDSA `chance` time base.
- `SoundPlayAt` argument syntax.
- FSTS DATA array order (xEdit: swim→walk; XCNT: walk→swim).
- FSTP tag ↔ annotation matching.
- Envelope Fast/Slow loop shapes.
- SNDR BNAM frequency variance signedness (we read `i8`, UESP says `u8`).
- XAudio2 as Skyrim's backend: from memory, not checked.

