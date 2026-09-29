-- skymod.rt: the runtime every converted Papyrus script requires. The contract it serves is the
-- `rt` table in docs/papyrus-transpiler.md. Positions are 0-based: the engine's Lua is patched.
--
-- Receivers are one of three things: a ref (engine userdata wrapping a form), a script instance
-- (a table per form and attached script), or None (the engine sentinel; nil counts as None).

local native, method, has_method, none_value = __native, __method, __has_method, __none_value
local is_engine_class = __is_engine_class
local class_of, is_a, warn, script_layers = __class_of, __is_a, __warn, __script_layers
local now, info = __now, __info
local effect_class, content_files, effect_def, spell_def, power_def = __effect_class, __content_files, __effect_def, __spell_def, __power_def
local item_def = __item_def
local av_part, global_value = __av_part, __global
local resolve_ref, make_zone, spawn_hazard = __resolve, __make_zone, __spawn_hazard
local method_kind, condition = __method_kind, __condition
local None = None
local lower, format, fmod = string.lower, string.format, math.fmod
local load_effect
local sethook = debug.sethook

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
    if cls then load_effect(l, cls) end
  end
  return cls or nil
end

local function parent_of(cls) return cls.__parent and rt.load(cls.__parent) end

-- load_effect hands a class's __effect (its own or inherited) to the engine: { AV or slot = {
-- capacity = "formula", amount = "formula" }, caster = { ... } }, formulas in worldstate.EFFECT_VARS.
-- It claims its MGEF unless __claims_archetype = false. A class with no functions anywhere in its
-- chain is pure: the engine runs its terms and it gets no instance.
load_effect = function(lname, cls)
  local effect, claims, pure = nil, true, true
  local c = cls
  while c do
    effect = effect or rawget(c, "__effect")
    if rawget(c, "__claims_archetype") == false then claims = false end
    if next(c.__fn) or next(c.__states) then pure = false end
    c = parent_of(c)
  end
  if effect then effect_class(lname, effect, claims, pure) end
end

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

-- A clock field holds the value last written and when (`base`, `since`), on the real clock (seconds)
-- or the game clock (hours). A read is that value moved by the time since, so rt.advance moves two
-- numbers, not every clock, and a read in the tick of its write gives back exactly what was
-- written. Both live beside `vars`, never in it, so only clock keys reach these metamethods; pairs
-- sees them as floats. A None (or any non-number) is kept and read back as it is: that clock
-- stands still. An instance rt.reset dropped reads the clocks as they were then (`stopped`).
local now_real, now_game = 0.0, 0.0
local epoch, stopped = 0, {} -- stopped[e]: the clocks when rt.reset ended epoch e
local number_type = math.type

local function clocked(vars, fields)
  if #fields == 0 then return end
  local kinds, base, since, mine = {}, {}, {}, epoch
  local function now_of(kind)
    if mine ~= epoch then
      local c = stopped[mine]
      return kind.game and c.game or c.real
    end
    return kind.game and now_game or now_real
  end
  local function write(kind, k, v)
    base[k], since[k] = v, now_of(kind)
  end
  for _, c in ipairs(fields) do
    local kind = clock_kinds[c.kind]
    kinds[c.name] = kind
    write(kind, c.name, rawget(vars, c.name))
    rawset(vars, c.name, nil)
  end
  setmetatable(vars, {
    __index = function(_, k)
      local kind, v = kinds[k], base[k]
      if not kind or not number_type(v) then return v end
      return v + kind.sign * (now_of(kind) - since[k])
    end,
    __newindex = function(t, k, v)
      local kind = kinds[k]
      if not kind then return rawset(t, k, v) end
      write(kind, k, v)
    end,
    __pairs = function(t)
      local key, clocks_now = nil, false
      return function()
        if not clocks_now then
          local k, v = next(t, key)
          if k ~= nil then
            key = k
            return k, v
          end
          clocks_now, key = true, nil
        end
        key = next(kinds, key)
        if key ~= nil then return key, t[key] end
      end, t, nil
    end,
  })
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
-- PlayerRef stands for the actor the player controls: rt.key(r) is that actor's ref for PlayerRef,
-- else r. Refs are cached one per form, so a table keyed by rt.key(r) has one key per actor.
local PLAYER = ref(0x14)
local function key(r)
  if rawequal(r, PLAYER) then return resolve_ref(r) end
  return r
end
rt.key = key

-- Papyrus `==`: an instance is its form.
Instance.__eq = function(a, b) return rawequal(key(form_of(a)), key(form_of(b))) end

-- Scripts attach under real refs; a lookup by PlayerRef finds the controlled actor's.
local by_ref = { __index = function(t, r) if rawequal(r, PLAYER) then return rawget(t, key(r)) end end }
local instances = setmetatable({}, by_ref) -- ref -> lowercase script name -> instance
local ordered = setmetatable({}, by_ref)   -- ref -> its instances in the order they were made (VMAD order)

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
  clocked(vars, cls.__clocks)
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
  local had = instances[form] ~= nil
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
  return had
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

-- Waits return at once: the splitter and the rewrites own every vanilla wait, so a call that gets
-- here is a function neither covers. It is named once, by where it is defined.
local waits = { ["utility.wait"] = true, ["utility.waitgametime"] = true }
local rt_source = debug.getinfo(1, "S").source

local function wait_returns(fn)
  return function()
    local level = 2
    local at = debug.getinfo(level, "S")
    while at and at.source == rt_source do
      level = level + 1
      at = debug.getinfo(level, "S")
    end
    local where = at and (at.short_src .. ":" .. at.linedefined) or "?"
    warn_once("wait:" .. where, fn .. " returns at once in the function at " .. where .. ": split or rewrite it")
  end
end

function rt.native(class, fn, global)
  if waits[low(class .. "." .. fn)] then return wait_returns(fn) end
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

local conditions = {} -- name -> ref:name(...) for a condition function
local function condition_caller(k)
  local m = conditions[k]
  if not m then
    m = function(self, ...) return condition(self, k, ...) end
    conditions[k] = m
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
-- ref.av.<Name>.value, .capacity or .amount: the naming rule's actor value read.
local function av_of(r)
  return setmetatable({}, { __index = function(_, name)
    return setmetatable({}, { __index = function(_, part) return av_part(r, name, part) end })
  end })
end

Ref.__index = function(r, k)
  if k == "av" then return av_of(r) end
  local owner = field_owner(r, k)
  if owner then return owner[k] end
  if engine_prop(r, k) then return rt.get(r, k) end
  if resolve(r, low(k)) then return caller(k) end
  local kind = method_kind(r, k)
  if kind == "condition" then return condition_caller(k) end
  if kind then return caller(k) end
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
  -- a patch that takes a parent's waits takes its OnTick too; a subclass's chained call finds none
  if low(name) ~= "ontick" then warn_once("parent:" .. low(class) .. "." .. low(name), "no parent '" .. name .. "' above " .. class) end
  return None
end

-- Instructions one handler run may take. A Papyrus poll loop (`while !ready; Wait(1)`) spins
-- forever while Wait returns at once; the budget stops that handler instead of freezing the game.
-- One hook, set once, counts them in steps while a handler runs (`depth`); `spent` is the running
-- handler's own count, so a handler it runs starts from zero and hands the count back.
local BUDGET = 1000000
local STEP = 10000
local spent, depth = 0, 0
sethook(function()
  if depth == 0 then return end
  spent = spent + STEP
  if spent > BUDGET then error("instruction budget exceeded", 2) end
end, "", STEP)

-- Each handler's own time (less the handlers it ran inside it) per class and name, in ms, since
-- the last rt.prof_report. Off unless the engine asks (rt.profile, --profile).
local prof, prof_inner, profiling = {}, 0, false

function rt.profile(on) profiling = on ~= 0 end

local function prof_add(class, name, t0, outer, ...)
  local dt = now() - t0
  local by = prof[class]
  if not by then
    by = {}
    prof[class] = by
  end
  local e = by[name]
  if not e then
    e = { n = 0, ms = 0, max = 0 }
    by[name] = e
  end
  local own = (dt - prof_inner) * 1000
  e.n, e.ms, e.max = e.n + 1, e.ms + own, math.max(e.max, own)
  prof_inner = outer + dt
  return ...
end

local function finish(outer_spent, ...)
  spent, depth = outer_spent, depth - 1
  return ...
end

-- rt.event runs a handler if the instance has one, isolated: an error or a runaway loop ends this
-- handler only, with a warning. Missing handlers are the norm, so they are silent.
local function budgeted(class, name, f, ...)
  local outer_spent = spent
  spent, depth = 0, depth + 1
  if not profiling then return finish(outer_spent, pcall(f, ...)) end
  local t0, outer = now(), prof_inner
  prof_inner = 0
  return prof_add(class, name, t0, outer, finish(outer_spent, pcall(f, ...)))
end

-- rt.prof_report logs the `top` costliest handlers over the last `ticks` ticks and starts over.
function rt.prof_report(ticks, top)
  if not profiling then return 0 end
  local all, total = {}, 0
  for class, by in pairs(prof) do
    for name, e in pairs(by) do
      e.key = class .. "." .. name
      all[#all] = e
      total = total + e.ms
    end
  end
  prof = {}
  table.sort(all, function(x, y) return x.ms > y.ms end)
  local out = { format("prof.scripts: total=%.2f", total / ticks) }
  for i = 0, math.min(top, #all) - 1 do
    local e = all[i]
    out[#out] = format("%s=%.3f (x%d, max %.2f)", e.key, e.ms / ticks, e.n, e.max)
  end
  info(table.concat(out, " ") .. format(" (ms avg/%d ticks)", ticks))
  return 0
end

function rt.event(inst, name, ...)
  local f = lookup(inst.class, state_of(inst), low(name))
  if not f then return end
  local ok, err = budgeted(inst.class.__name, name, f, inst, ...)
  if not ok then warn(tostring(inst) .. " " .. name .. ": " .. tostring(err)) end
end

-- rt.fragment runs fragment `fn` of the script `file` on `form`: a quest stage's, a topic info's.
function rt.fragment(form, file, fn, ...)
  local inst = find_instance(form, low(file))
  if not inst then
    warn_once("frag:" .. low(file), "no fragment script '" .. file .. "' on " .. tostring(form))
    return
  end
  rt.event(inst, fn, ...)
end

-- rt.guard runs any function the way a handler runs: under the budget, an error only warns.
function rt.guard(label, f, ...)
  local ok, err = budgeted(label, "guard", f, ...)
  if not ok then warn(label .. ": " .. tostring(err)) end
  return ok
end

-- rt.procedure runs one tick of a package procedure a mod wrote: `Procedure(actor, dt, ...inputs)` on
-- the class named like the PNAM. It returns "running", "done" or "failed", then where to walk (a
-- ref or a vec3, or nothing to stand) and a gait ("walk", "jog", "run", "fastwalk").
function rt.procedure(name, actor, dt, ...)
  local cls = rt.load(name)
  local f = cls and lookup(cls, nil, "procedure")
  if not f then
    warn_once("proc:" .. low(name), "no package procedure '" .. name .. "'")
    return "failed"
  end
  local ok, status, goal, gait = budgeted(name, "Procedure", f, actor, dt, ...)
  if not ok then
    warn("procedure " .. name .. ": " .. tostring(status))
    return "failed"
  end
  return status, goal, gait
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

-- rt.advance moves the real clock by `dt` seconds and the game clock by `game_dt` hours, and with
-- them every clock field. Once per tick, before any handler of that tick runs.
function rt.advance(dt, game_dt)
  now_real = now_real + dt
  now_game = now_game + game_dt
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
      local j = 0
      while j < #list do
        local inst = list[j]
        rt.event(inst, "OnTick")
        if list[j] == inst then j = j + 1 end -- else its OnTick deleted its form and the rest moved down
      end
    end
  end
  ticks = ticks + 1
end

local starting        -- during game start: { forms = attached, fresh = those that run OnInit }
local game_loading = false
local hooks = {} -- rt.hook's, in order: { name =, land =, cost = }
local core_set = {} -- a mod's replacement for a core hook, by name; false removes it
local add_core_hooks -- (below rt.hook)

local function send_now(form, name)
  for _, inst in ipairs(ordered[form] or {}) do rt.event(inst, name) end
end

-- rt.attach gives a form its scripts: every instance first, so siblings can find each other, then
-- OnInit on each when `init` is set (at game start, OnInit waits for rt.start_end). `list` is
-- { {name = ..., props = {...}}, ... }. A form that already has instances keeps them, so a cell that
-- loads again does not re-run OnInit.
function rt.attach(form, list, init)
  if instances[form] then return 0 end
  local made = 0
  for _, s in ipairs(list) do
    if rt.instance(form, s.name, s.props) then made = made + 1 end
  end
  if made > 0 and starting then
    starting.forms[#starting.forms] = form
    if init then starting.fresh[#starting.fresh] = form end
  elseif made > 0 and init then
    send_now(form, "OnInit")
  end
  return made
end

-- rt.start_begin and rt.start_end bracket game start (new game or load). Between them rt.attach
-- defers OnInit; rt.start_end sends OnGameLoaded to every form attached, then OnInit to the new ones.
-- rt.actor_value works only inside OnGameLoaded.
function rt.start_begin()
  hooks, core_set = {}, {}
  rt.load_effects()
  starting = { forms = {}, fresh = {} }
end

function rt.start_end()
  local s = starting
  starting = nil
  game_loading = true
  for i = 0, #s.forms - 1 do send_now(s.forms[i], "OnGameLoaded") end
  add_core_hooks()
  game_loading = false
  for i = 0, #s.fresh - 1 do send_now(s.fresh[i], "OnInit") end
end

-- rt.actor_value(name, {default = v, kind = "static" | "latched" | "pool" | "timer" | "stopwatch" |
-- "gametimer" | "gamestopwatch"}) creates a mod actor value, or gets it when it exists. The kind
-- defaults to static; a clock kind moves by itself, like the script clock fields.
function rt.actor_value(name, opts)
  if not game_loading then error("rt.actor_value outside OnGameLoaded", 2) end
  opts = opts or {}
  __actor_value(name, opts.default or 0.0, opts.kind or "static")
end

-- rt.effect(def) is an effect, in an effects/<name>.lua file that returns it (the name is the file's):
--   form = "Skyrim.esm:012FCD" | editor id  -- the record it stands in for; none makes a Lua form
--   tags = { "magic.fire", "kw.MagicDamageFire" }
--   av = { Health = { capacity = "formula", amount = "formula" } }, caster = { Magicka = {...} }
--   resist = "FrostResist"                  -- the AV that resists it (GetResistance), when tagged hostile
--   stack = "restart" | "add" | "keep"      -- the same caster landing it again from the same source
--   nostack = "Blessing"                    -- a group, across effects: only the strongest runs
--   taper = "1s"                            -- a timed copy goes on this long after d (t runs past d)
--   radius = 320                            -- a tunable's default; a bare name in a formula is one
--   land = function(e) ... end              -- once as it lands: return false and it does not start;
--                                           -- set e.m, e.d and tunables (e.taken = ...). An effect
--                                           -- never starts another: a spell names all its effects
--   script = "Name" | { "Name", Prop = value }  -- a moment script and its properties, or a list of
--                                              -- them; it switches the effect with self:SetActive(bool)
-- AV formulas are per tick, in t, m, d, the tunables and reads by the naming rule
-- (target.av.Health.value, global.GameHour, target:IsSneaking()). land gets e.caster, e.target,
-- e.spell, e.effect (refs), e.m and e.d. A <name>.patch.lua returns a function that edits the
-- definition from below it.
function rt.effect(def) return def end

-- rt.ref(name) is the form "File.esm:012FCD" or an editor id names, for a property that holds a form.
rt.ref = __ref

local lands = {} -- lower effect name -> its land (rt.load_effects)

-- rt.global.<Name> is a GLOB's value by editor id: the naming rule's global.<Name>.
rt.global = setmetatable({}, { __index = function(_, name) return global_value(name) end })

-- rt.hook(name, { land = function(e) end, cost = function(c) end }) adds a hook, or replaces the one
-- called `name` in its place; rt.hook(name, nil) removes it. land runs as any effect lands on
-- anyone, from any source, before the effect's own land, with its context (e.caster, e.target,
-- e.spell, e.effect, e.m, e.d, the tunables); cost runs as a spell is cast (c.caster, c.spell,
-- c.cost). Either returns false to stop that effect or refuse that cast. Hooks run in the order
-- they were added, which follows mod priority. Only inside OnGameLoaded; they last until the next
-- new game or load.
-- resist is the core Resist hook: a hostile effect's power, cut by each resistance of the target
-- up to its ResistCap. Resist Magic, then the effect's own (GetResistance); a poison's by
-- PoisonResist alone; a disease's not here (disease-resistance).
local function resist(e)
  local src = e.spell
  if not e.effect:HasTag("hostile") then return end
  if src and (src:HasTag("ignore_resist") or src:HasTag("disease")) then return end
  local av = e.target.av
  local cap = av.ResistCap.value
  local function keep(name) return 1 - math.min(av[name].value, cap) / 100 end
  if src and src:HasTag("poison") then
    e.m = e.m * keep("PoisonResist")
    return
  end
  e.m = e.m * keep("MagicResist")
  local own = e.effect:GetResistance()
  if own ~= "" and own ~= "MagicResist" then e.m = e.m * keep(own) end
end

-- CORE_HOOKS run after every mod's, so resistance has the last say, as in vanilla. rt.hook with a
-- core hook's name replaces it there; nil removes it.
local CORE_HOOKS = { { name = "Resist", land = resist } }

add_core_hooks = function()
  for i = 0, #CORE_HOOKS - 1 do
    local core = CORE_HOOKS[i]
    local def = core_set[core.name]
    if def == nil then def = core end
    if def then hooks[#hooks] = { name = core.name, land = def.land, cost = def.cost } end
  end
end

function rt.hook(name, def)
  if not game_loading then error("rt.hook outside OnGameLoaded", 2) end
  for i = 0, #CORE_HOOKS - 1 do
    if CORE_HOOKS[i].name == name then
      core_set[name] = def or false
      return
    end
  end
  for i = 0, #hooks - 1 do
    if hooks[i].name == name then
      if def then
        hooks[i] = { name = name, land = def.land, cost = def.cost }
      else
        for j = i, #hooks - 1 do hooks[j] = hooks[j + 1] end
      end
      return
    end
  end
  if def then hooks[#hooks] = { name = name, land = def.land, cost = def.cost } end
end

-- run_hooks runs each hook's `kind` on ctx: false when one stops it. A broken hook warns once and
-- is passed over.
local function run_hooks(kind, ctx)
  for i = 0, #hooks - 1 do
    local fn = hooks[i][kind]
    if fn then
      local ok, res = pcall(fn, ctx)
      if not ok then warn_once("hook " .. hooks[i].name, "hook " .. hooks[i].name .. ": " .. tostring(res)) end
      if ok and res == false then return false end
    end
  end
  return true
end

-- rt.land(lname, caster, target, spell, effect, m, d, tunables) runs the landing hooks, then the
-- effect's land: its context, or false when it does not start (worldstate.Hooks).
function rt.land(lname, caster, target, spell, effect, m, d, tunables)
  local e = { caster = caster, target = target, spell = spell, effect = effect, m = m, d = d, global = rt.global }
  for k, v in pairs(tunables) do e[k] = v end
  if not run_hooks("land", e) then return false end
  local fn = lands[lname]
  if fn and fn(e) == false then return false end
  return e
end

-- rt.cost(caster, spell, cost) runs the cost hooks: the cost, or false when the cast is refused.
function rt.cost(caster, spell, cost)
  local c = { caster = caster, spell = spell, cost = cost, global = rt.global }
  if not run_hooks("cost", c) then return false end
  return c.cost
end

-- load_defs runs every definition file in a content folder, lowest priority first per name: a full
-- file replaces what is below it, a <name>.patch.lua returns a function that edits it.
local function load_defs(folder, define)
  for _, f in ipairs(content_files(folder)) do
    local def
    for _, layer in ipairs(f.layers) do
      local chunk, err = loadfile(layer.path)
      if not chunk then
        warn(err)
      elseif not layer.patch then
        def = run(layer.path, chunk) or def
      elseif def then
        local edit = run(layer.path, chunk)
        if edit then run(layer.path, edit, def) end
      else
        warn(layer.path .. ": patches '" .. f.name .. "', which nothing below it defines")
      end
    end
    if type(def) == "table" then define(f.name, def) end
  end
end

-- rt.load_effects defines every effect the effects/ folders hold, then every spell, power and item
-- the spells/, powers/ and items/ folders hold (they name effects and spells), for the engine.
function rt.load_effects()
  lands = {}
  load_defs("effects", function(name, def)
    lands[name] = def.land
    effect_def(name, def)
  end)
  load_defs("spells", spell_def)
  load_defs("powers", power_def)
  load_defs("items", item_def)
end

-- rt.spell(def) is a spell, in a spells/<name>.lua file that returns it (the name is the file's):
--   form = "Skyrim.esm:012FCD" | editor id  -- the record it stands in for; none makes a Lua form
--   name = "Firebolt"                        -- what menus show
--   use = "charged" | "held", shape = "missile", cost = 41
--   tags = { "tier.apprentice", "enchantment" }  -- for spell-level numbers (cost, tier)
--   applies = { { "FireDamage", m = 25, d = "3s", area = 15, hits = "direct" }, ... }
-- A spell is data: it names every effect it applies, and effects hold the logic. d is "3s", "20tk"
-- (ticks) or seconds. A <name>.patch.lua returns a function that edits the definition from below.
function rt.spell(def) return def end

-- rt.power(def) is a lesser power, a power or a shout, in a powers/<name>.lua file that returns it:
--   form, name, shape                        -- as rt.spell
--   applies = {...}, cooldown = "24h"        -- one word; "24h" game hours, "15s" real seconds,
--                                            -- none for a lesser power
--   words = { { applies = {...}, cooldown = "15s" }, ... }  -- a shout's words, in order
--   cooldown_av = "Voice"                    -- the timer AV its cooldowns run on (default: its name)
--   cooldown_mult = "ShoutRecoveryMult"      -- an AV multiplying each cooldown
function rt.power(def) return def end

-- rt.item(def) says what using an item does, in an items/<name>.lua file that returns it:
--   form = "Skyrim.esm:03EADE"               -- the item's record (model, name, weight, value): required
--   use = "inventory" | "hand"               -- default: hand for a scroll, else inventory
--   applies = { { "AlchRestoreHealth", m = 50 } }  -- inventory: used up, applied to the user
--   casts = "Firebolt"                       -- hand: each cast of it uses one up, no Magicka
--   tags = { "poison" }                      -- a poison coats the held weapon instead (weapon-poison)
function rt.item(def) return def end

-- rt.faction(name, def) makes a faction at runtime, or gets the one called `name` unchanged. It is
-- game state from then on, saved whole; change it through the Faction natives. def may hold:
--   flags = {"track_crime", "ignore_trespass", ...}
--   crime = {murder =, assault =, trespass =, pickpocket =, steal_multiplier =, escape =,
--            werewolf =, arrest = bool, attack_on_detect = bool}
--   jail, follower_wait, stolen_chest, player_chest, crime_group, jail_outfit = forms
--   ranks = {"Novice", "Master"}  -- rank 0 first (Lua here is 0-based)
--   relations = {{faction =, reaction = "enemy" | "ally" | "friend" | "neutral", modifier =,
--                 mutual = true}}  -- mutual (the default) sets the other faction's side too
local FACTION_FORMS = { jail = true, follower_wait = true, stolen_chest = true, player_chest = true, crime_group = true, jail_outfit = true }
function rt.faction(name, def)
  local d = {}
  for k, v in pairs(def or {}) do d[k] = FACTION_FORMS[k] and form_of(v) or v end
  if d.relations then
    local rs = {}
    for i, r in pairs(d.relations) do rs[i] = { faction = form_of(r.faction), reaction = r.reaction, modifier = r.modifier, mutual = r.mutual } end
    d.relations = rs
  end
  return __faction(name, d)
end

-- rt.stolen_mark(item, marks) says whether a theft marks `item` stolen, over the engine's rule (a
-- unit worth more than the iStolenMarkMaxValue GMST, 5 by default; gold never): false for a mod's
-- currency, true for a cheap item a quest must track. Only inside OnGameLoaded; it lasts until the
-- next new game or load.
function rt.stolen_mark(item, marks)
  if not game_loading then error("rt.stolen_mark outside OnGameLoaded", 2) end
  __stolen_mark(form_of(item), marks)
end

-- rt.level_up_choice(name, { AV = "formula", ... }) adds or replaces a level-up choice: each formula
-- of `level` (the new level) goes onto that actor value's capacity for good. Only inside
-- OnGameLoaded; the last one wins.
function rt.level_up_choice(name, changes)
  if not game_loading then error("rt.level_up_choice outside OnGameLoaded", 2) end
  __level_up_choice(name, changes)
end

-- rt.formula(name, src) replaces one of the engine's named formulas (worldstate.FORMULAS) with a
-- string of math over its variables. Only inside OnGameLoaded; the last one wins.
function rt.formula(name, src)
  if not game_loading then error("rt.formula outside OnGameLoaded", 2) end
  __formula(name, src)
end

-- rt.zone(def) makes a volume at a ref's place and returns its ref, which hears OnTriggerEnter and
-- OnTriggerLeave like an authored trigger and goes when deleted or when its lifetime runs out:
--   rt.zone { at = ref, shape = { sphere = radius } or { box = { x, y, z } }, lifetime = seconds,
--             form = its base (for scripts, and the limit), limit = n (the oldest of this form and
--             caster go), caster = ref, spell = ref, every = seconds, burst = radius }
-- With a spell it casts on each actor inside that is hostile to the caster (every actor with no
-- caster): on entry, then every `every` seconds; with no `every` it fires once, at the first such
-- actor, on each within `burst`, and goes (a rune).
function rt.zone(def)
  if type(def.shape) ~= "table" or is_none(def.at) then error("rt.zone needs at and shape", 2) end
  def.at, def.form = form_of(def.at), def.form and form_of(def.form)
  def.caster, def.spell = def.caster and form_of(def.caster), def.spell and form_of(def.spell)
  return make_zone(def)
end

-- rt.spawn_hazard(effect) makes the hazard a Spawn Hazard effect names where its target stands, with
-- its caster, and returns its zone (None when it names none).
function rt.spawn_hazard(effect) return spawn_hazard(form_of(effect)) end

-- rt.seed_spell(owner, spell) puts a spell on a race's or an NPC_'s records' list, for every actor
-- of it; rt.unseed_spell(owner, spell) takes one off. Only inside OnGameLoaded: they last until the
-- next new game or load, like a record edit. A plugin's record edit is the better tool; they say so.
local function seed_spell(name, owner, spell, change)
  if not game_loading then error("rt." .. name .. " outside OnGameLoaded", 3) end
  warn_once(name, "rt." .. name .. ": prefer editing the RACE or NPC_ spell list (SPLO) in a plugin")
  __seed_spell(form_of(owner), form_of(spell), change)
end

function rt.seed_spell(owner, spell) seed_spell("seed_spell", owner, spell, 1) end
function rt.unseed_spell(owner, spell) seed_spell("unseed_spell", owner, spell, -1) end

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

-- rt.quest_var is a quest script member for a condition (GetVMQuestVariable): the first instance,
-- in the order they were made, that has it, as a number. nil when none has an int, float or bool.
function rt.quest_var(form, name)
  for _, inst in ipairs(ordered[form] or {}) do
    local v = inst.vars[name]
    if type(v) == "boolean" then return v and 1 or 0 end
    if type(v) == "number" then return v end
    if v ~= nil then return nil end
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
  stopped[epoch] = { real = now_real, game = now_game }
  epoch = epoch + 1
  instances = {}
  ordered = {}
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
