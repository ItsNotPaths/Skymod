-- ui/widget/prompt.lua
--
-- A button-prompt glyph, placed by ACTION — not by key. `prompt { action = "Activate" }`
-- resolves whatever the action is bound to RIGHT NOW (engine.prompt: rebinds and pad-style
-- switches track automatically, screens re-evaluate every frame) and draws the baked glyph
-- art (Kenney input prompts — every device family ships in the atlas). When there's no art
-- (unmapped code, atlas missing) it degrades to a "[F]"-style text hint; when the action is
-- unknown/unbound it renders nothing (an empty container, so flow layouts stay stable).
--
-- Placement: like any node — anchor/offset standalone, or inline in a row/column next to
-- its caption. `size` is the square glyph edge in px (default 24). A `color` tints/fades
-- the art (glyph art is white-on-dark friendly already; leave it unset for the real colors).
--
--   row { gap = 8, align = "center",
--     prompt { action = "Activate", size = 26 },
--     text { "Open", scale = 0.36 },
--   }
--
-- A raw glyph (no action, e.g. a tutorial montage or a wiimote gag) can bypass the widget:
-- image { source = "prompts/wii/wiimote", size = { 64, 64 } } — every set/key in the pack works.

function prompt(t)
  local p = t.action and engine.prompt(t.action) or nil
  if not p then
    return container { anchor = t.anchor, offset = t.offset }
  end
  local sz = t.size or 24
  if p.glyph and p.glyph ~= "" then
    return image {
      source = "prompts/" .. p.glyph,
      anchor = t.anchor,
      offset = t.offset,
      size = { sz, sz },
      color = t.color,
    }
  end
  local label = (p.label and p.label ~= "") and p.label:upper() or "?"
  return text {
    "[" .. label .. "]",
    anchor = t.anchor,
    offset = t.offset,
    scale = t.scale or 0.36,
    color = t.color or "#f6f6f6",
  }
end
