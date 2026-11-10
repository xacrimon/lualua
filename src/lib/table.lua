-- table.lua: table library, following ltablib.c (Lua 5.5).
-- Element access follows lua_geti / lua_seti, so __index, __newindex and
-- __len are honoured.
local R = require("runtime")

local unpack, concat = table.unpack, table.concat
local isTable = R.isTable

-- lua_geti: a plain table is read directly; otherwise the metamethods run,
-- which are not yieldable from a library function
local function geti(t, k)
  if isTable(t) then
    local v = t.hash[k]
    if v ~= nil or t.mt == nil then return v end
  end
  return R.noyield(R.index, t, k)
end

-- lua_seti (k is an integer, so it is a valid key)
local function seti(t, k, v)
  if isTable(t) then
    local h = t.hash
    if t.mt == nil or h[k] ~= nil then
      h[k] = v
      return
    end
  end
  R.noyield(R.setindex, t, k, v)
end
local ult = math.ult
local maxint = math.maxinteger
local INT_MAX = 2147483647
local RANLIMIT = 100

-- what-flags for checktab (as in ltablib.c)
local TR, TW, TL = 1, 2, 4

-- Arg must be a table, or a value whose metatable provides the metamethods
-- the operation needs.
local function checktab(v, n, fname, what)
  if R.isTable(v) then return end
  local mt = R.getmt(v)
  if mt ~= nil
     and ((what & TR) == 0 or mt.hash.__index ~= nil)
     and ((what & TW) == 0 or mt.hash.__newindex ~= nil)
     and ((what & TL) == 0 or type(v) == "string" or mt.hash.__len ~= nil) then
    return
  end
  R.checktable(v, n, fname)   -- raises the "table expected" error
end

-- luaL_len: length through __len, which must be an integer.
local function getn(t, n, fname, what)
  checktab(t, n, fname, what | TL)
  local l = R.tointeger(R.noyield(R.len, t))
  if l == nil then R.rterror("object length is not an integer") end
  return l
end

local MAXHSIZE = 1 << 30   -- largest hash part (ltable.c)

local function tcreate(sizeseq, sizerest)
  local a = R.checkinteger(sizeseq, 1, "create")
  local b = R.optinteger(sizerest, 2, "create", 0)
  -- sizes are unsigned in ltablib.c: negative values are out of range too
  if a < 0 or a > INT_MAX then R.argerror(1, "create", "out of range") end
  if b < 0 or b > INT_MAX then R.argerror(2, "create", "out of range") end
  if b > MAXHSIZE then R.rterror("table overflow") end
  return R.newtable()
end

local function tinsert(...)
  local t = ...
  local e = getn(t, 1, "insert", TR | TW) + 1   -- first empty element
  local n = select("#", ...)
  local pos, v
  if n == 2 then
    pos, v = e, select(2, ...)
  elseif n == 3 then
    local p = select(2, ...)
    pos = R.checkinteger(p, 2, "insert")
    if not ult(pos - 1, e) then R.argerror(2, "insert", "position out of bounds") end
    for i = e, pos + 1, -1 do seti(t, i, geti(t, i - 1)) end
    v = select(3, ...)
  else
    R.rterror("wrong number of arguments to 'insert'")
  end
  seti(t, pos, v)
end

local function tremove(t, pos)
  local size = getn(t, 1, "remove", TR | TW)
  pos = R.optinteger(pos, 2, "remove", size)
  if pos ~= size and ult(size, pos - 1) then
    R.argerror(2, "remove", "position out of bounds")
  end
  local v = geti(t, pos)
  while pos < size do
    seti(t, pos, geti(t, pos + 1))
    pos = pos + 1
  end
  seti(t, pos, nil)
  return v
end

local function tmove(a1, f, e, t, a2)
  f = R.checkinteger(f, 2, "move")
  e = R.checkinteger(e, 3, "move")
  t = R.checkinteger(t, 4, "move")
  local has2 = a2 ~= nil
  local tt = has2 and a2 or a1
  checktab(a1, 1, "move", TR)
  checktab(tt, has2 and 5 or 1, "move", TW)
  if e >= f then
    if not (f > 0 or e < maxint + f) then
      R.argerror(3, "move", "too many elements to move")
    end
    local n = e - f + 1
    if t > maxint - n + 1 then R.argerror(4, "move", "destination wrap around") end
    if t > e or t <= f or (has2 and not R.eq(a1, a2)) then
      for i = 0, n - 1 do seti(tt, t + i, geti(a1, f + i)) end
    else
      for i = n - 1, 0, -1 do seti(tt, t + i, geti(a1, f + i)) end
    end
  end
  return tt
end

local function tconcat(t, sep, i, j)
  local last = getn(t, 1, "concat", TR)
  sep = R.optstring(sep, 2, "concat", "")
  i = R.optinteger(i, 3, "concat", 1)
  last = R.optinteger(j, 4, "concat", last)
  local buf, nb = {}, 0
  for k = i, last do
    local v = geti(t, k)
    local tv = type(v)
    if tv ~= "string" and tv ~= "number" then
      R.rterror("invalid value (" .. R.type(v) .. ") at index " .. k .. " in table for 'concat'")
    end
    nb = nb + 1; buf[nb] = tostring(v)
    if k < last then nb = nb + 1; buf[nb] = sep end
  end
  return concat(buf, "", 1, nb)
end

local function tpack(...)
  local n = select("#", ...)
  local args = { ... }
  local t = R.newtable()
  for i = 1, n do t.hash[i] = args[i] end
  t.hash.n = n
  return t
end

local function tunpack(t, i, j)
  local n = getn(t, 1, "unpack", TR)
  i = R.optinteger(i, 2, "unpack", 1)
  local e = (j == nil) and n or R.checkinteger(j, 3, "unpack")
  if i > e then return end
  local d = e - i   -- number of elements minus 1
  if d < 0 or d >= INT_MAX or d + 1 >= 1000000 then
    R.rterror("too many results to unpack")
  end
  if isTable(t) and t.mt == nil then return unpack(t.hash, i, e) end
  local vals = {}
  for k = 0, d do vals[k + 1] = geti(t, i + k) end
  return unpack(vals, 1, d + 1)
end

---------------------------------------------------------------------------
-- Quicksort (Sedgewick, as in ltablib.c). 'less' is the order predicate.
---------------------------------------------------------------------------

-- l_randomizePivot
local function makeseed()
  return R.makeseed() & 0xFFFFFFFF
end

local function choosePivot(lo, up, rnd)
  local r4 = (up - lo) // 4
  return (rnd ~ lo ~ up) % (r4 * 2) + (lo + r4)
end

-- Pivot P is at a[up - 1]; partition a[lo+1 .. up-2] and return its index.
local function partition(t, lo, up, P, less)
  local i, j = lo, up - 1
  while true do
    i = i + 1
    local ai = geti(t, i)
    while less(ai, P) do
      if i == up - 1 then R.rterror("invalid order function for sorting") end
      i = i + 1
      ai = geti(t, i)
    end
    j = j - 1
    local aj = geti(t, j)
    while less(P, aj) do
      if j < i then R.rterror("invalid order function for sorting") end
      j = j - 1
      aj = geti(t, j)
    end
    if j < i then
      seti(t, up - 1, ai)
      seti(t, i, P)
      return i
    end
    seti(t, i, aj)
    seti(t, j, ai)
  end
end

local function auxsort(t, lo, up, rnd, less)
  while lo < up do
    -- sort a[lo], a[p], a[up]
    local alo, aup = geti(t, lo), geti(t, up)
    if less(aup, alo) then
      seti(t, lo, aup)
      seti(t, up, alo)
    end
    if up - lo == 1 then return end
    local p
    if up - lo < RANLIMIT or rnd == 0 then
      p = (lo + up) // 2
    else
      p = choosePivot(lo, up, rnd)
    end
    local ap = geti(t, p)
    alo = geti(t, lo)
    if less(ap, alo) then
      seti(t, p, alo)
      seti(t, lo, ap)
    else
      aup = geti(t, up)
      if less(aup, ap) then
        seti(t, p, aup)
        seti(t, up, ap)
      end
    end
    if up - lo == 2 then return end
    local P = geti(t, p)
    seti(t, p, geti(t, up - 1))
    seti(t, up - 1, P)
    p = partition(t, lo, up, P, less)
    local n
    if p - lo < up - p then
      auxsort(t, lo, p - 1, rnd, less)
      n = p - lo
      lo = p + 1
    else
      auxsort(t, p + 1, up, rnd, less)
      n = up - p
      up = p - 1
    end
    if (up - lo) // 128 > n then rnd = makeseed() end
  end
end

local function tsort(t, comp)
  local n = getn(t, 1, "sort", TR | TW)
  if n > 1 then
    if n >= INT_MAX then R.argerror(1, "sort", "array too big") end
    local less = R.lt
    if comp ~= nil then
      R.checkfunction(comp, 2, "sort")
      less = function(a, b) return R.truthy((comp(a, b))) end
    end
    auxsort(t, 1, n, 0, less)
  end
end

return function(G)
  local lib = R.newtable()
  R.setfuncs(lib, {
    concat = tconcat,
    create = tcreate,
    insert = tinsert,
    move = tmove,
    pack = tpack,
    remove = tremove,
    sort = function(t, comp)
      -- the comparator and metamethods run from a C boundary: not yieldable,
      -- and called from a native (no Lua call site)
      local st = R.stack
      local saved, savednat = st.nny or 0, st.nat
      st.nny = saved + 1
      st.nat = st.n
      local ok, err = pcall(tsort, t, comp)
      st.nny = saved
      st.nat = savednat
      if not ok then error(err, 0) end
    end,
    unpack = tunpack,
  })
  G.hash.table = lib
end
