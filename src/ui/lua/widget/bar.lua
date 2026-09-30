-- ui/widget/bar.lua
--
-- The reusable meter/progress bar — our remake of Skyrim's Scaleform `Components.Meter`: the vanilla
-- chrome (extracted from hudmenu.gfx) with our shader fill (a glossy sheen, masked to `value`) over
-- the chrome's fill window.
--
-- API:
--   bar{ style="stat"|"enemy", size={w,h}, value=0..1, from="left"|"center"|"right",
--        fill="#c8a24b", chrome_color="#ffffffff", anchor=, offset= }
-- `size` defaults to the style's native size. The chrome's ends keep their shape at the bar's height
-- and its middle stretches, so one style fits any width.
--
-- A mod overrides this file to restyle every bar; the 3-slice and the shader fill live in the engine.

-- The styles, baked from vanilla hudmenu.gfx in stage px: `chrome` is the extracted art, `size` its
-- native size, `cap` the width of each end that keeps its shape, and `inset` the fill window inside the
-- chrome {left, top, right, bottom}.
BAR_STYLES = {
  -- the health, magicka and stamina meter (MagickaMeter_mc at "Empty"; the three share it)
  stat  = { chrome = "interface/hud/meter.dds", size = { 287.5, 21.5 }, cap = 20, inset = { 20.2, 5.1, 20.4, 4.7 } },
  -- the enemy health bar (EnemyHealth_mc's still parts)
  enemy = { chrome = "interface/hud/enemy.dds", size = { 261.5, 14.5 }, cap = 14, inset = { 13.9, 5.1, 13.6, 5.2 } },
}

function bar(t)
  local st = BAR_STYLES[t.style or "stat"]
  local w = (t.size and t.size[0]) or st.size[0]
  local h = (t.size and t.size[1]) or st.size[1]
  local k = h / st.size[1] -- the chrome's ends and the fill inset scale with the height
  local l, top, r, bottom = st.inset[0] * k, st.inset[1] * k, st.inset[2] * k, st.inset[3] * k
  local cap = st.cap / st.size[0]
  return {
    _kind = "container",
    anchor = t.anchor,
    offset = t.offset,
    size = { w, h },
    image { source = st.chrome, slice = { cap, cap }, fill = "both", color = t.chrome_color },
    {
      _kind = "bar",
      anchor = "top_left",
      offset = { l, top },
      size = { w - l - r, h - top - bottom },
      value = t.value or 0,
      from = t.from,
      color = t.fill or "#c8a24b",
    },
  }
end
