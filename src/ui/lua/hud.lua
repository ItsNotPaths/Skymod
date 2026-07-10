-- ui/hud.lua
--
-- The in-world HUD — our Lua reimplementation of Skyrim's crosshair + activation prompt (the base
-- layer of hudmenu.gfx). Always on during gameplay, non-interactive: the engine resolves what the
-- crosshair points at (engine.activation()) and this draws the reticle + a contextual prompt above
-- it — "Open Chest", "Open Riverwood Trader", "Open Sleeping Giant Inn (Locked)", "Talk", "Take", …
--
-- The engine hands over NEUTRAL facts (kind/name/dest/locked/button); the WORDING lives here, so a
-- mod can reword/localize/restyle the prompt (override the VERB table or this whole file) without
-- touching the engine. This is the seed of the fuller hudmenu (compass, H/M/S bars) later.

-- kind -> verb. Override this table (or the file) to reword or localize prompts.
local VERB = {
  door      = "Open",
  container = "Open",
  actor     = "Talk",
  item      = "Take",
  flora     = "Harvest",
  activator = "Activate",
  book      = "Read",
}

local RETICLE  = "interface/reticle.dds" -- generated white dot (baseui.make_reticle)
local DOT      = 7    -- reticle size on screen (px)
local VERB_Y   = 30   -- the button+verb line sits below the reticle (+y = down)
local NAME_Y   = 60   -- object/place name below the verb line
local GLYPH    = 26   -- button-prompt glyph edge (px)
local GOLD      = "#d8bd76" -- locked accent
local WHITE     = "#f6f6f6"
local DIM       = "#d3ccb6" -- the smaller button+verb line

ui.screen(function()
  local a = engine.activation() -- { present, kind, name, dest, locked }

  local root = {
    _kind = "container",
    fill = "both",

    -- Crosshair reticle: the generated white dot at screen centre, slightly translucent.
    image {
      source = RETICLE,
      anchor = "center",
      size = { DOT, DOT },
      color = "#ffffffcc",
    },
  }

  -- Contextual prompt, stacked BELOW the reticle: the Activate button's glyph + the verb on one
  -- line, then the object/place name emphasised beneath it. Both centred. Locked targets read in a
  -- warmer gold. The glyph is the prompt{} widget — it tracks whatever "Activate" is bound to and
  -- degrades to a "[F]" text hint when there's no art.
  if a.present then
    local verb = VERB[a.kind] or "Activate"
    local name = (a.kind == "door") and a.dest or a.name

    root[#root + 1] = row {
      anchor = "center",
      offset = { 0, VERB_Y },
      gap = 8,
      align = "center",
      prompt { action = "Activate", size = GLYPH },
      text {
        verb,
        scale = 0.36,
        color = DIM,
      },
    }
    if name and name ~= "" then
      root[#root + 1] = text {
        a.locked and (name .. "   (Locked)") or name,
        anchor = "center",
        offset = { 0, NAME_Y },
        scale = 0.46,
        color = a.locked and GOLD or WHITE,
      }
    end
  end

  return root
end)
