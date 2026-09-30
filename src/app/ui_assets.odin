package main

// The UI pulled-asset MANIFEST: every vanilla asset baseui extracts to a stable named path (the
// browse dump in dump_swf_assets and the synthesized reticle are separate).
//
//   • BITMAP   (name != "") — an exported DefineBits symbol, pulled by name.
//   • INSTANCE (path != "") — a named instance drawn as it sits on the stage, at a frame label. Its
//     stage rect goes in the SWF's layout file (baseui_write_layout), so Lua places it exactly.
//   • SHAPE    (neither)    — one vector shape, found by its look: native px size + first solid fill.
//     Character ids change between game builds (the logo is 78 on LE, 554 or 567 on two SE builds);
//     instance names and looks do not.

UI_Asset :: struct {
	dest:    string, // output DDS under bethassets (Lua references this stable path)
	swf:     string, // source SWF/GFX, read through the VFS (a mod can override the source)
	name:    string, // BITMAP: exported symbol name
	path:    string, // INSTANCE: dotted instance names from the root
	label:   string, // INSTANCE: the frame label to draw ("" = first frame)
	hide:    []string, // INSTANCE: named children left out
	still:   bool,   // INSTANCE: only the children that never move (chrome without its fill)
	size:    [2]int, // SHAPE: native px size
	fill:    [4]u8,  // SHAPE: the shape's first solid fill (RGBA)
	recolor: [4]u8,  // SHAPE: output colour override; {0,0,0,0} = keep
}

// ART_SCALE is px per stage px for INSTANCE art: sharp up to a 1440p screen.
ART_SCALE :: 2

HUD_SWF :: "interface/exported/hudmenu.gfx"
HUD_ROOT :: "HUDMovieBaseInstance."

UI_ASSETS := [?]UI_Asset{
	// ── Bitmaps ──
	// Credits header icon.
	{dest = "interface/skyrimlogo.dds", swf = "interface/creditsmenu.swf", name = "SkyrimLogo"},

	// ── Instances: the HUD chrome ("Empty" = a meter without its fill, "Full" = with it) ──
	{dest = "interface/hud/compass.dds", swf = HUD_SWF, path = HUD_ROOT + "CompassShoutMeterHolder.Compass.CompassFrame"},
	{dest = "interface/hud/health_empty.dds", swf = HUD_SWF, path = HUD_ROOT + "Health.HealthMeter_mc", label = "Empty"},
	{dest = "interface/hud/health_full.dds", swf = HUD_SWF, path = HUD_ROOT + "Health.HealthMeter_mc", label = "Full"},
	{dest = "interface/hud/magicka_empty.dds", swf = HUD_SWF, path = HUD_ROOT + "Magica.MagickaMeter_mc", label = "Empty"},
	{dest = "interface/hud/magicka_full.dds", swf = HUD_SWF, path = HUD_ROOT + "Magica.MagickaMeter_mc", label = "Full"},
	{dest = "interface/hud/stamina_empty.dds", swf = HUD_SWF, path = HUD_ROOT + "Stamina.StaminaMeter_mc", label = "Empty"},
	{dest = "interface/hud/stamina_full.dds", swf = HUD_SWF, path = HUD_ROOT + "Stamina.StaminaMeter_mc", label = "Full"},
	// The enemy bar's "Empty" frame drops the whole bar, so its chrome is the part that never moves.
	{dest = "interface/hud/enemy_empty.dds", swf = HUD_SWF, path = HUD_ROOT + "EnemyHealth_mc", still = true, hide = {"BracketsInstance"}},
	{dest = "interface/hud/enemy_full.dds", swf = HUD_SWF, path = HUD_ROOT + "EnemyHealth_mc", label = "Full", hide = {"BracketsInstance"}},

	// ── Shapes (by size + fill) ──
	// Bethesda Game Studios logo.
	{dest = "interface/bethesdalogo.dds", swf = "interface/startmenu.swf", size = {621, 292}, fill = {0xbb, 0xbd, 0xbf, 0xff}},
	// The shout meter's deco FRAME (red border + knotwork ends, 3-sliced by the bar widget), re-coloured
	// WHITE so a bar can tint it.
	{dest = "interface/bar_frame.dds", swf = HUD_SWF, size = {358, 25}, fill = {0x99, 0, 0, 0xff}, recolor = {255, 255, 255, 255}},
	// The compass frame's silhouette in its black, used as a plain bar background (its grey border
	// would double the bar's own frame).
	{dest = "interface/bar_bg.dds", swf = HUD_SWF, size = {366, 30}, fill = {1, 1, 1, 0xff}, recolor = {1, 1, 1, 0xff}},
	// Sneak eye (the pupil is a hole), re-coloured WHITE so the HUD can tint it.
	{dest = "interface/sneak_eye.dds", swf = HUD_SWF, size = {95, 44}, fill = {0x99, 0x33, 0, 0xff}, recolor = {255, 255, 255, 255}},
}
