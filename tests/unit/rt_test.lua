-- skymod.rt against hand-written classes shaped like converted scripts. Run by rt_test.odin on
-- a VM whose ref 0x1234 is a plain ObjectReference (no gamedb).
local rt = require('skymod.rt')

local files = {
  objectreference = [[
    local rt = require('skymod.rt')
    local C = rt.class("ObjectReference", "Form")
    C.__fn["disable"] = rt.native("ObjectReference", "Disable", false)
    C.__fn["isdisabled"] = rt.native("ObjectReference", "IsDisabled", false)
    return C
  ]],
  base = [[
    local rt = require('skymod.rt')
    local C = rt.class("Base", "ObjectReference")
    C.__fn["greet"] = function(self) return "base" end
    C.__fn["f"] = function(self) return "A" end
    return C
  ]],
  mid = [[
    local rt = require('skymod.rt')
    local C = rt.class("Mid", "Base")
    C.__fn["f"] = function(self) return "B:" .. rt.parent(self, "Mid", "F") end
    return C
  ]],
  child = [[
    local rt = require('skymod.rt')
    local C = rt.class("Child", "Mid")
    C.__vars = { ["::count_var"] = { type = "Int", default = 3 } }
    C.__autoprop["count"] = "::count_var"
    C.__states["busy"] = {}
    C.__states["busy"]["greet"] = function(self) return "busy" end
    C.__fn["f"] = function(self) return "C:" .. rt.parent(self, "Child", "F") end
    return C
  ]],
}
rt.loader = function(l)
  local src = files[l]
  if src then return load(src, "=" .. l)() end
end

local r = ref(0x1234)
local inst = rt.instance(r, "Child")

-- method lookup: class chain, then a state's table ahead of the default one
assert(rt.call(inst, "Greet") == "base", "default-state lookup up the chain")
rt.call(inst, "GotoState") -- not defined here: warns once, returns None
inst.vars["::state"] = "Busy"
assert(rt.call(inst, "GREET") == "busy", "state table wins, names fold case")
inst.vars["::state"] = ""
assert(rt.call(inst, "greet") == "base", "back to the default state")

-- a parent call starts above the CALLING class, not self's
assert(rt.call(inst, "F") == "C:B:A", "three-level parent chain")

-- properties: member default, then the plugin value over it
assert(rt.get(inst, "Count") == 3, "autoprop default")
local filled = rt.instance(ref(0x5678), "Child", { count = 7 })
assert(rt.get(filled, "count") == 7, "autoprop from plugin value")
rt.set(filled, "Count", 9)
assert(filled.vars["::count_var"] == 9, "autoprop write lands on the member")

-- natives: an instance's form is the receiver, and a plain ref reaches the same class file
rt.call(inst, "Disable")
assert(rt.call(r, "IsDisabled") == true, "native through rt.native, read back on the ref")

-- a plain ref reaches its scripts' functions (a script-typed property holds the bare form)
assert(rt.call(r, "Greet") == "base", "ref falls through to its script instance")

-- None absorbs
assert(rt.call(None, "Anything") == None, "call on None")
assert(rt.call(nil, "Anything") == None, "nil is None")

-- Papyrus `==` (build/lua-02-papyrus-eq.patch plus the metatables here and in ref.odin)
assert(inst == r and r == inst, "instance equals its form's ref, both orders")
assert("ABC" == "abc" and "ABC" ~== "abc", "== folds case, === does not")
assert(None == nil and nil == None, "None is nil")
assert(inst ~= nil and r ~= None, "a live form is not None")
assert(r ~= ref(0x5678), "different forms differ")
assert(ref(0) == None, "a null form is None")

-- None is falsy (build/lua-03-falsy-userdata.patch); refs and instances stay truthy
assert(not None, "not None")
assert((None or 5) == 5 and rawequal(None and 5, None), "and/or pick the right operand")
if None then error("None took the branch") end
assert(r and inst, "a live ref and instance are truthy")

-- casts
for _, v in ipairs({ None, 0, 0.0, "" }) do
  assert(rt.cast(v, "bool") == false, "falsy: " .. tostring(v))
end
assert(rt.cast(nil, "bool") == false, "nil is false")
assert(rt.cast(inst, "bool") == true and rt.cast("a", "bool") == true, "truthy")
assert(rt.cast(-2.7, "int") == -2, "int truncates toward zero")
assert(rt.cast("12abc", "int") == 12, "int from a leading number")
assert(rt.cast(1.5, "string") == "1.500000", "Papyrus float format")
assert(rt.cast(true, "string") == "True", "Papyrus bool format")
assert(rt.cast(r, "child") == inst, "ref to its script")
assert(rt.cast(inst, "objectreference") == inst, "instance up its chain keeps identity")
assert(rt.cast(r, "actor") == None, "an object ref is not an Actor")
assert(rt.concat("n=", 2) == "n=2", "concat converts")

-- integer math truncates toward zero
assert(rt.idiv(-7, 2) == -3 and rt.imod(-7, 2) == -1, "Papyrus idiv/imod")
assert(rt.idiv(1, 0) == 0, "divide by zero yields 0")

-- arrays: 0-based, typed defaults, never nil
local a = rt.array(3, "int")
assert(rt.alen(a) == 3 and #a == 3 and a[0] == 0, "typed zeros")
rt.aset(a, 2, 5)
assert(rt.aget(a, 2) == 5 and rt.afind(a, 5, 0) == 2 and rt.arfind(a, 0, -1) == 1, "set/get/find")
assert(rt.aget(a, 3) == None, "out of range reads None")
local objs = rt.array(2, "actor")
assert(objs[0] == None and #objs == 2, "object slots hold None, not nil")

-- hand-written classes (docs/script-api.md): short forms, typed fields, clocks, OnTick
files.lever = [[
  local rt = require('skymod.rt')
  local C = rt.class("Lever", "ObjectReference")
  C.__vars = {
    pulled = rt.bool(false), sw = rt.stopwatch(0.0), cd = rt.gametimer(1.0),
    pos = rt.vec3(1, 2, 3), TickRate = rt.float(0.5), calls = rt.int(0), fired = rt.int(0),
  }
  function C:OnActivate() self.pulled = true; self.sw = 0.0 end
  function C:OnTick()
    self.calls = self.calls + 1
    if not self.pulled or self.sw < 1 then return end
    self.fired = self.fired + 1
    self.pulled = false
  end
  function C:GetPos() return self.pos end
  return C
]]
local lever = rt.instance(ref(0x2000), "Lever")
local other = rt.instance(ref(0x2001), "Lever")
assert(lever.pulled == false and lever.TickRate == 0.5, "fields read by name")
assert(lever:GetPos().y == 2, "a method defined with `function C:Name()`")
assert(lever:IsDisabled() == false, "a native through `self:Name()`")
lever.pos.x = 9
assert(other.pos.x == 1, "each instance gets its own vec3")
assert(not pcall(function() lever.pulld = true end), "a write to an undeclared field errors")

rt.event(lever, "OnActivate")
for _ = 1, 120 do
  rt.advance(1 / 60, 0.01)
  rt.tick(1 / 60)
end
assert(lever.calls == 4, "TickRate 0.5 runs OnTick every 30 ticks")
assert(lever.fired == 1 and not lever.pulled, "fires once the stopwatch passes 1 s")
assert(math.abs(lever.sw - 2) < 1e-9 and math.abs(lever.cd - -0.2) < 1e-9, "clocks move every tick")
other.sw = nil
rt.advance(1 / 60, 0)
assert(other.sw == None and lever.sw > 2, "a clock set to None stops, the others keep moving")
local seen = {}
for k, v in pairs(lever.vars) do seen[k] = v end
assert(seen.sw == lever.sw and seen.pulled == false and seen.TickRate == 0.5, "pairs sees a clock as its float, beside the other members")
other.cd = 0.0
assert(other.cd == 0.0, "a clock reads back exactly what was written, in the tick of the write")
other.cd = "x"
assert(other.cd == "x", "a non-number in a clock is kept as it is")
rt.restore_var(ref(0x2001), "lever", "cd", 3.25)
assert(other.cd == 3.25, "a restored clock reads its saved value")

local saved = {}
rt.save_vars(function(form, _, name, value, n)
  if name and form == ref(0x2000) then saved[name] = { value = value, n = n } end
end)
assert(saved.pos.n == 3 and saved.pos.value[0] == 9, "a vec3 saves as three floats")
assert(saved.TickRate == nil and saved.fired.value == 1, "only changed fields are saved")
rt.restore_var(ref(0x2000), "lever", "pos", { 4, 5, 6 })
assert(lever:GetPos().x == 4 and lever.pos.z == 6, "a saved vec3 comes back as a vec3")

-- names: converted members and properties by their Papyrus names, errors for the rest
assert(inst.Count == 3 and inst.count == 3, "a property reads through its backer, any case")
inst.Count = 5
assert(inst.vars["::count_var"] == 5, "and writes through it")
assert(not pcall(function() return lever.pulld end), "a read of an unknown name errors")
assert(not pcall(function() lever.TickRate = 1 end), "TickRate is fixed")
assert(rawequal(None.anything, None) and not None.anything, "a read on None is None")
assert(rawequal(None:Anything(), None), "a call on None is None")
None.anything = 5 -- a write on None is dropped, as in Papyrus
assert(rawequal(None.anything, None), "a write on None is dropped")
assert(lever:IsAnimRunning("x") == false, "an instance reaches natives its class files lack")

-- a bare ref reaches the fields of the scripts on it
assert(ref(0x2000).fired == 1, "field read through the ref")
ref(0x2000).fired = 7
assert(lever.fired == 7, "field write through the ref")
assert(not pcall(function() return ref(0x2000).nothing end), "unknown name on a ref errors")

-- auto state: entered at creation, without OnBeginState; rt.state adds handlers to a state
files.door = [[
  local rt = require('skymod.rt')
  local C = rt.class("Door", "ObjectReference")
  C.__vars = { began = rt.bool(false) }
  C.__autostate = "Waiting"
  local Waiting = rt.state(C, "Waiting")
  function Waiting:OnBeginState() self.began = true end
  function Waiting:Knock() return "waiting" end
  return C
]]
local door = rt.instance(ref(0x2004), "Door")
assert(door.vars["::state"] == "Waiting" and not door.began, "starts in its auto state, no OnBeginState")
assert(door:Knock() == "waiting", "a handler added with rt.state")

-- sequences: ordered stages that save by name
files.boat = [[
  local rt = require('skymod.rt')
  local C = rt.class("Boat", "ObjectReference")
  C.Stage = rt.sequence("Docked", "Sailing", "Arrived")
  C.__vars = { stage = C.Stage.Docked }
  return C
]]
local boat = rt.instance(ref(0x2005), "Boat")
local S = boat.class.Stage
assert(boat.stage == S.Docked and S.Docked < S.Sailing and S.Arrived >= S.Sailing, "stages compare by position")
boat.stage = S.Arrived
local stages = {}
rt.save_vars(function(form, _, name, value) if name and form == ref(0x2005) then stages[name] = value end end)
assert(stages.stage == "Arrived", "a stage saves as its name")
rt.restore_var(ref(0x2005), "boat", "stage", "Sailing")
assert(boat.stage == S.Sailing, "and restores to the same stage")
rt.restore_var(ref(0x2005), "boat", "stage", "Sunk")
assert(boat.stage == S.Docked, "an unknown saved stage falls back to the first")

-- a bare ref: its scripts' functions before its engine class; a field two scripts share is an error
files.second = [[
  local rt = require('skymod.rt')
  local C = rt.class("Second", "ObjectReference")
  C.__vars = { fired = rt.int(3) }
  return C
]]
rt.instance(ref(0x2000), "Second")
assert(not pcall(function() return ref(0x2000).fired end), "a field on two scripts is ambiguous")
assert(ref(0x2004):Knock() == "waiting", "a bare ref reaches its script's state function")

-- a native's call on None returns that native's zero
assert(None:IsDisabled() == false and None:GetScale() + 1 == 1.0, "None calls give the type's zero")

-- a property with get/set functions, by name
files.valued = [[
  local rt = require('skymod.rt')
  local C = rt.class("Valued", "ObjectReference")
  C.__vars = { ["::raw"] = rt.int(2) }
  C.__fn["__propget_amount"] = function(self) return self.vars["::raw"] * 10 end
  C.__fn["__propset_amount"] = function(self, v) self.vars["::raw"] = v // 10 end
  return C
]]
local valued = rt.instance(ref(0x2006), "Valued")
assert(valued.Amount == 20, "a full property reads through its getter")
valued.Amount = 50
assert(valued.vars["::raw"] == 5, "and writes through its setter")

-- stages step by position; past the end warns and stays
boat.stage = S.Docked
assert(boat.stage + 1 == S.Sailing and 1 + S.Sailing == S.Arrived, "stage + n")
assert(S.Arrived + 1 == S.Arrived, "past the end stays")

-- arguments: script functions declare parameters; natives take their CK defaults, or named ones
files.launcher = [[
  local rt = require('skymod.rt')
  local C = rt.class("Launcher", "ObjectReference")
  C.__vars = {}
  function C:Launch(target, speed, loud) return tostring(target) .. "/" .. speed .. "/" .. tostring(loud) end
  rt.params(C, "Launch", { { "target" }, { "speed", 1.5 }, { "loud", false } })
  return C
]]
local launcher = rt.instance(ref(0x2007), "Launcher")
assert(launcher:Launch("t") == "t/1.5/false", "defaults fill the missing arguments")
assert(launcher:Launch{ target = "t", loud = true } == "t/1.5/true", "named arguments")
assert(not pcall(function() launcher:Launch{ speed = 2 } end), "a required argument is required")
assert(not pcall(function() launcher:Launch{ target = "t", sped = 2 } end), "an unknown name is an error")
-- a converted script function takes its CK defaults from the generated table, also on a subclass
files.arenascript = [[
  local rt = require('skymod.rt')
  local C = rt.class("ArenaScript", "Quest")
  C.__vars = {}
  C.__fn["picknextfight"] = function(self, offset) return offset end
  return C
]]
files.arenachild = [[
  local rt = require('skymod.rt')
  local C = rt.class("ArenaChild", "ArenaScript")
  C.__vars = {}
  return C
]]
assert(rt.instance(ref(0x2101), "ArenaScript"):PickNextFight() == 0, "a converted function's default")
assert(rt.instance(ref(0x2102), "ArenaChild"):PickNextFight() == 0, "the default through the class chain")
local plain = ref(0x3000)
plain:Disable()
assert(plain:IsDisabled() == true, "a native with every argument defaulted")

-- round 3: None passed on purpose is an argument; GetState starts empty; a name on two scripts
-- or on both a member and a function is an error; rt.call on None returns the native's zero
assert(launcher:Launch(None) == "None/1.5/false", "None is an argument, not a missing one")
assert(valued.vars["::state"] == "", "the empty state before any GotoState")
assert(rawequal(rt.call(None, "GetScale"), 0.0), "rt.call on None gives the native's zero")
files.clash = [[
  local rt = require('skymod.rt')
  local C = rt.class("Clash", "ObjectReference")
  C.__vars = { ["phase"] = { type = "Int", default = 1 } }
  C.__fn["phase"] = function(self) return 2 end
  return C
]]
local clash = rt.instance(ref(0x2008), "Clash")
assert(not pcall(function() return clash.Phase end), "a member and a function of one name is an error")
files.third = [[
  local rt = require('skymod.rt')
  local C = rt.class("Third", "ObjectReference")
  C.__vars = {}
  function C:Knock() return "third" end
  return C
]]
rt.instance(ref(0x2004), "Third")
assert(not pcall(function() return ref(0x2004):Knock() end), "two scripts' different functions are ambiguous")

-- round 4: a field typed as a script reads as that script's instance; a bare number in __vars
-- is an error that names the field; rt.guard runs code under the budget
files.holder = [[
  local rt = require('skymod.rt')
  local C = rt.class("Holder", "ObjectReference")
  C.__vars = { door = rt.form("Door"), plainref = rt.form("ObjectReference") }
  return C
]]
local holder = rt.instance(ref(0x2009), "Holder")
holder.door = ref(0x2004)
holder.plainref = ref(0x2004)
assert(rawequal(holder.door, door), "a script-typed field reads as the instance")
assert(rawequal(holder.plainref, ref(0x2004)), "an engine-typed field stays the ref")
files.badvars = [[
  local rt = require('skymod.rt')
  local C = rt.class("BadVars", "ObjectReference")
  C.__vars = { TickRate = 10.0 }
  return C
]]
local okbad, errbad = pcall(rt.instance, ref(0x200A), "BadVars")
assert(not okbad and tostring(errbad):find("__vars.TickRate"), "a bare number in __vars names the field")
assert(rt.guard("test", function() return 1 end) and not rt.guard("test", function() while true do end end), "rt.guard budgets")

-- animation events reach only the forms that registered for them on the sender
files.bell = [[
  local rt = require('skymod.rt')
  local C = rt.class("Bell", "ObjectReference")
  C.__vars = { heard = rt.int(0) }
  function C:OnAnimationEvent(src, name) self.heard = self.heard + 1 end
  return C
]]
local bell = rt.instance(ref(0x2103), "Bell")
rt.anim_event(ref(0x2103), "Ring")
rt.drain()
assert(bell.heard == 0, "no registration, no event")
bell:RegisterForAnimationEvent(ref(0x2103), "Ring")
rt.anim_event(ref(0x2103), "ring")
rt.drain()
assert(bell.heard == 1, "a registered event arrives, names fold case")
bell:UnregisterForAnimationEvent(ref(0x2103), "Ring")
rt.anim_event(ref(0x2103), "Ring")
rt.drain()
assert(bell.heard == 1, "unregistered again")

rt.reset()
rt.advance(1 / 60, 0)
rt.tick(1 / 60)
assert(lever.calls == 4 and lever.sw > 2 and lever.sw < 2.02, "a reset drops ticking and clocked instances")
