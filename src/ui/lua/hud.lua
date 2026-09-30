-- ui/hud.lua
--
-- The in-world HUD — our Lua reimplementation of Skyrim's hudmenu.gfx: the crosshair + activation
-- prompt, the health/magicka/stamina meters, the enemy health bar and the notification feed.
-- Always on during gameplay, non-interactive. Positions follow the vanilla 1280x720 stage.
--
-- The engine hands over NEUTRAL facts (engine.activation(), engine.hud()); the wording, layout and
-- fade rules live here, so a mod can restyle any of it by overriding this file.
--
-- (hole hud-compass :tags (ui ui-train) :sev gap) no compass: vanilla shows a heading strip at the top centre; its markers are quest-markers.
-- (hole hud-sneak-eye :tags (ui ui-train player) :sev gap) no sneak eye over the crosshair while sneaking; its detection level needs sneak-detection.
-- (hole hud-location-name :tags (ui ui-train) :sev gap) entering a new location shows no name at the top right.
-- (hole hud-shout-meter :tags (ui ui-train magic) :sev gap) no shout cooldown meter under the compass.
-- (hole hud-charge-meters :tags (ui ui-train magic) :sev gap) no enchantment charge meters in the bottom corners.
-- (hole hud-arrow-count :tags (ui ui-train) :sev polish) no arrow count at the bottom right.
-- (hole hud-modes :tags (ui ui-train) :sev gap) the HUD shows the same in every mode: vanilla hides elements in dialogue, menus, on a horse and while swimming.

-- kind -> verb. Override this table (or the file) to reword or localize prompts.
local VERB = {
  door      = "Open",
  container = "Open",
  actor     = "Talk",
  body      = "Search",
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

-- Meters (vanilla: health bottom centre, magicka bottom left, stamina bottom right).
local METER_W, METER_H = 240, 20
local METER_Y   = -48  -- from the bottom edge
local METER_X   = 60   -- magicka/stamina inset from the side edges
local HEALTH    = "#b3302b"
local MAGICKA   = "#2f6fc4"
local STAMINA   = "#3f9c4a"
local FRAME     = "#9a9a9a"
local LINGER    = 2.0  -- seconds a meter stays after it no longer needs showing
local FADE      = 0.6  -- seconds it takes to fade out

-- Enemy health (vanilla: under the compass, name below in #999999).
local FOE_Y     = 60
local FOE_W     = 300
local FOE_SHOW  = 3.0  -- seconds the bar stays after the player's last hit, out of a fight

-- Notifications (vanilla: top left, fade out).
local NOTE_LIFE = 4.0
local NOTE_FADE = 1.0
local NOTE_MAX  = 4

-- hex colour "#rrggbb" at alpha a (0..1)
local function alpha(hex, a)
  return string.format("%s%02x", hex, math.floor(math.max(0, math.min(1, a)) * 255))
end

-- 1 while `needed`, then held LINGER seconds, then faded over FADE. `key` keeps the clock per meter.
local needed_at = {}
local function visibility(key, needed)
  if needed then needed_at[key] = ui.time end
  local since = ui.time - (needed_at[key] or -1e9)
  return 1 - math.max(0, math.min(1, (since - LINGER) / FADE))
end

local function frac(m)
  if not m or m.max <= 0 then return 0 end
  return m.cur / m.max
end

local function meter(m, color, a, props)
  local t = {
    size = { METER_W, METER_H },
    value = frac(m),
    fill = alpha(color, a),
    bg = "interface/bar_bg.dds", bg_color = alpha("#ffffff", a),
    frame = "interface/bar_frame.dds", frame_color = alpha(FRAME, a),
    slice = 48,
    inset = { 18, 5 },
  }
  for k, v in pairs(props) do t[k] = v end
  return bar(t)
end

-- The three player meters. Vanilla shows one while it is not full, and health also in combat.
local function meters(root, h)
  local list = {
    { "health",  h.health,  HEALTH,  "center", { anchor = "bottom",       offset = { 0, METER_Y } } },
    { "magicka", h.magicka, MAGICKA, "right",  { anchor = "bottom_left",  offset = { METER_X, METER_Y } } },
    { "stamina", h.stamina, STAMINA, "left",   { anchor = "bottom_right", offset = { -METER_X, METER_Y } } },
  }
  for _, e in ipairs(list) do
    local key, m, color, from, props = e[0], e[1], e[2], e[3], e[4]
    local a = visibility(key, frac(m) < 0.999 or (key == "health" and h.combat))
    if a > 0 then
      props.from = from
      root[#root] = meter(m, color, a, props)
    end
  end
end

-- The foe's health bar and name, while it fights the player or shortly after the player hit it.
local function foe(root, f)
  if not f or not (f.fighting or f.age < FOE_SHOW) then return end
  root[#root] = meter(f.health, HEALTH, 1, { anchor = "top", offset = { 0, FOE_Y }, size = { FOE_W, METER_H }, from = "center" })
  root[#root] = text {
    f.name,
    anchor = "top",
    offset = { 0, FOE_Y + METER_H + 6 },
    scale = 0.31,
    color = "#999999",
  }
end

-- The newest notifications, oldest on top, each fading out at the end of its life.
local function notes(root, list)
  local shown = {}
  for i = #list - 1, 0, -1 do
    local n = list[i]
    if n.age < NOTE_LIFE and #shown < NOTE_MAX then
      shown[#shown] = n
    end
  end
  if #shown == 0 then return end
  local col = column { anchor = "top_left", offset = { 60, 50 }, gap = 4 }
  for i = #shown - 1, 0, -1 do
    local n = shown[i]
    col[#col] = text {
      n.text,
      scale = 0.31,
      color = alpha("#ffffff", (NOTE_LIFE - n.age) / NOTE_FADE),
    }
  end
  root[#root] = col
end

ui.screen(function()
  local a = engine.activation() -- { present, kind, name, dest, locked }
  local h = engine.hud()        -- { health, magicka, stamina, combat, foe, notes }

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

    root[#root] = row {
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
      root[#root] = text {
        a.locked and (name .. "   (Locked)") or name,
        anchor = "center",
        offset = { 0, NAME_Y },
        scale = 0.46,
        color = a.locked and GOLD or WHITE,
      }
    end
  end

  if h then
    meters(root, h)
    foe(root, h.foe)
    notes(root, h.notes)
  end

  return root
end)
