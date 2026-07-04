-- ui/widget/bar.lua
--
-- The reusable meter/progress bar — our remake of Skyrim's Scaleform `Components.Meter`. Composited from
-- (back → front):
--   1. BG    — a stretchable background frame (e.g. hudmenu shape 416, the black stat-bar bg). Drawn as a
--              horizontal 3-SLICE (`slice` = cap widths in source px): the decorated ends stay fixed and
--              the uniform middle stretches, so ONE art fits ANY width. A flat `track` colour is the
--              fallback when there's no bg art.
--   2. FILL  — the value-driven shader fill (fake-cylindrical Blinn-Phong sheen), UNDER the frame so it
--              can span the full inner width and the frame's caps/border overlay its ends (no empty gaps).
--   3. FRAME — the stretchable decorated frame on top (e.g. hudmenu shape 395, the red border + knotwork
--              end-caps), also 3-sliced — its caps/border define the fill's visible window.
--
-- API — "a bar using this deco at this width with this fill":
--   bar{ size={w,h}, value=0..1, fill="#c8a24b",
--        frame="interface/bar_frame.dds", frame_color="#e0e0e0",   -- deco frame + its RGBA tint (the art
--                                                                  --   is white, so ANY colour works)
--        bg="interface/bar_bg.dds", bg_color="#000000",            -- background frame + its tint
--        slice=48,        -- 3-slice cap width (source px); the middle stretches
--        inset={ix,iy},   -- fill inset inside the frame (tuck x under the caps so there's no end gap)
--        anchor=, offset= }
-- `frame`/`bg` are tinted by `frame_color`/`bg_color` (an image draws texel × colour, so a WHITE deco art
-- recolours to anything; a black art can't be tinted lighter — extract it white if you need to recolour).
--
-- A mod overrides this file to restyle every bar; the 3-slice + shader fill live in the engine.

function bar(t)
  local w = (t.size and t.size[1]) or 220
  local h = (t.size and t.size[2]) or 22
  local slice_l = (type(t.slice) == "table" and t.slice[1]) or t.slice or 0

  -- Fill inset: horizontal defaults to the cap width (fill sits between the decorated ends), vertical to
  -- a small border. A number → symmetric; a table → {x,y}.
  local ix, iy
  if type(t.inset) == "table" then
    ix, iy = t.inset[1], t.inset[2]
  elseif type(t.inset) == "number" then
    ix, iy = t.inset, t.inset
  else
    ix, iy = slice_l, 3
  end

  local node = { _kind = "container", anchor = t.anchor, offset = t.offset, size = { w, h } }

  -- 1. BG (3-sliced image tinted by bg_color, or a flat colour track).
  if t.bg then
    node[#node + 1] = image { source = t.bg, slice = t.slice, fill = "both", color = t.bg_color }
  elseif t.track then
    node[#node + 1] = rect { fill = "both", color = t.track }
  end

  -- 2. FILL (shader), UNDER the frame. anchor=top_left so `inset` is a plain top-left offset (a centred
  -- anchor would fight the offset). It spans the full inner rect; the frame on top hides its ends.
  node[#node + 1] = {
    _kind = "bar",
    anchor = "top_left",
    offset = { ix, iy },
    size = { w - 2 * ix, h - 2 * iy },
    value = t.value or 0,
    color = t.fill or "#c8a24b",
  }

  -- 3. FRAME (3-sliced decorated frame on top, tinted by frame_color — its caps/border overlay the fill).
  if t.frame then
    node[#node + 1] = image { source = t.frame, slice = t.slice, fill = "both", color = t.frame_color }
  end

  return node
end
