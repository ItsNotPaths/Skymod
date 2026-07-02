-- ui/lib/ui.lua
--
-- The core UI framework: constructors + the interaction runtime. The kind IS the constructor name;
-- each constructor tags a table with its `_kind` and returns it, and the Odin loader walks the result
-- into the node tree. Shipped with the engine; a mod can override any of it via a VFS-resolved copy.
--
-- THIN-ODIN / FAT-LUA: the engine (Odin) only lays out + draws the tree and ROUTES raw input. What a
-- button IS, what its action DOES, focus styling, transient popups — all live here in Lua. Each frame
-- the engine calls ui._frame() for the composed tree, ui.dispatch(action) when a focusable is
-- activated, ui.back() on Backspace, sets ui.focus (the focused node id, so widgets style
-- themselves), and reads ui.result (a verb a screen hands back via ui.exit).

local function kind(name)
  return function(t)
    t._kind = name
    return t
  end
end

container = kind "container"
column = kind "column"
row = kind "row"
rect = kind "rect"
text = kind "text"
image = kind "image"
effect = kind "effect"
-- (shape kinds — line/circle/arc — arrive with the declarative-shapes substrate work; the Odin
-- loader has no mapping for them yet, so they aren't declared here until it does.)

-- bind("path") marks a property as a live binding (engine-evaluated). A screen written as a function
-- of state (ui.screen(function() ... end)) can also read engine state directly each frame, which is
-- what the built-in menus do; bind stays for static (table) screens.
function bind(path)
  return { _bind = path }
end

-- ── interaction runtime ─────────────────────────────────────────────────────────────────────────

ui = ui or {}
ui.handlers = {}     -- action name -> screen handler
ui._transients = {}  -- stack of active transients (popups/toasts), drawn over the screen
ui._screen = nil     -- the current screen's view function () -> tree
ui.result = nil      -- verb handed back to the engine (set via ui.exit; read+cleared by the engine)
ui.focus = nil       -- id of the focused node (set by the engine; widgets style off it)
ui.time = 0          -- seconds since the screen opened (set by the engine each frame; animations read it)
ui.vw = 0            -- viewport width/height in px (set by the engine each frame; absolute-px layout reads it)
ui.vh = 0

-- ui.anim_in returns an eased 0→1 progress for an entrance that began at `t0` and runs `dur` seconds
-- (cubic ease-out: fast in, soft settle). Screens tween a property between two values with it, e.g.
-- offset.x from off-screen to rest. Clamped, so it's a no-op once the entrance has finished.
function ui.anim_in(t0, dur)
  local k = (ui.time - (t0 or 0)) / (dur > 0 and dur or 1)
  if k < 0 then k = 0 elseif k > 1 then k = 1 end
  local inv = 1 - k
  return 1 - inv * inv * inv -- ease-out cubic
end

-- ui.screen registers a screen's view: a function returning the node tree, re-evaluated each frame so
-- bound props / lists are live.
function ui.screen(fn)
  ui._screen = fn
end

-- ui.on registers what an action does (the screen's behavior; the engine just routes the click here).
function ui.on(action, fn)
  ui.handlers[action] = fn
end

-- ui.exit asks the engine to leave the screen with a verb (e.g. "continue", "new_game", "mods").
function ui.exit(verb)
  ui.result = verb
end

-- ui.spawn opens a transient: a builder(data) -> tree drawn on top of the screen. Input capture is
-- OPT-IN — a transient whose root sets modal=true grabs focus (a confirm dialog); a passive one
-- (toast / level-up) leaves the base interactive and never freezes it. `data.on` maps the transient's
-- own button actions to callbacks (scoped: checked before the global handlers in ui.dispatch).
-- The spawn time is stamped into `data._t0` (unless preset) so builders can tween an entrance off
-- ui.anim_in(data._t0, dur) without every caller threading the clock through by hand.
function ui.spawn(builder, data)
  data = data or {}
  if data._t0 == nil then data._t0 = ui.time end
  ui._transients[#ui._transients + 1] = { builder = builder, data = data }
end

-- ui.close removes the topmost transient (a dialog confirming/cancelling itself).
function ui.close()
  ui._transients[#ui._transients] = nil
end

-- ui.back is Backspace: drop the topmost transient if any.
function ui.back()
  if #ui._transients > 0 then
    ui._transients[#ui._transients] = nil
  end
end

-- ui.dispatch runs an activated action: the topmost transient's own on[action] wins (so a dialog's
-- Yes/No stay scoped to it), else a screen-registered handler.
function ui.dispatch(action)
  local t = ui._transients[#ui._transients]
  if t and t.data.on and t.data.on[action] then
    t.data.on[action]()
    return
  end
  local h = ui.handlers[action]
  if h then h() end
end

-- ui._frame composes the tree the engine draws this frame: the screen, then each active transient on
-- top (painter's order). The engine lays this out, routes input to the topmost modal subtree, draws.
function ui._frame()
  local root = { _kind = "container", fill = "both" }
  if ui._screen then root[1] = ui._screen() end
  for _, t in ipairs(ui._transients) do
    root[#root + 1] = t.builder(t.data)
  end
  return root
end
