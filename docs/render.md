# Render, sky and weather

Skyrim: BSShader forward renderer (BSLighting/BSEffect/BSWater/BSSky shader properties), a hardcoded
sky from CLMT + WTHR, per-weather 4-slot time-of-day tables, XCLL/LTMP interiors, skinned NIFs.
We read NIF and DDS raw from the BSAs at run time (BCn is GPU-native, nothing is redistributed) and
sky/weather/lighting inputs from gamedb. Render and weather are native plugin seams because the area
is handed off to a non-GC replacement. Stub: fullbright SDL3 GPU forward renderer, clear-color sky,
one procedural water shader, actors as capsules, first-offered weather with instant switch.

Goal: vanilla's look through modern system, skinned actors, vanilla weather selection and transitions.

Out of scope: particles, decals, precipitation, spell art ([vfx.md](vfx.md)); streamer and asset
cache ([assets.md](assets.md)); skeletons and clips ([animation.md](animation.md)).

## Code map

| File | Role |
|---|---|
| [graphics/graphics.odin](../src/graphics/graphics.odin) | graphics seam: `Frame`, `Host`, `Table.draw`, VERSION 3 |
| [app/graphics_host.odin](../src/app/graphics_host.odin) | builds `Frame` (`draw_graphics` L25); built-in `draw_builtin` L160 |
| [weather/weather.odin](../src/weather/weather.odin) | weather seam: `Input`, `Now`, `Table.tick`, built-in L62, VERSION 1 |
| [app/weather_host.odin](../src/app/weather_host.odin#L14) | gathers regions/climate each tick, writes `ws.weather` |
| [worldstate/weather.odin](../src/worldstate/weather.odin#L8) | `Weather_State` (saved), script requests |
| [script/natives_weather.odin](../src/script/natives_weather.odin) | Weather natives |
| [gamedb/climate.odin](../src/gamedb/climate.odin) | climate, region and cell-region lookups |
| [esm/records_forms.odin:793](../src/formats/esm/records_forms.odin#L793) | CLMT WLST, REGN RDAT/RDWT, WTHR DATA/FNAM/NAM0/IMSP decode |
| [esm/records.odin:972](../src/formats/esm/records.odin#L972) | IMGS decode, unused |
| [render/render.odin](../src/render/render.odin) | device, pipelines, reversed-Z depth, present blit, UI pass |
| [render/mesh_draw.odin](../src/render/mesh_draw.odin) | `Mesh_Vertex`, mesh and effect pipelines |
| [render/texture.odin](../src/render/texture.odin) | DDS BCn upload, batched copy passes |
| [render/water_draw.odin](../src/render/water_draw.odin) | procedural water, hardcoded palette |
| [render/shaders](../src/render/shaders) | GLSL 450, compiled to SPIR-V by [build_shaders.sh](../build/build_shaders.sh), `#load`ed |
| [world/world.odin](../src/world/world.odin) | per-cell chunks, instances, frustum culling; skips `Sky\`, `Water\` (L49) |
| [world/terrain.odin](../src/world/terrain.odin), [terrain_cdlod.odin](../src/world/terrain_cdlod.odin) | near LAND meshes; CDLOD far field (height texture, instanced patches) |
| [world/water.odin](../src/world/water.odin), [water_lod.odin](../src/world/water_lod.odin) | per-cell quad at XCLW; baked distant water |
| [world/object_lod.odin](../src/world/object_lod.odin), [grass.odin](../src/world/grass.odin) | baked instanced object LOD; grass scatter |
| [world/stream.odin](../src/world/stream.odin) | worker decode, main upload (6 models, 8 chunk decorations per frame) |
| [formats/nif](../src/formats/nif/nodes.odin) | LE NiTriShape + SE BSTriShape parse |
| [app/camera.odin](../src/app/camera.odin), [worldstate/camera.odin](../src/worldstate/camera.odin) | view/proj (70° FOV, near 5, far 262144); saved `dist`/`target` |
| [app/actors.odin:299](../src/app/actors.odin#L299) | actor capsules, tint pipeline |
| [app/sim.odin:197](../src/app/sim.odin#L197) | `Snapshot` the sim publishes to main |

SDL 3.4.10, Vulkan SPIR-V; one scene pass into `present_tex`, UI pass, blit to swapchain;
reversed-Z (clear 0, `GREATER`) on D32F_S8 or D24S8; no MSAA/HDR/post/shadows; per-draw push
uniforms; sets per SDL rule (vertex UBO 1, frag samplers 2, frag UBO 3); sRGB textures with manual
`pow(1/2.2)` out. `Mesh_Vertex` is 28 B: pos f32x3, uv f32x2, normal snorm8x4 (w free), tangent
snorm8x4 (w = sign); shaders bind only pos and uv; u16 indices.

## Boundary

Plugin mechanics (export, version, trust, `Span`, save hooks): [native-plugins.md](native-plugins.md).
Applied at [game.odin:615](../src/app/game.odin#L615) (weather), [:619](../src/app/game.odin#L619)
(graphics). Seam packages import only `core:`, `base:`, `formid`, `plugin` ([test.sh:51](../build/test.sh#L51)).
Example plugin: [sight_blind.odin](../tests/plugins/sight_blind/sight_blind.odin).

**Graphics** — main thread, once per frame between `frame_acquire` and `end_frame`.

| `Frame` field | Content |
|---|---|
| `device`, `cmd`, `target`, `format`, `width/height` | `SDL_GPUDevice*`, command buffer, color target (fill all), swapchain format |
| `camera` | pos, view, proj (reversed-Z) |
| `time`, `interior`, `first_person` | real seconds; camera cell kind; hide `player` |
| `player`, `actors` | id, base, blended feet, capsule, dead ([L29](../src/graphics/graphics.odin#L29)) |
| `cells` | id, grid, interior only |
| `visuals` | EFSH/ARTO/IPDS/IMAD in force (vfx.md) |
| `host.refs / model_path / read_file / record` | placed refs with this frame's matrix; model path; VFS read; plugin record views |

No pass is open on entry; the plugin owns its depth target. `end_frame` draws the UI over `target`.

**Weather** — sim thread, once per tick after traversal. In: `hour`, `interior`, player cell's
`regions` (XCLR, RDAT override/priority, RDWT), worldspace `climate` (WLST), script `override` /
`request` / `instant`, last `now`. Out: `Now{current, outgoing, transition, natural}`, stored in
`ws.weather` and saved ([save.odin:410](../src/worldstate/save.odin#L410)). Plugin-private state
(next-change timer, RNG) goes through `skymod_save`/`skymod_load`.

Snapshot today: actor views, controlled body, first-person flag, camera follow/boom, body poses
(per-tick segments, main blends by `fr.alpha`), HUD, dialogue, visuals. No hour, weather or lighting.

## Holes

| id | gap | needs | mark |
|---|---|---|---|
| render-inputs-snapshot | `Frame` lacks hour, weather + transition, LTMP/XCLL, XCIM, XCCM, Show Sky flags | — | [graphics.odin:87](../src/graphics/graphics.odin#L87) |
| sky | no dome, sun, moons, stars, clouds, aurora | render-inputs-snapshot | [render.odin:20](../src/render/render.odin#L20) |
| day-night | fullbright: no sun, ambient, DALC, fog, IMGS, lights, shadows | render-inputs-snapshot | [mesh.frag:4](../src/render/shaders/mesh.frag#L4) |
| skinned-pipeline | no bones/weights in `Mesh_Vertex`; LE skinned draws bind pose, SE skinned dropped | anim-state-snapshot, anim-clip-store | [mesh_draw.odin:16](../src/render/mesh_draw.odin#L16) |
| view-model | no 1st/3rd-person player body | skinned-pipeline | [render.odin:21](../src/render/render.odin#L21) |
| camera-reads | no read-back for Force*Person, SetCameraTarget; ShowFirstPersonGeometry unimplemented | view-model | [natives.odin:21](../src/script/natives.odin#L21) |
| actor-alpha-render | SetAlpha stored and saved, never drawn; `abFade` ignored | — | [refs.odin:252](../src/worldstate/refs.odin#L252) |
| effect-vertex-alpha | effect shapes ignore vertex color/alpha, falloff, emissive, NiAlphaProperty blend | — | [nodes.odin:458](../src/formats/nif/nodes.odin#L458) |
| water-palette | WATR not decoded; one palette, no reflection | — | [water_draw.odin:16](../src/render/water_draw.odin#L16) |
| interior-water | interiors get no water plane | — | [water.odin:14](../src/world/water.odin#L14) |
| terrain-culling | CDLOD nodes not frustum-culled | — | [terrain_cdlod.odin:393](../src/world/terrain_cdlod.odin#L393) |
| graphics-gpu-streaming | streamer uploads GPU data even when a plugin draws | — | [graphics_host.odin:158](../src/app/graphics_host.odin#L158) |
| graphics-cell-data | plugin gets no LAND, XCLW or WATR per cell | — | [graphics.odin:37](../src/graphics/graphics.odin#L37) |
| weather-select | first offered weather, instant switch; wants chance roll, TNAM volatility timing, blend | — | [weather.odin:61](../src/weather/weather.odin#L61) |

- skinned-pipeline: LE takes only tris from NiSkinPartition ([nodes.odin:157](../src/formats/nif/nodes.odin#L157)); SE `data_size == 0` returns false ([blocks.odin:252](../src/formats/nif/blocks.odin#L252)).
- effect-vertex-alpha: `Geometry.alphas` is decoded; `Mesh_Vertex.normal.w` is free to carry it.
- water-palette: XCWT is already decoded into gamedb and the `Cell` view (`water_type`).
- day-night is needed by light-at-point ([sight.odin:85](../src/sight/sight.odin#L85), detection.md).
- New `Frame`/`Actor` fields (hour, weather, alpha, pose) are a graphics VERSION bump, appended at the end.

## Decisions

- Main owns SDL, render, GPU cache, UI; it reads sim state only with the sim parked.
- Render reads only the snapshot, never `ws.clock` or traversal; new inputs are published by the sim.
- The streamer loads every asset for every consumer; the sim owns live cells and placement; only IDs and plain data cross.
- Weather is its own system (climate, selection, transitions), as graphics is.
- VFX is part of the graphics seam: whoever draws an actor draws its effect shaders; visuals are saved in `worldstate.visuals`, a new handle is a new start.
- The sim owns the animation clock; main samples the full skeleton from the same read-only clips.
- light-at-point runs on the sim from LIGH refs, cell lighting, clock and weather, never from render state.
- Seam views grow only at the end; no field is removed or reordered.
- LE and SE are one code path (union), never an edition branch.
- Values come from records/GMSTs first, UESP only where data has none; no Bethesda assets in repo or binary.

## Open questions

- SDL3 is linked statically with no `-rdynamic` ([dev.sh](../build/dev.sh), [release.sh](../release.sh)): a plugin cannot resolve `SDL_*GPU*` for `Frame.device`. Export them or add a function table. Untested.
- Vanilla blend curve between the four WTHR time slots.
- How RDAT override and priority combine; UESP says the RDWT global is unused.
- Unit of WTHR DATA `trans_delta`; how DATA precipitation/thunder fades relate to the transition.
- How vanilla bounds interior water.
- Which GMSTs drive weather timing.