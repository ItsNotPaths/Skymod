-- Papyrus equality fork: '==' folds ASCII case and asks '__eq' across types; '===' is rawequal.

local calls = 0
local last_a, last_b
local function eqmt(result)
  return {__eq = function(a, b)
    calls = calls + 1
    last_a, last_b = a, b
    return result
  end}
end

local function yes() return setmetatable({}, eqmt(true)) end
local function no() return setmetatable({}, eqmt(false)) end

local function syntax_err(src, near)
  local f, msg = load(src)
  if f ~= nil then return false end
  return near == nil or string.find(msg, near, 0, true) ~= nil
end

-- string folding
do
  local up, low, mixed = "ABC", "abc", "aBc"
  assert(up == low and low == up and mixed == up, "case fold")
  assert(not (up ~= low), "~= folds")
  assert(up ~= "abcd" and "ab" ~= up, "different lengths")
  assert("" == "" and "" ~= "a" and not ("" == " "), "empty strings")
  assert("\xC4" ~= "\xE4", "non-ASCII bytes are exact")
  assert("A\xC4" == "a\xC4", "ASCII folds beside non-ASCII")
  assert("@" ~= "`" and "[" ~= "{" and "Z" == "z" and "A" == "a", "only A-Z fold")
  assert("1" ~= 1, "string is not number")
  local long_up = string.rep("HELLO WORLD ", 5)
  local long_low = string.rep("hello world ", 5)
  assert(#long_up > 40, "long strings")
  assert(long_up == long_low and not (long_up ~= long_low), "long fold")
  assert(long_up ~= long_low .. "x", "long different lengths")
  assert(string.rep("a", 40) == string.rep("A", 40), "short at limit")
  assert(string.rep("a", 41) == string.rep("A", 41), "long at limit")
  local s = "HeLLo"
  assert(s == "hello" and "HELLO" == s and s ~= "help", "EQK string fold")
  assert(("x"):upper() == "x", "runtime string fold")
end

-- '__eq' across types, both orders
do
  local t = yes()
  local others = {0, 1, 1.5, "abc", true, false, {}, io.stdout}
  for i = 0, #others - 1 do
    local v = others[i]
    calls = 0
    assert(t == v, "tbl == " .. tostring(v))
    assert(last_a === t and last_b === v, "args tbl, v")
    assert(v == t, tostring(v) .. " == tbl")
    assert(last_a === v and last_b === t, "args v, tbl")
    assert(not (t ~= v) and not (v ~= t), "~= negates")
    assert(calls == 4, "one call each")
  end
  local nilv = nil
  calls = 0
  assert(t == nilv and nilv == t and calls == 2, "nil in registers")
  local f = no()
  calls = 0
  assert(f ~= 1 and 1 ~= f and not (f == "x") and calls == 3, "false result")
end

-- '__eq' on constant forms (EQK / EQI)
do
  local t = yes()
  calls = 0
  assert(t == nil and t == "abc" and t == 1 and t == 1.5 and t == true, "EQK/EQI call __eq")
  assert(t == 1000000 and t == -1 and t == false, "large and negative constants")
  assert(not (t ~= nil), "~= nil calls __eq")
  assert(calls == 9, "constant forms call count")
  assert(nil == t and "abc" == t and 1 == t and 1.5 == t, "constant first")
  assert(last_a === 1.5 and last_b === t, "constant first keeps order")
  assert(t == 2 and math.type(last_b) == "integer", "EQI integer literal")
  assert(t == 2.0 and math.type(last_b) == "float", "EQI float literal")
  local f = no()
  assert(f ~= nil and not (f == nil) and f ~= "abc" and f ~= 1, "false result on constants")
  local plain = {}
  assert(plain ~= nil and plain ~= 1 and plain ~= "abc" and not (plain == 1.5), "no __eq, constants")
  assert(1 == 1.0 and 2 ~= 2.5 and "ABC" == "abc", "constant vs constant")
  local n = 3
  assert(n == 3 and n == 3.0 and n ~= 4 and n ~= "3" and n ~= nil, "plain numbers")
end

-- metatable order: first operand, then second
do
  local seen
  local a = setmetatable({}, {__eq = function() seen = "A"; return true end})
  local b = setmetatable({}, {__eq = function() seen = "B"; return true end})
  assert(a == b and seen == "A", "first operand wins")
  assert(b == a and seen == "B", "first operand wins, swapped")
  assert(1 == b and seen == "B", "second when first has none")
  assert(nil == a and seen == "A", "second when first is nil")
end

-- non-boolean results use truthiness
do
  local zero = setmetatable({}, {__eq = function() return 0 end})
  local str = setmetatable({}, {__eq = function() return "" end})
  local none = setmetatable({}, {__eq = function() end})
  assert(zero == 1 and str == nil and not (none == 1), "truthiness")
  assert(zero ~= nil == false and none ~= nil, "~= truthiness")
end

-- same object never calls '__eq'
do
  local t = no()
  calls = 0
  assert(t == t and not (t ~= t) and calls == 0, "identity")
end

-- '__eq' on the shared string and number metatables
do
  local smt = getmetatable("")
  smt.__eq = function(a, b) return #tostring(a) == #tostring(b) end
  assert("ab" == "cd" and "ab" ~= "abc", "string metatable __eq")
  smt.__eq = nil
  assert("ab" ~= "cd", "string metatable __eq removed")
  debug.setmetatable(0, {__eq = function() return true end})
  local x = 1
  assert(x == 2 and x == 2.5 and x == "y" and 5 == x, "number metatable __eq")
  assert(x ~== 2, "=== ignores number metatable")
  debug.setmetatable(0, nil)
  assert(x ~= 2, "number metatable removed")
end

-- full userdata with '__eq'
do
  local fmt = getmetatable(io.stdout)
  fmt.__eq = function() return true end
  local t = {}
  assert(io.stdout == nil and nil == io.stdout and io.stdout == 1 and t == io.stdout, "userdata __eq")
  assert(io.stdout ~== nil and not (io.stdout === t), "=== ignores userdata __eq")
  fmt.__eq = nil
  assert(io.stdout ~= nil and io.stdout ~= t, "userdata __eq removed")
end

-- '__eq' may yield from every form
do
  local t = setmetatable({}, {__eq = function(a, b)
    coroutine.yield("in eq")
    return b ~== "no"
  end})
  local co = coroutine.wrap(function()
    local other = {}
    return t == other, t == nil, t == 1, t == 1.5, t ~= "x", t == "no", nil == t
  end)
  for _ = 0, 6 do assert(co() == "in eq", "yield") end
  local r = table.pack(co())
  assert(r.n == 7, "yield results count")
  assert(r[0] and r[1] and r[2] and r[3] and not r[4] and not r[5] and r[6], "yield results")
end

-- '__eq' is named in debug info for every form
do
  local name
  local t = setmetatable({}, {__eq = function()
    local info = debug.getinfo(1, "n")
    name = info.namewhat .. ":" .. tostring(info.name)
    return true
  end})
  local other = {}
  assert(t == other and name == "metamethod:eq", "OP_EQ name")
  name = nil
  assert(t == "abc" and name == "metamethod:eq", "OP_EQK name")
  name = nil
  assert(t == 7 and name == "metamethod:eq", "OP_EQI name")
end

-- '===' and '~==' never call metamethods
do
  local t, u = yes(), yes()
  local nilv, one = nil, 1
  calls = 0
  assert(not (t === u) and t ~== u and t === t and not (t ~== t), "tables")
  assert(t ~== nil and t ~== nilv and nil ~== t and t ~== 1 and 1 ~== t, "constants")
  assert(t ~== 1.5 and t ~== "abc" and t ~== true and t ~== one, "more constants")
  assert(not (t === nil) and not (t === 1) and not (t === "abc"), "=== constants")
  assert(calls == 0, "no metamethod calls")
end

-- '===' is rawequal
do
  local s = "ABC"
  assert(not ("ABC" === "abc") and "ABC" ~== "abc" and s ~== "abc" and s === "ABC", "byte exact")
  local long_up = string.rep("X", 50)
  local long_low = string.rep("x", 50)
  assert(long_up ~== long_low and long_up === string.rep("X", 50), "long byte exact")
  assert(1 === 1.0 and 1.0 === 1 and not (1 ~== 1.0), "int/float")
  local i, f = 3, 3.0
  assert(i === f and i === 3.0 and f === 3 and f ~== 3.5 and i ~== "3", "int/float registers")
  assert(nil === nil and false === false and false ~== nil, "nil/false")
end

-- NaN
do
  local nan = 0 / 0
  assert(not (nan == nan) and nan ~= nan, "NaN ==")
  assert(not (nan === nan) and nan ~== nan, "NaN ===")
  assert(not rawequal(nan, nan), "NaN rawequal")
  local t = {}
  assert(nan ~= t and nan ~= 1 and nan ~== 1, "NaN vs others")
end

-- rawequal is exact
do
  assert(not rawequal("ABC", "abc") and rawequal("abc", "abc"), "rawequal strings")
  assert(rawequal(1, 1.0), "rawequal numbers")
  local t, u = yes(), yes()
  calls = 0
  assert(not rawequal(t, u) and not rawequal(t, nil) and calls == 0, "rawequal no __eq")
end

-- table keys and constants stay case-sensitive
do
  local t = {ABC = 1}
  assert(t.ABC == 1 and t.abc == nil and t["abc"] == nil, "keys case-sensitive")
  t.abc = 2
  assert(t.ABC == 1 and t.abc == 2, "two keys")
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  assert(n == 2, "two entries")
  local a, b = "Key", "KEY"
  assert(a === "Key" and b === "KEY", "constants not merged")
end

-- lexing
do
  assert(load("return 1===1")() == true, "a===b")
  assert(load("return 1 ~== 2")() == true, "a ~== b")
  assert(load("return 1~==1")() == false, "a~==b")
  assert(load("return 1==1")() == true, "a==b")
  assert(load("return 1~=2")() == true, "a~=b")
  assert(load("local a=1 a=a+1 return a")() == 2, "a=b")
  assert(load("return 5 ~ 3")() == 6, "~ still xor")
  assert(load("return ~0")() == -1, "~ still bnot")
  assert(load("return 'a'=='A'")() == true, "== on literals")
  assert(load("local s=[==[x]==] return s")() == "x", "long brackets")
  assert(syntax_err("x = ="), "x = =")
  assert(syntax_err("return 1 ==== 1"), "====")
  assert(syntax_err("return 1 ~=== 1"), "~===")
  assert(syntax_err("return 1 = = 1"), "= =")
  assert(syntax_err("return 1 ~ == 1"), "~ ==")
  assert(syntax_err("x === 1", "'==='"), "=== token name")
  assert(syntax_err("x ~== 1", "'~=='"), "~== token name")
  assert(syntax_err("x == 1", "'=='"), "== token name")
  assert(syntax_err("x ~= 1", "'~='"), "~= token name")
  assert(syntax_err("x << 1", "'<<'"), "<< token name")
  assert(syntax_err("x >> 1", "'>>'"), ">> token name")
  assert(syntax_err("x :: 1", "'::'"), ":: token name")
  assert(syntax_err("return 1 +", "<eof>"), "<eof> token name")
end

-- precedence
do
  assert((1 === 1 and 2 === 2) == true, "=== above and")
  assert((1 === 2 or 3 === 3) == true, "=== above or")
  assert((not 1 === 2) == false, "not above ===")
  assert(("a" .. "b" === "ab") == true, ".. above ===")
  assert(("AB" === "a" .. "b") == false, "=== raw after ..")
  assert(("AB" == "a" .. "b") == true, "== soft after ..")
  assert((1 + 1 === 2) == true, "+ above ===")
  assert((false === false == true) == true, "left assoc with ==")
  assert((1 < 2 === true) == true, "left assoc with <")
  assert((nil === nil and "x" or "y") == "x", "and/or around ===")
  assert((1 ~== 1 or "z") == "z", "~== with or")
end
