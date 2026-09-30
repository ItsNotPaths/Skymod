-- ui/main_menu.lua
--
-- The SkyMod main menu — our Lua reimplementation of Skyrim's startmenu, shipped as the synthesized
-- built-in UI mod (content/ui). FAT-LUA: this file owns the menu's structure AND behavior. It builds
-- the secondary panels (confirm / Load selector) as a SIDEBAR transient, registers what each action
-- does (ui.on), and registers the screen view (ui.screen). The engine only routes input + draws.
--
-- THE SIDEBAR (from startmenu.swf, swfdump'd — shapes 5000/8500/9400 over a 1280x720 stage): a tall,
-- narrow VERTICAL STRIPE that slides in from the right and rests to the LEFT of the menu buttons. The
-- stripe is translucent black (#000000 @ ~0.59 in the SWF) with a thin light inset line down each side
-- (the SWF's accent is #999999 @ ~0.4; we use Skyrim's UI off-white #bbbdbf so the "white borders"
-- read as the user sees them). Content (confirm text / save selector) is centred. Built from our
-- primitives, not the SWF sprite — same look, our engine. Continue/New/Quit confirm IN the stripe;
-- Load shows the save selector in it.
--
-- Style: hard white-on-black; `scale` is glyph height as a fraction of the atlas px (atlas = 64px), so
-- 0.31 ≈ 20px (the SWF menu size). House style: one property per line (diffable + patchable).

local SIDE_W = 320 -- stripe width (px); SWF stripe is ~327 wide at the 1280x720 ref, scaled to height
local START_X = SIDE_W + 24 -- offset.x fully off the right edge (slide start)
local REST_X = -300 -- offset.x at rest: the stripe's right edge sits just left of the menu buttons

-- sidebar wraps `content` (a list of centred nodes) in the sliding stripe. Modal, so input scopes to
-- it (the menu buttons stay visible to its right but inert). The slide tweens off the spawn time
-- (ui.spawn stamps data._t0) via ui.anim_in. Reused by confirm + load_panel.
local function sidebar(data, content)
  local k = ui.anim_in(data._t0, 0.22)
  local x = REST_X + (1 - k) * (START_X - REST_X) -- ease in from off-screen-right to rest-left-of-buttons

  local col = {
    _kind = "column",
    anchor = "center", -- centred in the stripe (vertically + horizontally)
    align = "center",
    size = { SIDE_W - 56, 0 },
    gap = 18,
  }
  for _, c in ipairs(content) do
    col[#col] = c
  end

  return {
    _kind = "container",
    modal = true,
    anchor = "top_right",
    offset = { x, 0 },
    size = { SIDE_W, 0 },
    fill = "y", -- full height (the SWF stripe is ~full stage height)
    color = "#00000097", -- translucent black body (alpha 151, from the SWF)
    -- inset light lines ~5px in from each edge (the SWF's faint accent, white)
    rect { anchor = "left", offset = { 5, 0 }, size = { 2, 0 }, fill = "y", color = "#bbbdbfdd" },
    rect { anchor = "right", offset = { -5, 0 }, size = { 2, 0 }, fill = "y", color = "#bbbdbfdd" },
    col,
  }
end

-- confirm builds a Yes/No (or single-button) prompt inside the sidebar. Actions scope to data.on.
local function confirm(data)
  local buttons = { _kind = "row", gap = 36, align = "center" }
  buttons[#buttons] = button { data.yes or "Yes", action = "yes", scale = 0.31 }
  if data.no then
    buttons[#buttons] = button { data.no, action = "no", scale = 0.31 }
  end
  return sidebar(data, {
    text { data.title, scale = 0.32, color = "#ffffff" },
    buttons,
  })
end

-- load_panel shows the save selector inside the sidebar (Lua asks the engine for the saves).
local function load_panel(data)
  local content = {
    text { "LOAD", scale = 0.36, color = "#ffffff" },
    rect { fill = "x", size = { 0, 2 }, color = "#bbbdbf55" }, -- divider under the title
  }
  local saves = engine.list_saves()
  if #saves == 0 then
    content[#content] = text { "No saves yet.", scale = 0.24, color = "#8a8a8a" }
  else
    for i, s in ipairs(saves) do
      -- Rows share the `load_save` action but need a UNIQUE id, or focus/highlight collapses onto the
      -- first row (the engine tracks focus by id; `id` defaults to `action`).
      content[#content] = button { s.label, action = "load_save", id = "save_" .. i, scale = 0.26 }
    end
  end
  content[#content] = text { " ", scale = 0.16 } -- spacer
  content[#content] = button { "Back", action = "back", scale = 0.3 }
  return sidebar(data, content)
end

-- is_header: an ALL-CAPS line is a role/section title (styled brighter); mixed-case is a name.
local function is_header(s)
  return s ~= "" and s == string.upper(s) and s:match("%a") ~= nil
end

-- credits_panel dims the menu and scrolls the credits up from the bottom (vanilla behavior). The text
-- is engine.credits() — read THROUGH THE VFS from interface/credits.txt, so it's the user's own game
-- credits (a mod can override that file). Constant-speed scroll off ui.time; any click or Back exits.
local function credits_panel(data)
  local lines = engine.credits()
  local col = { _kind = "column", anchor = "top", align = "center", gap = 6, size = { 980, 0 } }
  -- The credits' header icon: the SkyrimLogo bitmap we extracted from creditsmenu.swf → bethassets DDS
  -- (loaded through the VFS, so a mod can override it). credits.txt opens with <img src='SkyrimLogo'>.
  col[#col] = image { source = "interface/skyrimlogo.dds", size = { 129, 244 } }
  col[#col] = text { " ", scale = 0.3 } -- gap below the logo
  if #lines == 0 then
    col[#col] = text { "(credits unavailable)", scale = 0.24, color = "#8a8a8a" }
  else
    for _, ln in ipairs(lines) do
      if ln == "" then
        col[#col] = text { " ", scale = 0.18 } -- blank-line spacer
      elseif is_header(ln) then
        col[#col] = text { ln, scale = 0.26, color = "#cfcfcf" }
      else
        col[#col] = text { ln, scale = 0.24, color = "#8f8f8f" }
      end
    end
  end
  -- Scroll: start the column just below the bottom edge, move up at a constant speed.
  local elapsed = ui.time - (data._t0 or 0)
  local SPEED = 50 -- px/sec
  col.offset = { 0, (ui.vh > 0 and ui.vh or 720) - SPEED * elapsed }
  return {
    _kind = "container",
    modal = true,
    action = "back", -- the whole screen is a hit target: any click dismisses
    fill = "both",
    color = "#000000f2", -- dim the menu behind
    col,
  }
end

-- ── menu layout (baked values; a mod overriding this file can retune them) ─────────────────────────
local MENU = {
  logo_pos    = { -0.370, -0.047 }, -- logo on-screen offset, NDC (x = right, y = up; 0,0 = centre)
  logo_scale  = 0.850,
  menu_off    = { -134, -86 },      -- Continue/New/Load… button column offset from bottom_right (px)
}

-- ui.menu_logo: the engine reads this each frame to place/scale/light the 3D logo (logo.nif, drawn in
-- the scene behind the UI). DISABLED for now — logo.nif's texture doesn't map correctly (reads as
-- near-black/white with no midtones), so we skip rendering it entirely until it's replaced with proper
-- logo art. Flip enabled back to true (and the MENU logo_* values above tune it) to re-enable.
ui.menu_logo = { enabled = false }

-- ── behavior (the engine routes activations here; all secondary panels are the sidebar) ───────────
ui.on("continue", function()
  ui.spawn(confirm, {
    title = "Continue?",
    yes = "Yes",
    no = "No",
    on = {
      yes = function() ui.close(); ui.exit("continue") end,
      no = function() ui.close() end,
    },
  })
end)

ui.on("mods", function()
  ui.exit("mods")
end)

ui.on("credits", function()
  ui.spawn(credits_panel, {
    on = { back = function() ui.close() end },
  })
end)

ui.on("new_game", function()
  if engine.save_exists() then
    ui.spawn(confirm, {
      title = "Start a new game?",
      yes = "Yes",
      no = "No",
      on = {
        yes = function() ui.close(); ui.exit("new_game") end,
        no = function() ui.close() end,
      },
    })
  else
    ui.exit("new_game") -- nothing to lose → no confirm needed
  end
end)

ui.on("load", function()
  ui.spawn(load_panel, {
    on = {
      load_save = function() ui.close(); ui.exit("continue") end, -- single quicksave slot for now
      back = function() ui.close() end,
    },
  })
end)

ui.on("settings", function()
  ui.spawn(confirm, {
    title = "Settings — soon.",
    yes = "OK",
    on = { yes = function() ui.close() end },
  })
end)

ui.on("quit", function()
  ui.spawn(confirm, {
    title = "Quit SkyMod?",
    yes = "Quit",
    no = "Cancel",
    on = {
      yes = function() ui.close(); ui.exit("quit") end,
      no = function() ui.close() end,
    },
  })
end)

-- ── the screen (re-evaluated each frame, so enabled states are live) ────────────────────────────
ui.screen(function()
  local has_save = engine.save_exists()
  -- Publish the logo placement to the table the engine reads after this frame.
  ui.menu_logo.pos = MENU.logo_pos
  ui.menu_logo.scale = MENU.logo_scale
  return container {
    id = "main_menu",
    fill = "both",
    color = "#00000000", -- TRANSPARENT: the 3D logo renders in the scene behind the UI; an opaque bg
    -- here would cover it. The dark backdrop comes from the scene clear (MENU_CLEAR), not the UI.

    -- (The title is the 3D logo mesh rendered in the scene behind this UI — see ui.menu_logo above.)

    -- News, top-right. Subtle white over a faint panel (~1.7× the original size). The body is ONE
    -- text node; the box auto-wraps it to the content width (see widget/box.lua) — no hand-split lines.
    box {
      id = "news",
      anchor = "top_right",
      offset = { -44, 44 },
      width = 544,
      pad = 27,
      gap = 12,
      color = "#0a0a0acc",

      text { "News", scale = 0.5, color = "#e8e8e8" },
      text {
        "Welcome to SkyMod. Patch notes and community news appear here.",
        scale = 0.40,
        color = "#9a9a9a",
      },
    },

    -- Menu items, lower-right, right-aligned. Sat higher + further left than vanilla and LARGER, with
    -- one UNIFORM size for every entry (vanilla's per-item sizing — fat Continue/New, selected-grows —
    -- is the "mess" we skip). The sidebar slides in to the LEFT of this column.
    column {
      id = "menu",
      anchor = "bottom_right",
      offset = MENU.menu_off,
      gap = -8,
      align = "right",

      button { "Continue", action = "continue", scale = 0.40, enabled = has_save },
      button { "New Game", action = "new_game", scale = 0.40 },
      button { "Load", action = "load", scale = 0.40, enabled = has_save },
      button { "Credits", action = "credits", scale = 0.40 },
      button { "Mods", action = "mods", scale = 0.40 },
      button { "Settings", action = "settings", scale = 0.40 },
      button { "Quit", action = "quit", scale = 0.40 },
    },

    -- Bethesda Game Studios logo (their mark, extracted from their files — shape 78 in startmenu.swf),
    -- bottom-left above the version, as in vanilla. Native 621×292, shown small.
    image {
      source = "interface/bethesdalogo.dds",
      id = "bgs_logo",
      anchor = "bottom_left",
      offset = { 22, -48 },
      size = { 190, 89 },
    },

    -- Build/version, bottom-left (the SWF's <version> field).
    text {
      "SkyMod — pre-alpha",
      id = "version",
      anchor = "bottom_left",
      offset = { 24, -20 },
      scale = 0.23,
      color = "#6a6a6a",
    },
  }
end)
