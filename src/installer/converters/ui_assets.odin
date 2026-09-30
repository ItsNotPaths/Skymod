package converters

// The UI assets the install writes to a stable named path (the bank and the reticle are separate).
//
//   • BITMAP   (name != "") — an exported DefineBits symbol, pulled by name.
//   • INSTANCE (path != "") — a named instance drawn as it sits on the stage, at a frame label. Its
//     stage rect goes in the SWF's layout file (write_layout), so Lua places it exactly.
//   • SHAPE    (neither)    — one vector shape, found by its look: native px size + first solid fill.
//     Character ids change between game builds (the logo is 78 on LE, 554 or 567 on two SE builds);
//     instance names and looks do not.

UI_Asset :: struct {
	dest:    string, // output DDS under bethassets (Lua references this stable path)
	swf:     string, // source SWF/GFX in the vanilla install
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

	// ── Instances: the HUD chrome (a meter at "Empty" is its frame without the fill) ──
	{dest = "interface/hud/compass.dds", swf = HUD_SWF, path = HUD_ROOT + "CompassShoutMeterHolder.Compass.CompassFrame"},
	// The compass letters: a strip longer than a full turn, scrolled under the compass mask.
	{dest = "interface/hud/compass_strip.dds", swf = HUD_SWF, path = HUD_ROOT + "CompassShoutMeterHolder.Compass.DirectionRect"},
	// The stat meter chrome (health, magicka and stamina share it); widget/bar.lua bakes its numbers.
	{dest = "interface/hud/meter.dds", swf = HUD_SWF, path = HUD_ROOT + "Magica.MagickaMeter_mc", label = "Empty"},
	// The enemy bar's "Empty" frame drops the whole bar, so its chrome is the part that never moves;
	// widget/bar.lua bakes its numbers.
	{dest = "interface/hud/enemy.dds", swf = HUD_SWF, path = HUD_ROOT + "EnemyHealth_mc", still = true, hide = {"BracketsInstance"}},

	// ── Shapes (by size + fill) ──
	// Bethesda Game Studios logo.
	{dest = "interface/bethesdalogo.dds", swf = "interface/startmenu.swf", size = {621, 292}, fill = {0xbb, 0xbd, 0xbf, 0xff}},
	// Sneak eye (the pupil is a hole), re-coloured WHITE so the HUD can tint it.
	{dest = "interface/sneak_eye.dds", swf = HUD_SWF, size = {95, 44}, fill = {0x99, 0x33, 0, 0xff}, recolor = {255, 255, 255, 255}},
}
