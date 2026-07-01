-- ui/widget/button.lua
--
-- A clickable menu item: a real hit-rect node (the `column` wrapper) holding a styled `text` label.
-- The wrapper — NOT the text — carries the `action`/`id`/`enabled`, so the engine hit-tests + focuses
-- a genuine button rectangle rather than the glyph bounding box. The rect is the label's size for now
-- (the wrapper auto-measures to its child); pass an explicit `size` to give it a fixed/padded hit area
-- later without restyling the menu. A Lua-composed widget on top of the core primitives — mods
-- override this file to restyle every button at once.
--
-- The widget styles ITSELF off the engine-provided `ui.focus` (the focused node id): Odin just routes
-- input + sets ui.focus, the button decides what "focused" looks like. Skyrim's startmenu is hard
-- white-on-black: an unselected item is a dim white, the selected one bright white (vanilla also grows
-- it 20→24px; we keep size steady for now to avoid list jitter). `enabled` (a live bool) greys +
-- disables — the wrapper's `disabled` state dims its whole subtree (the label) in Odin's emit.

function button(t)
  local id = t.id or t.action
  local focused = (ui.focus ~= nil) and (ui.focus == id)
  return column {
    id = id,
    action = t.action,
    enabled = t.enabled,
    anchor = t.anchor,
    offset = t.offset,
    size = t.size, -- explicit hit rect; nil → auto-measures to the label (text-sized for now)
    text {
      t[1], -- the label
      scale = t.scale,
      color = focused and "#ffffff" or (t.color or "#bdbdbd"),
    },
  }
end
