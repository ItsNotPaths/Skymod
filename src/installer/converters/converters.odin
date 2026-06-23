package converters

// Converters (ROADMAP Phase 1d): one file per converter, registered into the
// installer registry so adding a converter is additive. First converters prove
// the pipeline cheaply — DDS passthrough/validate, NIF passthrough, and a real
// transform (xwm/fuz -> ogg + .lip timeline) — with stub registrations for the
// hard ones (HKX->glTF, PEX->Lua, material-translation, .tri->blendshapes).
// Stubbed; built in Phase 1.
