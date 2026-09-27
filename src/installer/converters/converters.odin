package converters

// (hole anim-clip-store :tags (threading animation assets) :sev gap :needs (hkx-porter stream-requests)) clips and skeletons are needed by the sim (clock, annotations, root motion, hitbox bones) and by main (full sampling). Wanted: the streamer loads them once into a read-only store both threads read; the porter keeps annotations and the root-motion track apart from the bone tracks.
// Converters (ROADMAP Phase 1d): one file per converter, registered into the
// installer registry so adding a converter is additive. Stub registrations for the
// hard ones (HKX->glTF, material-translation, .tri->blendshapes). PEX->Lua is built:
// scripts.odin. xWMA->Ogg: audio.odin.
//
// (hole asset-converters :tags (assets unclaimed) :sev gap) only the script converter exists. Material translation and .tri blendshapes have no pipeline.
// (hole hkx-porter :tags (animation assets unclaimed) :sev blocker :needs (actor-states)) no hkx porter: skeletons, clips and behaviour projects (vanilla and Nemesis/Pandora mods) must convert at install time to a modern format (glTF clips, actor-state data), keeping clip annotations (SoundPlay.*, weaponSwing, FootLeft); the engine never reads .hkx.
// (hole video-converter :tags (assets ui) :sev gap) Bink (.bik) videos stay Bink: nothing converts them at install to a normal format (mp4 planned; codec undecided — H.264 needs x264 (GPL) or openh264, AV1 has SVT-AV1 + dav1d). ffmpeg decodes Bink once its bink demuxer and decoders are enabled.
// Stubbed; built in Phase 1.
