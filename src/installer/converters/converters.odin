package converters

// Converters (ROADMAP Phase 1d): one file per converter, registered into the
// installer registry so adding a converter is additive. Stub registrations for the
// hard ones (HKX->glTF, material-translation, .tri->blendshapes). PEX->Lua is built:
// scripts.odin. xWMA->Ogg: audio.odin.
//
// (hole asset-converters :tags (assets unclaimed) :sev gap) only the script converter exists. Material translation and .tri blendshapes have no pipeline.
// (hole hkx-porter :tags (animation assets unclaimed) :sev blocker :needs (actor-states)) no hkx porter: skeletons, clips and behaviour projects (vanilla and Nemesis/Pandora mods) must convert at install time to a modern format (glTF clips, actor-state data), keeping clip annotations (SoundPlay.*, weaponSwing, FootLeft); the engine never reads .hkx.
// Stubbed; built in Phase 1.
