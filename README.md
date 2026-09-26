# SkyMod

A custom engine that runs *legally-owned* Skyrim content. Not a Skyrim
reimplementation in the OpenMW-parity sense — a modern engine that ingests
Skyrim's data and assets at **install time** and serves clean, open formats to a
thin runtime. We redistribute **zero** Bethesda assets; the engine operates on
the user's own install. (Full plan: `ROADMAP.md`, kept local.)

Built with **Odin** + **SDL3 / SDL3_gpu**. The build chassis (vendored static
SDL3, GLSL→SPIR-V shaders, release script) follows the `alchaspec` / `2diso`
sibling projects.

> **Status:** Phase 0 (Foundations) — the chassis. An SDL3 window links and runs;
> the renderer, debug camera, and ImGui land in the following Phase-0 steps.

## Layout

    src/
      platform/   SDL3 window, input, audio, timing
      render/     SDL3_gpu behind our Renderer interface; render/shaders (GLSL)
      math/       thin helpers over core:math/linalg
      vfs/        virtual filesystem: BSA/BA2 mounts + loose files
      formats/    pure parsers, no engine deps: bsa, esm, nif, ...
      installer/  source detection, converter registry, manifest/cache
      assetdb/    runtime asset cache: load-on-demand, ref-counted
      world/      cell/worldspace, scene graph, ref placement
      gamedb/     parsed ESM record database (in-memory, queryable)
      physics/    Jolt wrapper
      app/        the test-bed executable (entry point)
      tools/      ImGui inspectors, asset browser, golden differ
    tests/
      fixtures/   SYNTHETIC minimal-valid records (committed)
      unit/       per-parser tests — run in CI, no game assets ever
      golden/     opt-in, needs a local install; gitignored data
      smoke/      integration: load a known cell end-to-end
    build/        build scripts (shaders, tests)
    download-deps.sh  one-time vendoring of SDL3 + glslang
    release.sh        self-contained build -> ../skymod-release/

## Toolchain

Pinned Odin: see `.odin-version` (`dev-2026-05-nightly:ea5175d`). Also needs
`cmake` / `curl` (one-time SDL3 build) and a C/C++ toolchain.

## Build & run

    ./download-deps.sh        # once: static SDL3 + glslangValidator + Dear ImGui -> vendor/
    ./build/test.sh           # type-check every package + run unit tests (the CI gate)
    ./build/dev.sh --run      # debug build (leak report at exit) -> build/out/, then run
    ./release.sh              # self-contained binary -> ../skymod-release/skymod

`release.sh` compiles `src/render/shaders` to SPIR-V, then statically links the
vendored SDL3 so the shipped binary reads no external SDL — run it on a desktop
session with Vulkan. The window opens; press Esc (or close it) to quit.

`build/dev.sh` is the debug build (`-debug`): bounds checks plus a
`Tracking_Allocator` leak/bad-free report at exit (`[mem] clean` on success — see
`docs/memory.md`). Logging goes to `skymod.log` beside the binary, wiped each run;
pass `--persist-logs` for an accumulating timestamped `logs/` folder instead.

## Testing

`build/test.sh` is the CI gate: it `odin check`s every package and runs
`odin test tests/unit` against **synthetic** fixtures only. Golden / visual-
regression tests are opt-in, require a local Skyrim install, and live on the
developer's machine only (`tests/golden`, gitignored) — never in the repo or CI.

## Credits

The names and parameter types of the condition (CTDA) functions come from
[xEdit](https://github.com/TES5Edit/TES5Edit) (`wbDefinitionsTES5.pas`), by the
xEdit team, under the Mozilla Public License 2.0.
