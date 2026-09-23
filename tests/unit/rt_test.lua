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
