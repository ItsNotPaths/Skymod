-- ui/widget/box.lua
--
-- A panel that holds stacked content over a background. A Lua-composed widget: a `column` (so its
-- children stack) that paints its `color` as a background and insets them by `pad`. The column
-- auto-measures its height from the children (+ padding), so a panel grows to fit its content.
-- `width` fixes the panel width; height is intrinsic. Mods override this file to restyle every box.

function box(t)
  t._kind = "column"
  t.gap = t.gap or 6
  t.pad = t.pad or 12
  if t.width then
    t.size = { t.width, t.height or 0 } -- height 0 → auto-measure from content + padding
    -- Auto-wrap text children to the content width (width minus both paddings) so body copy flows
    -- across lines instead of overflowing — a text child can still set its own `wrap` to override.
    local content_w = t.width - 2 * t.pad
    for _, c in ipairs(t) do
      if type(c) == "table" and c._kind == "text" and c.wrap == nil then
        c.wrap = content_w
      end
    end
  end
  return t
end
