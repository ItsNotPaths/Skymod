package converters

// Converters (ROADMAP Phase 1d): one file per converter, registered into the
// installer registry so adding a converter is additive. First converters prove
// the pipeline cheaply — DDS passthrough/validate, NIF passthrough, and a real
// transform (xwm/fuz -> ogg + .lip timeline) — with stub registrations for the
// hard ones (HKX->glTF, material-translation, .tri->blendshapes). PEX->Lua is built:
// scripts.odin.
//
// HOLE(audio, blocker): no audio output anywhere in src — no device, no mixer, no voice bus. The engine is silent.
// HOLE(audio, gap): the xwm/fuz -> ogg + .lip converter is described here and does not exist, so voice and sound assets stay unreadable even once a mixer lands, and lip timings never reach a face.
// HOLE(assets, gap): only the script converter exists. HKX->glTF, material translation and .tri blendshapes have no pipeline.
// Stubbed; built in Phase 1.
