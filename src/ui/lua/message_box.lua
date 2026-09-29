-- ui/message_box.lua
--
-- The message box: a message's text and its buttons over the paused world. The engine hands over the
-- text and the button labels (engine.message_box()); the screen hands back the picked button index
-- with ui.exit. A message with no buttons gets one OK button, as in Skyrim.

local OK       = "Ok"
local WIDTH    = 560
local STACK_AT = 4 -- this many buttons or more stack in a column, not a row
local WHITE    = "#f6f6f6"
local LINE     = "#bbbdbfaa"

local function pick_action(i)
  local a = "pick_" .. i
  if not ui.handlers[a] then
    ui.on(a, function() ui.exit(tostring(i)) end)
  end
  return a
end

ui.screen(function()
  local m = engine.message_box()
  if not m then
    return container {}
  end

  local labels = m.buttons
  if #labels == 0 then
    labels = { OK }
  end
  local buttons = {
    _kind = #labels >= STACK_AT and "column" or "row",
    gap = #labels >= STACK_AT and 10 or 40,
    align = "center",
  }
  for i, label in ipairs(labels) do
    buttons[#buttons] = button { label, action = pick_action(i), id = "pick_" .. i, scale = 0.3 }
  end

  return box {
    modal = true,
    anchor = "center",
    width = WIDTH,
    pad = 28,
    gap = 22,
    align = "center",
    color = "#000000c8",
    rect { fill = "x", size = { 0, 2 }, color = LINE },
    text { m.body, scale = 0.3, color = WHITE },
    buttons,
    rect { fill = "x", size = { 0, 2 }, color = LINE },
  }
end)
