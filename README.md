# SkyMod

SkyMod is a openMW like "engine" that runs Skyrim content from a copy that the
user owns. At install time, it reads the game data and assets and converts them
to open formats. At run time, it loads only those converted formats.
The repository contains no Bethesda assets.

[Odin](https://odin-lang.org), [SDL3](https://github.com/libsdl-org/SDL), [Jolt](https://github.com/jrouwe/joltphysics), [Lua](https://github.com/lua/lua), [ffmpeg](https://git.ffmpeg.org/ffmpeg.git), [ba2]((https://github.com/Ryan-rsm-McKenzie/bsa-rs), 

The installer transpiles Papyrus to Lua*, so the engine never runs Papyrus.

*The lua used in skymod is patched in 2 ways, it is 0 based like papyrus, and it 
carries standard !=, +=, <= symbols on top of lua's. It is also falsy in ways that
match skyrim/CE papyrus

Mods extend the engine at two levels:

- **Lua scripts.** A mod ships `.lua` files that replace a script, or
  `.patch.lua` files that edit one. Mod priority sets the order.
- **Native "plugins".** A mod ships a `.so` or `.dll` in its `native/` folder.
  A plugin replaces or extends one engine *seam* (detection, combat, sight,
  magic, graphics, and more). See `src/plugin` and the examples in
  `tests/plugins`.

(standard esp/esl/bsa mods also work just fine)

## Requirements

- Odin, at the version in `.odin-version`. Another version can work, but the
  build prints a warning.
- A C/C++ toolchain, `cmake`, and `curl`.
- A Rust toolchain (`cargo`, edition 2021) for the BSA packer in
  `build/bsa_glue`.
- A Vulkan desktop session to run the engine.
- A Skyrim install, LE or SE, to run the engine. The unit tests do not need it.

## Build

```sh
./download-deps.sh     # once: fetch and build the dependencies into vendor/
./build/test.sh        # type-check every package, then run the unit tests
./build/dev.sh --run   # debug build into build/out/, then run it
./release.sh           # static release build into ../skymod-release/
(you can also ./quicktest.sh from the source dir to automate release.sh and launch)
```

Before the first run, set the path to your Skyrim install in `settings.txt`.
Use `source_game_se` or `source_game_le`. The engine finds the edition from the
executable.

The debug build writes a report of leaks and bad frees at exit. a clean run
prints `[mem] clean`. The log is `skymod.log`, beside the binary. Pass
`--persist-logs` to keep one log per run in `logs/`

## Layout

```
src/
  app/           the executable: boot, main loop, cell load, UI screens
  formats/       parsers with no engine dependencies: esm, nif, bsa, pex, swf, dds, ...
  installer/     finds the game install and converts assets
  transpile/     Papyrus (pex) to Lua
  vfs/ assetdb/  asset lookup and the runtime asset cache
  gamedb/        the record database, read-only
  worldstate/    the saved game state that changes: actors, quests, crime, clock
  world/         cells, streaming, placement
  script/        the Lua runtime and the natives that scripts call
  ai/ nav/       AI packages, movement, and paths
  conditions/    CTDA evaluation
  plugin/        loads native plugins and gives them the seams
  <seam>/        one package per seam: combat, detection, sight, magic,
                 magicphys, weather, graphics, condfn
  render/ ui/    GPU drawing and the UI system
  platform/      SDL window, devices, timing
tools/           dev tools: esmdump, nifdump, pexdump, pex2lua, scriptrun, ...
tests/
  unit/          unit tests with synthetic fixtures only
  plugins/       example native plugins for the seams
  golden/        opt-in tests that need a local install (not committed)
build/           build scripts and patches for the vendored dependencies
vendor/          fetched by download-deps.sh (not committed)
```

## Dependencies

`download-deps.sh` fetches the dependencies into `vendor/`. The repository does
not include them. Changes to a dependency are patch files in `build/`, for
example `build/lua-01-zero-index.patch`.

| Dependency | License |
|---|---|
| SDL3 | zlib |
| Dear ImGui, odin-imgui | MIT |
| Jolt Physics, JoltC | MIT |
| Lua 5.4 (patched) | MIT |
| FFmpeg (audio decode only, LGPL build) | LGPL 2.1+ |
| ba2 (Rust crate) | 0BSD |
| Kenney Input Prompts | CC0 |

## Credits

The names and parameter types of the condition (CTDA) functions come from
[xEdit](https://github.com/TES5Edit/TES5Edit) (`wbDefinitionsTES5.pas`), by the
xEdit team, under the Mozilla Public License 2.0.

## License

GPL-3.0. See `LICENSE`. Native plugins link into the engine, they must also be GPL-3.0 for public safety
Skyrim and its content are the property of Bethesda Softworks.
This project is not affiliated with Bethesda.
