-- skymod.rt: the runtime every converted Papyrus script requires. The contract it serves is the
-- `rt` table in docs/papyrus-transpiler.md. Positions are 0-based: the engine's Lua is patched.
--
-- Receivers are one of three things: a ref (engine userdata wrapping a form), a script instance
-- (a table per form and attached script), or None (the engine sentinel; nil counts as None).

local native, method, has_method, none_value = __native, __method, __has_method, __none_value
local is_engine_class = __is_engine_class
local class_of, is_a, warn, script_layers = __class_of, __is_a, __warn, __script_layers
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

-- A function assigned to a class goes into its method table, so hand-written code can say
-- `function C:OnTick()`. Converted code fills `__fn` directly.
local Class = {
  __newindex = function(cls, k, v)
    if type(v) == "function" then
      cls.__fn[low(k)] = v
    else
      rawset(cls, k, v)
    end
  end,
}

function rt.class(name, parent)
  local cls = setmetatable({
    __name = name,
    __parent = parent and low(parent),
    __fn = {},
    __states = {},
    __vars = {},
    __autoprop = {},
    __cache = {},
    __names = {},
    __plain = {}, -- name -> vars key, for a field read and written as stored (Instance's fast path)
    __params = {},
  }, Class)
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

-- defines reports whether `lname` is a function anywhere in the chain, in any state.
local function defines(cls, lname)
  local c = cls
  while c do
    if c.__fn[lname] then return true end
    for _, st in pairs(c.__states) do
      if st[lname] then return true end
    end
    c = parent_of(c)
  end
  return false
end

-- ── field types ─────────────────────────────────────────────────────────────
-- Hand-written scripts declare `__vars` entries with these (docs/script-api.md section 2). Each
-- returns the { type, default } shape the transpiler emits.

local function field(t) return function(v) return { type = t, default = v } end end
rt.bool, rt.int, rt.float, rt.string = field("Bool"), field("Int"), field("Float"), field("String")
rt.timer, rt.stopwatch = field("Timer"), field("Stopwatch")
rt.gametimer, rt.gamestopwatch = field("GameTimer"), field("GameStopwatch")
function rt.form(t) return { type = t } end
function rt.array_of(elem) return { type = elem .. "[]" } end

-- A vec3 is a position or an Euler rotation. In `__vars` the value itself declares the field.
local Vec3 = { __name = "vec3" }
function rt.vec3(x, y, z) return setmetatable({ x = x or 0.0, y = y or 0.0, z = z or 0.0 }, Vec3) end
local function is_vec3(v) return getmetatable(v) == Vec3 end
local function copy_vec3(v) return rt.vec3(v.x, v.y, v.z) end

-- A sequence is an ordered set of named stages, compared by position (`self.stage < S.Dead`). In
-- `__vars` a stage declares the field; it saves as its name, so adding or reordering stages keeps
-- old saves meaningful.
local Stage = { __name = "stage" }
Stage.__lt = function(a, b) return a.pos < b.pos end
Stage.__le = function(a, b) return a.pos <= b.pos end
Stage.__tostring = function(st) return st.name end
local function is_stage(v) return getmetatable(v) == Stage end

function rt.sequence(...)
  local names = { ... }
  local seq, list = {}, {}
  for i = 0, #names - 1 do
    list[i] = setmetatable({ name = names[i], pos = i, seq = seq, list = list, first = names[0] }, Stage)
    seq[names[i]] = list[i]
  end
  return seq
end

-- `stage + n` is the stage n places on; past either end it warns and stays.
Stage.__add = function(st, n)
  if type(st) == "number" then st, n = n, st end
  local to = st.list[st.pos + n]
  if to then return to end
  warn("stage " .. st.name .. " + " .. tostring(n) .. " is past the end of its sequence; it stays")
  return st
end

-- spec_of turns a `__vars` entry into its { type, default } shape.
local function spec_of(name, v)
  if is_vec3(v) then return { type = "Vec3", default = v } end
  if is_stage(v) then return { type = "Stage", default = v } end
  if type(v) ~= "table" then error("__vars." .. tostring(name) .. " needs a type: rt.float(" .. tostring(v) .. "), rt.int(...)", 0) end
  return v
end


-- rt.state returns a class's state table, made on first use; `function Busy:OnActivate()` on it
-- lands lowercase, as converted state handlers are.
local State = { __newindex = function(st, k, v) rawset(st, low(k), v) end }
function rt.state(cls, name)
  local l = low(name)
  local st = setmetatable(cls.__states[l] or {}, State)
  cls.__states[l] = st
  cls.__cache = {}
  return st
end

-- Clocks: the engine moves them every tick (rt.advance). Sign is the direction, game marks game time.
local clock_kinds = {
  timer = { sign = -1 },
  stopwatch = { sign = 1 },
  gametimer = { sign = -1, game = true },
  gamestopwatch = { sign = 1, game = true },
}

-- Every clock field of every instance, flat: one list per kind, holding (vars table, key) pairs
-- at 2i and 2i+1, so rt.advance is one tight loop per kind with a constant step.
local clocks = { timer = {}, stopwatch = {}, gametimer = {}, gamestopwatch = {} }

local function add_clocks(vars, fields)
  for _, c in ipairs(fields) do
    local list = clocks[c.kind]
    list[#list] = vars
    list[#list] = c.name
  end
end

-- Keys an instance keeps for itself, so no field may use them.
local reserved = { form = true, class = true, vars = true, base = true }

local plain_types = { bool = true, int = true, float = true, string = true, vec3 = true, stage = true }

-- script_typed lists the fields whose type is a script class; reading one gives that script's
-- instance on the form it holds (a plugin or a save stores the bare form).
local function script_typed(specs)
  local out = {}
  for k, s in pairs(specs) do
    local t = low(s.type or "")
    if t ~= "" and not plain_types[t] and not clock_kinds[t] and t:sub(-2) ~= "[]" and not is_engine_class(t) then out[k] = t end
  end
  return out
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
local ordered = {}   -- ref -> its instances in the order they were made (VMAD order)

-- The tick schedule. An instance whose class defines OnTick joins the group of its TickRate, which
-- never changes, and takes a fixed slot in it: (its place in the group) mod (the group's period in
-- ticks). A tick visits only the slots that are due, so equal rates spread over the period and an
-- idle slot costs nothing. The period needs the tick length, so it is set on the first tick.
local groups = {} -- rate in seconds (0 = every tick) -> { every = ticks or nil, n, slots, waiting }
local rates = {}  -- the group keys, in the order the groups were made
local ticks = 0

local function place(g, inst)
  local slot = g.n % g.every
  g.n = g.n + 1
  local list = g.slots[slot] or {}
  g.slots[slot] = list
  list[#list] = inst
end

local function schedule(inst, rate)
  rate = rate or 0
  local g = groups[rate]
  if not g then
    g = { n = 0, slots = {}, waiting = {} }
    groups[rate] = g
    rates[#rates] = rate
  end
  if g.every then place(g, inst) else g.waiting[#g.waiting] = inst end
end

-- snapshot copies a member's start value; an array is copied so writes into it show as changes.
local function snapshot(vars)
  local base = {}
  for k, v in pairs(vars) do
    if type(v) == "table" and not is_instance(v) and not is_stage(v) then
      local c = setmetatable({}, getmetatable(v))
      for i, e in pairs(v) do c[i] = e end
      v = c
    end
    base[k] = v
  end
  return base
end

-- A member with no initializer is Null in the file; Papyrus gives it its type's zero.
local zeros = {
  int = 0, float = 0.0, bool = false, string = "",
  timer = 0.0, stopwatch = 0.0, gametimer = 0.0, gamestopwatch = 0.0,
}
local function type_default(t, v)
  if is_vec3(v) then return copy_vec3(v) end
  if not rawequal(v, nil) then return v end -- a declared None stays None (None == nil in Papyrus equality)
  local z = zeros[low(t)]
  if z == nil then return None end
  return z
end

local function clock_fields(specs)
  local list = {}
  for k, s in pairs(specs) do
    if clock_kinds[low(s.type)] then list[#list] = { name = k, kind = low(s.type) } end
  end
  return list
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
  local specs = {}
  for i = #chain - 1, 0, -1 do
    for k, v in pairs(chain[i].__vars) do specs[k] = spec_of(k, v) end
  end
  local vars = {}
  for k, s in pairs(specs) do vars[k] = type_default(s.type, s.default) end
  vars["::state"] = "" -- the empty state, as GetState() reports it before any GotoState
  for i = 0, #chain - 1 do -- the nearest auto state; OnBeginState does not run for it (CK)
    if chain[i].__autostate then
      vars["::state"] = chain[i].__autostate
      break
    end
  end
  if cls.__clocks == nil then
    cls.__clocks = clock_fields(specs)
    cls.__script_typed = script_typed(specs)
    cls.__ticks = defines(cls, "ontick")
    for k in pairs(specs) do
      if reserved[k] then warn(cls.__name .. ": field '" .. k .. "' uses a reserved name") end
    end
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
  local inst = setmetatable({ form = form, class = cls, vars = vars, base = snapshot(vars) }, Instance)
  local per = instances[form]
  if not per then
    per = {}
    instances[form] = per
  end
  per[low(script)] = inst
  local list = ordered[form] or {}
  ordered[form] = list
  list[#list] = inst
  add_clocks(vars, cls.__clocks)
  if cls.__ticks then schedule(inst, vars.TickRate) end
  return inst
end

function rt.instances_of(form) return instances[form] end

local function drop(list, inst)
  for j = 0, #list - 1 do
    if rawequal(list[j], inst) then
      for k = j, #list - 2 do list[k] = list[k + 1] end
      list[#list - 1] = nil
      return true
    end
  end
  return false
end

-- rt.detach drops a deleted form's instances. They leave the tick schedule, and events queued
-- for the form find no one.
function rt.detach(form)
  for _, inst in ipairs(ordered[form] or {}) do
    local g = inst.class.__ticks and groups[inst.vars.TickRate or 0]
    if g and not (g.waiting and drop(g.waiting, inst)) then
      for _, list in pairs(g.slots) do
        if drop(list, inst) then break end
      end
    end
  end
  instances[form] = nil
  ordered[form] = nil
end

-- find_instance is the script instance on `ref` whose chain includes class `lname`.
local function find_instance(ref, lname)
  local per = instances[ref]
  if not per then return nil end
  if per[lname] then return per[lname] end
  for _, inst in ipairs(ordered[ref]) do
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
-- rt.cast, concat, idiv, imod and alen must never raise: the transpiler moves them past calls.
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

-- ── arguments ───────────────────────────────────────────────────────────────
-- A parameter list is { {name, default}, ... } in declaration order; an entry with no default is
-- required. A call may leave out trailing arguments, which take their defaults, or pass one plain
-- table of named arguments: `self:MoveTo{ akTarget = m, afZOffset = 50.0 }`.

local ok_params, generated = pcall(require, 'skymod.params') -- "class.fn" -> list, from the CK sources
local native_params = ok_params and generated.natives or {}
local script_params = ok_params and generated.scripts or {} -- converted script functions
local params_by_fn = {} -- lowercase fn -> the first native's list, for calls whose class resolves engine-side
for key, list in pairs(native_params) do
  local fn = key:match("%.(.*)$")
  if params_by_fn[fn] == nil then params_by_fn[fn] = list end
end

local function with_defaults(list, ...)
  local n, first = select('#', ...), ...
  local named = n == 1 and type(first) == "table" and getmetatable(first) == nil
  if not named and n >= #list then return ... end
  local out = {}
  for i = 0, #list - 1 do
    local p = list[i]
    local v
    if named then v = first[p[0]] elseif i < n then v = (select(i + 1, ...)) end
    if rawequal(v, nil) then -- a None passed on purpose is an argument (None == nil in Papyrus equality)
      if #p < 2 then error("missing argument '" .. p[0] .. "'", 3) end
      v = p[1]
    end
    out[i] = v
  end
  if named then
    for k in pairs(first) do
      local known = false
      for i = 0, #list - 1 do known = known or list[i][0] == k end
      if not known then error("no parameter '" .. tostring(k) .. "'", 3) end
    end
  end
  return table.unpack(out, 0, #list - 1)
end

-- rt.params declares a script function's parameters, for hand-written scripts:
-- `rt.params(C, "Launch", { {"target"}, {"speed", 1.0} })`.
function rt.params(cls, name, list) cls.__params[low(name)] = list end

local function params_of(cls, lname)
  local c = cls
  while c do
    local p = c.__params[lname] or script_params[low(c.__name) .. "." .. lname]
    if p then return p end
    c = parent_of(c)
  end
end

function rt.native(class, fn, global)
  local p = native_params[low(class .. "." .. fn)]
  if global then
    if p then return function(...) return native(class, fn, nil, args_out(with_defaults(p, ...))) end end
    return function(...) return native(class, fn, nil, args_out(...)) end
  end
  if p then return function(self, ...) return native(class, fn, form_of(self), args_out(with_defaults(p, ...))) end end
  return function(self, ...) return native(class, fn, form_of(self), args_out(...)) end
end

-- ── calls ───────────────────────────────────────────────────────────────────

local function state_of(recv) return is_instance(recv) and recv.vars["::state"] or nil end

-- resolve finds `lname` for a receiver: an instance's own class chain; for a plain ref the scripts
-- attached to its form first (a property typed as a script holds the bare form), then its engine class.
local function resolve(recv, lname)
  if is_instance(recv) then return lookup(recv.class, state_of(recv), lname), recv end
  local found, owner
  for _, inst in ipairs(ordered[recv] or {}) do
    local f = lookup(inst.class, state_of(inst), lname)
    if f and found and f ~= found then
      error("'" .. lname .. "' is a different function on more than one script on " .. tostring(recv) .. "; rt.cast to one", 3)
    end
    if f and not found then found, owner = f, inst end
  end
  if found then return found, owner end
  local cls = rt.load(class_of(recv))
  local f = cls and lookup(cls, nil, lname)
  if f then return f, recv end
  return nil
end

function rt.call(recv, name, ...)
  local lname = low(name)
  if is_none(recv) then
    warn_once("none:" .. lname, "'" .. name .. "' called on None")
    return none_value(name)
  end
  local f, self = resolve(recv, lname)
  if f then
    local p = is_instance(self) and params_of(self.class, lname)
    if p then return f(self, with_defaults(p, ...)) end
    return f(self, ...)
  end
  local p = params_by_fn[lname]
  if p then return method(form_of(recv), name, args_out(with_defaults(p, ...))) end
  return method(form_of(recv), name, args_out(...))
end

-- ── names ───────────────────────────────────────────────────────────────────
-- Hand-written code reads and writes fields as `self.x`, and calls as `self:Name()`; a bare ref
-- reaches the fields and functions of the scripts on it the same way. Converted code uses `vars`
-- and rt.call directly.

-- name_of says what `k` is on an instance: the vars key holding it, true for a function, PROP for a
-- property with get/set functions, or false. In order: a field as written, a script function, a
-- converted member (lowercase) or a property's backer, a full property, then a native. Cached per class.
local PROP = {}
local function name_of(inst, k)
  local names = inst.class.__names
  local n = names[k]
  if n ~= nil then return n end
  local vars, l = inst.vars, low(k)
  if not rawequal(vars[k], nil) then -- None == nil in Papyrus equality
    n = k
  elseif defines(inst.class, l) then
    if not rawequal(vars[l], nil) then
      error("'" .. tostring(k) .. "' is both a member and a function of " .. inst.class.__name .. "; use self.vars." .. l .. " or rt.call", 3)
    end
    n = true
  elseif not rawequal(vars[l], nil) then
    n = l
  else
    local c = inst.class
    while c and not n do
      n = c.__autoprop[l]
      c = parent_of(c)
    end
    if not n and defines(inst.class, "__propget_" .. l) then n = PROP end
    n = n or has_method(inst.form, k)
  end
  names[k] = n
  return n
end

local methods = {} -- name -> caller, shared by every receiver
local function caller(k)
  local m = methods[k]
  if not m then
    m = function(self, ...) return rt.call(self, k, ...) end
    methods[k] = m
  end
  return m
end

local function no_name(recv, k) error("no field or function '" .. tostring(k) .. "' on " .. tostring(recv), 3) end

Instance.__index = function(inst, k)
  local n = inst.class.__plain[k]
  if n then return inst.vars[n] end
  n = name_of(inst, k)
  if type(n) == "string" then
    local v, t = inst.vars[n], inst.class.__script_typed[n]
    if not t and n ~= "TickRate" then inst.class.__plain[k] = n end
    if t and type(v) == "userdata" then return find_instance(v, t) or v end
    return v
  end
  if n == PROP then return rt.get(inst, k) end
  if n then return caller(k) end
  no_name(inst, k)
end

-- A write must name a declared field, so a typo cannot make a member that is never saved.
Instance.__newindex = function(inst, k, v)
  local n = inst.class.__plain[k]
  if not n then
    n = name_of(inst, k)
    if n == PROP then return rt.set(inst, k, v) end
    if type(n) ~= "string" then no_name(inst, k) end
    if n == "TickRate" then error("TickRate is fixed when the instance is made", 2) end
  end
  if v == nil then v = None end
  inst.vars[n] = v
end

-- field_owner is the one script on ref `r` with a field or property `k`. Two is an error: which
-- one was meant needs `rt.cast(r, "Script")`.
local function field_owner(r, k)
  local owner
  for _, inst in ipairs(ordered[r] or {}) do
    local n = name_of(inst, k)
    if type(n) == "string" or n == PROP then
      if owner then error("'" .. tostring(k) .. "' is a field of more than one script on " .. tostring(r) .. "; rt.cast to one", 3) end
      owner = inst
    end
  end
  return owner
end

local function engine_prop(r, k)
  local cls = rt.load(class_of(r))
  return cls and defines(cls, "__propget_" .. low(k))
end

local Ref = debug.getregistry()["skymod.ref"]
Ref.__index = function(r, k)
  local owner = field_owner(r, k)
  if owner then return owner[k] end
  if engine_prop(r, k) then return rt.get(r, k) end
  if resolve(r, low(k)) or has_method(r, k) then return caller(k) end
  no_name(r, k)
end
Ref.__newindex = function(r, k, v)
  local owner = field_owner(r, k)
  if owner then
    owner[k] = v
  elseif engine_prop(r, k) then
    rt.set(r, k, v)
  else
    no_name(r, k)
  end
end

function rt.static(class, name, ...)
  local cls = rt.load(class)
  local f = cls and lookup(cls, nil, low(name))
  if f then
    local p = params_of(cls, low(name))
    if p then return f(with_defaults(p, ...)) end
    return f(...)
  end
  local p = native_params[low(class .. "." .. name)]
  if p then return native(class, name, nil, args_out(with_defaults(p, ...))) end
  return native(class, name, nil, args_out(...))
end

function rt.parent(self, class, name, ...)
  local cls = rt.load(class)
  local up = cls and parent_of(cls)
  local f = up and lookup(up, state_of(self), low(name))
  if f then
    local p = params_of(up, low(name))
    if p then return f(self, with_defaults(p, ...)) end
    return f(self, ...)
  end
  warn_once("parent:" .. low(class) .. "." .. low(name), "no parent '" .. name .. "' above " .. class)
  return None
end

-- Instructions one handler run may take. A Papyrus poll loop (`while !ready; Wait(1)`) spins
-- forever while Wait returns at once; the budget stops that handler instead of freezing the game.
local BUDGET = 1000000
local function over_budget() error("instruction budget exceeded", 2) end

-- rt.event runs a handler if the instance has one, isolated: an error or a runaway loop ends this
-- handler only, with a warning. Missing handlers are the norm, so they are silent.
local function budgeted(f, ...)
  local hook, mask, count = gethook()
  sethook(over_budget, "", BUDGET)
  local ok, err = pcall(f, ...)
  if hook then sethook(hook, mask, count) else sethook() end
  return ok, err
end

function rt.event(inst, name, ...)
  local f = lookup(inst.class, state_of(inst), low(name))
  if not f then return end
  local ok, err = budgeted(f, inst, ...)
  if not ok then warn(tostring(inst) .. " " .. name .. ": " .. tostring(err)) end
end

-- rt.guard runs any function the way a handler runs: under the budget, an error only warns.
function rt.guard(label, f, ...)
  local ok, err = budgeted(f, ...)
  if not ok then warn(label .. ": " .. tostring(err)) end
  return ok
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

-- rt.anim_event(sender, name) sends an animation event through the registrations (drivers use it
-- in place of the animation system).
rt.anim_event = __anim_event

-- rt.ticking: an instance on `form` has OnTick in its current state.
function rt.ticking(form)
  for _, inst in ipairs(ordered[form] or {}) do
    if lookup(inst.class, state_of(inst), "ontick") then return true end
  end
  return false
end

-- check_anim_handler: a script on `form` with an OnAnimationEvent handler never hears `event`,
-- because its form did not register for it. Say so once (script-api.md section 4).
function rt.check_anim_handler(form, event)
  for _, inst in ipairs(ordered[form] or {}) do
    if lookup(inst.class, state_of(inst), "onanimationevent") then
      local name = inst.class.__name
      warn_once("anim:" .. low(name) .. ":" .. low(event),
        name .. " handles OnAnimationEvent but did not register for '" .. event .. "' on its own ref")
    end
  end
end

function rt.drain()
  local q = queue
  queue = {}
  for _, e in ipairs(q) do
    for _, inst in ipairs(ordered[e.form] or {}) do
      rt.event(inst, e.name, table.unpack(e.args, 0, e.args.n - 1))
    end
  end
  return #q
end

-- rt.advance moves every clock field: real clocks by `dt` seconds, game clocks by `game_dt` hours.
-- Once per tick, before any handler of that tick runs. A clock a script set to None stays None.
local function step(list, d)
  for i = 0, #list - 1, 2 do
    local vars, k = list[i], list[i + 1]
    local v = vars[k]
    if type(v) == "number" then vars[k] = v + d end
  end
end

function rt.advance(dt, game_dt)
  step(clocks.timer, -dt)
  step(clocks.stopwatch, dt)
  step(clocks.gametimer, -game_dt)
  step(clocks.gamestopwatch, game_dt)
end

-- rt.tick calls OnTick on the instances due this tick, once per tick after the queue drains: group
-- by group in the order they were made, each slot in the order its instances were made.
function rt.tick(dt)
  for i = 0, #rates - 1 do
    local g = groups[rates[i]]
    if not g.every then
      g.every = math.max(1, math.floor(rates[i] / dt + 0.5))
      for j = 0, #g.waiting - 1 do place(g, g.waiting[j]) end
      g.waiting = nil
    end
    local list = g.slots[ticks % g.every]
    if list then
      for j = 0, #list - 1 do rt.event(list[j], "OnTick") end
    end
  end
  ticks = ticks + 1
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

-- ── saves ───────────────────────────────────────────────────────────────────

local function same(a, b)
  if type(a) ~= "table" or type(b) ~= "table" or is_instance(a) or is_instance(b) then
    return rawequal(form_of(a), form_of(b))
  end
  if #a ~= #b then return false end
  for i, e in pairs(a) do
    if not rawequal(form_of(e), form_of(b[i])) then return false end
  end
  return true
end

-- rt.save_vars calls emit(form) for every form with scripts, then emit(form, script, member,
-- value, length) for each member that differs from its start value. An array arrives as a
-- 0-based table of forms and scalars with its length, a vec3 as three floats, a stage as its name.
function rt.save_vars(emit)
  for form, per in pairs(instances) do
    emit(form)
    for script, inst in pairs(per) do
      for name, v in pairs(inst.vars) do
        if not same(v, inst.base[name]) then
          if is_array(v) then
            local out = {}
            for i = 0, #v - 1 do out[i] = form_of(v[i]) end
            emit(form, script, name, out, #v)
          elseif is_vec3(v) then
            emit(form, script, name, { v.x, v.y, v.z }, 3)
          elseif is_stage(v) then
            emit(form, script, name, v.name)
          else
            emit(form, script, name, form_of(v))
          end
        end
      end
    end
  end
end

-- rt.restore_var puts a saved member value back on a form's script instance.
function rt.restore_var(form, script, name, value)
  local inst = instances[form] and instances[form][script]
  if not inst then return end
  local base = inst.base[name]
  if type(value) == "table" then
    value = is_vec3(base) and rt.vec3(value[0], value[1], value[2]) or rt.as_array(value)
  elseif is_stage(base) then
    local st = base.seq[value]
    if not st then
      warn(tostring(inst) .. ": saved stage '" .. tostring(value) .. "' no longer exists, back to " .. base.first)
      st = base.seq[base.first]
    end
    value = st
  end
  inst.vars[name] = value
end

-- rt.reset drops every instance and queued event: a loaded save rebuilds them.
function rt.reset()
  instances = {}
  ordered = {}
  clocks = { timer = {}, stopwatch = {}, gametimer = {}, gamestopwatch = {} }
  groups = {}
  rates = {}
  ticks = 0
  queue = {}
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
    for _, i in ipairs(ordered[recv] or {}) do
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
