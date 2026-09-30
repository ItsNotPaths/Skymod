# Visual effects

Skyrim builds VFX from two layers. **NIF content**: Gamebryo `NiParticleSystem` /
`BSStripParticleSystem` graphs (emitters, modifier stacks, `NiPSys*Ctlr` controllers) plus
`BSEffectShaderProperty` geometry (additive/blended cards with falloff, greyscale palettes, soft
depth, controller-animated UV and color). **Records** that play that content at runtime: EFSH (a
membrane shader on a target's skinned geometry plus a surface-emitted particle system, fully
parameterised in a 400-byte `DATA`), ARTO (a NIF attached to an actor), IPDS→IPCT (per-material
impact NIF + decal + sound), RFCT (ARTO+EFSH pair), IMAD (screen-space curves), and LIGH. MGEF
links eight of these per effect (casting light/art, hit shader/art, enchant shader/art, impact
set, IMAD); ENCH links none and inherits from its MGEFs.

We read both, records are decoded at load into gamedb, NIFs are parsed at run time from the
user's BSAs through the VFS. No Bethesda asset is converted or shipped, records are an import
format, and LE and SE content load as one union. Whether effect NIFs get an install-time
conversion (the project's rule for other asset kinds) is the new owner's call.

The current code is a stub. The **sim side is built**: `worldstate.visuals` holds every effect in
force (Papyrus `EffectShader`/`VisualEffect`/`PlayImpactEffect`/`ImageSpaceModifier`, and MGEF
hit shader/hit art/IMAD on effect start/stop), is saved, and reaches the graphics seam as
`Frame.visuals` each frame. **Nothing reads `Frame.visuals`**: the built-in drawer is fullbright
and draws only static `BSEffectShaderProperty` shapes with a constant UV scroll, additive. No
particles, decals, lights or skin shaders exist.

The goal: a particle and effect-shader runtime inside the graphics seam that simulates NIF
emitters and EFSH particle halves on one core, draws EFSH membranes on skinned actors, attaches
ARTO, resolves IPDS to impacts and decals, and draws LIGH, all from record data, with no sim
state beyond the visual store.

Related: [render.md](render.md) (graphics seam, lighting, skinning, post),
[magic.md](magic.md) (effects, spell bodies, cast states), [native-plugins.md](native-plugins.md)
(C ABI).

## Code map

| What | Where |
|---|---|
| Graphics seam: `Table.draw`, `Frame`, `Visual`, `Host` | [graphics.odin:54](../src/graphics/graphics.odin#L54), [:88](../src/graphics/graphics.odin#L88), [:106](../src/graphics/graphics.odin#L106) |
| Seam applied | [game.odin:619](../src/app/game.odin#L619) |
| Frame build (main), snapshot copy (sim), built-in drawer | [graphics_host.odin:25](../src/app/graphics_host.odin#L25), [:74](../src/app/graphics_host.odin#L74), [:160](../src/app/graphics_host.odin#L160) |
| `Snapshot.visuals`, `publish_snapshot` | [sim.odin:213](../src/app/sim.odin#L213), [:253](../src/app/sim.odin#L253) |
| Visual store: `Visual_Kind`, `Visual`, `play_visual`, `expire_visuals`, `effect_visuals` | [visuals.odin:10](../src/worldstate/visuals.odin#L10), [:19](../src/worldstate/visuals.odin#L19), [:50](../src/worldstate/visuals.odin#L50), [:85](../src/worldstate/visuals.odin#L85), [:126](../src/worldstate/visuals.odin#L126) |
| Effect start/stop → visuals (script phase) | [instances.odin:191](../src/script/lua/instances.odin#L191), [:201](../src/script/lua/instances.odin#L201) |
| Expiry after clock advance | [events.odin:497](../src/script/lua/events.odin#L497) |
| Save / load with form remap | [save.odin:612](../src/worldstate/save.odin#L612), [:1112](../src/worldstate/save.odin#L1112) |
| Papyrus natives | [natives_visuals.odin:11](../src/script/natives_visuals.odin#L11) |
| Record decode: EFSH `DATA`, IPCT `DATA`, `DODT` | [records_visuals.odin:110](../src/formats/esm/records_visuals.odin#L110), [:164](../src/formats/esm/records_visuals.odin#L164), [:183](../src/formats/esm/records_visuals.odin#L183) |
| Record index: EFSH, ARTO, IPCT, IPDS, IMAD, RFCT | [gamedb/visuals.odin:79](../src/gamedb/visuals.odin#L79), [:102](../src/gamedb/visuals.odin#L102), [:114](../src/gamedb/visuals.odin#L114), [:134](../src/gamedb/visuals.odin#L134), [:151](../src/gamedb/visuals.odin#L151), [:170](../src/gamedb/visuals.odin#L170) |
| MGEF art slots and offsets | [records_forms.odin:520](../src/formats/esm/records_forms.odin#L520), [:533](../src/formats/esm/records_forms.odin#L533) |
| Plugin record views (visuals) | [plugin/records_visuals.odin](../src/plugin/records_visuals.odin) |
| NIF walk (nodes + tri-shapes only) | [nodes.odin:221](../src/formats/nif/nodes.odin#L221), [:254](../src/formats/nif/nodes.odin#L254) |
| `BSEffectShaderProperty` decode: source texture, UV scroll from `BSEffectShaderPropertyFloatController` | [materials.odin:151](../src/formats/nif/materials.odin#L151), [:190](../src/formats/nif/materials.odin#L190) |
| FX pipeline (additive `SRC_ALPHA,ONE`, depth test, no write, reversed-Z), draw call, pass | [mesh_draw.odin:236](../src/render/mesh_draw.odin#L236), [:143](../src/render/mesh_draw.odin#L143), [world.odin:546](../src/world/world.odin#L546) |
| FX shaders | [effect.vert](../src/render/shaders/effect.vert), [effect.frag](../src/render/shaders/effect.frag) |
| Spell casts/hits/places (where cast art and impacts hook) | [magicphys_host.odin:46](../src/app/magicphys_host.odin#L46), [:191](../src/app/magicphys_host.odin#L191), [:198](../src/app/magicphys_host.odin#L198) |
| Tests | [visuals_test.odin](../tests/unit/visuals_test.odin) (store, effect visuals, EFSH decode) |

## Boundary

VFX is part of the graphics seam (`skymod_graphics`, VERSION 3); there is no VFX seam. A plugin
replaces `Table.draw`, called on main once per frame with the SDL GPU device, command buffer and
target. Export pattern: [sight_blind.odin](../tests/plugins/sight_blind/sight_blind.odin).

```odin
Visual :: struct {
	handle:   u32,         // new handle = new start
	kind:     Visual_Kind, // Shader (EFSH), Art (ARTO), Impact (IPDS), Imod (IMAD)
	form:     Form_ID,
	ref:      Form_ID,     // 0 = screen
	facing:   Form_ID,     // Art: beam target
	flags:    u32,         // Art: RFCT 1 face target, 2 attach to camera, 4 inherit rotation
	node:     cstring,     // Impact: node; "" = root
	pos:      [3]f32,      // Impact with ref 0
	strength: f32,         // Imod
	cross:    bool,        // Imod: the one cross-fade modifier
	fade:     f32,         // Imod ramp seconds
	age:      f32,         // seconds since start, as of the last tick
	left:     f32,         // 0 = until gone from the frame
}
```

- Data flow per tick (60 Hz, sim thread): clock advance → `expire_visuals` → script phase
  (`play_visual`/`stop_visual`) → `publish_snapshot` copies the store. Main copies
  `Snapshot.visuals` into `Frame.visuals` each frame.
- `Frame` also has the camera, actors (capsules only), cells, `time` (main's clock),
  `Host.refs`, `Host.model_path`, `Host.read_file` (any VFS path: the plugin parses NIF/DDS
  itself) and `Host.record` (record views; spans live until frame end).
- Drawer rule: draw a visual while its handle is in the frame; a visual on an undrawn ref is not
  drawn. Same (kind, form, ref) replayed = new handle.
- Script natives write the store only, never render. `PlayImpactEffect` visuals stay at least
  `IMPACT_MIN` = 1 s so a slow frame sees them.

Missing from the contract (append-only, bump `VERSION`):

| Gap | For |
|---|---|
| Live spell bodies are only in `g.sim.spell_bodies`, not in the snapshot or `Frame` | projectile/beam/spray art (`cast-visuals`) |
| Casts and landings reach `script.start_spell` only; no event to graphics | casting art, impacts at landings |
| `Magic_Effect` view exposes `info.art` as raw local IDs; the remapped `art` array is gamedb-only ([plugin/records.odin:142](../src/plugin/records.odin#L142), [worldhost/records.odin:147](../src/worldhost/records.odin#L147)) | `effect-fx`, `enchant-visuals` |
| No LIGH view; LIGH `DATA` undecoded except the carried flag ([records_forms.odin:1117](../src/formats/esm/records_forms.odin#L1117)) | casting light, Light archetype |
| EXPL not indexed, no view | `hazards`, `dust-drop-effect`, `destruction-visuals` |
| PROJ decode is motion only ([records_projectiles.odin:8](../src/formats/esm/records_projectiles.odin#L8)): no `MODL`, light, `NAM1` muzzle flash model, muzzle light/duration, fade | `cast-visuals` |
| `Frame.actors` carries no skeleton, worn or hand items | membranes, enchant art, hand art |
| No surface point / MATT query | decals, IPDS entry choice (`impact-pick`) |
| `rt.effect` has no art fields ([effect_defs.odin:44](../src/worldstate/effect_defs.odin#L44)); a Lua-form effect has no MGEF and shows nothing | `effect-fx` |
| `age` is tick-quantised; interpolate with `Frame.time` from the frame a handle first appears | smooth ramps |

## Holes

`swiss '(hole <id>)'` lists needs and dependents.

### particles (blocker)

[mesh_draw.odin:229](../src/render/mesh_draw.odin#L229). No particle system anywhere; every NIF
emitter is dropped (fire, smoke, dust, magic, precipitation).

- Blocks to support (nif.xml): `NiParticleSystem`, `BSStripParticleSystem`, `NiPSysData`,
  `BSStripPSysData`, `BSMasterParticleSystem`; emitters `NiPSysBoxEmitter`,
  `NiPSysSphereEmitter`, `NiPSysCylinderEmitter`, `NiPSysMeshEmitter`; modifiers
  `NiPSysAgeDeathModifier`, `NiPSysSpawnModifier`, `NiPSysPositionModifier`,
  `NiPSysBoundUpdateModifier`, `NiPSysGravityModifier`, `NiPSysDragModifier`,
  `NiPSysBombModifier`, `NiPSysRotationModifier`, `NiPSysGrowFadeModifier`,
  `NiPSysColorModifier`, `NiPSysColliderManager` + `NiPSysPlanarCollider` /
  `NiPSysSphericalCollider`, `BSPSysSimpleColorModifier`, `BSPSysScaleModifier`,
  `BSPSysLODModifier`, `BSPSysInheritVelocityModifier`, `BSPSysRecycleBoundModifier`,
  `BSPSysSubTexModifier`, `BSPSysHavokUpdateModifier`, `BSPSysStripUpdateModifier`,
  `BSWindModifier`, `BSParentVelocityModifier`; controllers `NiPSysEmitterCtlr`,
  `NiPSysUpdateCtlr`, `NiPSysModifierActiveCtlr`, `BSPSysMultiTargetEmitterCtlr`,
  `BSEffectShaderPropertyFloatController`, `BSEffectShaderPropertyColorController`.
- Particle materials are `BSEffectShaderProperty`, so the effect-shader decode must cover the full
  property (below) for particles to look right.
- EFSH particle halves use the same model (birth ramp, lifetime±var, normal speed/accel, velocity,
  acceleration, scale/color keys, rotation±var, atlas frames). One core for both.
- Cosmetic and unsaved; simulate on main or the drawer's own threads, not the sim.
- Needed by `effect-fx`, `dust-drop-effect`. Precipitation also waits on weather/sky
  ([render.md](render.md)).

### decals (gap)

[mesh_draw.odin:230](../src/render/mesh_draw.odin#L230). No decals: blood, scorch, impact marks.

- IPCT `DODT`: min/max width and height, depth, shininess, parallax scale/passes, flags
  (1 parallax, 2 alpha blend, 4 alpha test, 8 no subtextures), color; textures from `DNAM`/`ENAM`
  TXST. IPCT `DATA`: orientation (0 surface normal, 1 projectile vector, 2 reflection), angle
  threshold, placement radius, `no_decal`.
- Skin blood decals: EFSH has `EFSH_BLOOD_GEOMETRY`; vanilla usage unconfirmed.
- Needs a surface hit and MATT (`impact-pick`, vfx/physics). Vanilla lifetime/count caps are INI
  settings; values unconfirmed.

### effect-fx (gap, needs particles)

[natives_magic.odin:7](../src/script/natives_magic.odin#L7). MGEF art, shaders and light do not
show.

- Sim side done: `effect_visuals` emits hit shader + hit art on the target and IMAD when the target
  is the player; stop is reference-counted across running effects on the same target
  ([visuals.odin:105](../src/worldstate/visuals.odin#L105)).
- Draw side is the hole:
  - EFSH membrane over the target's skinned mesh: fill (`ICON`, 3 color keys with scales/times,
    alpha ramp fade-in/full/fade-out/persistent/pulse, UV anim speed and scale), holes (`NAM7`,
    start/end time and value), membrane palette (`NAM8`), edge (falloff, color, ramp, width),
    membrane blend (src/dest/op/z-test as CK D3D enums). Flags: no membrane, no particles, edge
    inverse, skin only, ignore alpha, project UVs, lighting, no weapons, particle animated.
    Addon models (DEBR) with their own fade/scale ramps, ambient sound. Layout:
    [records_visuals.odin:34](../src/formats/esm/records_visuals.odin#L34).
  - EFSH particle half: `ICO2` texture, `NAM9` palette, parameters above.
  - ARTO NIF on the actor; attach node rule unconfirmed.
  - IMAD belongs to the post stack ([render.md](render.md)).
- Blocked in practice on `skinned-pipeline` (render): no skinned geometry to put a membrane on.

### cast-visuals (gap)

[visuals.odin:123](../src/worldstate/visuals.odin#L123). No casting art or casting light on the
caster; no IPDS where a projectile or touch lands.

- MGEF casting art (ARTO, hand effects) and casting light (LIGH) run while readied/casting; timing
  waits on cast states (`cast-animation`, `spell-use`, [magic.md](magic.md)). Casting is instant.
- Landing: MGEF impact data (IPDS) → IPCT by surface MATT
  ([gamedb/visuals.odin:134](../src/gamedb/visuals.odin#L134)); `Impact` visual at the hit ref, or
  ref 0 at `pos` on terrain.
- Body art comes from PROJ (model, light, muzzle flash) — undecoded, and bodies are not in `Frame`.
- Hook point: magicphys host sees `ws.launches`, hits and places. Shapes are the four magicphys
  primitives (Beam, Spray, Projectile, Aura; [magicphys.odin:24](../src/magicphys/magicphys.odin#L24));
  their look is this hole, their motion is not. Anchors are the chest until `anchor-names`.

### enchant-visuals (gap, needs twin-enchantments)

[visuals.odin:124](../src/worldstate/visuals.odin#L124). No enchant shader or art on enchanted
items.

- Source: MGEF enchant shader (EFSH) and enchant art (ARTO) of the ENCH's effects; which effect
  wins on a multi-effect ENCH is unconfirmed. Item → ENCH via `EITM`
  ([equipment.odin:142](../src/gamedb/equipment.odin#L142)); worn constant effects sync in
  [natives_magic.odin:138](../src/script/natives_magic.odin#L138).
- `twin-enchantments` ([natives_magic.odin:136](../src/script/natives_magic.odin#L136)): two worn
  items with one ENCH run it once, so visuals must key on the item, not the effect.
- Needs hand/worn items in `Frame`, plus `view-model` and `skinned-pipeline`.

### visual-archetypes (gap)

[scripts.odin:185](../src/gamedb/scripts.odin#L185). Archetypes with no mechanic besides art get no
class, so they do nothing. IDs: [records_forms.odin:453](../src/formats/esm/records_forms.odin#L453).

| Archetype | ID | Vanilla (UESP MGEF) |
|---|---|---|
| Light | 12 | related form = LIGH |
| Night Eye | 14 | unconfirmed; likely the MGEF IMAD |
| Detect Life | 19 | no related form; target shader, details unconfirmed |
| Guide | 25 | related form = HAZD; Clairvoyance only; needs a nav path to the quest target |

### dust-drop-effect (gap, needs particles, animation)

[fxdustdroprandomscript.patch.lua:4](../src/script/patches/fxdustdroprandomscript.patch.lua#L4).
`FXDustDropRandomScript`: every 10–30 s, `PlayAnimation` `PlayAnim01/02/03` + sound; on 01,
`PlaceAtMe(FallingDustExplosion01)` 0.5 s later. Our rewrite is an `OnTick` state machine with
saved script state. Rule: cosmetic loops live in the effect (NIF controller sequence + particles +
EXPL art), no script state, nothing saved.

### Adjacent

- `hazards` ([forms.odin:430](../src/gamedb/forms.odin#L430), magic/world): "Their art is
  effect-fx."
- `destruction-visuals`, `impact-pick`, `camera-shake`, `screen-fade`: vfx-tagged, not unclaimed.
- `effect-vertex-alpha` (vertex color/alpha, falloff, emissive, `NiAlphaProperty` blend dropped on
  effect shapes), `skinned-pipeline`, `view-model`, `actor-alpha-render`,
  `render-inputs-snapshot`: render ([render.md](render.md)).

## Data

| Record | Read | Where | UESP |
|---|---|---|---|
| EFSH | `ICON`, `ICO2`, `NAM7`, `NAM8`, `NAM9`, `DATA` (400 B; 344/396 in old forms); addon DEBR @244, ambient sound @308 | [records_visuals.odin:110](../src/formats/esm/records_visuals.odin#L110) | [EFSH](https://en.uesp.net/wiki/Skyrim_Mod:Mod_File_Format/EFSH) |
| ARTO | `MODL`, `DNAM` (0 casting, 1 hit, 2 enchantment) | [gamedb/visuals.odin:102](../src/gamedb/visuals.odin#L102) | [ARTO](https://en.uesp.net/wiki/Skyrim_Mod:Mod_File_Format/ARTO) |
| IPCT | `MODL`, `DATA`, `DODT`, `DNAM`/`ENAM` TXST, `SNAM`/`NAM1` sounds, `NAM2` hazard | [gamedb/visuals.odin:114](../src/gamedb/visuals.odin#L114) | [IPCT](https://en.uesp.net/wiki/Skyrim_Mod:Mod_File_Format/IPCT) |
| IPDS | `PNAM` (MATT, IPCT) | [gamedb/visuals.odin:134](../src/gamedb/visuals.odin#L134) | [IPDS](https://en.uesp.net/wiki/Skyrim_Mod:Mod_File_Format/IPDS) |
| RFCT | `DATA` ARTO@0, EFSH@4, flags@8 | [gamedb/visuals.odin:170](../src/gamedb/visuals.odin#L170) | [RFCT](https://en.uesp.net/wiki/Skyrim_Mod:Mod_File_Format/RFCT) |
| IMAD | `DNAM`, curves | [gamedb/visuals.odin:151](../src/gamedb/visuals.odin#L151) | [IMAD](https://en.uesp.net/wiki/Skyrim_Mod:Mod_File_Format/IMAD) |
| MGEF | `DATA` casting light@24, hit shader@32, enchant shader@36, casting art@92, hit art@96, IPDS@100, enchant art@116, IMAD@132 | [records_forms.odin:533](../src/formats/esm/records_forms.odin#L533) | [MGEF](https://en.uesp.net/wiki/Skyrim_Mod:Mod_File_Format/MGEF) |
| ENCH | no visual fields | – | [ENCH](https://en.uesp.net/wiki/Skyrim_Mod:Mod_File_Format/ENCH) |
| LIGH | carried flag only; `DATA` (radius, color, flags, falloff exp, FOV, near clip, flicker period/intensity/movement) unread | [records_forms.odin:1117](../src/formats/esm/records_forms.odin#L1117) | [LIGH](https://en.uesp.net/wiki/Skyrim_Mod:Mod_File_Format/LIGH) |
| PROJ | motion only | [records_projectiles.odin:8](../src/formats/esm/records_projectiles.odin#L8) | [PROJ](https://en.uesp.net/wiki/Skyrim_Mod:Mod_File_Format/PROJ) |
| EXPL | not indexed | – | [EXPL](https://en.uesp.net/wiki/Skyrim_Mod:Mod_File_Format/EXPL) |
| TXST, MATT, DEBR, HAZD, DUAL | unread for visuals | – | [TXST](https://en.uesp.net/wiki/Skyrim_Mod:Mod_File_Format/TXST), [MATT](https://en.uesp.net/wiki/Skyrim_Mod:Mod_File_Format/MATT), [DEBR](https://en.uesp.net/wiki/Skyrim_Mod:Mod_File_Format/DEBR), [HAZD](https://en.uesp.net/wiki/Skyrim_Mod:Mod_File_Format/HAZD), [DUAL](https://en.uesp.net/wiki/Skyrim_Mod:Mod_File_Format/DUAL) |

- EFSH/IPCT field order is xEdit's `wbDefinitionsTES5`, validated on SE Skyrim.esm; UESP's IPCT
  listing differs in places, ours is the checked one. MGEF art offsets validated on all 950 SE
  MGEFs and match UESP.
- `BSEffectShaderProperty` (nif.xml): SF1/SF2 flag words, UV offset/scale, source texture, clamp
  mode, lighting influence, env map min LOD, falloff start/stop angle and opacity, base color and
  scale, soft falloff depth, greyscale texture; SE adds env map, normal, env mask textures and env
  map scale. Only source texture and UV-offset controllers are read now.
- `tools/nifdump` prints block types of a NIF inside a BSA.

## Decisions

- VFX is part of the graphics seam: the plugin drawing an actor's skinned mesh draws its effects.
- Script and magic visuals are saved state in `worldstate.visuals`, crossing as `Frame.visuals`;
  a new handle is a new start.
- Placed emitters (water, rapids, wind) come with their refs, not as visuals.
- Script natives never call render or the mixer; render reads the snapshot only; main touches sim
  state only with the sim parked.
- Only plain data crosses a seam: fixed structs, `Form_ID` (u64), spans.
- Cosmetic loops belong in the effect, with no script state and nothing saved.
- Spell shapes are four hardcoded magicphys primitives (Lua, keyframes, formulas rejected); the
  visual layer draws what they report.
- Records are an import format; values from records and GMSTs before UESP.
- LE and SE as one union, never branch on edition.
- Graphics as a whole, VFX drawing included, is handed off.

## Build and test

```sh
./download-deps.sh     # once
./build/test.sh        # shaders, type-check, import contracts, test plugins, unit tests
./build/dev.sh --run   # debug build
```

- `build/test.sh` enforces that `src/graphics` imports only `core:`, `base:`, `formid`, `plugin`.
- Unit tests are synthetic-fixture only.
- Graphics plugin: a folder in [tests/plugins](../tests/plugins) exporting
  `skymod_graphics :: proc "c" (version: u32, table: rawptr) -> b32` that checks
  `graphics.VERSION` and sets `(^graphics.Table)(table).draw`; built to
  `build/out/test-plugins/<name>.so`. No graphics example exists yet.
- Running needs `source_game_se` or `source_game_le` in `settings.txt`.
