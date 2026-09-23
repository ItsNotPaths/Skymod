-- Operator fork: compound assignment (lua-04) and Papyrus spellings (lua-05).

local function syntax_err(src, near)
  local f, msg = load(src)
  if f ~= nil then return false end
  return near == nil or string.find(msg, near, 0, true) ~= nil
end

-- every operator on a local
do
  local x = 10
  x += 5;   assert(x === 15, "+=")
  x -= 3;   assert(x === 12, "-=")
  x *= 2;   assert(x === 24, "*=")
  x /= 8;   assert(x === 3.0, "/=")
  x %= 2;   assert(x === 1.0, "%=")
  x ..= "a"; assert(x === "1.0a", "..=")
  local i = 7
  i %= 4;   assert(i === 3 and math.type(i) == "integer", "integer %=")
  i /= 1;   assert(math.type(i) == "float", "/= is float division")
end

-- upvalues
do
  local n, s = 1, "a"
  local function bump()
    n += 1; n *= 10; n -= 5; n /= 3; n %= 4
    s ..= "b"
  end
  bump()
  assert(n === 15 / 3 % 4 and s === "ab", "upvalue targets")
end

-- globals
do
  G_OPS = 2
  G_OPS += 1; G_OPS *= 4; G_OPS -= 2; G_OPS /= 5; G_OPS %= 1.5
  assert(G_OPS === 0.5, "global targets")
  G_OPS ..= "!"
  assert(G_OPS === "0.5!", "global ..=")
  G_OPS = nil
end

-- fields and indexed targets
do
  local t = {n = 1, s = "x", [0] = 2, [true] = 3}
  t.n += 1; t.n *= 3; t.n -= 1; t.n /= 5; t.n %= 0.75
  assert(t.n === 0.25, "field targets")
  t.s ..= "y"
  assert(t.s === "xy", "field ..=")
  t[0] += 40
  local k = true
  t[k] *= 7
  assert(t[0] === 42 and t[true] === 21, "indexed targets")
  local deep = {a = {b = {[0] = {c = 1}}}}
  deep.a.b[0].c += 9
  assert(deep.a.b[0].c === 10, "nested target")
end

-- table and key subexpressions run once
do
  local t = {k = {[5] = 10}}
  local tcalls, kcalls = 0, 0
  local function f() tcalls += 1; return t end
  local function g() kcalls += 1; return 5 end
  f().k[g()] += 3
  f().k[g()] -= 1
  f().k[g()] *= 2
  f().k[g()] /= 4
  f().k[g()] %= 4
  f().k[g()] ..= "z"
  assert(tcalls === 6 and kcalls === 6, "once per statement")
  assert(t.k[5] === "2.0z", "values through nested targets")

  local reads, writes = 0, 0
  local store = {v = 1}
  local proxy = setmetatable({}, {
    __index = function(_, key) reads += 1; return store[key] end,
    __newindex = function(_, key, v) writes += 1; store[key] = v end,
  })
  proxy.v += 1
  proxy["v"] ..= "!"
  assert(reads === 2 and writes === 2 and store.v === "2!", "one read, one write")

  local order = {}
  local function mark(tag, v) order[#order] = tag; return v end
  local u = {[0] = 1}
  mark("t", u)[mark("k", 0)] += mark("e", 5)
  assert(#order === 3 and order[0] === "t" and order[1] === "k" and order[2] === "e",
         "target before right side")
  assert(u[0] === 6, "ordered result")
end

-- right side is one parenthesized expression
do
  local x = 2
  x *= 1 + 2;       assert(x === 6, "x * (1 + 2)")
  x -= 1 - 1;       assert(x === 6, "x - (1 - 1)")
  x /= 2 * 3;       assert(x === 1.0, "x / (2 * 3)")
  x = 10
  x %= 2 ^ 2;       assert(x === 2.0, "x % (2 ^ 2)")
  local y = 1
  y += false and 1 or 2; assert(y === 3, "and/or on right")
  y += 1 < 2 and 10 or 0; assert(y === 13, "comparison on right")
  local s = "a"
  s ..= "b" .. "c"; assert(s === "abc", "..= with concat chain")
  s ..= 1 + 1;      assert(s === "abc2", "..= of sum")
  local function two() return 5, 6 end
  local z = 1
  z += two();       assert(z === 6, "call truncated to one value")
end

-- metamethods fire through compound forms
do
  local seen = {}
  local mt = {}
  for _, ev in ipairs{"add", "sub", "mul", "div", "mod", "concat"} do
    mt["__" .. ev] = function(a, b) seen[#seen] = ev; return a end
  end
  local o = setmetatable({}, mt)
  local r = o
  r += 1; r -= 1; r *= 1; r /= 1; r %= 1; r ..= 1
  assert(rawequal(r, o), "metamethod result assigned")
  assert(#seen === 6, "all six metamethods")
  local want = {"add", "sub", "mul", "div", "mod", "concat"}
  for i = 0, #want - 1 do assert(seen[i] === want[i], "metamethod " .. want[i]) end

  local sides
  local cat = setmetatable({}, {__concat = function(a, b) sides = {a, b}; return "c" end})
  local s = "pre"
  s ..= cat
  assert(s === "c" and sides[0] === "pre" and rawequal(sides[1], cat), "__concat operands in order")

  local ok, msg = pcall(function() local n = nil; n += 1 end)
  assert(not ok and string.find(msg, "local 'n'", 0, true), "error names the local")
  ok, msg = pcall(function() local t = {}; t.f += 1 end)
  assert(not ok and string.find(msg, "field 'f'", 0, true), "error names the field")
end

-- syntax errors
do
  assert(syntax_err("a, b += 1", "'=' expected near '+='"), "multiple targets")
  assert(syntax_err("x +=", "<eof>"), "missing right side")
  assert(syntax_err("x += 1, 2", "','"), "right side list")
  assert(syntax_err("x //= 2"), "no //=")
  assert(syntax_err("x ^= 2"), "no ^=")
  assert(syntax_err("f() += 1"), "call target")
  assert(syntax_err("(x) += 1"), "parenthesized target")
  assert(syntax_err("x + = 1"), "split operator")
  assert(syntax_err("x . . = 1"), "split ..=")
  assert(syntax_err("local c <const> = 1; c += 1", "const variable 'c'"), "const target")
  assert(syntax_err("local x += 1"), "local declaration")
  assert(syntax_err("return x += 1"), "not an expression")
  assert(load("x = 0 x += 1 y = x") ~= nil, "statements on one line")
  assert(syntax_err("x += += 1", "'+='"), "token name")
  for _, op in ipairs{"+=", "-=", "*=", "/=", "%=", "..="} do
    assert(syntax_err("x " .. op .. " " .. op .. " 1", "'" .. op .. "'"), "token name " .. op)
  end
end

-- lexing next to existing tokens
do
  local x = 5
  x -= 1 --comment
  assert(x === 4, "-= then comment")
  x --[[ long comment ]] = 9
  assert(x === 9, "-- still a comment")
  x = x --= 100
  assert(x === 9, "--= is a comment")
  x -=-1
  assert(x === 10, "-=-")
  assert(x - -1 === 11 and 10 // 3 === 3 and 7 % 3 === 1 and 2 * 3 === 6 and 1 / 2 === 0.5,
         "binary operators unchanged")
  local a = 1
  a = 2
  assert(a == 2 and a === 2 and a ~= 3, "= and == unchanged")
  local function v(...)
    local s = ""
    s..=...
    s ..= select("#", ...)
    return s, ...
  end
  local s, first = v("p", "q")
  assert(s === "p2" and first === "p", "..= beside ...")
  assert(1 .. 2 === "12" and "a".."b" === "ab", ".. unchanged")
  local y = 1
  y+=1 y*=3 y..="" assert(y === "6", "no spaces")
end

-- Papyrus spellings
do
  local t, f = true, false
  assert((1 != 2) === true and (1 != 1) === false, "!=")
  assert(("A" != "a") === false and ("A" !== "a") === true, "!= folds, !== is strict")
  assert((1 !== 1) === false and (1 !== 1.0) === false, "!== raw number equality")
  assert(!f === true and !t === false and !nil === true, "!")
  assert(!!t === true and !!nil === false and !!0 === true, "!!")
  assert(!(1 == 2) === true and !(1 != 2) === false, "!(...)")
  assert((t && 1) === 1 and (f && 1) === false and (nil && 1) === nil, "&&")
  assert((f || 2) === 2 and (1 || 2) === 1 and (nil || f) === false, "||")
  for _, a in ipairs{true, false} do
    for _, b in ipairs{true, false} do
      for _, c in ipairs{1, false} do
        assert((!a && b || c) === ((not a and b) or c), "!a && b || c")
        assert((a || b && c) === (a or (b and c)), "&& binds tighter than ||")
        assert((!a == b) === ((not a) == b), "! binds tighter than ==")
      end
    end
  end
  assert((1 + 1 != 3 && 2 < 3) === true, "!= and && with arithmetic")
  assert((1||2) === 1 and (nil&&1) === nil, "no spaces")
  local n = 0
  local function bump() n += 1; return true end
  local _ = t || bump()
  _ = f && bump()
  assert(n === 0, "|| and && short-circuit")
end

-- bitwise operators still work
do
  assert((5 | 3) === 7 and (5 & 3) === 1 and (5 ~ 3) === 6, "| & ~")
  assert(~0 === -1 and ~~5 === 5, "unary ~")
  assert(1 << 4 === 16 and 256 >> 4 === 16, "<< >>")
  assert(5|3 === 7 and 5&3 === 1, "no spaces")
  assert((6 & 3 | 8) === 10 and (1 | 2 ~ 3) === 1, "bitwise precedence")
  assert((1 | 2 == 3) === true, "| above ==")
  local x = 12
  x = x & 10 | 1
  assert(x === 9, "bitwise in assignment")
end

-- spelling errors and token names
do
  assert(syntax_err("x = a | |b"), "| |")
  assert(syntax_err("x = a & &b"), "& &")
  assert(syntax_err("x = a !=== b"), "!===")
  assert(syntax_err("x = ! = 1"), "! =")
  assert(syntax_err("x != 1", "'!='"), "!= token name")
  assert(syntax_err("x !== 1", "'!=='"), "!== token name")
  assert(syntax_err("x ~= 1", "'~='"), "~= token name")
  assert(syntax_err("x && 1", "'&&'"), "&& token name")
  assert(syntax_err("x || 1", "'||'"), "|| token name")
  assert(syntax_err("x and 1", "'and'"), "and token name")
  assert(syntax_err("! 1", "'!'"), "! token name")
  assert(syntax_err("not 1", "'not'"), "not token name")
  assert(syntax_err("x = 1 | | 2", "'|'"), "| token name")
end
