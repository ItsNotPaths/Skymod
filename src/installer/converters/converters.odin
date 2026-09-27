package converters

// Converters (ROADMAP Phase 1d): one file per converter, registered into the
// installer registry so adding a converter is additive. First converters prove
// the pipeline cheaply — DDS passthrough/validate, NIF passthrough, and a real
// transform (xwm/fuz -> ogg + .lip timeline) — with stub registrations for the
// hard ones (HKX->glTF, material-translation, .tri->blendshapes). PEX->Lua is built:
// scripts.odin.
//
// (hole audio-output :tags audio :sev blocker) no audio output anywhere in src — no device, no mixer, no voice bus. The engine is silent.
// (hole voice-converter :tags audio :sev gap) the xwm/fuz -> ogg + .lip converter is described here and does not exist, so voice and sound assets stay unreadable even once a mixer lands, and lip timings never reach a face.
// (hole asset-converters :tags (assets unclaimed) :sev gap) only the script converter exists. Material translation and .tri blendshapes have no pipeline.
// (hole hkx-porter :tags (animation assets unclaimed) :sev blocker :needs (actor-states)) no hkx porter: skeletons, clips and behaviour projects (vanilla and Nemesis/Pandora mods) must convert at install time to a modern format (glTF clips, actor-state data); the engine never reads .hkx.
// Stubbed; built in Phase 1.
