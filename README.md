# SkyMod

An OpenMW-like engine for Skyrim content, from a copy the user owns.

- Install time: reads game data and assets, converts them to open formats
- Run time: loads only the converted formats
- No Bethesda assets in the repo
- Standard esp/esl/bsa mods work

Built on [Odin](https://odin-lang.org), [SDL3](https://github.com/libsdl-org/SDL),
[Jolt](https://github.com/jrouwe/joltphysics), [Lua](https://github.com/lua/lua),
[FFmpeg](https://git.ffmpeg.org/ffmpeg.git),
[ba2](https://github.com/Ryan-rsm-McKenzie/bsa-rs).

## Changes from vanilla

`*` = not done, needs a better solution, or unclaimed.

```
scripts
  papyrus -> lua at install, no papyrus at run time
  patched lua: 0-based, != += && ||, None falsy
  Wait() loops -> per-tick timers, no script lag
  455 hand rewrites of the costliest scripts
  per-handler instruction budget, no runaway scripts
  mods replace (.lua) or patch (.patch.lua) single functions

actor values and factions
  scripts create AVs by name (rt.actor_value)
  AV kinds: static, latched, pool, timer, stopwatch, game-time clocks
  AV parts: value, capacity, amount
  perks and level are AVs; formulas read any AV
  scripts create factions at runtime (rt.faction): ranks, crime, relations
  script factions saved whole

simulation
  fixed 60 Hz tick, apart from framerate
  sim thread; main thread only draws
  menus pause the world
  one game clock, no short-timer freeze
  double-precision physics, no far-origin jitter
  clutter settles and sleeps
  no-collision flora is walk-through
  time skip callers (sleep/wait, fast travel, jail)       *

form and ref IDs
  64-bit: slot << 32 | local
  no 255-plugin or ESL limit
  slot set once per plugin, never reused
  mod order changes overrides, never identity
  own slots for created refs, effects, script factions, lua forms
  mod UUID (skymod/mod.txt) carries forms across installs

saves
  add or reorder mods mid-save
  script state saved as diff from defaults
  spell lists saved as deltas
  mod actor values stored by name
  compression (zstd)                                      *

mods
  built-in MO2-style manager, one folder per mod
  plugin order from mod order
  profiles, separators, locked base/DLC rows
  lua defines forms by name (rt.effect, rt.spell)
  native .so/.dll plugins replace engine seams
  native plugins need user trust (path + SHA-256)
  LE and SE in one engine
  audio -> Opus at install; mods ship WAV or Ogg
  asset cache eviction (built, off)                       *

actors and combat
  player is an actor like any NPC
  combat damage seam: gear, armor, crits, sneak, difficulty
  perks -> actor values + hit/armor hooks
  item instances keep their own form ID
  actor states (sit, sleep, sneak, swing)                 *
  bash and block damage                                   *
  item tempering                                          *
  mounts, flight, bleedout                                *
  animation                                               *

magic
  spells, powers, scrolls, enchantments -> data + lua
  per-tick effect formulas, resist/stacking hooks
  spell shapes: beam, spray, projectile, aura
  absorption, wards, disease, soul gems, poison           *
  shouts                                                  *
  cast and enchantment visuals                            *

render and ui
  lua based ui framework        *
```

## Requirements

- Odin at `.odin-version` (others warn)
- C/C++ toolchain, `cmake`, `curl`
- Rust (`cargo`), for the BSA packer in `build/bsa_glue`
- Vulkan
- Skyrim LE or SE to run (not for unit tests)

## Build

```sh
./download-deps.sh     # once: dependencies into vendor/
./build/test.sh        # type-check every package, run unit tests
./build/dev.sh --run   # debug build into build/out/, run it
./release.sh           # static release build into ../skymod-release/
./quicktest.sh         # release.sh, then launch
```

- Set your install in `settings.txt` (`source_game_se` or `source_game_le`)
- Debug build reports leaks at exit; clean = `[mem] clean`
- Log: `skymod.log` beside the binary; `--persist-logs` keeps one per run

## Layout

```
src/
  app/           executable: boot, main loop, cell load, UI screens
  formats/       parsers, no engine deps: esm, nif, bsa, pex, swf, dds, ...
  installer/     game detection, asset conversion
  transpile/     papyrus (pex) -> lua
  vfs/ assetdb/  asset lookup, runtime asset cache
  gamedb/        record database, read-only
  worldstate/    saved game state: actors, quests, crime, clock
  world/         cells, streaming, placement
  script/        lua runtime, natives
  ai/ nav/       AI packages, movement, paths
  conditions/    CTDA evaluation
  plugin/        native plugin loader
  <seam>/        combat, detection, sight, magic, magicphys, weather, graphics, condfn
  render/ ui/    GPU drawing, UI
  platform/      SDL window, devices, timing
tools/           esmdump, nifdump, pexdump, pex2lua, scriptrun, ...
tests/
  unit/          synthetic fixtures only
  plugins/       example native plugins
  golden/        needs a local install (not committed)
build/           build scripts, dependency patches
vendor/          from download-deps.sh (not committed)
```

## Dependencies

Fetched into `vendor/`, not committed. Our changes are patches in `build/`.

| Dependency | License |
|---|---|
| SDL3 | zlib |
| Dear ImGui, odin-imgui | MIT |
| Jolt Physics, JoltC | MIT |
| Lua 5.4 (patched) | MIT |
| FFmpeg (audio decode, LGPL build) | LGPL 2.1+ |
| ba2 (Rust crate) | 0BSD |
| Kenney Input Prompts | CC0 |

## Credits

CTDA function names and parameter types come from
[xEdit](https://github.com/TES5Edit/TES5Edit) (`wbDefinitionsTES5.pas`), by the
xEdit team, under the Mozilla Public License 2.0.

## License

- GPL-3.0, see `LICENSE`
- Native plugins link into the engine, so they must also be GPL-3.0
- Skyrim and its content are the property of Bethesda Softworks
- Not affiliated with Bethesda
