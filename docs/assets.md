# Assets and streaming

Skyrim streams a `uGridsToLoad` cell window from BSA v104/v105 + loose `Data/` (NIF, DDS, `bhk*`) and
draws prebaked `.btr`/`.bto`/`.btt` LOD. We read NIF/DDS/BSA raw at run time through our own VFS
(index, don't copy; mods override by path; no Bethesda asset shipped). Scripts, audio, magic and UI
convert at install. Distant LOD is rebuilt from MNAM/LAND/XCLW, and vanilla LOD files are unread. Now:
an Odin worker-pool decode, budgeted main-thread upload, a refcounted GPU cache with eviction off, and
a write-once CPU collision store. Goal: a streamer (Rust) behind a C ABI with bounded memory.
See also [render.md](render.md), [animation.md](animation.md).

## Code map

| File | Role |
|---|---|
| [installer.odin](../src/installer/installer.odin) | Boot gate `content_ready`; per-`Part` rerun keyed by converter version + data hash; `archive_order` |
| [converters/](../src/installer/converters/) | pex→Lua, xWMA/FUZ→Opus (+raw `.lip`, repacked v105), magic→Lua, SWF→DDS; output as `content/<mod>/bethassets` |
| [vfs.odin](../src/vfs/vfs.odin) | Loose roots (first wins) over archives (last wins); normalized-path index; `read` thread-safe after mount |
| [cell_load.odin:494](../src/app/cell_load.odin#L494) | `mount_game_mods`: user mods > content mods > vanilla |
| [bsa.odin](../src/formats/bsa/bsa.odin), [pack.odin](../src/formats/bsa/pack.odin) | BSA read (pread, zlib/LZ4); v105 pack via Rust [bsa_glue](../build/bsa_glue/). No BA2 (not a Skyrim format) |
| [models.odin](../src/models/models.odin) | `models.ID` (u32) = interned lowercase mesh path; any thread |
| [assetdb.odin](../src/assetdb/assetdb.odin) | `decode_model` (worker, CPU only) → `Cpu_Model`; `upload_cpu_model` (main); refcounts + cold LRU |
| [collision_fill.odin](../src/assetdb/collision_fill.odin), [collisions.odin](../src/collisions/collisions.odin) | Sim's CPU copy per model: collision, cutout, AABB, furniture markers, `ProjectileNode` |
| [nif/collision.odin](../src/formats/nif/collision.odin) | `bhk*` → Box/Sphere/Capsule/Convex/Mesh, bodies, hinges; ×69.99124 baked in |
| [stream.odin](../src/world/stream.odin) | Request dedup, decode pool, upload (6/frame) and decorate (8/frame) budgets, load mode (96) |
| [terrain.odin](../src/world/terrain.odin), [water.odin](../src/world/water.odin), [grass.odin](../src/world/grass.odin) | Per-chunk decoration on main from gamedb |
| [object_lod.odin](../src/world/object_lod.odin), [water_lod.odin](../src/world/water_lod.odin), [terrain_cdlod.odin](../src/world/terrain_cdlod.odin) | Whole-worldspace LOD bakes per quad; CDLOD height texture |
| [world.odin](../src/world/world.odin) | Chunks; `acquire_chunk_assets`/`release_chunk_assets`; sync `load_chunk` for interiors |
| [window.odin](../src/world/window.odin), [space.odin](../src/world/space.odin), [world/collision.odin](../src/world/collision.odin) | Sim: live-cell window, `Ref_Event`, `sync_physics` from the store |

## Boundary

- **Threads.** The sim (60 Hz) emits `Ref_Event`s at tick end ([forward_ref_events](../src/app/sim.odin#L318)
  → `handoff.Queue`). Main applies them ([apply_ref](../src/app/sim.odin#L363) → `stream_apply`) and
  calls `stream_update` each frame. N decode workers share a LIFO `reqs` and a `ready` list.
- **Collision store.** The sim's [of](../src/collisions/collisions.odin#L46) returns `known=false` until
  the model lands, and that miss is the request (`take_wanted`, each frame). [put](../src/collisions/collisions.odin#L83)
  is first-wins and immutable, so readers hold it unlocked. Nothing is evicted.
- **Saved:** nothing. All of this is rebuilt from records and the VFS.
- **Not a plugin seam:** formats, gamedb, vfs and installer are core. Mods change assets by VFS override.

### C-ABI crossing list (Rust streamer; GPU upload stays in render on main)

| Direction | Item | Today | Needs for C |
|---|---|---|---|
| in | `stream_init`, `stream_apply`, `stream_update`, `stream_begin_load`/`stream_pump_load`, `stream_retarget`, `stream_destroy` | Odin procs, main | `extern "C"`, opaque handle |
| in | `Ref_Event` / [Ref_Placement](../src/world/space.odin#L44) | Odin union + slice | tag + union, `{ptr,len}`; `u64` form IDs, `u32` model IDs, column-major `[16]f32` |
| out | VFS read | `vfs.read` | callback like graphics `Host.read_file` ([graphics.odin:72](../src/graphics/graphics.odin#L72)) |
| out | model path | `models.path` | callback like `Host.model_path` |
| out | upload / release | `upload_cpu_model`, render `upload_*` | callback taking a flat `Cpu_Model` (verts 28 B, `u16` idx, BCn mips) |
| out | refcount | `model_acquire`/`model_release` | owned by the streamer, or a callback |
| out | collision | `collisions.put` | flat blob, see `collision-blob-abi` |
| out | gamedb | 13 queries (`cell_terrain`, `cell_base_textures`, `cell_dominant_texture`, `landscape_diffuse`, `grass_for_texture`, `cell_water`, `cells_of`, `cell_by_formid`, `refs_of`, `ref_effective_disabled`, `lod_model_of`, `base_size`, `is_tree`/`model_of`) | a view or an install-baked index, see `gamedb-for-streamer` |

Precedent: [bsa_glue](../build/bsa_glue/) is a Rust `staticlib` with `#[repr(C)]` and `extern "C"`,
built offline by [build-ba2.sh](../build/build-ba2.sh) and bound with `foreign import`.

## Holes

| id | gap | needs | mark |
|---|---|---|---|
| cache-eviction | `model_cache_mb`/`texture_cache_mb` default 0: RSS unbounded; the collision store and `models` table grow only | — | [assetdb.odin:143](../src/assetdb/assetdb.odin#L143) |
| collision-blob-abi | `nif.Collision` is Odin slices + `matrix[4,4]f32`; needs a flat C blob | — | [nif/collision.odin:99](../src/formats/nif/collision.odin#L99) |
| gamedb-for-streamer | the streamer queries gamedb directly; Rust needs a C read view or its own index | — | [stream.odin:273](../src/world/stream.odin#L273) |
| asset-converters | no material (`BSLightingShaderProperty`/texture set) or `.tri` blendshape pipeline | — | [converters.odin:9](../src/installer/converters/converters.odin#L9) |

- **cache-eviction:** the refcounts, cold LRU and DEVTOOLS balance asserts are built. The risk is a
  dangling `inst.model` / `Lod_Draw.model` after eviction, not a leak. Textures are ~75–83% of the footprint.
- **collision-blob-abi:** use one immutable blob per model: header (version, counts, offsets), a shared
  vertex/index pool, `i32` for `int`, `u8` bools, and a `has` byte for `projectile`. Reserve Havok
  material fields for `havok-materials` ([:593](../src/formats/nif/collision.odin#L593)).
- **gamedb-for-streamer:** record views already cover `Cell`, `Worldspace`, `Placed_Ref` and `Form`;
  LAND grids, cell ref lists, LTEX resolution and MNAM are missing. The render hole `graphics-cell-data`
  needs the same LAND data. An install-baked index must be rebuilt on a load-order change.
- **asset-converters:** the mark note is out of date. Audio, magic and UI converters exist, and the
  header's "stub registrations" do not. `decode_model` uses only the diffuse slot.

Adjacent (other areas): `graphics-gpu-streaming`, `anim-clip-store`, `hkx-porter`, `lip-converter`,
`havok-materials`, `load-order-files`, `mod-audio-convert`, `model-request-read`.

## Decisions

- The engine never reads `.hkx`/`.pex` at run time; mods ship the converted format.
- Index, don't copy: `content/` holds converted output only. (may change)
- The streamer is the one loader for every asset kind; the sim places things; the streamer picks visual LOD.
- Only IDs and plain data cross sim↔main, never pointers.
- Main owns the GPU cache; the sim reads only the CPU collision store.
- A read of something not yet loaded is the request.
- Every system drains and resumes; a drain hands in streaming results.
- LE and SE are one engine, a union, never a branch.
- The debug exit must print `[mem] clean`: eviction frees exactly what upload allocated.

## questions

- Eviction budget sizes (a 256 MB model budget is an untuned note).
- `.tri` output format (glTF morph targets assumed).
- Which base records carry alternate-texture sets for material translation.
- The manifest never compares source/archive lines: should a changed install re-trigger conversion?
