package main

// The UI pulled-asset MANIFEST: every vanilla asset baseui extracts to a stable named path (the
// browse dump in dump_swf_assets and the synthesized reticle are separate).
//
//   • BITMAP (name != "") — an exported DefineBits symbol, pulled by name.
//   • SHAPE  (name == "") — a vector shape, found by its look: native px size + solid fill. Character
//     ids change between game builds (the logo is 78 on LE, 554 or 567 on two SE builds), the look
//     does not.

UI_Asset :: struct {
	dest:    string, // output DDS under bethassets (Lua references this stable path)
	swf:     string, // source SWF/GFX, read through the VFS (a mod can override the source)
	name:    string, // BITMAP: exported symbol name. "" → a SHAPE, found by size + fill below.
	size:    [2]int, // SHAPE: native px size
	fill:    [4]u8,  // SHAPE: the shape's own solid fill (RGBA)
	recolor: [4]u8,  // SHAPE: output fill override; {0,0,0,0} = keep `fill`
}

UI_ASSETS := [?]UI_Asset{
	// ── Bitmaps (by exported name; edition-stable) ──
	// Credits header icon.
	{dest = "interface/skyrimlogo.dds", swf = "interface/creditsmenu.swf", name = "SkyrimLogo"},

	// ── Shapes (by size + fill) ──
	// Bethesda Game Studios logo.
	{dest = "interface/bethesdalogo.dds", swf = "interface/startmenu.swf", size = {621, 292}, fill = {0xbb, 0xbd, 0xbf, 0xff}},
	// Stat-bar deco FRAME (red border + knotwork ENDS, 3-sliced: the ends stay
	// fixed, the middle stretches to any width — there is NO separate end-cap). Re-rasterized WHITE so a
	// bar can tint it per stat (red × tint stays red, hence the recolour).
	{dest = "interface/bar_frame.dds", swf = "interface/exported/hudmenu.gfx", size = {358, 25}, fill = {0x99, 0, 0, 0xff}, recolor = {255, 255, 255, 255}},
	// Stat-bar BG, used as-is. In hudmenu it is the compass frame (CompassFrame); the HUD uses it for both.
	{dest = "interface/bar_bg.dds", swf = "interface/exported/hudmenu.gfx", size = {366, 30}, fill = {1, 1, 1, 0xff}},
	// Compass centre notch, used as-is.
	{dest = "interface/compass_notch.dds", swf = "interface/exported/hudmenu.gfx", size = {27, 45}, fill = {0xbb, 0xbd, 0xbf, 0xff}},
	// Sneak eye (the pupil is a hole), re-rasterized WHITE so the HUD can tint it.
	{dest = "interface/sneak_eye.dds", swf = "interface/exported/hudmenu.gfx", size = {95, 44}, fill = {0x99, 0x33, 0, 0xff}, recolor = {255, 255, 255, 255}},
}
