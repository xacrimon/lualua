-- Regression tests for fixed lualua bugs. Each check holds under reference
-- Lua 5.5 too: run with `lua tests/regress.lua` and `lua lualua.lua tests/regress.lua`.

local function check(ok, ...) assert(ok, ...) end
local function err(f, ...)
  local ok, e = pcall(f, ...)
  assert(not ok, "expected an error")
  return e
end
-- positions in this file are compared as "@: " (line numbers are not checked)
local function norm(v)
  if type(v) ~= "string" then return v end
  return (v:gsub("tests/regress%.lua:%d+: ", "@: "))
end
local function eq(a, b) a = norm(a); assert(a == b, tostring(a) .. " ~= " .. tostring(b)) end

-- syntax: 'break' outside a loop
eq(select(2, load("print(1) break")), [[[string "print(1) break"]:1: break outside loop near 'break']])
eq(select(2, load("local function f() if x then break end end")),
   [[[string "local function f() if x then break end end"]:1: break outside loop near 'break']])

-- a backward goto closes the to-be-closed variables declared after its label
do
  local closed = {}
  do
    local n = 0
    ::top::
    local x <close> = setmetatable({}, { __close = function() closed[#closed + 1] = n end })
    n = n + 1
    if n < 3 then goto top end
  end
  eq(table.concat(closed, ","), "1,2,3")
end

-- __eq only between two tables or two userdata
do
  local mt = { __eq = function() return true end }
  local t = setmetatable({}, mt)
  eq(t == io.stdout, false)
  eq(t == setmetatable({}, mt), true)
end

-- string arithmetic goes through the string metamethods; bitwise operators do not coerce
eq(err(function() return "abc" + 1 end), "@: attempt to add a 'string' with a 'number'")
eq(err(function() return {} + "abc" end), "@: attempt to add a 'table' with a 'string'")
eq(err(function() return "1" & 3 end),
   "@: attempt to perform bitwise operation on a string value (constant '1')")
eq(err(function() return -"abc" end), "@: attempt to unm a 'string' with a 'string'")
eq(err(function() return "1" // 0 end), "attempt to divide by zero")
eq("10" + 1, 11); eq("3" * "4", 12); eq(-"2", -2); eq("7" // "2", 3)
check(getmetatable("").__add ~= nil and getmetatable("").__unm ~= nil)

-- variable descriptions
do
  local t = {}
  eq(err(function() return t[1].x end), "@: attempt to index a nil value (field 'integer index')")
  local k = "kk"
  eq(err(function() return t[k].x end), "@: attempt to index a nil value (field '?')")
  eq(err(function() return ("x")() end), "@: attempt to call a string value (constant 'x')")
end

-- errors of a table store are reported on the line where the statement ends
eq(err(load("local t = nil\nt.x\n=\n1", "=s")), "s:4: attempt to index a nil value (local 't')")

-- error levels when a native calls a native
eq(err(error, "msg", 2):match("^[^:]*:%d+: msg$") ~= nil, true)

-- argument errors name the function by its call site
do
  local s = string.rep
  eq(err(function() s() end), "@: bad argument #1 to 's' (string expected, got no value)")
  eq(err(function() for _ in string.rep do end end),
     "@: bad argument #1 to 'for iterator' (string expected, got nil)")
  eq(err(function() return 1 + setmetatable({}, { __add = string.rep }) end),
     "@: bad argument #2 to 'add' (number expected, got table)")
  eq(err(function() return tostring(setmetatable({}, { __tostring = string.rep })) end),
     "bad argument #1 to 'string.rep' (string expected, got table)")
end

-- a deep recursion is a Lua stack overflow, whoever runs out of stack first
do
  local function f(n) if n == 0 then return 0 end return 1 + f(n - 1) end
  local e = err(f, 1e7)
  check(e:match("^tests/regress.lua:%d+: stack overflow$"), e)
end

-- base library argument checks
eq(err(rawequal, 1), "bad argument #2 to 'rawequal' (value expected)")
eq(err(rawget, {}), "bad argument #2 to 'rawget' (value expected)")
eq(err(rawset, {}, 1), "bad argument #3 to 'rawset' (value expected)")
eq(err(rawlen, 5), "bad argument #1 to 'rawlen' (table or string expected, got number)")
eq(err(getmetatable), "bad argument #1 to 'getmetatable' (value expected)")
eq(err(setmetatable, {}), "bad argument #2 to 'setmetatable' (nil or table expected, got no value)")
eq(err(pcall), "bad argument #1 to 'pcall' (value expected)")
eq(err(xpcall, print), "bad argument #2 to 'xpcall' (function expected, got no value)")
eq(err(error, nil, "x"), "bad argument #2 to 'error' (number expected, got string)")
eq(select("#", pairs({})), 4)
eq(select(2, pairs(5)), 5)
eq(err(function() assert(nil, "m") end), "@: m")
eq(err(function() assert(false) end), "@: assertion failed!")

-- load
eq(select(2, load("x=", 42)), [[[string "42"]:1: unexpected symbol near <eof>]])
eq(select(2, load("return 1", nil, "x")), "attempt to load a text chunk (mode is 'x')")
-- (reader errors run under pcall: reference lua.c's message handler would append a traceback)
local function loadmsg(...)
  local args = table.pack(...)
  local _, _, msg = pcall(function() return load(table.unpack(args, 1, args.n)) end)
  return msg
end
eq(loadmsg(function() error("boom") end), "@: boom")
do
  local n = 0
  eq(select(2, load(function() n = n + 1; if n == 1 then return 1 end end)), "(load):1: unexpected symbol near '1'")
end
eq(load(123), nil)
eq(loadmsg(function() return {} end), "@: reader function must return a string")
eq(load("return 2", "c", "t", nil)(), 2)

-- package
eq(select(2, package.searchpath("x%1", "./?.none")), "no file './x%1.none'")
eq(select(2, package.searchpath("a.b", "./?.x;./?.y")), "no file './a/b.x'\n\tno file './a/b.y'")
eq(select(2, package.searchpath("a.b", "./?.x", "", "_")), "no file './a.b.x'")
check(type(package.searchers) == "table" and #package.searchers == 4)
do
  package.loaded.__regress_false = false
  package.preload.__regress_false = function() return "loaded" end
  eq(require("__regress_false"), "loaded")
end

-- collectgarbage("param")
eq(collectgarbage("param", "majorminor"), 50)
eq(err(collectgarbage, "param", "bogus"), "bad argument #2 to 'collectgarbage' (invalid option 'bogus')")
do
  local old = collectgarbage("param", "pause", 123)
  eq(collectgarbage("param", "pause"), 118)   -- stored with 5 significant bits
  collectgarbage("param", "pause", old)
end

-- coroutine.wrap adds the caller's position to string errors
do
  local w = coroutine.wrap(function() error("x") end)
  eq(err(function() return w() end), "@: @: x")
  eq(err(function() return w() end), "@: cannot resume dead coroutine")
end

-- io methods count self as argument 1
do
  local f = io.tmpfile()
  eq(err(function() f:write({}) end), "@: bad argument #1 to 'write' (string expected, got table)")
  eq(err(f.read, f, "x"), "bad argument #2 to '?' (invalid format)")
  eq(err(function() f:seek("bad") end), "@: bad argument #1 to 'seek' (invalid option 'bad')")
  f:write("  12.5e3 0x1F -7 .5 abc")
  f:seek("set")
  local a, b, c, d, e = f:read("n", "n", "n", "n", "n")
  eq(a, 12500.0); eq(b, 31); eq(c, -7); eq(d, 0.5); eq(e, nil)
  f:close()
end

-- os.date errors carry no host position
eq(err(os.date, "%Y", 2^60), "date result cannot be represented in this installation")
eq(err(os.date, "%Q", 0), "bad argument #1 to 'os.date' (invalid conversion specifier '%Q')")

-- debug library
eq(err(debug.setmetatable, 1, 5), "bad argument #2 to 'debug.setmetatable' (nil or table expected, got number)")
do
  local info = debug.getinfo(1)
  eq(info.what, "main"); eq(info.linedefined, 0); check(type(info.func) == "function")
  local function g() return debug.getinfo(1, "S") end
  local line = debug.getinfo(1, "l").currentline
  eq(g().linedefined, line - 1)
end

-- math: no compat functions; frexp keeps the sign of zero
eq(math.pow, nil)
eq(1 / select(1, math.frexp(-0.0)), -math.huge)
eq(math.frexp(8), 0.5); eq(select(2, math.frexp(8)), 4)

-- strings built in blocks
eq(string.rep("ab", 3, ","), "ab,ab,ab")
eq(("xyz"):rep(0), "")
eq(string.upper(string.rep("aZ", 1500)), string.rep("AZ", 1500))
eq(string.reverse("abcdef" .. string.rep("x", 2000) .. "123"), "321" .. string.rep("x", 2000) .. "fedcba")
eq(string.gsub("hello world", "o", "0"), "hell0 w0rld")
eq(string.gsub("abc", "", "-"), "-a-b-c-")
eq(string.format("%q", "a\nb\0c\"9"), '"a\\\nb\\0c\\"9"')
eq(string.find("abababc", "abc", 1, true), 5)

print("OK")
