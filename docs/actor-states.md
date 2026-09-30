# Actor states

Skyrim: Havok behavior graphs (`.hkx` projects, graph variables, anim events) plus the engine's
per-actor state fields; mods patch graphs via FNIS/Nemesis/Pandora. We replace both with one
sim-owned state model: the engine never reads `.hkx` (`hkx-porter` converts at install), state must
live on the 60 Hz sim thread and be saved, and mods add states by API, not graph patches. Now: a
stub, one named state per actor, every request granted. Goal: one model that AI, scripts and
conditions write and read and animation plays, with per-state properties and transitions.

## Code map

| File | Role |
|---|---|
| [actorstate.odin](../src/actorstate/actorstate.odin) | The model: `Model` [43](../src/actorstate/actorstate.odin#L43), engine IDs [17](../src/actorstate/actorstate.odin#L17), `Change` [30](../src/actorstate/actorstate.odin#L30), `Saved` [36](../src/actorstate/actorstate.odin#L36) |
| [worldstate.odin:111](../src/worldstate/worldstate.odin#L111) | `World_State.states`, the one instance |
| [equipment.odin:199](../src/worldstate/equipment.odin#L199) | `apply_state_changes`: drains changes, only consumer is the sleep outfit |
| [actors.odin:132](../src/app/actors.odin#L132) | Drain call, after the AI bodies tick |
| [refs.odin:288](../src/worldstate/refs.odin#L288) | `stop_doing`: death resets state |
| [save.odin:373](../src/worldstate/save.odin#L373) | `actor_states: []Saved`, by name ([669](../src/worldstate/save.odin#L669), [892](../src/worldstate/save.odin#L892)) |
| [furniture.odin:194](../src/ai/furniture.odin#L194) | `posture_on`: Lay marker -> Sleep, else Sit, none -> IdleMarker |
| [furniture.odin:202](../src/ai/furniture.odin#L202) | `hold_seat`, called each AI tick ([ai.odin:142](../src/ai/ai.odin#L142)). The agent duplicates it as `posture` ([ai.odin:47](../src/ai/ai.odin#L47)) |
| [procedures.odin:49](../src/ai/procedures.odin#L49) | Follow copies the leader's Sneak |
| [interact.odin:126](../src/app/interact.odin#L126) | Player Sneak toggle |
| [game_frame.odin:461](../src/app/game_frame.odin#L461) | Sprint leaves Sneak. Sneak sets the move speed. |
| [natives_actor.odin:49](../src/script/natives_actor.odin#L49) | `IsSneaking`, `StartSneaking`, `GetSitState`, `GetSleepState` |
| [functions.odin:772](../src/conditions/functions.odin#L772) | `IsSneaking`, `GetSitting` ([799](../src/conditions/functions.odin#L799)), `GetSleeping` |
| [seams.odin:43](../src/app/seams.odin#L43) | `plugin.Actor.sneaking` ([plugin.odin:38](../src/plugin/plugin.odin#L38)) in the seam snapshot |
| [hud.odin:99](../src/app/hud.odin#L99) | `hud.sneaking`, the only state main sees |
| [projectiles.odin:91](../src/worldstate/projectiles.odin#L91), [melee.odin:17](../src/app/melee.odin#L17) | Swing: a one-tick event queue, not a state |
| [casting.odin:21](../src/script/casting.odin#L21) | `cast_hand`: instant pay and land, not a state |
| [procedures.odin:295](../src/ai/procedures.odin#L295) | AI `UseMagic`: `Cast_Order`, landed in the script phase with no cost or hand ([natives_magic.odin:219](../src/script/natives_magic.odin#L219)) |
| [actorstate_test.odin](../tests/unit/actorstate_test.odin) | Model unit test |

## Boundary

Not a native plugin seam ([native-plugins.md](native-plugins.md)). The model runs on the sim thread
only, at a fixed 60 Hz. Writers run in the tick, and the host drains once per tick. It is saved by
state name. [build/test.sh:51](../build/test.sh#L51) holds it to seam import rules, so it lifts out.

| Proc | Contract |
|---|---|
| `state_id(name)` [55](../src/actorstate/actorstate.odin#L55) | Interned u32, session-stable; saves and mods use names |
| `current(actor)` [68](../src/actorstate/actorstate.odin#L68) | Absent = Stand |
| `request(actor, id)` [75](../src/actorstate/actorstate.odin#L75) | Always true, replaces |
| `leave` [81](../src/actorstate/actorstate.odin#L81), `reset` [86](../src/actorstate/actorstate.odin#L86) | Back to Stand |
| `drain` [91](../src/actorstate/actorstate.odin#L91) | `Change{u64 actor, u32 from, to}` span |
| `saved` [108](../src/actorstate/actorstate.odin#L108), `restore` [115](../src/actorstate/actorstate.odin#L115) | `{u64 actor, string state}`, no change emitted |

Missing from the contract:
- per-state properties
- a state set or layers per actor
- request parameters (Cast: hand and spell; Attack: keyword)
- transition events for animation and scripts
- any Lua `rt` call.

## Holes

| id | gap | needs | marks |
|---|---|---|---|
| actor-states | stub: no properties, entry checks or transitions | — | [actorstate.odin:41](../src/actorstate/actorstate.odin#L41), [72](../src/actorstate/actorstate.odin#L72) |
| actor-state-overlap | one state per actor: Sneak and a seat evict each other | actor-states | [actorstate.odin:73](../src/actorstate/actorstate.odin#L73) |
| actor-state-sit-steps | Get{Sit,Sleep}State return only 0 and 3; steps 1, 2, 4 missing | actor-states | [actorstate.odin:98](../src/actorstate/actorstate.odin#L98) |
| paralysis-read | `Paralysis` AV written ([effects.odin:66](../src/magictranslate/effects.odin#L66)), never read | actor-states | [actorstate.odin:42](../src/actorstate/actorstate.odin#L42) |
| guard-draws-weapon | `proc_guard` warns with its weapon sheathed | actor-states | [packages.odin:504](../src/ai/packages.odin#L504) |
| action-state-conditions | IsAttackType/IsSprinting/IsBlocking pass; IsWeaponOut/IsWeaponMagicOut/IsCasting/IsBleedingOut read 0 | actor-states | [functions.odin:449](../src/conditions/functions.odin#L449), [450](../src/conditions/functions.odin#L450) |
| spell-use | only instant pay; no charged, held or item-charge use | actor-states | [casting.odin:6](../src/script/casting.odin#L6) |
| concentration | no held cast | spell-use | [casting.odin:7](../src/script/casting.odin#L7) |
| dual-cast | no two-hand cast | spell-use | [casting.odin:8](../src/script/casting.odin#L8) |

- **actor-states**: other holes that need it: combat-brain ([combat.odin:74](../src/combat/combat.odin#L74): brain actions are state requests via a new `Fight` field and seam `VERSION`), anim-graph-names ([events.odin:76](../src/script/lua/events.odin#L76): a Havok name -> state table), hkx-porter ([converters.odin:10](../src/installer/converters/converters.odin#L10)), bleedout, block-damage, cast-facing, flight, mounts, idle-graph, swing-spell.
- **action-state-conditions**: gated perk entries are skipped via `UNBUILT` ([perks.odin:180](../src/magictranslate/perks.odin#L180)). Drop the entries there once the functions have bodies.
- **spell-use**: proposed, not confirmed: one `Cast(hand, spell)` state owns timing. It self-releases when charged (AI) or on button-up (player), and early release cancels. `proc_use_magic` requests it with CastTimeMin/Max as the hold time. Magic rules: [magic.md](magic.md).
- **dual-cast**: on the state side, one `Cast` holds both hand slots.

## Decisions

- One model: AI, scripts and conditions write and read it. Animation plays it and never decides it.
- Do not copy Havok behavior graphs or Nemesis/Pandora patching.
- Not a native plugin seam: mods add states through the model's own API.
- Swing, potion drink, dodge roll and paraglide are states, requested by name (combat brain, scripts).
- States carry their own properties (Sleep: speed 0) and transitions (move while asleep -> WakeUp).
- Behavior data converts at install time. The engine reads only the ported format.
- Saves store state names, not IDs.
- The player's controller uses the same request API as the AI.

## Open questions

- GetSitState/GetSleepState value 1: the mark calls it a step, but `Actor.psc` documents only 0, 2, 3 and 4.
- The MGEF DATA flag bit for "No Dual Cast Modifications".
- The layer split for overlap (posture / action / weapon, or a set with exclusion rules).
