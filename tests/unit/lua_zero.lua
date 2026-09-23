-- 0-based Lua fork: every sequence/string position starts at 0.

local function isborder(t, n)
  if n == 0 then return rawget(t, 0) == nil end
  return rawget(t, n - 1) ~= nil and rawget(t, n) == nil
end

local function same(t, list)
  for i = 0, #list - 1 do
    if t[i] ~= list[i] then return false end
  end
  return #t == #list
end

local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

local function errs(pat, f, ...)
  local ok, msg = pcall(f, ...)
  return not ok and string.find(tostring(msg), pat, 0, true) ~= nil
end

-- empty table and key 0
do
  local t = {}
  assert(#t == 0, "empty len")
  assert(next(t) == nil, "empty next")
  t[0] = "a"
  assert(#t == 1, "t[0] alone has len 1")
  t[1] = "b"
  assert(#t == 2, "0,1 len 2")
  t[0] = nil
  assert(isborder(t, #t), "border after removing key 0")
  assert(#t == 0 or #t == 2, "len after removing key 0")
end

-- constructors
do
  local t = {10, 20, 30}
  assert(t[0] == 10 and t[1] == 20 and t[2] == 30, "constructor keys")
  assert(t[3] == nil and t[-1] == nil, "constructor bounds")
  assert(#t == 3, "constructor len")

  local function three() return "x", "y", "z" end
  local function pack(...) return {...} end
  local v = pack(1, 2, 3)
  assert(v[0] == 1 and v[2] == 3 and #v == 3, "{...}")
  assert(#pack() == 0 and pack()[0] == nil, "{...} empty")

  local m = {three()}
  assert(m[0] == "x" and m[2] == "z" and #m == 3, "{f()}")
  local m2 = {0, three()}
  assert(m2[0] == 0 and m2[1] == "x" and m2[3] == "z" and #m2 == 4, "{a, f()}")
  local m3 = {three(), 9}
  assert(m3[0] == "x" and m3[1] == 9 and #m3 == 2, "{f(), a} truncates")

  local mixed = {1, 2, x = 3, [10] = 4, 5}
  assert(mixed[0] == 1 and mixed[1] == 2 and mixed[2] == 5, "mixed list")
  assert(mixed.x == 3 and mixed[10] == 4, "mixed hash")
  assert(#mixed == 3, "mixed len")

  -- more items than one SETLIST flush (50), with and without multret tail
  local parts = {}
  for i = 0, 299 do parts[#parts] = tostring(i) end
  local big = load("return {" .. table.concat(parts, ",") .. "}")()
  assert(#big == 300, "big constructor len")
  for i = 0, 299 do assert(big[i] == i, "big constructor key " .. i) end
  local bigm = load("local f = ... return {" .. table.concat(parts, ",") .. ", f()}")(three)
  assert(#bigm == 303 and bigm[299] == 299 and bigm[300] == "x" and bigm[302] == "z", "big constructor multret")
end

-- holes, negative keys, float keys
do
  local t = {1, nil, 3}
  assert(isborder(t, #t), "hole border")
  t = {}
  t[-1] = "neg"
  t[-5] = "neg5"
  assert(#t == 0, "negative keys are not a sequence")
  t[0] = "z"
  assert(#t == 1 and t[-1] == "neg", "negative keys kept")

  t = {}
  t[1.0] = "one"
  assert(t[1] == "one" and math.type(next(t)) == "integer", "float key normalised")
  t[0.0] = "zero"
  assert(t[0] == "zero" and #t == 2, "float 0.0")
  t[-0.0] = "negzero"
  assert(t[0] == "negzero", "-0.0 is key 0")
  t[0.5] = "half"
  assert(t[0.5] == "half" and #t == 2, "non-integral float key")
  assert(t[2 ^ 53] == nil, "huge float absent")
end

-- growth far past the array part, shrink, regrow
do
  local t = {}
  for i = 0, 10000 do t[i] = i * 2 end
  assert(#t == 10001, "grown len")
  for i = 0, 10000 do assert(t[i] == i * 2, "grown key") end
  assert(count(t) == 10001, "grown count")

  for i = 10, 10000 do t[i] = nil end
  assert(#t == 10, "shrunk len")
  for i = 0, 200 do t["s" .. i] = i end  -- force rehash
  assert(#t == 10, "shrunk len after rehash")
  for i = 0, 9 do assert(t[i] == i * 2, "survivor " .. i) end
  assert(t[10] == nil and t[5000] == nil, "removed stay removed")

  for i = 10000, 0, -1 do t[i] = -i end  -- reinsert from the top down
  assert(#t == 10001, "regrown len")
  for i = 0, 10000 do assert(t[i] == -i, "regrown key") end

  for i = 0, 10000, 2 do t[i] = nil end
  assert(isborder(t, #t), "half-empty border")
  for i = 1, 10000, 2 do assert(t[i] == -i, "odd kept") end
end

-- integer keys in the hash part only (exercises hash_search)
do
  local t = {}
  for i = 1, 16 do t["k" .. i] = i end
  for i = 1, 16 do t["k" .. i] = nil end
  for i = 0, 5 do t[i] = i end
  assert(#t == 6, "hash-only sequence len")
  t[7] = 7
  assert(isborder(t, #t), "hash-only border with gap")
  local u = {[0] = 1}
  u[math.maxinteger] = 1
  assert(isborder(u, #u), "maxinteger key border")
end

-- keys 0 and 2^k - 1 only in the hash part (hash_search up to maxinteger)
do
  local t = {}
  for i = 1, 129 do t["h" .. i] = i end  -- 256 nodes, 127 still free
  t[0] = 0
  for k = 1, 62 do t[(1 << k) - 1] = k end
  t[math.maxinteger - 1] = "top"
  assert(#t == math.maxinteger, "hash_search stops at maxinteger")
  t[math.maxinteger - 1] = nil
  assert(isborder(t, #t), "hash_search binary search border")
  assert(#t >= 1 << 62, "hash_search border past 2^62")
end

-- __len is still used
assert(#setmetatable({}, {__len = function() return 42 end}) == 42, "__len")

-- next / pairs visit each key once
do
  local t = {}
  for i = -3, 40 do t[i] = i end
  t.a, t.b, t[2.5] = "a", "b", 2.5
  local seen, n = {}, 0
  for k, v in pairs(t) do
    assert(seen[k] == nil, "pairs repeats a key")
    seen[k] = true
    n = n + 1
    assert(t[k] == v, "pairs value")
  end
  assert(n == 44 + 3, "pairs count")
  assert(next({[0] = "x"}) == 0, "next yields key 0 first from array")
  local k, v = next({5, 6})
  assert(k == 0 and v == 5, "next array order")
  assert(next({5, 6}, 0) == 1, "next after 0")
  assert(next({5, 6}, 1) == nil, "next after last")
  assert(errs("invalid key to 'next'", next, {5, 6}, 7), "next bad key")
  for key in pairs(t) do t[key] = nil end  -- clearing during traversal is allowed
  assert(next(t) == nil, "cleared during pairs")
end

-- ipairs
do
  local got = {}
  for i, v in ipairs({"a", "b", "c", nil, "e"}) do got[#got] = i .. v end
  assert(table.concat(got, ",") == "0a,1b,2c", "ipairs order")
  local n = 0
  for _ in ipairs({}) do n = n + 1 end
  assert(n == 0, "ipairs empty")
  for _ in ipairs({[1] = "x"}) do n = n + 1 end
  assert(n == 0, "ipairs stops at missing 0")
  local _, _, start = ipairs({})
  assert(start == -1, "ipairs control start")
  local proxy = setmetatable({}, {__index = function(_, i) if i < 3 then return i * 10 end end})
  got = {}
  for i, v in ipairs(proxy) do got[#got] = v end
  assert(#got == 3 and got[0] == 0 and got[2] == 20, "ipairs __index")
end

-- table.insert
do
  local t = {}
  table.insert(t, "a")
  assert(t[0] == "a" and #t == 1, "insert append empty")
  table.insert(t, "b")
  assert(same(t, {"a", "b"}), "insert append")
  table.insert(t, 0, "z")
  assert(same(t, {"z", "a", "b"}), "insert front")
  table.insert(t, 1, "m")
  assert(same(t, {"z", "m", "a", "b"}), "insert middle")
  table.insert(t, #t, "end")
  assert(same(t, {"z", "m", "a", "b", "end"}), "insert at #t")
  assert(errs("position out of bounds", table.insert, t, #t + 1, "x"), "insert past end")
  assert(errs("position out of bounds", table.insert, t, -1, "x"), "insert negative")
  assert(errs("wrong number of arguments", table.insert, t, 0, 1, 2), "insert arg count")
  local e = {}
  table.insert(e, 0, "only")
  assert(same(e, {"only"}), "insert 0 into empty")
end

-- table.remove
do
  local t = {"a", "b", "c", "d"}
  assert(table.remove(t) == "d" and same(t, {"a", "b", "c"}), "remove last")
  assert(table.remove(t, 0) == "a" and same(t, {"b", "c"}), "remove first")
  assert(table.remove(t, 1) == "c" and same(t, {"b"}), "remove at #t-1")
  assert(table.remove(t, #t) == nil and same(t, {"b"}), "remove at #t")
  assert(errs("position out of bounds", table.remove, t, #t + 1), "remove past #t")
  assert(errs("position out of bounds", table.remove, t, -2), "remove negative")
  assert(table.remove(t) == "b" and #t == 0, "remove to empty")
  assert(table.remove(t) == nil, "remove empty")
  assert(table.remove(t, 0) == nil and #t == 0, "remove 0 on empty")
  assert(errs("position out of bounds", table.remove, t, 1), "remove 1 on empty")
  local n = {[-1] = "neg"}
  assert(table.remove(n) == "neg" and n[-1] == nil, "remove on empty touches t[#t-1]")
end

-- table.move
do
  local a = {1, 2, 3}
  table.move(a, 0, 2, 1)
  assert(same(a, {1, 1, 2, 3}), "move up overlapping")
  a = {1, 2, 3, 4}
  table.move(a, 1, 3, 0)
  assert(a[0] == 2 and a[1] == 3 and a[2] == 4 and a[3] == 4, "move down overlapping")
  local b = table.move({1, 2, 3}, 0, 2, 0, {})
  assert(same(b, {1, 2, 3}), "move to other table")
  local c = table.move({1, 2, 3}, 0, -1, 0, {})
  assert(#c == 0, "move empty range")
  local d = table.move({1, 2, 3}, 1, 2, 5, {})
  assert(d[5] == 2 and d[6] == 3 and d[0] == nil, "move offsets")
end

-- table.concat
do
  local t = {1, 2, 3}
  assert(table.concat(t) == "123", "concat default")
  assert(table.concat(t, ",") == "1,2,3", "concat sep")
  assert(table.concat(t, ",", 1) == "2,3", "concat i")
  assert(table.concat(t, ",", 0, 0) == "1", "concat single")
  assert(table.concat(t, ",", 1, 0) == "", "concat empty range")
  assert(table.concat({}) == "", "concat empty")
  assert(table.concat({[-1] = "n", [0] = "z"}, "", -1, 0) == "nz", "concat negative i")
  assert(errs("at index 3", table.concat, t, ",", 0, 3), "concat reports key")
end

-- table.pack / table.unpack
do
  local p = table.pack(1, nil, 3)
  assert(p[0] == 1 and p[1] == nil and p[2] == 3 and p.n == 3, "pack")
  local e = table.pack()
  assert(e.n == 0 and e[0] == nil, "pack empty")

  local a, b, c = table.unpack({1, 2, 3})
  assert(a == 1 and b == 2 and c == 3, "unpack all")
  assert(select("#", table.unpack({1, 2, 3})) == 3, "unpack count")
  a, b = table.unpack({1, 2, 3}, 1)
  assert(a == 2 and b == 3, "unpack from 1")
  assert(select("#", table.unpack({1, 2, 3}, 0, 0)) == 1, "unpack single")
  assert(select("#", table.unpack({})) == 0, "unpack empty")
  assert(select("#", table.unpack({1, 2}, 1, 0)) == 0, "unpack empty range")
  assert(select("#", table.unpack(p, 0, p.n - 1)) == 3, "unpack pack round trip")
  a, b = table.unpack({[-1] = "n", [0] = "z"}, -1, 0)
  assert(a == "n" and b == "z", "unpack negative")
end

-- table.sort
do
  local t = {3, 1, 2}
  table.sort(t)
  assert(same(t, {1, 2, 3}), "sort 3")
  table.sort(t, function(x, y) return x > y end)
  assert(same(t, {3, 2, 1}), "sort desc")
  local one = {7}
  table.sort(one)
  assert(one[0] == 7, "sort 1")
  local two = {9, 8}
  table.sort(two)
  assert(two[0] == 8 and two[1] == 9 and two[2] == nil and two[-1] == nil, "sort 2")
  table.sort({})
  math.randomseed(7)
  local r = {}
  for i = 0, 999 do r[i] = math.random(-500, 500) end
  table.sort(r)
  assert(#r == 1000 and r[-1] == nil and r[1000] == nil, "sort big bounds")
  for i = 1, 999 do assert(r[i - 1] <= r[i], "sort big order") end
end

-- string.sub
do
  local s = "hello"
  assert(s:sub(0, 0) == "h", "sub first char")
  assert(s:sub(0) == "hello", "sub whole")
  assert(s:sub(1, 2) == "el", "sub inclusive end")
  assert(s:sub(4) == "o", "sub last")
  assert(s:sub(-1) == "o", "sub -1")
  assert(s:sub(-3, -2) == "ll", "sub negative")
  assert(s:sub(2, 1) == "", "sub empty")
  assert(s:sub(5) == "", "sub past end")
  assert(s:sub(-100, 1) == "he", "sub clamp start")
  assert(s:sub(3, 100) == "lo", "sub clamp end")
  assert(s:sub(0, -100) == "", "sub end before start")
  assert(s:sub(math.mininteger, math.maxinteger) == "hello", "sub extremes")
  assert((""):sub(0) == "", "sub empty string")
end

-- string.byte
do
  local s = "abc"
  assert(s:byte() == 97, "byte default")
  assert(s:byte(2) == 99, "byte 2")
  assert(s:byte(-1) == 99, "byte -1")
  local a, b, c = s:byte(0, -1)
  assert(a == 97 and b == 98 and c == 99, "byte range")
  assert(select("#", s:byte(3)) == 0, "byte past end")
  assert(select("#", s:byte(1, 0)) == 0, "byte empty range")
  assert(select("#", s:byte(-10, 0)) == 1, "byte clamped start")
end

-- string.find / match / gmatch / gsub
do
  local s = "hello"
  local i, j = s:find("ll")
  assert(i == 2 and j == 3, "find plain")
  i, j = s:find("l+")
  assert(i == 2 and j == 3, "find pattern")
  i, j = s:find("h")
  assert(i == 0 and j == 0, "find at 0")
  assert(s:find("l", 3) == 3, "find init")
  assert(s:find("l", 4) == nil, "find init past match")
  assert(s:find("o", -1) == 4, "find init -1")
  assert(s:find("h", -100) == 0, "find init clamped")
  assert(s:find("x") == nil, "find none")
  assert(s:find(".", 0, true) == nil, "find plain special")
  i, j = s:find("")
  assert(i == 0 and j == -1, "find empty pattern")
  i, j = s:find("", 5)
  assert(i == 5 and j == 4, "find empty at end")
  assert(s:find("", 6) == nil, "find past end")
  assert(s:find("^l") == nil and s:find("^l", 2) == 2, "find anchor init")
  i, j = s:find("^")
  assert(i == 0 and j == -1, "find bare anchor")
  local a, b, cap = s:find("(l+)")
  assert(a == 2 and b == 3 and cap == "ll", "find captures")

  assert(s:match("l+") == "ll", "match")
  assert(s:match("l", 3) == "l" and s:match("h", 1) == nil, "match init")
  local p1, p2 = s:match("()ll()")
  assert(p1 == 2 and p2 == 4, "position captures")
  assert(s:match("()", 5) == 5, "position capture at end")

  local out = {}
  for p in ("abc"):gmatch("()") do out[#out] = p end
  assert(table.concat(out, ",") == "0,1,2,3", "gmatch positions")
  out = {}
  for w in ("one two three"):gmatch("%a+", 4) do out[#out] = w end
  assert(table.concat(out, ",") == "two,three", "gmatch init")
  out = {}
  for w in ("ab"):gmatch(".", -1) do out[#out] = w end
  assert(table.concat(out) == "b", "gmatch negative init")
  out = {}
  for w in ("ab"):gmatch(".", 10) do out[#out] = w end
  assert(#out == 0, "gmatch init past end")

  assert(("abc"):gsub("()", "%1") == "0a1b2c3", "gsub position capture")
  assert(("hello world"):gsub("(%w+) (%w+)", "%2 %1") == "world hello", "gsub %n unchanged")
  assert(select(2, ("aaa"):gsub("a", "b", 2)) == 2, "gsub max count")
end

-- string.pack / string.unpack positions
do
  local data = string.pack("i1i1i1", 1, 2, 3)
  local a, b, c, nxt = string.unpack("i1i1i1", data)
  assert(a == 1 and b == 2 and c == 3 and nxt == 3, "unpack next position")
  a, nxt = string.unpack("i1", data, 1)
  assert(a == 2 and nxt == 2, "unpack from 1")
  a, nxt = string.unpack("i1", data, -1)
  assert(a == 3 and nxt == 3, "unpack from -1")
  assert(select("#", string.unpack("", data, 3)) == 1, "unpack empty fmt at end")
  assert(errs("data string too short", string.unpack, "i1", data, 3), "unpack at end")
  assert(errs("initial position out of string", string.unpack, "i1", data, 4), "unpack past end")
  local z, zn = string.unpack("z", "ab\0cd")
  assert(z == "ab" and zn == 3, "unpack z")
  local s1, n1 = string.unpack("s1", string.pack("s1", "xyz"))
  assert(s1 == "xyz" and n1 == 4, "unpack s1")
  assert(string.packsize("i4") == 4 and #data == 3, "sizes unchanged")
end

-- utf8
do
  local s = "a\u{3B1}b\u{10348}"  -- bytes: a(0) α(1,2) b(3) 𐍈(4..7)
  assert(#s == 8, "utf8 fixture")
  assert(utf8.len(s) == 4, "utf8.len")
  assert(utf8.len(s, 1) == 3, "utf8.len i")
  assert(utf8.len(s, 0, 0) == 1, "utf8.len i j")
  assert(utf8.len(s, 0, 1) == 2, "utf8.len counts starts")
  assert(utf8.len(s, 3, -1) == 2, "utf8.len negative j")
  assert(utf8.len(s, -4) == 1, "utf8.len negative i")
  assert(utf8.len(s, 8) == 0, "utf8.len i at end")
  assert(utf8.len("") == 0, "utf8.len empty")
  assert(errs("initial position out of bounds", utf8.len, s, 9), "utf8.len i past end")
  assert(errs("initial position out of bounds", utf8.len, s, -9), "utf8.len i before start")
  assert(errs("final position out of bounds", utf8.len, s, 0, 8), "utf8.len j past end")
  local fail, pos = utf8.len("ab\xffcd")
  assert(fail == nil and pos == 2, "utf8.len bad byte position")
  fail, pos = utf8.len("ab\xffcd", 3)
  assert(fail == 2, "utf8.len skips bad byte")

  assert(utf8.codepoint(s) == 97, "codepoint default")
  assert(utf8.codepoint(s, 1) == 0x3B1, "codepoint 1")
  assert(utf8.codepoint(s, -4) == 0x10348, "codepoint negative")
  local c1, c2, c3 = utf8.codepoint(s, 0, 3)
  assert(c1 == 97 and c2 == 0x3B1 and c3 == 98, "codepoint range")
  assert(select("#", utf8.codepoint(s, 3, 2)) == 0, "codepoint empty")
  assert(errs("out of bounds", utf8.codepoint, s, 8), "codepoint past end")
  assert(errs("out of bounds", utf8.codepoint, s, 0, 8), "codepoint j past end")
  assert(errs("out of bounds", utf8.codepoint, s, -9), "codepoint before start")
  assert(errs("invalid UTF-8 code", utf8.codepoint, s, 2), "codepoint on continuation")

  assert(utf8.offset(s, 1) == 0, "offset 1st char")
  assert(utf8.offset(s, 2) == 1, "offset 2nd char")
  assert(utf8.offset(s, 4) == 4, "offset 4th char")
  assert(utf8.offset(s, 5) == 8, "offset one past last")
  assert(utf8.offset(s, 6) == nil, "offset too far")
  assert(utf8.offset(s, -1) == 4, "offset last char")
  assert(utf8.offset(s, -4) == 0, "offset first from end")
  assert(utf8.offset(s, -5) == nil, "offset before start")
  assert(utf8.offset(s, 0, 2) == 1, "offset 0 finds char start")
  assert(utf8.offset(s, 0, 6) == 4, "offset 0 in 4-byte char")
  assert(utf8.offset(s, 2, 3) == 4, "offset from i")
  assert(utf8.offset(s, -1, 3) == 1, "offset back from i")
  assert(utf8.offset(s, 1, -4) == 4, "offset negative i")
  assert(errs("continuation byte", utf8.offset, s, 1, 2), "offset on continuation")
  assert(errs("position out of bounds", utf8.offset, s, 1, 9), "offset i past end")

  local got = {}
  for p, c in utf8.codes(s) do got[#got] = p .. ":" .. c end
  assert(table.concat(got, ",") == "0:97,1:945,3:98,4:66376", "utf8.codes positions")
  got = 0
  for _ in utf8.codes("") do got = got + 1 end
  assert(got == 0, "utf8.codes empty")
  assert(errs("invalid UTF-8 code", function() for _ in utf8.codes("a\xff") do end end), "utf8.codes invalid")
  assert(utf8.char(72, 105) == "Hi", "utf8.char unchanged")
end

-- math.random
do
  math.randomseed(1234)
  local seen = {}
  for _ = 1, 20000 do
    local r = math.random(10)
    assert(math.type(r) == "integer" and r >= 0 and r <= 9, "random(n) range")
    seen[r] = true
  end
  for i = 0, 9 do assert(seen[i], "random(n) hits " .. i) end
  for _ = 1, 100 do assert(math.random(1) == 0, "random(1) is 0") end
  local lo, hi = false, false
  for _ = 1, 5000 do
    local r = math.random(3, 5)
    assert(r >= 3 and r <= 5, "random(m, n) inclusive")
    lo = lo or r == 3
    hi = hi or r == 5
  end
  assert(lo and hi, "random(m, n) hits both ends")
  assert(math.random(3, 3) == 3, "random(m, m)")
  assert(math.type(math.random(0)) == "integer", "random(0) full integer")
  assert(errs("interval is empty", math.random, -1), "random(-1)")
  assert(errs("interval is empty", math.random, math.mininteger), "random(minint)")
  assert(errs("interval is empty", math.random, 5, 4), "random(5, 4)")
  local big = math.random(math.maxinteger)
  assert(big >= 0 and big < math.maxinteger, "random(maxint)")
  local f = math.random()
  assert(math.type(f) == "float" and f >= 0 and f < 1, "random() float")
end

-- unchanged ordinals and counts
do
  assert(select(1, "a", "b") == "a" and select(-1, "a", "b") == "b", "select ordinals")
  assert(select("#", "a", nil) == 2, "select #")
  assert(#"abc" == 3 and ("abc"):len() == 3, "string length")
  assert(rawlen({1, 2}) == 2 and rawlen("xy") == 2, "rawlen")
  assert(string.format("%d-%s", 1, "x") == "1-x", "format args")
  assert(debug.getinfo(1, "l").currentline > 0, "debug level 1")
end

-- registry layout and package.searchers
do
  local reg = debug.getregistry()
  assert(type(reg[1]) == "thread", "registry[LUA_RIDX_MAINTHREAD]")
  assert(reg[2] == _G, "registry[LUA_RIDX_GLOBALS]")
  assert(math.type(reg[0]) == "integer", "registry[0] is the ref free list")
  assert(#reg >= 3, "registry sequence covers reserved keys")

  assert(type(package.searchers[0]) == "function", "searchers[0]")
  assert(#package.searchers == 4, "searchers count")
  package.preload.zero_mod = function() return 42 end
  assert(require("zero_mod") == 42, "require through preload")
  table.insert(package.searchers, function(name)
    if name == "zero_extra" then return function() return "extra" end end
    return "\n\tno extra '" .. name .. "'"
  end)
  assert(require("zero_extra") == "extra", "appended searcher runs")
  local ok, msg = pcall(require, "zero_missing")
  assert(not ok and msg:find("no field package.preload['zero_missing']", 0, true)
    and msg:find("no extra 'zero_missing'", 0, true), "require error lists every searcher")
  table.remove(package.searchers)
end

-- randomized stress: integer keys against a string-keyed model
do
  math.randomseed(20260922)
  local t, model = {}, {}
  local LO, HI = -20, 300
  local function check_all(step)
    for k = LO, HI do
      if t[k] ~= model[tostring(k)] then
        error("stress mismatch at key " .. k .. " step " .. step)
      end
    end
    local n = #t
    assert((n == 0 and model["0"] == nil) or
           (model[tostring(n - 1)] ~= nil and model[tostring(n)] == nil),
           "stress border step " .. step)
  end
  local function check_pairs(step)
    local n = 0
    for k, v in pairs(t) do
      assert(math.type(k) == "integer" and model[tostring(k)] == v, "stress pairs key step " .. step)
      n = n + 1
    end
    assert(n == count(model), "stress pairs count step " .. step)
  end
  for step = 1, 6000 do
    local k = math.random(LO, HI)
    local r = math.random(0, 9)
    if step % 1500 < 400 then k = math.random(0, 64) end  -- phases dense near 0
    if r < 3 then
      t[k], model[tostring(k)] = nil, nil
    elseif r == 3 then
      t[k + 0.0], model[tostring(k)] = step, step  -- float key with integer value
    else
      t[k], model[tostring(k)] = step, step
    end
    if step % 777 == 0 then  -- bulk clear to force shrinking rehashes
      for key = LO, HI do
        if math.random(0, 1) == 0 then t[key], model[tostring(key)] = nil, nil end
      end
      for i = 1, 50 do t["pad" .. i] = i; t["pad" .. i] = nil end
    end
    check_all(step)
    if step % 50 == 0 then check_pairs(step) end
  end
  check_pairs(-1)
end

-- randomized stress: table.insert/remove against a string-keyed list model
do
  math.randomseed(99)
  local t, m, mn = {}, {}, 0
  for step = 1, 4000 do
    local r = math.random(0, 3)
    if r <= 1 or mn == 0 then
      local pos = math.random(0, mn)
      table.insert(t, pos, step)
      for i = mn, pos + 1, -1 do m[tostring(i)] = m[tostring(i - 1)] end
      m[tostring(pos)] = step
      mn = mn + 1
    else
      local pos = math.random(0, mn - 1)
      local v = table.remove(t, pos)
      assert(v == m[tostring(pos)], "list stress removed value step " .. step)
      for i = pos, mn - 2 do m[tostring(i)] = m[tostring(i + 1)] end
      m[tostring(mn - 1)] = nil
      mn = mn - 1
    end
    assert(#t == mn, "list stress len step " .. step)
    if step % 25 == 0 then
      for i = 0, mn - 1 do assert(t[i] == m[tostring(i)], "list stress value step " .. step) end
    end
  end
end

return "ok"
