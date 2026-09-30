-- ui/hud.lua
--
-- The in-world HUD — our Lua reimplementation of Skyrim's hudmenu.gfx: the crosshair + activation
-- prompt, the compass, the sneak eye, the health/magicka/stamina meters, the enemy health bar and the
-- notification feed.
-- Always on during gameplay, non-interactive. Positions follow the vanilla 1280x720 stage.
--
-- The engine hands over NEUTRAL facts (engine.activation(), engine.hud()); the wording, layout and
-- fade rules live here, so a mod can restyle any of it by overriding this file.
--
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

-- The vanilla stage layout and art, extracted from hudmenu.gfx by the installer (interface/
-- hudmenu_layout.lua): stage rects in px for every named instance and for each art file.
local LAYOUT = engine.layout("hudmenu") or {}
local STAGE  = LAYOUT.stage or { w = 1280, h = 720 }
local ART    = LAYOUT.art or {}
local INST   = LAYOUT.instances or {}
local ROOT   = "HUDMovieBaseInstance."
local REF_EM = 64 -- the UI's text px at scale 1

-- Meter fills. Meters fade out LINGER seconds after they stop being needed, over FADE seconds.
local HEALTH    = "#b3302b"
local MAGICKA   = "#2f6fc4"
local STAMINA   = "#3f9c4a"
local LINGER    = 2.0
local FADE      = 0.6

-- Sneak eye (vanilla: over the crosshair, the pupil round the dot). HIDDEN/DETECTED sits above it,
-- clear of the activation prompt.
local EYE_W, EYE_H = 64, 30
local EYE_SHUT     = 0.25 -- the eye's height while nobody has noticed the player, of EYE_H

-- Enemy health: seconds the bar stays after the player's last hit, out of a fight.
local FOE_SHOW  = 3.0

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

-- The screen scale and x offset that fit the stage's height, centred.
local function stage_fit()
  local k = ui.vh / STAGE.h
  return k, (ui.vw - STAGE.w * k) / 2
end

-- node props that put a node on stage rect `r`
local function place(r)
  local k, ox = stage_fit()
  return { anchor = "top_left", offset = { ox + r.x * k, r.y * k }, size = { r.w * k, r.h * k } }
end

local function with(t, props)
  for key, v in pairs(props) do t[key] = v end
  return t
end

-- text scale for a vanilla font size in stage px
local function text_scale(px)
  local k = stage_fit()
  return px * k / REF_EM
end

-- A meter: the bar primitive laid over the fill's vanilla box. The box at "Empty" says where the fill
-- grows from: gone or shrunk in place (the centre), left at the left end, or left at the right end.
local function meter(root, style, fill_path, value, color, a)
  local moving = INST[fill_path] and INST[fill_path].moving
  local box = moving and moving.Full
  if not box then return end
  local st = BAR_STYLES[style]
  local window = st.size[1] - st.inset[1] - st.inset[3]
  local r = {
    x = box.x - st.inset[0],
    y = box.y + box.h / 2 - st.inset[1] - window / 2,
    w = box.w + st.inset[0] + st.inset[2],
    h = st.size[1],
  }
  local from = "center"
  local e = moving.Empty
  if e then
    local d = (e.x + e.w / 2) - (box.x + box.w / 2)
    if d < -1 then from = "left" elseif d > 1 then from = "right" end
  end
  root[#root] = bar(with(place(r), {
    style = style, value = value, from = from,
    fill = alpha(color, a), chrome_color = alpha("#ffffff", a),
  }))
end

-- The three player meters. Vanilla shows one while it is not full, and health also in combat.
local function meters(root, h)
  local list = {
    { "health",  h.health,  ROOT .. "Health.HealthMeter_mc.HealthLeft", HEALTH },
    { "magicka", h.magicka, ROOT .. "Magica.MagickaMeter_mc",           MAGICKA },
    { "stamina", h.stamina, ROOT .. "Stamina.StaminaMeter_mc",          STAMINA },
  }
  for _, e in ipairs(list) do
    local name, m, fill_path, color = e[0], e[1], e[2], e[3]
    local a = visibility(name, frac(m) < 0.999 or (name == "health" and h.combat))
    if a > 0 then meter(root, "stat", fill_path, frac(m), color, a) end
  end
end

-- The compass: the vanilla frame, and the vanilla letter strip scrolled by heading and cut to the
-- compass mask. The strip's x at the Compass sprite's "Zero" and "ThreeSixty" frames spans one turn.
local function compass(root, heading)
  local c = ROOT .. "CompassShoutMeterHolder.Compass."
  local frame, art = ART["interface/hud/compass.dds"], ART["interface/hud/compass_strip.dds"]
  local strip, mask = INST[c .. "DirectionRect"], INST[c .. "CompassMask_mc"]
  if not frame or not art or not strip or not strip.at or not mask then return end
  root[#root] = image(with(place(frame), { source = "interface/hud/compass.dds" }))
  local turn = strip.at.ThreeSixty.x - strip.at.Zero.x
  local x = art.x + turn * heading / 360 -- the strip art's left edge now (the art is drawn at "Zero")
  local m = mask.rect
  root[#root] = image(with(place({ x = m.x, y = art.y, w = m.w, h = art.h }), {
    source = "interface/hud/compass_strip.dds",
    uv = { (m.x - x) / art.w, 0, (m.x + m.w - x) / art.w, 1 },
  }))
end

-- The sneak eye: opens as the most watchful actor notices the player.
local function sneak_eye(root, h)
  if not h.sneaking then return end
  local open = EYE_SHUT + (1 - EYE_SHUT) * h.detection
  root[#root] = image {
    source = "interface/sneak_eye.dds",
    anchor = "center",
    size = { EYE_W, EYE_H * open },
    color = alpha("#d7d7d7", 0.5 + 0.5 * h.detection),
  }
  root[#root] = text {
    h.detected and "DETECTED" or "HIDDEN",
    anchor = "center",
    offset = { 0, -EYE_H },
    scale = 0.3,
    color = alpha("#d7d7d7", 0.6),
  }
end

-- The foe's health bar (shrinking to its centre) and its name below it, while it
-- fights the player or shortly after the player hit it.
local function foe(root, f)
  if not f or not (f.fighting or f.age < FOE_SHOW) then return end
  meter(root, "enemy", ROOT .. "EnemyHealth_mc", frac(f.health), HEALTH, 1)
  local label = INST[ROOT .. "EnemyHealth_mc.BracketsInstance.RolloverNameInstance"]
  if not label then return end
  root[#root] = container(with(place(label.rect), {
    text { f.name, anchor = "center", scale = text_scale(20), color = "#999999" },
  }))
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
    compass(root, h.heading)
    sneak_eye(root, h)
    meters(root, h)
    foe(root, h.foe)
    notes(root, h.notes)
  end

  return root
end)
