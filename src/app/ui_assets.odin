package main

// The UI pulled-asset MANIFEST + cross-edition LINK TABLE — every vanilla asset baseui extracts to a
// stable named path (the browse dump in dump_swf_assets and the synthesized reticle are separate).
//
// Two kinds, inferred from whether `name` is set:
//   • BITMAP  (name != "") — an exported DefineBits symbol, pulled by name. Names are stable across
//                            editions, so there's no le/se split.
//   • SHAPE   (name == "") — a vector shape, pulled by Scaleform character id. SSE re-exported every menu
//                            SWF/GFX so the id differs per edition, AND an id is often reused for
//                            unrelated art (LE hudmenu holds BOTH 416 = the black bar bg AND 467 = an
//                            unrelated 11px shape). So we never guess by id or "first present" — we store
//                            the verified id per edition and read the column for the install's edition.
//
// Filling the SE column (on an SE install; LE is already filled from the dev box):
//   odin run tools/swfdump -- "<...\Skyrim - Interface.bsa>" --name <swf> --shapes <outdir>
// then match the DDS whose size/fill equals the LE fingerprint noted per row and paste its id into `se`.
// (se = 0 → not yet mapped → that shape is skipped + logged on SE; the widget falls back gracefully.)

UI_Asset :: struct {
	dest:    string, // output DDS under bethassets (Lua references this STABLE path, not the per-edition id)
	swf:     string, // source SWF/GFX, read through the VFS (a mod can override the source)
	name:    string, // BITMAP: exported symbol name. "" → this row is a SHAPE, pulled by id below.
	le:      u16,    // SHAPE: LE (v104) character id
	se:      u16,    // SHAPE: SE (v105) character id — 0 until mapped on an SE install
	recolor: [4]u8,  // SHAPE: output fill override; {0,0,0,0} = keep the shape's OWN fill
}

// LE fingerprints (size + source fill) are noted per shape row — the visual key for matching the SE id.
UI_ASSETS := [?]UI_Asset{
	// ── Bitmaps (by exported name; edition-stable) ──
	// Credits header icon.
	{dest = "interface/skyrimlogo.dds", swf = "interface/creditsmenu.swf", name = "SkyrimLogo"},

	// ── Shapes (by per-edition character id) ──
	// Bethesda Game Studios logo — startmenu, 621×292 #bbbdbf, used as-is.
	{dest = "interface/bethesdalogo.dds", swf = "interface/startmenu.swf", le = 78},
	// Stat-bar deco FRAME — hudmenu, 358×25 #990000 (red border + knotwork ENDS, 3-sliced: the ends stay
	// fixed, the middle stretches to any width — there is NO separate end-cap). Re-rasterized WHITE so a
	// bar can tint it per stat (red × tint stays red, hence the recolour).
	{dest = "interface/bar_frame.dds", swf = "interface/exported/hudmenu.gfx", le = 395, recolor = {255, 255, 255, 255}},
	// Stat-bar BG — hudmenu, 366×30 #010101 (the frame's black background companion), used as-is.
	{dest = "interface/bar_bg.dds", swf = "interface/exported/hudmenu.gfx", le = 416},
}
