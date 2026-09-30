# Native plugins

A native plugin is a shared library (`.so` or `.dll`) that replaces or extends one engine *seam*.
A seam is a table of C function pointers. The engine fills the table with its built-in, then each
plugin changes the entries it replaces. Every area doc in this folder names its seam, if it has
one.

Any language that can export a C function and read C structs can write a plugin: C, C++, Zig,
Rust, Odin, and more. Languages with a garbage collector are not supported.

## Loading

- A mod keeps its plugins in `<mod>/native/`. See [plugin.odin:16](../src/plugin/plugin.odin#L16).
- The engine loads plugins in mod priority order, lowest first. In one folder, it loads them by
  file name.
- A plugin loads only after the user trusts it in the mod manager. Trust is per file, by path and
  SHA-256. A changed file is untrusted again. See [trust.odin](../src/plugin/trust.odin).
- The seams are applied once, at game setup, in
  [game.odin:610](../src/app/game.odin#L610).

## The seam call

A plugin exports one function per seam, named `skymod_<seam>`:

```c
bool skymod_combat(uint32_t version, void *table);
```

- `version` is the seam's `VERSION`. Return false for a version you do not know. The table then
  stays as it was.
- `table` points to the seam's table, already filled by the built-in and by lower-priority
  plugins. Overwrite the entries you replace. Keep a copy of an old entry to call through to it.
- The last plugin that changes a seam owns it. The log names each owner.

| Seam | Export | Package | Doc |
|---|---|---|---|
| detection | `skymod_detection` | [src/detection](../src/detection) | [detection.md](detection.md) |
| sight | `skymod_sight` | [src/sight](../src/sight) | [detection.md](detection.md) |
| combat brain | `skymod_combat` | [src/combat](../src/combat) | [combat.md](combat.md) |
| condition functions | `skymod_conditions` | [src/condfn](../src/condfn) | - |
| magic landing | `skymod_magic` | [src/magic](../src/magic) | [magic.md](magic.md) |
| spell bodies | `skymod_magicphys` | [src/magicphys](../src/magicphys) | [magic.md](magic.md) |
| weather | `skymod_weather` | [src/weather](../src/weather) | [render.md](render.md) |
| graphics | `skymod_graphics` | [src/graphics](../src/graphics) | [render.md](render.md) |

Audio and the record database are core. They are not seams.

## Plain data only

Only plain data crosses a seam: fixed-size structs, `Form_ID`s (`u64`), and spans.

- `Span(T)` is `{T *data; intptr_t len;}`. See [plugin.odin:20](../src/plugin/plugin.odin#L20).
- `Form_ID` is `slot << 32 | local`. See [formid.odin](../src/formid/formid.odin).
- A seam's input holds a `^plugin.World`. It answers queries about the game: refs, actor values,
  factions, keywords, quests, GMSTs, game time, and records. See
  [world.odin](../src/plugin/world.odin). Record views for 48 record kinds are in
  [src/plugin/records*.odin](../src/plugin/records.odin).
- Every callback takes the host's `data` pointer first.

## Saved state

A plugin that keeps state across saves exports three more functions. The save stores the data
under the plugin's ID. If the plugin is removed, its data stays in the save.

```c
const char *skymod_id(void);                        // "name.uuid", stable forever
intptr_t    skymod_save(uint8_t *out, intptr_t cap); // returns size; writes only if it fits
void        skymod_load(const uint8_t *data, intptr_t len); // len 0: start fresh
```

See [plugin.odin:113](../src/plugin/plugin.odin#L113).

## Examples

[tests/plugins](../tests/plugins) holds small example plugins. `build/test.sh` builds each
one into `build/out/test-plugins/<name>.so`.

- [combat_calm](../tests/plugins/combat_calm/combat_calm.odin): nobody fights.
- [detection_blind](../tests/plugins/detection_blind), [sight_blind](../tests/plugins/sight_blind):
  nobody sees.
- [condition_add](../tests/plugins/condition_add): adds a condition function.
- [save_counter](../tests/plugins/save_counter/save_counter.odin): saved state.

## License

Native plugins link into the engine, so they must also be GPL-3.0. See [LICENSE](../LICENSE).
