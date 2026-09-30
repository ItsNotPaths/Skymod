# Animation

Skyrim: Havok Behavior 2010.2 graphs + Havok Animation clips (annotations, `animationdatasinglefile.txt`
motion data), Havok ragdolls from `skeleton.nif`, Gamebryo controller sequences on props, FaceFX `.lip`.
We translate at install and never read `.hkx` at run time: no shippable Havok runtime, LE 32-bit and SE
64-bit packfiles must be one union, and graph reproduction and Nemesis/Pandora patching are ruled out
in favor of one actor-state model ([actor-states.md](actor-states.md)).
Now: actors are Jolt `CharacterVirtual` capsules, meshes draw in bind pose, animation natives return zero.
Goal: porter → read-only clip store → sim-side `(clip, t)` clock at 60 Hz (annotations, root motion,
hitbox bones) → snapshot record → main samples the full skeleton at interpolated `t` for skinning.

## Code map

| File | Role |
|---|---|
| [app/actors.odin:59](../src/app/actors.odin#L59) | `tick_actor_bodies`: AI velocity → `character_move`; root-motion point at [:120](../src/app/actors.odin#L120) |
| [app/actors.odin:37](../src/app/actors.odin#L37) | `Actor_Body`: per-actor sim record; animation state goes beside it |
| [app/actors.odin:113](../src/app/actors.odin#L113) | seated actors pinned to `ai.seated` ([ai/furniture.odin:224](../src/ai/furniture.odin#L224)) |
| [app/actors.odin:246](../src/app/actors.odin#L246) | `Actor_View`: snapshot actor record; capsule only, no pose |
| [app/game_frame.odin:154](../src/app/game_frame.odin#L154) | `game_tick` order: actors [:181](../src/app/game_frame.odin#L181), swings [:184](../src/app/game_frame.odin#L184), scripts [:199](../src/app/game_frame.odin#L199), publish [:202](../src/app/game_frame.odin#L202) |
| [app/melee.odin:17](../src/app/melee.odin#L17) | `tick_swings`: hit resolves the tick it is requested; no hit frame |
| [app/sim.odin:197](../src/app/sim.odin#L197) | `Snapshot`: poses are tick segments, main blends by `alpha` ([:85](../src/app/sim.odin#L85)) |
| [handoff/handoff.odin:42](../src/handoff/handoff.odin#L42) | `Latest`: triple-buffered sim → main publish |
| [physics/physics.odin:780](../src/physics/physics.odin#L780) | `Character`; `character_move` [:842](../src/physics/physics.odin#L842) takes horizontal `[2]f32` u/s |
| [graphics/graphics.odin:29](../src/graphics/graphics.odin#L29) | `skymod_graphics` seam `Actor`: blended feet + capsule; [`Frame`](../src/graphics/graphics.odin#L88) |
| [world/poses.odin:22](../src/world/poses.odin#L22) | `Poses`: whole rigid bodies only, no node poses |
| [collisions/collisions.odin:46](../src/collisions/collisions.odin#L46) | store pattern to copy: read-miss = request, `take_wanted` [:75](../src/collisions/collisions.odin#L75), immutable entries |
| [installer/installer.odin:158](../src/installer/installer.odin#L158) | versioned install parts ([:35](../src/installer/installer.odin#L35)); porter needs its own |
| [installer/converters/scripts.odin](../src/installer/converters/scripts.odin) | pex→lua: the shape the porter copies |
| [formats/nif/nodes.odin:99](../src/formats/nif/nodes.odin#L99) | `walk_node` bakes node transforms; `controller_ref` unused ([:86](../src/formats/nif/nodes.odin#L86)) |
| [formats/nif/blocks.odin:410](../src/formats/nif/blocks.odin#L410) | skin partition: bone indices skipped |
| [gamedb/actors.odin:21](../src/gamedb/actors.odin#L21) | `Race.skeletons` (ANAM); WKMV/RNMV decoded |
| [app/cell_load.odin:48](../src/app/cell_load.odin#L48) | `Skyrim - Animations.bsa` not mounted |
| [script/registry.odin:158](../src/script/registry.odin#L158) | unimplemented manifest natives return their type's zero |
| [script/lua/events.odin:80](../src/script/lua/events.odin#L80) | `send_anim_event` → `OnAnimationEvent`; Lua `rt.anim_event` ([rt.lua:1105](../src/script/lua/rt.lua#L1105)) |
| [worldstate/scripts.odin:90](../src/worldstate/scripts.odin#L90) | `RegisterForAnimationEvent` store |
| [script/patches](../src/script/patches) | 169 rewrites already use `PlayAnimation` + `OnAnimationEvent`/`IsAnimRunning` |
| [magicphys/magicphys.odin:83](../src/magicphys/magicphys.odin#L83) | host `anchor(actor, name) → {pos, dir}` |
| [audio/triggers.odin:152](../src/audio/triggers.odin#L152) | `anim_sound`: empty sink for sound annotations |

## Boundary

Not a plugin seam; only plain data crosses threads (IDs, POD, `plugin.Span`), never pointers.

| In | From | When |
|---|---|---|
| actor state + changes | `actorstate.current`, `drain` | sim, per tick |
| velocity, facing, seat pose | `ai.tick_loaded`, `ai.seated` | sim, per tick |
| graph calls | `PlayAnimation`, `SendAnimationEvent`, `PlayIdle`, `SetLookAt`, graph vars | sim, script phase |
| swing / cast requests | `ws.swings`, `cast_hand` | sim |
| clips, skeletons, state data | porter output via clip store | streamer → store |

| Out | To | When |
|---|---|---|
| root-motion velocity | replaces/scales `vel` before `character_move` | sim, same tick |
| annotations | `send_anim_event`, combat hit frame, `audio.anim_sound` | sim, crossing tick; before `tick_swings` |
| bone poses | hitboxes, magic anchors, ragdoll | sim, per tick |
| clip-done read | `IsAnimRunning`, guards | sim |
| per-actor record | snapshot → main | per tick |
| skinning palette | graphics seam | main, per frame |
| prop node poses | physics, snapshot | sim |

Missing contract (sketch): `Actor_View` + state, heading, layers `(clip_id, t_from, t_to, weight)`, cut
flag, look-at target, `attached_to (form, bone)`; main samples `lerp(t_from, t_to, alpha)`, no blend
across a cut. `graphics.Actor` + palette or `(clip, t)`; bump seam `VERSION` (now 3); seam packages import
only `core:`, `base:`, `formid`, `plugin`.
Saved now: actor states by name ([save.odin:373](../src/worldstate/save.odin#L373)), anim registrations
([:401](../src/worldstate/save.odin#L401)). No `(clip, t)` is saved.

## Holes

| id | gap | needs | marks |
|---|---|---|---|
| animation | no skeleton, no sampling, nothing plays | hkx-porter, skinned-pipeline | [nodes.odin:99](../src/formats/nif/nodes.odin#L99), [actors.odin:56](../src/app/actors.odin#L56) |
| hkx-porter | no install-time port of skeletons, clips, behavior projects (vanilla + Nemesis/Pandora) | actor-states | [converters.odin:10](../src/installer/converters/converters.odin#L10) |
| anim-clip-store | no read-only store both threads read | hkx-porter | [converters.odin:3](../src/installer/converters/converters.odin#L3) |
| anim-state-snapshot | actor view is capsule only | — | [actors.odin:34](../src/app/actors.odin#L34) |
| anim-events-sim | annotations never fire | animation | [events.odin:75](../src/script/lua/events.odin#L75) |
| root-motion-velocity | movement is AI velocity only | animation | [actors.odin:120](../src/app/actors.odin#L120) |
| anim-natives | `PlayAnimation` (296), `PlayAnimationAndWait` (309) stubbed; `IsAnimRunning` false | animation | [natives.odin:13](../src/script/natives.odin#L13), [:14](../src/script/natives.odin#L14), [:345](../src/script/natives.odin#L345) |
| anim-graph-names | no map from Havok event/variable names to states | actor-states | [events.odin:76](../src/script/lua/events.odin#L76) |
| sit-rotation-read | `SetSittingRotation` has no read | animation | [natives.odin:22](../src/script/natives.odin#L22) |
| prop-node-poses | moving-collision props need sim-driven node poses | animation | [nodes.odin:97](../src/formats/nif/nodes.odin#L97) |
| idle-graph | IDLE, ANIO not decoded (IDLM flags only) | actor-states | [nodes.odin:98](../src/formats/nif/nodes.odin#L98) |
| look-at-target | no per-actor look-at store on the sim | anim-state-snapshot | [natives_ai.odin:8](../src/script/natives_ai.odin#L8) |
| look-at | `SetLookAt`/`ClearLookAt` stubs | animation | [natives_ai.odin:9](../src/script/natives_ai.odin#L9) |
| lip-converter | `.lip` copied raw | — | [audio.odin:9](../src/installer/converters/audio.odin#L9) |
| lip-sync-voice-map | main has no speaker → playing line + time | lip-converter | [scenes.odin:238](../src/script/lua/scenes.odin#L238) |
| mount-attach | no `attached to (form, bone)` in the view | anim-state-snapshot | [interact.odin:177](../src/app/interact.odin#L177) |
| mounts | activating a horse opens dialogue | actor-states | [interact.odin:178](../src/app/interact.odin#L178) |
| flight | Hover/Orbit/FlightGrab fail; flying conditions read 0; flag unused | actor-states | [packages.odin:227](../src/ai/packages.odin#L227), [functions.odin:453](../src/conditions/functions.odin#L453), [actors.odin:488](../src/worldstate/actors.odin#L488) |
| anchor-names | every anchor is the chest | animation | [magicphys_host.odin:156](../src/app/magicphys_host.odin#L156) |
| cast-animation | casting is instant | animation | [casting.odin:5](../src/script/casting.odin#L5) |
| actor-hitboxes | hits land on the capsule only | animation | [actors.odin:30](../src/app/actors.odin#L30) |
| actor-ragdoll | dead actors keep the standing capsule | animation | [actors.odin:32](../src/app/actors.odin#L32) |
| actor-knockdown | `KnockAreaEffect` (29), `PushActorAway` (10) do nothing | actor-ragdoll | [natives_magic.odin:279](../src/script/natives_magic.odin#L279) |

- hkx-porter: keep annotations; store root motion and annotations apart from bone tracks; output is a
  content mod under `content/`, like `basescripts`.
- anim-natives: whether `PlayAnimation` can complete in one tick is this area's call; the dependent
  script rewrites are done with it, not before.
- mount-attach bones: `SaddleBone` (horse), `NPC Saddlebone` (dragon). anchor-names: `NPC L/R MagicNode`,
  `NPC Head MagicNode`, `MagicEffectsNode`; our-name → node map undecided.
- actor-hitboxes: per-bone colliders swept by the weapon (Precision-style) is the default.
- Related, other owners: `skinned-pipeline` ([mesh_draw.odin:16](../src/render/mesh_draw.odin#L16)),
  `view-model` ([render.odin:21](../src/render/render.odin#L21)), `anim-sounds`
  ([triggers.odin:151](../src/audio/triggers.odin#L151)), `effect-sounds`, `dust-drop-effect`.

## Decisions

- The sim owns the animation clock: advances `(clip, t)`, fires annotations, applies root motion, samples hitbox bones.
- Main samples the full skeleton from the same clips; no pose tick + pose interpolation on main.
- Clip choice is logic and runs in `game_tick`; root motion runs in lockstep with physics.
- Annotations fire on the sim in the crossing tick, never from main's sampler.
- Animation LOD is later; do not design for it.
- The streamer is the one loader; only IDs and plain data cross threads.
- Main touches sim state only while the sim is parked.
- The engine never reads `.hkx`; do not copy behavior graphs or Nemesis/Pandora patching.
- Behavior and animation are one problem: states first, animation plays them.
- The actor-state model is not a plugin seam; mods extend it through its own API.
- LE and SE are one union, never a branch.
- Lip-sync translates `.lip` (or derives visemes from audio); no FaceFX port; can beat vanilla.
- Every actor fights with its third-person body; the view model only draws.
- The player is an NPC (ref 0x14); every path serves all actors.
- An animation wait is `OnAnimationEvent(src, evt)`; `IsAnimRunning(anim)` is true from `PlayAnimation` return to end.
- A replacing animation sends the replaced one's end event; a detaching cell sends none (`OnCellDetach` ends the run).
- After a load: resume the animation or send its end event.
- Events reach registered forms only; a handler without a registration warns once.
- A read and its write share one store (`SetLookAt`, `SetSittingRotation`, `SetAllowFlying` need reads).
- An absent system's completion read answers "done".

## questions

- Layout of `animationdatasinglefile.txt` motion data: unconfirmed.
- Which props use `NiControllerSequence` vs `BSBehaviorGraphExtraData`: unconfirmed.
- Semantics of `fAIHeadTrack*`, `fProjectileKnockMultBiped`, `fWaterKnockdown*`: unconfirmed.
- `hkPhonemes:f:*` channels → `.tri` morph mapping: unconfirmed.
- Whether queued annotations must keep order across actors: unconfirmed.
