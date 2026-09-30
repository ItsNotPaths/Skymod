# Detection and sight

Skyrim's detection is exe logic tuned by `fSneak*`/`fDetection*` GMSTs and fed by
`CreateDetectionEvent`. We reimplement it on the sim thread behind two native seams
(`skymod_detection`, `skymod_sight`), because no record holds the model and it must tick at 60 Hz
apart from render. Stub now: 3-pick Jolt LOS with a 190-degree cone and cutout dimming is real,
but `judge` treats any sight as detected, light is always 1, and noise and Invisibility are ignored.
Goal: a faithful awareness model that writes the same saved store.

## Code map

| File | Role |
|---|---|
| [detection/detection.odin](../src/detection/detection.odin) | Seam v2: `Table{tick, judge}`, `Input`, `Host`; built-in tick (6-group stagger, fade, look), `heard` |
| [detection/model.odin](../src/detection/model.odin) | `Senses`, `judge_builtin` stub |
| [sight/sight.odin](../src/sight/sight.odin) | Seam v1: `Mode{Raw, Cone, Detect}`, `Table{level, has_los, range, light}`, picks, cone, cutout attenuation |
| [sighthost/sighthost.odin](../src/sighthost/sighthost.odin) | Engine side of sight: player eye/VP (package globals), `hits` over `physics.ray_hits` |
| [app/seams.odin](../src/app/seams.odin) | Actor snapshot, `detection_tick`, noise window + footsteps, applies `set`s |
| [worldstate/awareness.odin](../src/worldstate/awareness.odin) | Awareness store API, `Noise`, `make_noise`, `sound_level` |
| [worldstate/save.odin:191](../src/worldstate/save.odin#L191) | `Saved_Awareness`; load remaps IDs, drops missing forms |
| [plugin/world.odin](../src/plugin/world.odin) | `World` query table every seam gets (AVs, GMSTs, refs, awareness) |
| [condfn/condfn.odin](../src/condfn/condfn.odin) | `skymod_conditions`: a plugin can answer CTDA 711 GetLightLevel, which has no engine function |
| [physics/physics.odin:97](../src/physics/physics.odin#L97) | `LAYER_SIGHT`: cutout bodies, seen only by `ray_hits(cutouts = true)` |
| [assetdb/collision_fill.odin:40](../src/assetdb/collision_fill.odin#L40) | `cutout_mesh`: alpha-tested shapes or canopy lathe hull |
| [script/natives_ref.odin:63](../src/script/natives_ref.odin#L63) | `HasLOS`, `GetSightLevel` (ours, mode 0-2), `IsDetectedBy` |
| [app/hud.odin:100](../src/app/hud.odin#L100) | Stealth eye: max `level` and any `detected` against the player |
| [tests/plugins/detection_blind](../tests/plugins/detection_blind/detection_blind.odin), [sight_blind](../tests/plugins/sight_blind/sight_blind.odin) | Example seam plugins |

## Boundary

- **Thread and tick:** sim thread, in `game_tick`. Order: snapshot, detection, combat, crime
  ([actors.odin:82](../src/app/actors.odin#L82)), then the physics step. Rays run unlocked
  because Jolt is not stepping. Scripts query sight after the step.
- **Detection in:** `Span(Actor){id, space, interior, pos, speed, dead, sneaking}`, the whole
  store before the tick (`known`), noises of the last 6 ticks, and host `sight` (Cone),
  `range` and `light`.
- **Detection out:** only `Host.set(Pair)`. Sets are buffered and applied after `tick`; the last
  write wins; `{0, false}` deletes the pair ([seams.odin:81](../src/app/seams.odin#L81)).
- **Sight:** `level`/`has_los`/`range`/`light` over `Host{eye, vp, hits}`. Callers are the
  detection host, HasLOS, RegisterForLOS, CTDA 27 and AI procedures.
- **Saved:** `ws.awareness` (`{viewer, target} -> {level, detected}`), in full. Noises are not saved.
- **Readers of `detected`:** combat seam ([combat.odin:173](../src/combat/combat.odin#L173)),
  sneak-attack flag ([damage.odin:23](../src/script/damage.odin#L23)), crime witnesses
  ([crime.odin:175](../src/worldstate/crime.odin#L175)), CTDA 45, `IsDetectedBy`.
- **Main thread:** gets only `Hud_View.detection`/`.detected` in the snapshot.
- **ABI gaps:** `judge` gets no IDs, so it cannot read Sneak, armor or Invisibility; `Senses`
  has no actions; no detection edge events; no last-known position; `light` is per ref, not
  per point; `sighthost` state is global.

## Holes

| id | gap | needs | mark |
|---|---|---|---|
| sneak-detection | Real model: skill, light, noise, movement, armor, cone, cutout cover | light-at-point | [model.odin:6](../src/detection/model.odin#L6) |
| light-at-point | `light` returns 1; no lighting on the sim | day-night | [sight.odin:85](../src/sight/sight.odin#L85) |
| invisibility-read | `Invisibility` AV (set by MGEF archetype 11) unread; acting does not end it | - | [model.odin:7](../src/detection/model.odin#L7) |
| sound-occlusion | Hearing is distance only | - | [detection.odin:103](../src/detection/detection.odin#L103) |
| detection-events | No detected/lost edges (blocks combat-barks) | - | [awareness.odin:21](../src/worldstate/awareness.odin#L21) |
| sound-level-normal | `iSoundLevelNormal` 50 is a guess | - | [awareness.odin:44](../src/worldstate/awareness.odin#L44) |
| view-cone-source | 190-degree cone unsourced | - | [sight.odin:57](../src/sight/sight.odin#L57) |
| cutout-cover-source | `CUTOUT_COVER` 0.4 is a guess | - | [sight.odin:60](../src/sight/sight.odin#L60) |

- sneak-detection: a model needing actor values must replace `tick`, or bump VERSION to add
  IDs to `Senses`.
- light-at-point: LIGH `DATA`, `XCLL`/`LTMP`, LGTM, WTHR and CLMT are not parsed yet. Share the
  parsers with render ([render.md](render.md)).
- invisibility-read: breaking on action needs a dispel on the magic side ([magic.md](magic.md)).
  The see-through draw is render's `actor-alpha-render`.

## Decisions

- `worldstate.awareness` is the one read (combat, conditions, stealth meter, sneak attacks); only the model writes it.
- The real model replaces `judge` behind the same `Senses` and store.
- Light goes with lighting and weather; hearing goes with the model.
- Light is computed on the sim from LIGH refs, cell lighting, the clock and weather, never from render state.
- Detection runs before combat each tick.
- Seams are native-only, plain data; seam packages import only `core`, `base`, `formid`, `plugin`.
- The player is an ordinary actor row; `World.player` = the controlled actor.
- HasLOS follows the CK: 3 picks, NPCs see only actors, the player is clipped to the camera; an NPC's has_los has no cone.
- Cutouts dim sight and block nothing; refs with moving bodies get no cutout.
- Papyrus `GetLightLevel` returns 100 until light exists ([registry.odin:164](../src/script/registry.odin#L164)).

## Open questions

- Which GMST fills which term of the UESP formula (matched by value only).
- The visual/light term and how the light GMSTs combine.
- The eye-state thresholds.
- How the 0..1 seam light maps to the `GetLightLevel` scale (scripts compare against 30; `iLightLevelMax` is 300).
- The vanilla view-cone angle: Skyrim.esm has no cone GMST.
- `iSoundLevelNormal`: absent from the esm.
- Four CK links (IsDetectedBy, GetDetected, GetLightLevel, CreateDetectionEvent) not fetched (403).

