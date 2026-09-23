-- skymod.rt: the runtime every converted Papyrus script requires. The contract it serves is the
-- `rt` table in docs/papyrus-transpiler.md. Positions are 0-based: the engine's Lua is patched.
--
-- Receivers are one of three things: a ref (engine userdata wrapping a form), a script instance
-- (a table per form and attached script), or None (the engine sentinel; nil counts as None).

local native, class_of, is_a, warn, script_layers = __native, __class_of, __is_a, __warn, __script_layers
local None = None
local lower, format, fmod = string.lower, string.format, math.fmod
local sethook, gethook = debug.sethook, debug.gethook

local rt = { None = None }

local lowered = {}
local function low(s)
  local l = lowered[s]
  if l == nil then
    l = lower(s)
    lowered[s] = l
  end
  return l
end

local warned = {}
local function warn_once(key, msg)
  if not warned[key] then
    warned[key] = true
    warn(msg)
  end
end

local function is_none(v) return v == nil or v == None end

-- ── classes ─────────────────────────────────────────────────────────────────

local classes = {} -- lowercase name -> class table, or false when no file exists

-- run calls a chunk, warning with its file on error.
local function run(path, f, ...)
  local ok, res = pcall(f, ...)
  if not ok then
    warn(path .. ": " .. tostring(res))
    return nil
  end
  return res
end

-- rt.loader(lname) builds a script's class from every file that ships it, lowest priority first
-- (loader.odin): a full <name>.lua replaces what is below it, a <name>.patch.lua returns a
-- function that edits the class so far.
rt.loader = function(lname)
  local cls
  for _, layer in ipairs(script_layers(lname)) do
    local chunk, err = loadfile(layer.path)
    if not chunk then
      warn(err)
    elseif not layer.patch then
      cls = run(layer.path, chunk) or cls
    elseif not cls then
      warn(layer.path .. ": patches '" .. lname .. "', which nothing below it defines")
    else
      local edit = run(layer.path, chunk)
      if edit then run(layer.path, edit, cls) end
      cls.__cache = {}
    end
  end
  return cls
end

function rt.class(name, parent)
  local cls = {
    __name = name,
    __parent = parent and low(parent),
    __fn = {},
    __states = {},
    __vars = {},
    __autoprop = {},
    __overridden = {},
    __cache = {},
  }
  classes[low(name)] = cls
  return cls
end

function rt.load(name)
  local l = low(name)
  local cls = classes[l]
  if cls == nil then
    cls = rt.loader(l) or false
    classes[l] = cls
  end
  return cls or nil
end

local function parent_of(cls) return cls.__parent and rt.load(cls.__parent) end

-- lookup finds a function up the class chain, the current state's table before each level's
-- default one. Cached per class and state; a miss caches false.
local function lookup(cls, state, lname)
  local sk = (state and state ~= "") and low(state) or ""
  local per = cls.__cache[sk]
  if per == nil then
    per = {}
    cls.__cache[sk] = per
  end
  local f = per[lname]
  if f == nil then
    local c = cls
    while c do
      local st = sk ~= "" and c.__states[sk]
      f = (st and st[lname]) or c.__fn[lname]
      if f then break end
      c = parent_of(c)
    end
    f = f or false
    per[lname] = f
  end
  return f or nil
end

local function is_subclass(cls, lname)
  local c = cls
  while c do
    if low(c.__name) == lname then return true end
    c = parent_of(c)
  end
  return false
end

-- ── instances ───────────────────────────────────────────────────────────────

local Instance = {
  __name = "instance",
  __tostring = function(i) return "[" .. i.class.__name .. " " .. tostring(i.form) .. "]" end,
}
local function is_instance(v) return getmetatable(v) == Instance end
local function form_of(v)
  if is_instance(v) then return v.form end
  return v
end
-- Papyrus `==`: an instance is its form. Refs are cached one per form, so identity is enough.
Instance.__eq = function(a, b) return rawequal(form_of(a), form_of(b)) end

local instances = {} -- ref -> lowercase script name -> instance

-- A member with no initializer is Null in the file; Papyrus gives it its type's zero.
local zeros = { int = 0, float = 0.0, bool = false, string = "" }
local function type_default(t, v)
  if v ~= nil then return v end
  local z = zeros[low(t)]
  if z == nil then return None end
  return z
end

-- rt.instance attaches a script to a form: member defaults from every class in the chain, then
-- the plugin's property values (lowercase property name -> value) over their backing members.
function rt.instance(form, script, props)
  local cls = rt.load(script)
  if not cls then
    warn_once("load:" .. low(script), "no script '" .. script .. "'")
    return nil
  end
  local chain = {}
  local c = cls
  while c do
    chain[#chain] = c
    c = parent_of(c)
  end
  local vars = {}
  for i = #chain - 1, 0, -1 do
    for k, v in pairs(chain[i].__vars) do vars[k] = type_default(v.type, v.default) end
  end
  for name, value in pairs(props or {}) do
    if type(value) == "table" and getmetatable(value) == nil then rt.as_array(value) end
    for i = 0, #chain - 1 do
      local backer = chain[i].__autoprop[name]
      if backer then
        vars[backer] = value
        break
      end
    end
  end
  local inst = setmetatable({ form = form, class = cls, vars = vars }, Instance)
  local per = instances[form]
  if not per then
    per = {}
    instances[form] = per
  end
  per[low(script)] = inst
  return inst
end

function rt.instances_of(form) return instances[form] end

-- find_instance is the script instance on `ref` whose chain includes class `lname`.
local function find_instance(ref, lname)
  local per = instances[ref]
  if not per then return nil end
  if per[lname] then return per[lname] end
  for _, inst in pairs(per) do
    if is_subclass(inst.class, lname) then return inst end
  end
  return nil
end

-- ── values ──────────────────────────────────────────────────────────────────

local Array = { __name = "array" }
local function is_array(v) return getmetatable(v) == Array end

-- rt.as_array marks a 0-based table (a plugin's array property) as a Papyrus array.
function rt.as_array(t) return setmetatable(t, Array) end

local function to_int(v)
  local ty = type(v)
  if ty == "number" then
    if math.type(v) == "integer" then return v end
    if v ~= v then return 0 end
    return math.tointeger(v >= 0 and math.floor(v) or math.ceil(v)) or 0
  end
  if ty == "boolean" then return v and 1 or 0 end
  if ty == "string" then
    local n = tonumber(v) or tonumber(v:match("^%s*([-+]?%d+)"))
    return n and to_int(n) or 0
  end
  return 0
end

local function to_float(v)
  local ty = type(v)
  if ty == "number" then return v + 0.0 end
  if ty == "boolean" then return v and 1.0 or 0.0 end
  if ty == "string" then
    return (tonumber(v) or tonumber(v:match("^%s*([-+]?%d*%.?%d+)")) or 0) + 0.0
  end
  return 0.0
end

local function to_bool(v)
  if is_none(v) then return false end
  local ty = type(v)
  if ty == "boolean" then return v end
  if ty == "number" then return v ~= 0 end
  if ty == "string" then return v ~= "" end
  if is_array(v) then return #v > 0 end
  return true
end

local to_string
to_string = function(v)
  if is_none(v) then return "None" end
  local ty = type(v)
  if ty == "string" then return v end
  if ty == "boolean" then return v and "True" or "False" end
  if ty == "number" then
    if math.type(v) == "integer" then return tostring(v) end
    return format("%f", v)
  end
  if is_array(v) then
    local parts = {}
    for i = 0, #v - 1 do parts[i] = to_string(v[i]) end
    return "[" .. table.concat(parts, ", ") .. "]"
  end
  return tostring(v)
end

local function to_object(v, t)
  if is_none(v) then return None end
  if is_instance(v) then
    if is_subclass(v.class, t) then return v end
    v = v.form
  end
  if type(v) ~= "userdata" then return None end
  if is_a(v, t) then return v end
  return find_instance(v, t) or None
end

local casts = { bool = to_bool, int = to_int, float = to_float, string = to_string }

-- rt.cast converts to a lowercase Papyrus type name. Arrays and "" pass through.
function rt.cast(v, t)
  local f = casts[t]
  if f then return f(v) end
  if t == "" or t:sub(-2) == "[]" then return v end
  return to_object(v, t)
end

function rt.concat(a, b) return to_string(a) .. to_string(b) end

-- Papyrus integer division and modulo truncate toward zero; fmod does, Lua's // does not.
function rt.idiv(a, b)
  if b == 0 then
    warn_once("div0", "integer divide by zero")
    return 0
  end
  return (a - fmod(a, b)) // b
end

function rt.imod(a, b)
  if b == 0 then
    warn_once("div0", "integer divide by zero")
    return 0
  end
  return fmod(a, b)
end

-- ── arrays ──────────────────────────────────────────────────────────────────
-- A Papyrus array never holds nil: None is stored as the sentinel, so `#a` and ipairs stay exact.

function rt.array(n, elem)
  local d = type_default(elem)
  local a = setmetatable({}, Array)
  for i = 0, n - 1 do a[i] = d end
  return a
end

function rt.alen(a)
  if is_none(a) then return 0 end
  return #a
end

local function in_range(a, i)
  if is_none(a) or i < 0 or i >= #a then
    warn_once("array", "array index out of range")
    return false
  end
  return true
end

function rt.aget(a, i)
  if not in_range(a, i) then return None end
  return a[i]
end

function rt.aset(a, i, v)
  if not in_range(a, i) then return end
  if v == nil then v = None end
  a[i] = v
end

function rt.afind(a, v, start)
  if is_none(a) then return -1 end
  for i = start or 0, #a - 1 do
    if a[i] == v then return i end
  end
  return -1
end

function rt.arfind(a, v, start)
  if is_none(a) then return -1 end
  start = start or -1
  if start < 0 then start = #a + start end
  for i = start, 0, -1 do
    if a[i] == v then return i end
  end
  return -1
end

-- ── natives ─────────────────────────────────────────────────────────────────

-- args_out hands natives forms, never script instances.
local function args_out(...)
  local n = select('#', ...)
  for i = 1, n do
    if is_instance((select(i, ...))) then
      local t = table.pack(...)
      for j = 0, n - 1 do t[j] = form_of(t[j]) end
      return table.unpack(t, 0, n - 1)
    end
  end
  return ...
end

function rt.native(class, fn, global)
  if global then
    return function(...) return native(class, fn, nil, args_out(...)) end
  end
  return function(self, ...) return native(class, fn, form_of(self), args_out(...)) end
end

-- ── calls ───────────────────────────────────────────────────────────────────

local function state_of(recv) return is_instance(recv) and recv.vars["::state"] or nil end

-- resolve finds `lname` for a receiver: its own class chain, and for a plain ref also the scripts
-- attached to its form, since a property typed as a script holds the bare form.
local function resolve(recv, lname)
  if is_instance(recv) then return lookup(recv.class, state_of(recv), lname), recv end
  local cls = rt.load(class_of(recv))
  local f = cls and lookup(cls, nil, lname)
  if f then return f, recv end
  for _, inst in pairs(instances[recv] or {}) do
    f = lookup(inst.class, state_of(inst), lname)
    if f then return f, inst end
  end
  return nil
end

function rt.call(recv, name, ...)
  local lname = low(name)
  if is_none(recv) then
    warn_once("none:" .. lname, "'" .. name .. "' called on None")
    return None
  end
  local f, self = resolve(recv, lname)
  if f then return f(self, ...) end
  if not is_instance(recv) then return native(class_of(recv), name, recv, args_out(...)) end
  warn_once("call:" .. lname, "no function '" .. name .. "' on " .. tostring(recv))
  return None
end

function rt.static(class, name, ...)
  local cls = rt.load(class)
  local f = cls and lookup(cls, nil, low(name))
  if f then return f(...) end
  return native(class, name, nil, args_out(...))
end

function rt.parent(self, class, name, ...)
  local cls = rt.load(class)
  local up = cls and parent_of(cls)
  local f = up and lookup(up, state_of(self), low(name))
  if f then return f(self, ...) end
  warn_once("parent:" .. low(class) .. "." .. low(name), "no parent '" .. name .. "' above " .. class)
  return None
end

-- Instructions one handler run may take. A Papyrus poll loop (`while !ready; Wait(1)`) spins
-- forever while Wait returns at once; the budget stops that handler instead of freezing the game.
local BUDGET = 1000000
local function over_budget() error("instruction budget exceeded", 2) end

-- rt.event runs a handler if the instance has one, isolated: an error or a runaway loop ends this
-- handler only, with a warning. Missing handlers are the norm, so they are silent.
function rt.event(inst, name, ...)
  local f = lookup(inst.class, state_of(inst), low(name))
  if not f then return end
  local hook, mask, count = gethook()
  sethook(over_budget, "", BUDGET)
  local ok, err = pcall(f, inst, ...)
  if hook then sethook(hook, mask, count) else sethook() end
  if not ok then warn(tostring(inst) .. " " .. name .. ": " .. tostring(err)) end
end

-- rt.send queues an event for every script on `form`, and reports whether `form` has any; rt.drain
-- runs the queue, once per tick. An event sent while the queue drains runs on the next drain, as
-- Papyrus queues it too.
local queue = {}

function rt.send(form, name, ...)
  if not instances[form] then return false end
  queue[#queue] = { form = form, name = name, args = table.pack(...) }
  return true
end

function rt.drain()
  local q = queue
  queue = {}
  for _, e in ipairs(q) do
    for _, inst in pairs(instances[e.form] or {}) do
      rt.event(inst, e.name, table.unpack(e.args, 0, e.args.n - 1))
    end
  end
  return #q
end

-- rt.attach gives a form its scripts: every instance first, so siblings can find each other, then
-- OnInit on each when `init` is set. `list` is { {name = ..., props = {...}}, ... }. A form that
-- already has instances keeps them, so a cell that loads again does not re-run OnInit.
function rt.attach(form, list, init)
  if instances[form] then return 0 end
  local made = {}
  for _, s in ipairs(list) do
    local inst = rt.instance(form, s.name, s.props)
    if inst then made[#made] = inst end
  end
  if init then
    for _, inst in ipairs(made) do rt.event(inst, "OnInit") end
  end
  return #made
end

-- ── properties ──────────────────────────────────────────────────────────────

local function find_prop(recv, lp, kind)
  local inst = recv
  if not is_instance(inst) then
    -- an engine class's own property (GlobalVariable.Value), self being the ref
    local c = rt.load(class_of(recv))
    while c do
      local f = c.__fn[kind .. lp]
      if f then return recv, nil, f end
      c = parent_of(c)
    end
    for _, i in pairs(instances[recv] or {}) do
      if find_prop(i, lp, kind) then
        inst = i
        break
      end
    end
    if not is_instance(inst) then return nil end
  end
  local c = inst.class
  while c do
    local backer = c.__autoprop[lp]
    if backer then return inst, backer end
    local f = c.__fn[kind .. lp]
    if f then return inst, nil, f end
    c = parent_of(c)
  end
  return nil
end

function rt.get(obj, prop)
  local lp = low(prop)
  local inst, backer, f = find_prop(obj, lp, "__propget_")
  if backer then return inst.vars[backer] end
  if f then return f(inst) end
  warn_once("get:" .. lp, "no property '" .. prop .. "' on " .. tostring(obj))
  return None
end

function rt.set(obj, prop, v)
  local lp = low(prop)
  local inst, backer, f = find_prop(obj, lp, "__propset_")
  if backer then
    inst.vars[backer] = v
  elseif f then
    f(inst, v)
  else
    warn_once("set:" .. lp, "no property '" .. prop .. "' on " .. tostring(obj))
  end
end

return rt
