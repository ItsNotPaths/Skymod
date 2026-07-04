-- ui/loading_menu.lua
--
-- The SkyMod load screen — our Lua reimplementation of Skyrim's loadingmenu.swf, shipped as the
-- built-in UI mod. We SKIP the spinning 3D model; the layout keeps the vanilla essentials:
--   • a progress bar across the bottom (the reusable `bar` widget: shader FILL + drawn FRAME),
--   • the player LEVEL top-right (edittext id 1500 = "$LEVEL", ~size 16, #999999),
--   • a rotating loading TIP snippet bottom-right (edittext id 2000 = 500x185, right-aligned).
--
-- The TIP text is NOT in the SWF — it comes from the game's LSCR (load-screen) DESC records, decoded
-- into engine.load_progress().tip. Non-interactive: the engine's load loop drives it, pumping progress
-- into the host each frame. Re-evaluated every frame (ui.screen), so the bar + tip update live.

local TRACK  = "#000000cc" -- empty-bar background (vanilla shape_5000's black fill, semi-transparent)
local BORDER = "#bbbdbf"   -- bar outline (vanilla shape_5000's grey outline — the "frame")
local FILL   = "#c8a24b"   -- warm gold fill (the shader tints the sheen with it)

ui.screen(function()
  local p = engine.load_progress()               -- { frac, phase, level, tip }
  local vw = (ui.vw > 0 and ui.vw) or 1280
  local bar_w = math.floor(vw * 0.5)

  -- The LSCR tip pool is empty until the game data is decoded (the first ~40% of boot); show NO tip until
  -- a real one is available (an empty text renders nothing) rather than a placeholder.
  local tip = p.tip or ""

  return {
    _kind = "container",
    fill = "both",
    color = "#000000ff",                          -- opaque black backdrop (no world behind the load screen)

    -- Player level, TOP-right (vanilla "$LEVEL" field colour). Its own bar is deferred until the player
    -- stat data structure is fleshed out.
    text {
      string.format("Level %d", p.level or 1),
      anchor = "top_right",
      offset = { -60, 48 },
      scale = 0.30,
      color = "#999999",
    },

    -- Progress bar centred across the bottom: the vanilla stat-bar deco (hudmenu shape 416 black bg +
    -- shape 395 red frame, both 3-sliced so the decorated knotwork ends stay fixed and the middle
    -- stretches to width) with our shader fill inside.
    bar {
      anchor = "bottom",
      offset = { 0, -60 },
      size = { bar_w, 30 },
      value = p.frac or 0,
      fill = FILL,
      bg = "hudmenu/shape_416.dds",    -- black background frame
      frame = "interface/bar_frame.dds", -- the decorated frame (shape 395), extracted WHITE
      frame_color = "#ffffff",          -- tint the white frame to any RGBA (health=red, magicka=blue, …)
      slice = 48,                       -- knotwork cap width (source px) kept fixed; middle stretches
      -- fill inset {x,y}: x sits the fill just inside the knotwork (which ends ~30px in) so it neither
      -- gaps nor bleeds into the cap; y insets it inside the top/bottom border.
      inset = { 32, 8 },
    },

    -- Phase label, above the bar (the bar's top is ~90px up, so clear it), centred.
    text {
      p.phase or "",
      anchor = "bottom",
      offset = { 0, -100 },
      scale = 0.30,
      color = "#bbbdbf",
    },

    -- Loading tip snippet, bottom-right, wrapped (vanilla edittext 2000 geometry: 500 wide).
    text {
      tip,
      anchor = "bottom_right",
      offset = { -60, -150 },
      size = { 500, 0 },
      wrap = 500,
      scale = 0.34,
      color = "#cfcfcf",
    },
  }
end)
