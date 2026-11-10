-- math.lua: math library, following lmathlib.c (Lua 5.5).
-- Float functions wrap host math primitives after our argument checks.
local R = require("runtime")

local function unary(name, f)
  return function(x) return f(R.checknumber(x, 1, name)) end
end

local function abs(x)
  if math.type(x) == "integer" then return x < 0 and -x or x end
  return math.abs(R.checknumber(x, 1, "abs") + 0.0)
end

local function floor(x)
  if math.type(x) == "integer" then return x end
  return math.floor(R.checknumber(x, 1, "floor"))
end

local function ceil(x)
  if math.type(x) == "integer" then return x end
  return math.ceil(R.checknumber(x, 1, "ceil"))
end

local function fmod(a, b)
  if math.type(a) == "integer" and math.type(b) == "integer" then
    if b == 0 then R.argerror(2, "fmod", "zero") end
    if b == -1 then return 0 end
    return math.fmod(a, b)
  end
  local x = R.checknumber(a, 1, "fmod") + 0.0
  local y = R.checknumber(b, 2, "fmod") + 0.0
  return math.fmod(x, y)
end

local function modf(x)
  if math.type(x) == "integer" then return x, 0.0 end
  local n = R.checknumber(x, 1, "modf") + 0.0
  local ip = (n < 0) and math.ceil(n) or math.floor(n)   -- integer if it fits
  local frac = (n == ip) and 0.0 or (n - ip)
  return ip, frac
end

local function log(x, base)
  local v = R.checknumber(x, 1, "log")
  if base == nil then return math.log(v) end
  return math.log(v, R.checknumber(base, 2, "log"))
end

local function atan(y, x)
  local yy = R.checknumber(y, 1, "atan")
  local xx = R.optnumber(x, 2, "atan", 1)
  return math.atan(yy, xx)
end

local function tointeger(...)
  if select("#", ...) == 0 then R.argerror(1, "tointeger", "value expected") end
  return R.tointeger((...))
end

local function mtype(...)
  if select("#", ...) == 0 then R.argerror(1, "type", "value expected") end
  return math.type((...))
end

local function ult(a, b)
  return math.ult(R.checkinteger(a, 1, "ult"), R.checkinteger(b, 2, "ult"))
end

local function max(...)
  local n = select("#", ...)
  if n < 1 then R.argerror(1, "max", "value expected") end
  local args = { ... }
  local best = args[1]
  for i = 2, n do
    if R.lt(best, args[i]) then best = args[i] end
  end
  return best
end

local function min(...)
  local n = select("#", ...)
  if n < 1 then R.argerror(1, "min", "value expected") end
  local args = { ... }
  local best = args[1]
  for i = 2, n do
    if R.lt(args[i], best) then best = args[i] end
  end
  return best
end

---------------------------------------------------------------------------
-- Pseudo-random numbers: xoshiro256** as in lmathlib.c (64-bit branch).
-- Lua's >> is a logical shift, matching the unsigned C arithmetic.
---------------------------------------------------------------------------

local st = { 0, 0, 0, 0 }
local SCALE = 2.0 ^ -53

local function rotl(x, n)
  return (x << n) | (x >> (64 - n))
end

local function nextrand()
  local s0, s1 = st[1], st[2]
  local s2 = st[3] ~ s0
  local s3 = st[4] ~ s1
  local res = rotl(s1 * 5, 7) * 9
  st[1] = s0 ~ s3
  st[2] = s1 ~ s2
  st[3] = s2 ~ (s1 << 17)
  st[4] = rotl(s3, 45)
  return res
end

local function setseed(n1, n2)
  st[1], st[2], st[3], st[4] = n1, 0xff, n2, 0
  for _ = 1, 16 do nextrand() end
end

local makeseed = R.makeseed

-- Project a random integer into [0, n] (unsigned), retrying as in C.
local function project(ran, n)
  local lim = n
  local sh = 1
  while (lim & (lim + 1)) ~= 0 do
    lim = lim | (lim >> sh)
    sh = sh * 2
  end
  ran = ran & lim
  while math.ult(n, ran) do
    ran = nextrand() & lim
  end
  return ran
end

local function random(...)
  local a, b = ...
  local rv = nextrand()
  local nargs = select("#", ...)
  local low, up
  if nargs == 0 then
    return (rv >> 11) * SCALE   -- float in [0, 1)
  elseif nargs == 1 then
    low = 1
    up = R.checkinteger(a, 1, "random")
    if up == 0 then return rv end   -- full random integer
  elseif nargs == 2 then
    low = R.checkinteger(a, 1, "random")
    up = R.checkinteger(b, 2, "random")
  else
    R.rterror("wrong number of arguments")
  end
  if low > up then R.argerror(1, "random", "interval is empty") end
  return project(rv, up - low) + low
end

local function randomseed(...)
  local a, b = ...
  local n1, n2
  if select("#", ...) == 0 then
    n1 = makeseed()
    n2 = nextrand()
  else
    n1 = R.checkinteger(a, 1, "randomseed")
    n2 = R.optinteger(b, 2, "randomseed", 0)
  end
  setseed(n1, n2)
  return n1, n2
end

return function(G)
  setseed(makeseed(), 0)

  local lib = R.newtable()
  R.setfuncs(lib, {
    abs = abs,
    acos = unary("acos", math.acos),
    asin = unary("asin", math.asin),
    atan = atan,
    ceil = ceil,
    cos = unary("cos", math.cos),
    deg = unary("deg", math.deg),
    exp = unary("exp", math.exp),
    floor = floor,
    fmod = fmod,
    log = log,
    max = max,
    min = min,
    modf = modf,
    rad = unary("rad", math.rad),
    random = random,
    randomseed = randomseed,
    sin = unary("sin", math.sin),
    sqrt = unary("sqrt", math.sqrt),
    tan = unary("tan", math.tan),
    tointeger = tointeger,
    type = mtype,
    ult = ult,
  })
  -- frexp and ldexp are part of the standard build; the other compat
  -- functions (LUA_COMPAT_MATHLIB) are not
  R.setfuncs(lib, {
    frexp = function(x)
      x = R.checknumber(x, 1, "frexp") * 1.0   -- (keeps -0.0)
      if x == 0 or x ~= x or x == math.huge or x == -math.huge then return x, 0 end
      local e = R.floorlog2(math.abs(x)) + 1
      return R.ldexp(x, -e), e   -- exact: a power-of-two scaling
    end,
    ldexp = function(m, e)
      return R.ldexp(R.checknumber(m, 1, "ldexp") * 1.0, R.checkinteger(e, 2, "ldexp"))
    end,
  })
  lib.hash.huge = math.huge
  lib.hash.pi = math.pi
  lib.hash.maxinteger = math.maxinteger
  lib.hash.mininteger = math.mininteger
  G.hash.math = lib
end
