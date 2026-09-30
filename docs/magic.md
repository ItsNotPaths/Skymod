# Magic

Skyrim: MGEF archetypes on SPEL/SCRL/ENCH/ALCH/INGR/SHOU entries, PERK entry points, hardcoded
`MagicTarget`/`ActiveEffect` logic. We translate records at install to Lua (`rt.effect/spell/power/item`,
perks as hooks): named AVs and formulas, one `.patch.lua`-able file per edid, no fixed AV indices.
Stub: instant casts, `on_hit` always lands, no absorb/ward/disease/soul gem/poison/charge/shouts.
Goal: vanilla fidelity on this model. See [actor-states.md](actor-states.md), [vfx.md](vfx.md), [combat.md](combat.md).

## Code map

| File | Role |
|---|---|
| [magictranslate.odin:42](../src/magictranslate/magictranslate.odin#L42) | `translate`: records → `effects/ spells/ powers/ items/ perks/` Lua in the core scripts mod; run by [installer.odin:184](../src/installer/installer.odin#L184) and [tools/magic2lua](../tools/magic2lua/main.odin) |
| [effects.odin:16](../src/magictranslate/effects.odin#L16) | MGEF → `rt.effect`: baked archetype terms, tags, `resist`, No Recast → `stack="keep"`, PVM keyword → `nostack` |
| [spells.odin:38](../src/magictranslate/spells.odin#L38) | SPEL/SCRL/ENCH → `rt.spell`, powers/SHOU → `rt.power` ([:61](../src/magictranslate/spells.odin#L61), [:74](../src/magictranslate/spells.odin#L74)), delivery + first PROJ → primitive ([:112](../src/magictranslate/spells.odin#L112)), conditioned entries → effect copies ([:155](../src/magictranslate/spells.odin#L155)) |
| [items.odin:11](../src/magictranslate/items.odin#L11) | ALCH/INGR → `rt.item` (INGR: first effect only) |
| [abilities.odin](../src/magictranslate/abilities.odin) | ability → one effect at the SPEL form + gate script |
| [perks.odin:45](../src/magictranslate/perks.odin#L45) | entry points → `rt.perk` hook functions |
| [rt.lua:1225](../src/script/lua/rt.lua#L1225) | `rt.effect`; `rt.hook` [:1255](../src/script/lua/rt.lua#L1255); core `Resist` hook [:1278](../src/script/lua/rt.lua#L1278); `rt.magic_hit` [:1375](../src/script/lua/rt.lua#L1375); `rt.load_effects` [:1447](../src/script/lua/rt.lua#L1447); `rt.spell`/`power`/`item` to [:1502](../src/script/lua/rt.lua#L1502); `rt.zone` [:1549](../src/script/lua/rt.lua#L1549) |
| [rt.odin:311](../src/script/lua/rt.odin#L311) | `run_magic_hit`: `worldstate.Hooks` ([effect_defs.odin:61](../src/worldstate/effect_defs.odin#L61)) → Lua |
| [effect_defs.odin:19](../src/worldstate/effect_defs.odin#L19), [spell_defs.odin:23](../src/worldstate/spell_defs.odin#L23), [power_defs.odin:15](../src/worldstate/power_defs.odin#L15), [item_defs.odin:17](../src/worldstate/item_defs.odin#L17) | compiled definitions by form; `spell_view` [spell_defs.odin:171](../src/worldstate/spell_defs.odin#L171) answers for def or record |
| [effects.odin:14](../src/worldstate/effects.odin#L14) | `Active_Effect`; `advance_effect` [:62](../src/worldstate/effects.odin#L62) runs capacity/amount terms per tick |
| [stacking.odin:17](../src/worldstate/stacking.odin#L17), [resistance.odin:17](../src/worldstate/resistance.odin#L17) | defined-effect stacking; record stacking/resist fallbacks (to delete) |
| [casting.odin:21](../src/script/casting.odin#L21) | `cast_hand` (instant); `use_power` [:56](../src/script/casting.odin#L56) (no caller yet) |
| [natives_magic.odin:324](../src/script/natives_magic.odin#L324) | `start_effects`: the one landing path for every source; `cast_spell` [:284](../src/script/natives_magic.odin#L284), `use_item` [:306](../src/script/natives_magic.odin#L306), `sync_constant_effects` [:138](../src/script/natives_magic.odin#L138) |
| [magic_seam.odin:15](../src/script/magic_seam.odin#L15) | host side of `skymod_magic` |
| [magic.odin](../src/magic/magic.odin) | seam `skymod_magic` + stub built-ins |
| [magicphys.odin](../src/magicphys/magicphys.odin) | seam `skymod_magicphys` + built-in beam/spray/projectile/aura |
| [magicphys_host.odin:46](../src/app/magicphys_host.odin#L46) | host side: launches → casts, buffered procs, landing markers |
| [zones.odin](../src/worldstate/zones.odin) | runes, cloaks, HAZD hazards as runtime volumes |
| [src/script/effects](../src/script/effects/archetypevaluemodifier.lua) | archetype classes the translator does not bake (soul trap, summon, cloak, ...) |

## Model

- `rt.effect`: per-tick formula terms `av = { Health = { capacity=, amount= } }` in `t`, `m`, `d`
  and ≤8 tunables (capacity live, amount deltas kept), `caster = {...}` terms, tags, `resist`,
  `stack` (restart/add/keep), `nostack` group, `taper`, own `hooks.magichit`, moment scripts.
- `rt.spell`: data only: `use` (charged/held), `cost`, `shape`, `tags`, `applies = {{ effect, m,
  d, area, hits = "direct" }}`. Enchantments are spells tagged `enchantment`.
- `rt.power`: words, each `applies` + cooldown on a timer AV (`24h` game hours, `15s` real,
  shouts share `Voice`, scaled by `cooldown_mult`).
- `rt.item`: `inventory` (applies to user) or `hand` (casts `casts`, one per cast, no Magicka).
- Passives: `ApplyEffect(effect, m)` with no duration, until `DispelEffect`.
- Tags: dotted, prefix-matched ([tags.odin:8](../src/magic/tags.odin#L8)); keywords are
  `kw.<edid>`; translator writes `hostile`, `archetype.*`, `school.*`, `poison`, `disease`,
  `status`, `power.duration` on effects, never on spells.
- Hooks (`rt.hook`, only in `OnGameLoaded`): `magiccost`, `magichit`, weapon kinds, generic
  `action`/`hit`. Parts `{value, add, mult, set}` settle as `set` or `(value+add)*mult`, so order
  does not matter. Order: `perks/` files, mods by priority, core `Resist` last.
- Landing ([natives_magic.odin:324](../src/script/natives_magic.odin#L324)): ghost check → seam
  `on_hit` once per source+target → `OnHit` → per effect: record MGEF conditions, record resist,
  seam `scale`, `magichit` hooks, effect's own `magichit` → `stack_effect` → `start_effect`.
- Shapes ([magicphys.odin:24](../src/magicphys/magicphys.odin#L24)): Self → none/Aura,
  Contact → none (hit carries it), Missile/Arrow/Lobber → Projectile, Target Location →
  Projectile + `place` (lands on an XMARKER), Beam/Target Actor → Beam, Flame/Cone → Spray, area →
  `burst` aura at the landing.

## Boundary

Native seams: `<mod>/native/*.so|.dll`, user-trusted by SHA-256, export `skymod_<seam> :: proc "c"
(version: u32, table: rawptr) -> b32` and overwrite table entries
([plugin.odin](../src/plugin/plugin.odin), pattern [combat_calm](../tests/plugins/combat_calm/combat_calm.odin)).
Plain data only; world reads through `plugin.World` ([world.odin](../src/plugin/world.odin)).
Applied at [game.odin:614](../src/app/game.odin#L614), [:618](../src/app/game.odin#L618).

| Seam | Table | In | Out |
|---|---|---|---|
| `skymod_magic` v1 | `on_hit(h, Hit) -> Verdict`, `scale(h, Hit, effect, {m,d}) -> {m,d}` | `Hit{spell, caster, target, direct}`; `Host{world}` | `Lands/Absorbed/Warded/Reflected`; scaled numbers |
| `skymod_magicphys` v1 | `tick(^Input)` | casts since last tick, live bodies, loaded actors, `dt`, gravity | host procs `spawn/put/remove/hit/place`, buffered and applied after `tick` |

Contract gaps the fidelity holes need:
- Host acts only on `Lands`: no Magicka gain on `Absorbed`, no ward drain, no reflect relaunch.
- `magic.Host` has no writes (AV gain/drain, relaunch).
- `Hit` lacks source kind (self-delivered, hostile, cost), spell flags, hand, dual-cast.
- `Hit.direct` is always true at `on_hit`; `start_spell` drops magicphys' flag.
- magicphys `strike` ignores radius (Jolt ray); `anchor` is always the chest.

Thread and tick: all on the sim thread, 60 Hz. `tick_cast` ([game_frame.odin:174](../src/app/game_frame.odin#L174))
→ `tick_magicphys` ([:185](../src/app/game_frame.odin#L185), hits start effects this tick) →
`run_scripts` ([:199](../src/app/game_frame.odin#L199): `tick_effects` [events.odin:136](../src/script/lua/events.odin#L136),
AI `UseMagic` casts [events.odin:426](../src/script/lua/events.odin#L426) launch next tick). No
body is published to main.

Saved: `Active_Effect` ([save.odin:610](../src/worldstate/save.odin#L610)), spell lists and words
as deltas, cooldowns as timer AVs, plugin blobs (`skymod_save`/`skymod_load`). Not saved:
definitions and hooks (rebuilt each start), spell bodies and markers.

## Holes

| id | gap | needs | mark |
|---|---|---|---|
| spell-absorption | `AbsorbChance` never rolled | seam contract gaps | [magic.odin:46](../src/magic/magic.odin#L46) |
| wards | `WardPower` blocks nothing, no break, `Mod_Ward_Magic_Absorption_Percent` unread | concentration, stagger | [magic.odin:47](../src/magic/magic.odin#L47) |
| death-dispel | death ends no effect; No Death Dispel flag unread | | [natives_magic.odin:188](../src/script/natives_magic.odin#L188) |
| record-resist | skipped record effects resist by old code (magnitude only, ALCH poisons, ARMO, no `ResistCap`) | | [resistance.odin:16](../src/worldstate/resistance.odin#L16) |
| record-stacking | skipped record effects stack by old code (Weakness potions, any-caster recast, No Recast) | | [stacking.odin:44](../src/worldstate/stacking.odin#L44) |
| disease-resistance | Disease spells unresisted | | [resistance.odin:8](../src/worldstate/resistance.odin#L8) |
| disease-effects | Disease spells never start; no hit passes one | disease-resistance | [natives_magic.odin:61](../src/script/natives_magic.odin#L61) |
| spell-use | only instant pay-up-front casts | actor-states | [casting.odin:6](../src/script/casting.odin#L6) |
| concentration | no held drain + 1 s reapply | spell-use | [casting.odin:7](../src/script/casting.odin#L7) |
| concentration-conditions | spell/effect condition checks not inverted | concentration | [natives_magic.odin:322](../src/script/natives_magic.odin#L322) |
| dual-cast | no dual cast | spell-use | [casting.odin:8](../src/script/casting.odin#L8) |
| stack-per-hand | cast has no hand; two-hand Flames restarts one copy | spell-use | [stacking.odin:8](../src/worldstate/stacking.odin#L8) |
| cast-facing | NPC casts sideways; no turn-to-target gate | actor-states | [casting.odin:19](../src/script/casting.odin#L19) |
| item-charge | staves cannot cast, no ENCH charge, `Left/RightItemCharge` empty | spell-use | [casting.odin:20](../src/script/casting.odin#L20) |
| shouts | no Shout action, hold-for-words, Voice natives, `GetCurrentShoutVariation` | | [interact.odin:130](../src/app/interact.odin#L130), [casting.odin:54](../src/script/casting.odin#L54) |
| proc-shout | `Shout` package procedure fails | shouts | [packages.odin:225](../src/ai/packages.odin#L225) |
| power-bodies | powers/shouts skip magicphys, no cone | | [casting.odin:55](../src/script/casting.odin#L55) |
| area-entries | `hits="direct"` entries land on area hits; struck+burst = one direct hit | | [magicphys_host.odin:189](../src/app/magicphys_host.odin#L189) |
| spell-body-saves | bodies and markers not saved | | [magicphys_host.odin:105](../src/app/magicphys_host.odin#L105) |
| hazards | no hazard from impact data sets, EXPL, or lobber runes | | [forms.odin:430](../src/gamedb/forms.odin#L430) |
| soul-gems | no `TrapSoul`, SLGM unindexed, no soul on a stack, no recharge | death-dispel | [natives_magic.odin:17](../src/script/natives_magic.odin#L17) |
| weapon-poison | no poisoned weapon state, doses, apply on hit | | [natives_magic.odin:302](../src/script/natives_magic.odin#L302) |
| ingredients | no known-effect state, no `LearnEffect*` natives | | [natives_equip.odin:44](../src/script/natives_equip.odin#L44) |
| brew-enchant-perks | alchemy/enchant perks scale nothing | crafting-screen | [natives_magic.odin:6](../src/script/natives_magic.odin#L6) |
| slow-time | no world time scale | | [scripts.odin:186](../src/gamedb/scripts.odin#L186) |
| telekinesis | nothing holds a body/actor | | [scripts.odin:187](../src/gamedb/scripts.odin#L187) |
| rider-rules | perk riders copied unevenly (none on scrolls, staves, weapon ENCH, runes; 34 test player) | | [magictranslate.odin:41](../src/magictranslate/magictranslate.odin#L41) |
| ability-splits | 27 abilities with per-part conditions keep records | | [magictranslate.odin:90](../src/magictranslate/magictranslate.odin#L90) |
| stage-families | vampire/Serana stage abilities are one ability per stage | | [abilities.odin:6](../src/magictranslate/abilities.odin#L6) |
| magic-perk-points | 5 entry points untranslated | | [perks.odin:13](../src/magictranslate/perks.odin#L13) |
| magic-conditions | 13 magic condition functions have no body and pass | | [functions.odin:452](../src/conditions/functions.odin#L452) |

- spell-use: proposed, not confirmed: caster asks once for a Cast state `(hand, spell)`; it owns
  timing, and `proc_use_magic` uses package inputs 4/5 as hold time.
- record-resist/record-stacking: the translator already emits `stack`/`nostack`; goal is to delete both fallbacks.
- rider-rules: each rider stays an entry of its items, perk gate in the rider's own `magichit`.
- item-charge: `use_hand` skips staves at [melee.odin:63](../src/app/melee.odin#L63).
- soul-gems: [archetypesoultrap.lua](../src/script/effects/archetypesoultrap.lua) calls `TrapSoul` in `OnEffectFinish`, so it needs death-dispel.
- magic-conditions: an `EPMagic_*`-gated perk applies to every spell until this lands.

## Decisions

- Magic is Lua content; runtime never reads magic records; mods port with `magic2lua`.
- Records are an import format; the model does not bend to their limits.
- Costs, cooldowns, resists, caps (`ResistCap`), perk ranks are named AVs.
- Effect = per-tick formulas + Lua at landing; no visuals on effects.
- A spell names all its effects; an effect never starts another.
- Any given duration is timed (negative = 0); only the source makes an effect last.
- Shapes are four hardcoded primitives in `skymod_magicphys`; more is a script.
- Landing: on-hit once per spell+target (absorb, ward, reflect stop the whole spell), then per effect.
- Landing rules are native; formulas, spells, shapes are content.
- `Resist` is the core hook and runs last.
- Stacking: sources add, same caster restarts, `nostack` keeps the strongest.
- Concentration reapplies every 1 s, fixed.
- Power cooldown in game hours, shout in real seconds on shared `Voice`, lesser power none.
- Shouts: tap = one word, hold = more, up to unlocked words.
- Conditioned spell entry → copy of its effect carrying the conditions.
- Ability → one effect at the ability's form; vampire stage is `m`.
- Power Affects Duration only (`power.duration` tag).
- Eating an ingredient learns its first effect; the two-effect perk follows record order.

## Open questions

- How a creature hit rolls a disease, and the base chance.
- Concentration cost: continuous or per-second drain.
- Shout per-word hold times.
- `fMagicWardPowerMaxBase` use.
- `DiseaseResist` as catch chance (UESP, not confirmed in data).
- Soul gem pick order (smallest fitting gem).

