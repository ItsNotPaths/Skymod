# Combat

Skyrim: exe-side CombatController / combat behavior trees tuned by CSTY, RACE `ATKD`/`ATKE` attack
data on behavior events, a reach + cone hit at the hit frame, and a hard-coded damage formula with
BGSEntryPoint perks. We replace it with one native seam, `skymod_combat` (brain + damage), because
none of it is data we can translate and mods must swap it as native code; perks become Lua hooks at
install. Now: a proximity stub brain, a capsule ray-fan hit landing the tick it is asked, and a
vanilla-faithful damage formula. Goal: CSTY-driven tactics whose actions are actor states, a timed
hit model (block, bash, power, stagger) on per-bone hitboxes, bleedout, material-aware projectiles.

## Code map

| File | Role |
|---|---|
| [combat/combat.odin](../src/combat/combat.odin) | Seam types, `Table`, stub brain `tick_builtin` (L75) |
| [combat/damage.odin](../src/combat/damage.odin) | `Attack`, `Part`, `damage_builtin` (L71) |
| [ai/combat.odin](../src/ai/combat.odin) | Seam host: `tick_combat` (L39), host procs, mover goal `combat_goal` (L127) |
| [app/actors.odin:82](../src/app/actors.odin#L82) | Tick order: snapshot → detection → `tick_combat` → packages |
| [app/melee.odin](../src/app/melee.odin) | `tick_swings` (stamina, 5-ray fan), `use_hand` (player input) |
| [app/projectiles.odin](../src/app/projectiles.odin) | Projectile flight on Jolt, hit, `embed` |
| [worldstate/projectiles.odin](../src/worldstate/projectiles.odin) | `Flight`, `Hit`, `Swing`, `strike`, `friend_hit` |
| [script/damage.odin](../src/script/damage.odin) | `weapon_hit` / `land_attack`: the one landing path, calls `Table.damage` |
| [script/natives_actor.odin:121](../src/script/natives_actor.odin#L121) | `damage_health` → `check_death`, the single Health sink |
| [script/lua/rt.lua:1255](../src/script/lua/rt.lua#L1255) | `rt.hook` kinds meleecost/archcost/meleehit/archhit/armorhit |
| [script/lua/rt.odin:365](../src/script/lua/rt.odin#L365) | Lua hook context → `Part`s |
| [magictranslate/perks.odin:45](../src/magictranslate/perks.odin#L45) | PERK entry point → hook part map |
| [script/lua/events.odin:198](../src/script/lua/events.odin#L198) | OnHit dispatch |
| [tests/plugins/combat_calm](../tests/plugins/combat_calm/combat_calm.odin) | Example plugin replacing `tick` |

## Boundary

- Seam: export `skymod_combat :: proc "c" (version: u32, table: rawptr) -> b32`, overwrite entries
  of `Table{tick, damage}` ([combat.odin:60](../src/combat/combat.odin#L60)), `VERSION` 3. Plain data
  only (`Form_ID` = u64, `Span` = `{T*, len}`); no C header yet. Loader:
  [plugin.odin:89](../src/plugin/plugin.odin#L89).
- `tick(^Input)`: once per tick, sim thread, 60 Hz, after detection, before AI packages. In: loaded
  `plugin.Actor`s, `Fighter{actor, fight, struck_by}`, `^plugin.World` queries, `host.aggro` (AIDT).
  Out: `host.set(actor, Fight{state: None|Warn|Combat|Flee, target, warned, swing})`,
  `host.swing(actor, Attack_Kind)`. The host moves the actor; only combat-override packages steer.
- `damage(^World, Attack, base) -> f32`: once per landed weapon hit, same tick, from `tick_swings` /
  `tick_projectiles`. `Attack` carries `Part{add, mult, set}`s already filled by the perk/mod hooks
  (damage, armor_pen, crit_chance, crit_damage, power_mult, sneak_mult, per-piece rating); the seam
  composes them. A new term (block, bash) = new `Part` + new `VERSION` + new Lua context key.
- Main sees only `Actor_View.combat` ([actors.odin:246](../src/app/actors.odin#L246)) and the HUD foe.
- Saved: `Flight`s, friend-hit counts. Not saved: `Fight` (in `ai.Agent`), `struck`, swing queue; a
  load starts everyone at `None`.
- Nothing produces `Power` or `Bash` yet: every swing caller passes `{}`; only `Sneak` is set
  (awareness). Stamina, hooks and formula already handle both.

## Holes

| id | gap | needs | mark |
|---|---|---|---|
| hit-model | flat weapon damage in reach; no arc/timing, block, power, stagger, attack types | — | [combat.odin:73](../src/combat/combat.odin#L73) |
| combat-brain | answers only State + target; no tactics, block, dodge, ranged, spells, groups | actor-states | [combat.odin:74](../src/combat/combat.odin#L74) |
| block-damage | no block state; `fBlock*`, `fStaminaBlockDmgMult`, `Mod_Percent_Blocked` unread | actor-states | [damage.odin:66](../src/combat/damage.odin#L66) |
| blocked-hits | OnHit `abHitBlocked` always false | block-damage | [events.odin:196](../src/script/lua/events.odin#L196) |
| bash-damage | bash deals full weapon damage; `fShieldBash*`, `fWeaponBashMax`, `Mod_Bashing_Damage` unread | hit-model | [damage.odin:64](../src/combat/damage.odin#L64) |
| bleedout | essential actor stands at 0 Health; `fBleedout*` unread | actor-states | [natives_actor.odin:126](../src/script/natives_actor.odin#L126) |
| projectile-ricochet | every projectile embeds | havok-materials (for surface) | [projectiles.odin:105](../src/app/projectiles.odin#L105) |

- hit-model: resolve on the sim-side hit-frame annotation (`anim-events-sim`,
  [events.odin:75](../src/script/lua/events.odin#L75)) against `actor-hitboxes`
  ([actors.odin:30](../src/app/actors.odin#L30)); RACE `ATKD`/`ATKE` and WEAP `DNAM` stagger are not decoded.
- combat-brain: CSTY and NPC_ `ZNAM` are not decoded; PACK `CNAM` is decoded
  ([packages.odin:39](../src/gamedb/packages.odin#L39)) and unread. A brain needs a CSTY record view in `plugin`.
- block-damage also gates `swing-spell` ([perks.odin:14](../src/magictranslate/perks.odin#L14)) and
  `action-state-conditions` IsBlocking/IsAttackType ([functions.odin:449](../src/conditions/functions.odin#L449)).
- projectile-ricochet: we embed 4 units (`EMBED_DEPTH`), not `fCombatMissileStickDepth`; IPDS/IPCT undecoded.
- Related polish holes in the same code: `swing-cone`, `attack-stamina-rules`, `crit-rules`,
  `ranged-sneak-mult`, `npc-damage-skill`, `armor-base-factor`, `disengage-distance`,
  `aggro-radius-targets`, `kill-essential`. Full list: `swiss '(tag combat)'`.

## Decisions

- Every actor fights with its third-person body; the camera is only the aim origin.
- The player is an NPC (0x14); combat code never forks on the player except the controller.
- The brain is the only AI seam; navmesh, tree walker and packages stay engine code.
- Actor states are not a native seam: swing, block, dodge are states requested by name through the actor-state API.
- The sim owns the animation clock and samples hitbox bones at tick time.
- Hitboxes default to per-bone race-skeleton colliders with a weapon sweep (Precision-style).
- A seam reads a snapshot, queries, returns commands; never writes worldstate; one call per tick.
- The built-in is the first plugin; last mod wins; the stub stays until the real model replaces it.
- Perks are rank AVs + hook `Part`s; no item seam; Lua never overrides engine behavior.
- Combat start and sneak attacks read only the awareness store.
- A missing system answers its resting state (not blocking, not bleeding out).
- Release draws nothing for combat (no swing arc, hitboxes, overhead stats).

## Open questions

- Block formula: `fBlockMax` 0.7 vs UESP's 85% cap; shape unconfirmed.
- Bash formula shape over `fShieldBashMin/Max/PCMax`, `fWeaponBashMax`: unconfirmed.
- How the `fStagger*` GMSTs combine: unconfirmed.
- `fBleedout*` use, and whether `Kill` on an essential actor refuses or bleeds out: unconfirmed.
- Swing cone width (`fCombatHitConeAngle` is absent from Skyrim.esm); ours is ±30°.
- `DISENGAGE` 4096 and the 1.5 s swing interval are guesses.
- Difficulty `fDiffMultHP*`: only `fDiffMultHPToPCL` exists (Update.esm); the rest use UESP defaults.
