-- runtime.lua: value model and core semantics of the Lua 5.5 interpreter.
--
-- Value representation
--   nil, boolean, number (integer/float), string, function, thread
--                      -> the corresponding host Lua values
--   table                -> object created by R.newtable(): a host table whose
--                           metatable is TableMT, with fields
--                             hash  host table holding every key/value pair
--                             mt    Lua metatable (a Lua table) or nil
--                             n     border hint used by R.rawlen
--   userdata             -> object created by R.newuserdata(): host table with
--                           metatable UserdataMT, fields payload and mt
--
-- Host primitives used: arithmetic/comparison on numbers and strings,
-- tonumber(string), coroutine switching, math.tointeger. Everything with
-- Lua-level meaning (metamethods, errors, calls, indexing) lives here.

local R = {}

local type, getmetatable, setmetatable = type, getmetatable, setmetatable
local tostring, tonumber, next = tostring, tonumber, next
local mtype, tointeger = math.type, math.tointeger
local unpack, pack = table.unpack, table.pack
local error = error

local TableMT = {}      -- host metatable marking Lua tables
local UserdataMT = {}   -- host metatable marking userdata
R.TableMT = TableMT
R.UserdataMT = UserdataMT

-- Variants for objects whose Lua metatable has __gc when it is set: the host
-- calls __gc (the host finalizer) when the object is collected, and that
-- calls the Lua finalizer. Lua semantics: the field is checked at setmetatable time.
local TableGcMT, UserdataGcMT = {}, {}
local function isTableClass(c) return c == TableMT or c == TableGcMT end
local function isUserdataClass(c) return c == UserdataMT or c == UserdataGcMT end

-- Error object used to unwind a suspended coroutine that is being closed
-- (coroutine.close). It is not catchable by pcall and closes variables without
-- an error argument, as in Lua.
R.CLOSING = setmetatable({}, { __name = "closing" })

-- Metatables for types other than table/userdata (e.g. typemt.string).
R.typemt = {}

-- Frame stack of the running coroutine. Compiled Lua functions push a frame
-- {src = short source, line = current line} on entry and pop it on exit.
-- Native functions do not push frames.
R.stack = { n = 0 }

---------------------------------------------------------------------------
-- Errors
---------------------------------------------------------------------------

-- Position prefix "src:line: " of the Lua frame `level` levels from the top
-- (level 1 = innermost Lua function). Empty string if there is no such frame.
local function where(level)
  local st = R.stack
  -- a native called directly by another native (e.g. pcall(error, msg)) has
  -- no Lua caller, so it gets no position: st.nat is the depth of such a call
  if level == 1 and st.nat == st.n then return "" end
  local i = st.n - level + 1
  local f = i >= 1 and st[i]
  if f then return f.src .. ":" .. f.line .. ": " end
  return ""
end
R.where = where

-- Raise a Lua value unchanged (no position added).
local function throw(v)
  error(v, 0)
end
R.throw = throw

-- Raise a runtime error message with the position of the current Lua frame.
local function rterror(msg)
  error(where(1) .. msg, 0)
end
R.rterror = rterror

-- The Lua frame that called the running native, or nil if a native called it
-- (no Lua call site: the function is then named by its global name).
local function callerframe()
  local st = R.stack
  if st.nat == st.n then return nil end
  return st[st.n]
end

-- Global name of a library function (as luaL_argerror's pushglobalfuncname):
-- searches the loaded modules for the function itself (fobj), or else for a
-- function stored under fname.
local function qualifiedname(fname, fobj)
  local loaded = R.loadedtable
  if loaded ~= nil then
    -- global functions are named without their module (_G.print is "print")
    local g = loaded.hash._G
    if fobj ~= nil then
      for mk, mod in next, loaded.hash do
        if R.isTable(mod) then
          for fk, fv in next, mod.hash do
            if fv == fobj and type(fk) == "string" then
              return (mk == "_G") and fk or (mk .. "." .. fk)
            end
          end
        end
      end
    end
    if fobj ~= nil then return fname end   -- known function, not in a loaded module
    if R.isTable(g) and type(g.hash[fname]) == "function" then return fname end
    local k, mod = next(loaded.hash, nil)
    while k ~= nil do
      if R.isTable(mod) and type(mod.hash[fname]) == "function" then
        return (k == "_G") and fname or (k .. "." .. fname)
      end
      k, mod = next(loaded.hash, k)
    end
  end
  return fname
end

local function argerror(n, fname, msg)
  local st = R.stack
  local cf = callerframe()
  local desc = cf and cf.cdesc
  if desc and desc:sub(1, 8) == "method '" then
    -- method call: the receiver is argument 1 for the call but not for the function
    n = n - 1
    if n == 0 then rterror("calling '" .. fname .. "' on bad self (" .. msg .. ")") end
  end
  if cf == nil then fname = qualifiedname(fname, st.natfn) end
  rterror("bad argument #" .. n .. " to '" .. fname .. "' (" .. msg .. ")")
end
R.argerror = argerror

---------------------------------------------------------------------------
-- Types and metatables
---------------------------------------------------------------------------

-- Lua type name of any value.
local function ltype(v)
  local t = type(v)
  if t == "table" then
    local c = getmetatable(v)
    if isTableClass(c) then return "table" end
    if isUserdataClass(c) then return "userdata" end
    error("internal: host table leaked into Lua values")
  end
  return t
end
R.type = ltype

-- Lua metatable of any value (a Lua table) or nil.
local function getmt(v)
  local t = type(v)
  if t == "table" then
    local c = getmetatable(v)
    if isTableClass(c) or isUserdataClass(c) then return v.mt end
    return nil
  end
  return R.typemt[t]
end
R.getmt = getmt

-- Type name for error messages: the __name metafield if it is a string.
local function objtypename(v)
  local mt = getmt(v)
  if mt ~= nil then
    local name = mt.hash.__name
    if type(name) == "string" then return name end
  end
  return ltype(v)
end
R.objtypename = objtypename

-- Raw metamethod lookup: the value of field `ev` in the metatable, or nil.
local function metamethod(v, ev)
  local mt = getmt(v)
  if mt == nil then return nil end
  return mt.hash[ev]
end
R.metamethod = metamethod

local function isTable(v)
  return type(v) == "table" and isTableClass(getmetatable(v))
end
R.isTable = isTable

local function isUserdata(v)
  return type(v) == "table" and isUserdataClass(getmetatable(v))
end
R.isUserdata = isUserdata

local function newtable()
  return setmetatable({ hash = {}, n = 0, mt = nil }, TableMT)
end
R.newtable = newtable

function R.newuserdata(payload, mt)
  return setmetatable({ payload = payload, mt = mt }, UserdataMT)
end

-- Weak-mode metatables for the host storage of weak Lua tables.
local weakmts = {}
local function weakmt(mode)
  local m = weakmts[mode]
  if not m then
    m = { __mode = mode }
    weakmts[mode] = m
  end
  return m
end

-- Runs the Lua finalizer of an object collected by the host.
local function finalize(o)
  local mt = o.mt
  local h = mt and mt.hash.__gc
  if h ~= nil then
    -- errors in finalizers are ignored (Lua reports them only as warnings)
    pcall(R.call, h, o)
  end
end
R.finalize = finalize
TableGcMT.__gc = finalize
UserdataGcMT.__gc = finalize

-- Set the Lua metatable of a table or userdata (mt is a Lua table or nil).
function R.setmetatable(obj, mt)
  obj.mt = mt
  if mt ~= nil and mt.hash.__gc ~= nil then
    local c = getmetatable(obj)
    if c == TableMT then setmetatable(obj, TableGcMT)
    elseif c == UserdataMT then setmetatable(obj, UserdataGcMT) end
  end
  if isTable(obj) then
    local mode = mt and mt.hash.__mode
    if type(mode) == "string" and (mode:find("k", 1, true) or mode:find("v", 1, true)) then
      setmetatable(obj.hash, weakmt(mode))
    else
      setmetatable(obj.hash, nil)
    end
  end
  return obj
end

---------------------------------------------------------------------------
-- Raw table access
---------------------------------------------------------------------------

local function rawget(t, k)
  return t.hash[k]
end
R.rawget = rawget

local function rawset(t, k, v)
  if k == nil then rterror("table index is nil") end
  if k ~= k then rterror("table index is NaN") end
  t.hash[k] = v
end
R.rawset = rawset

-- A border of the table (raw length). Uses t.n as a hint.
local function rawlen(t)
  local h, n = t.hash, t.n
  if n > 0 and h[n] == nil then
    repeat n = n - 1 until n == 0 or h[n] ~= nil
  else
    while h[n + 1] ~= nil do n = n + 1 end
  end
  t.n = n
  return n
end
R.rawlen = rawlen

-- Lua `next`: returns the key and value following k, or nil at the end.
function R.next(t, k)
  return next(t.hash, k)
end

---------------------------------------------------------------------------
-- Calls
---------------------------------------------------------------------------

-- Calls f(...) honouring __call chains (at most 15 objects, as in Lua 5.5).
-- desc names the called expression for error messages; n counts the chain.
local function callchain(desc, f, n, ...)
  if type(f) == "function" then return f(...) end
  local h = metamethod(f, "__call")
  if h == nil then
    rterror("attempt to call a " .. objtypename(f) .. " value" .. (desc and (" (" .. desc .. ")") or ""))
  end
  if n >= 15 then rterror("'__call' chain too long; possibly a loop") end
  return callchain(nil, h, n + 1, f, ...)
end

-- Call any Lua value with the given arguments; returns all results.
local function call(f, ...)
  return callchain(nil, f, 0, ...)
end
R.call = call

-- Calls f from a library function (a C boundary in Lua): the call is not
-- yieldable, so the coroutine's non-yieldable depth is raised meanwhile.
function R.ccall(f, ...)
  local st = R.stack
  local saved, savednat = st.nny or 0, st.nat
  st.nny = saved + 1
  st.nat = st.n   -- a native called from here has no Lua call site
  local savedn, savedf = st.natnargs, st.natfn
  st.natnargs, st.natfn = select("#", ...), f
  local r = pack(call(f, ...))
  st.natnargs, st.natfn = savedn, savedf
  st.nny = saved
  st.nat = savednat
  return unpack(r, 1, r.n)
end

-- Like call, but the error message names the called expression `desc`
-- (for example "global 'print'"). Used by compiled code.
local function callx(desc, f, ...)
  return callchain(desc, f, 0, ...)
end
R.callx = callx

---------------------------------------------------------------------------
-- Indexing
---------------------------------------------------------------------------

local function varinfo(desc)
  return desc and (" (" .. desc .. ")") or ""
end
R.varinfo = varinfo

-- o[k] with the __index metamethod chain. desc names o for error messages.
local function index(o, k, desc)
  for _ = 1, 2000 do
    local h
    if type(o) == "table" and isTableClass(getmetatable(o)) then
      local v = o.hash[k]
      if v ~= nil then return v end
      local mt = o.mt
      if mt == nil then return nil end
      h = mt.hash.__index
      if h == nil then return nil end
    else
      local mt = getmt(o)
      if mt == nil then
        rterror("attempt to index a " .. objtypename(o) .. " value" .. varinfo(desc))
      end
      h = mt.hash.__index
      if h == nil then
        rterror("attempt to index a " .. objtypename(o) .. " value" .. varinfo(desc))
      end
    end
    if type(h) == "function" then return (h(o, k)) end
    o = h
    desc = nil
  end
  rterror("'__index' chain too long; possibly a loop")
end
R.index = index

-- o[k] = v with the __newindex metamethod chain.
local function setindex(o, k, v, desc)
  for _ = 1, 2000 do
    local h
    if type(o) == "table" and isTableClass(getmetatable(o)) then
      local hash = o.hash
      if hash[k] ~= nil then
        hash[k] = v
        return
      end
      local mt = o.mt
      h = mt and mt.hash.__newindex
      if h == nil then
        rawset(o, k, v)
        return
      end
    else
      local mt = getmt(o)
      if mt == nil then
        rterror("attempt to index a " .. objtypename(o) .. " value" .. varinfo(desc))
      end
      h = mt.hash.__newindex
      if h == nil then
        rterror("attempt to index a " .. objtypename(o) .. " value" .. varinfo(desc))
      end
    end
    if type(h) == "function" then
      h(o, k, v)
      return
    end
    o = h
    desc = nil
  end
  rterror("'__newindex' chain too long; possibly a loop")
end
R.setindex = setindex

---------------------------------------------------------------------------
-- Numbers and coercions
---------------------------------------------------------------------------

-- Number value of v for arithmetic (numbers and numeric strings), or nil.
local function tonum(v)
  local t = type(v)
  if t == "number" then return v end
  if t == "string" then return tonumber(v) end
  return nil
end
R.tonum = tonum

-- Integer value of v for bitwise operations, or nil.
local function tointeger_v(v)
  local x = tonum(v)
  if x == nil then return nil end
  return tointeger(x)
end
R.tointegerv = tointeger_v

-- Lua `tonumber(v)`: number, numeric string converted, or nil.
function R.tonumber(v)
  return tonum(v)
end

-- Lua `math.tointeger`-like conversion (numbers and numeric strings).
function R.tointeger(v)
  return tointeger_v(v)
end

---------------------------------------------------------------------------
-- Arithmetic
---------------------------------------------------------------------------

-- Calls metamethod h for event ev; errors name it as "metamethod 'add'".
local function mmcall(ev, h, a, b)
  return (callx("metamethod '" .. ev:sub(3) .. "'", h, a, b))
end

local function arithmeta(ev, a, b, da, db)
  local h = metamethod(a, ev) or metamethod(b, ev)
  if h ~= nil then return mmcall(ev, h, a, b) end
  -- blame the first operand that is not a number
  local culprit, d = b, db
  if tonum(a) == nil then culprit, d = a, da end
  rterror("attempt to perform arithmetic on a " .. objtypename(culprit) .. " value" .. varinfo(d))
end

local function bitmeta(ev, a, b, da, db)
  local h = metamethod(a, ev) or metamethod(b, ev)
  if h ~= nil then return mmcall(ev, h, a, b) end
  if tonum(a) ~= nil and tonum(b) ~= nil then
    -- blame the operand that has no integer representation
    local d = (tointeger_v(a) == nil) and da or db
    rterror("number" .. varinfo(d) .. " has no integer representation")
  end
  local culprit, d = b, db
  if tonum(a) == nil then culprit, d = a, da end
  rterror("attempt to perform bitwise operation on a " .. objtypename(culprit) .. " value" .. varinfo(d))
end

function R.add(a, b, da, db)
  local x, y = tonum(a), tonum(b)
  if x and y then return x + y end
  return arithmeta("__add", a, b, da, db)
end

function R.sub(a, b, da, db)
  local x, y = tonum(a), tonum(b)
  if x and y then return x - y end
  return arithmeta("__sub", a, b, da, db)
end

function R.mul(a, b, da, db)
  local x, y = tonum(a), tonum(b)
  if x and y then return x * y end
  return arithmeta("__mul", a, b, da, db)
end

function R.div(a, b, da, db)
  local x, y = tonum(a), tonum(b)
  if x and y then return x / y end
  return arithmeta("__div", a, b, da, db)
end

function R.pow(a, b, da, db)
  local x, y = tonum(a), tonum(b)
  if x and y then return x ^ y end
  return arithmeta("__pow", a, b, da, db)
end

function R.mod(a, b, da, db)
  local x, y = tonum(a), tonum(b)
  if x and y then
    if mtype(x) == "integer" and mtype(y) == "integer" then
      if y == 0 then rterror("attempt to perform 'n%0'") end
    end
    return x % y
  end
  return arithmeta("__mod", a, b, da, db)
end

function R.idiv(a, b, da, db)
  local x, y = tonum(a), tonum(b)
  if x and y then
    if mtype(x) == "integer" and mtype(y) == "integer" then
      if y == 0 then rterror("attempt to divide by zero") end
    end
    return x // y
  end
  return arithmeta("__idiv", a, b, da, db)
end

function R.unm(a, da)
  local x = tonum(a)
  if x then return -x end
  local h = metamethod(a, "__unm")
  if h ~= nil then return (call(h, a, a)) end
  rterror("attempt to perform arithmetic on a " .. objtypename(a) .. " value" .. varinfo(da))
end

function R.band(a, b, da, db)
  local x, y = tointeger_v(a), tointeger_v(b)
  if x and y then return x & y end
  return bitmeta("__band", a, b, da, db)
end

function R.bor(a, b, da, db)
  local x, y = tointeger_v(a), tointeger_v(b)
  if x and y then return x | y end
  return bitmeta("__bor", a, b, da, db)
end

function R.bxor(a, b, da, db)
  local x, y = tointeger_v(a), tointeger_v(b)
  if x and y then return x ~ y end
  return bitmeta("__bxor", a, b, da, db)
end

function R.shl(a, b, da, db)
  local x, y = tointeger_v(a), tointeger_v(b)
  if x and y then return x << y end
  return bitmeta("__shl", a, b, da, db)
end

function R.shr(a, b, da, db)
  local x, y = tointeger_v(a), tointeger_v(b)
  if x and y then return x >> y end
  return bitmeta("__shr", a, b, da, db)
end

function R.bnot(a, da)
  local x = tointeger_v(a)
  if x then return ~x end
  local h = metamethod(a, "__bnot")
  if h ~= nil then return (call(h, a, a)) end
  if tonum(a) ~= nil then rterror("number has no integer representation") end
  rterror("attempt to perform bitwise operation on a " .. objtypename(a) .. " value" .. varinfo(da))
end

---------------------------------------------------------------------------
-- Comparison, concatenation, length
---------------------------------------------------------------------------

local function truthy(v)
  return v ~= nil and v ~= false
end
R.truthy = truthy

function R.eq(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  local ca, cb = getmetatable(a), getmetatable(b)
  if not (isTableClass(ca) or isUserdataClass(ca)) or not (isTableClass(cb) or isUserdataClass(cb)) then
    return false
  end
  local h = metamethod(a, "__eq") or metamethod(b, "__eq")
  if h == nil then return false end
  return truthy((call(h, a, b)))
end

local function cmperror(a, b)
  local t1, t2 = objtypename(a), objtypename(b)
  if t1 == t2 then
    rterror("attempt to compare two " .. t1 .. " values")
  end
  rterror("attempt to compare " .. t1 .. " with " .. t2)
end

function R.lt(a, b)
  local ta, tb = type(a), type(b)
  if (ta == "number" or ta == "string") and ta == tb then return a < b end
  local h = metamethod(a, "__lt") or metamethod(b, "__lt")
  if h == nil then cmperror(a, b) end
  return truthy((mmcall("__lt", h, a, b)))
end

function R.le(a, b)
  local ta, tb = type(a), type(b)
  if (ta == "number" or ta == "string") and ta == tb then return a <= b end
  local h = metamethod(a, "__le") or metamethod(b, "__le")
  if h == nil then cmperror(a, b) end
  return truthy((mmcall("__le", h, a, b)))
end

function R.concat(a, b, da, db)
  local ta, tb = type(a), type(b)
  if (ta == "string" or ta == "number") and (tb == "string" or tb == "number") then
    return a .. b
  end
  local h = metamethod(a, "__concat") or metamethod(b, "__concat")
  if h ~= nil then return mmcall("__concat", h, a, b) end
  local culprit, d = b, db
  if ta == "string" or ta == "number" then culprit, d = b, db else culprit, d = a, da end
  rterror("attempt to concatenate a " .. objtypename(culprit) .. " value" .. varinfo(d))
end

-- Lua `#v`.
local function len(v, desc)
  if type(v) == "string" then return #v end
  local h = metamethod(v, "__len")
  if h ~= nil then return (call(h, v, v)) end   -- like Lua, the operand is passed twice
  if isTable(v) then return rawlen(v) end
  rterror("attempt to get length of a " .. objtypename(v) .. " value" .. varinfo(desc))
end
R.len = len

---------------------------------------------------------------------------
-- tostring
---------------------------------------------------------------------------

-- Address part of the host representation, e.g. "0x5581...".
local function addr_of(v)
  return (tostring(v):gsub("^[^:]+: ", ""))
end

-- Lua `tostring(v)` (honours __tostring and __name).
local function tostr(v)
  local t = type(v)
  if t == "string" then return v end
  if t == "number" then return tostring(v) end
  if t == "nil" or t == "boolean" then return tostring(v) end
  local h = metamethod(v, "__tostring")
  if h ~= nil then
    local s = (call(h, v))
    if type(s) == "number" then return tostring(s) end
    if type(s) ~= "string" then rterror("'__tostring' must return a string") end
    return s
  end
  local lt = ltype(v)
  local name = metamethod(v, "__name")
  if type(name) == "string" and (lt == "table" or lt == "userdata") then
    return name .. ": " .. addr_of(v)
  end
  if lt == "table" or lt == "userdata" then
    return lt .. ": " .. addr_of(v)
  end
  return tostring(v)
end
R.tostring = tostr

---------------------------------------------------------------------------
-- Argument checking helpers for library functions
---------------------------------------------------------------------------

local function typeerror(n, fname, expected, v)
  local got = (v == nil) and "nil" or objtypename(v)
  if v == nil then
    -- an argument past the ones the caller passed is "no value"
    local st = R.stack
    local nargs
    if st.nat == st.n then nargs = st.natnargs    -- called from a native
    elseif st.n > 0 then nargs = st[st.n].nargs end
    if nargs and n > nargs then got = "no value" end
  end
  local mt = getmt(v)
  if mt ~= nil and type(mt.hash.__name) == "string" then got = mt.hash.__name end
  argerror(n, fname, expected .. " expected, got " .. got)
end
R.typeerror = typeerror

function R.checkinteger(v, n, fname)
  if mtype(v) == "integer" then return v end
  local x = tonum(v)
  if x == nil then typeerror(n, fname, "number", v) end
  local i = tointeger(x)
  if i == nil then argerror(n, fname, "number has no integer representation") end
  return i
end

function R.optinteger(v, n, fname, default)
  if v == nil then return default end
  return R.checkinteger(v, n, fname)
end

function R.checknumber(v, n, fname)
  local x = tonum(v)
  if x == nil then typeerror(n, fname, "number", v) end
  return x
end

function R.optnumber(v, n, fname, default)
  if v == nil then return default end
  return R.checknumber(v, n, fname)
end

function R.checkstring(v, n, fname)
  local t = type(v)
  if t == "string" then return v end
  if t == "number" then return tostring(v) end
  typeerror(n, fname, "string", v)
end

function R.optstring(v, n, fname, default)
  if v == nil then return default end
  return R.checkstring(v, n, fname)
end

function R.checktable(v, n, fname)
  if not isTable(v) then typeerror(n, fname, "table", v) end
  return v
end

function R.checkfunction(v, n, fname)
  if type(v) ~= "function" then typeerror(n, fname, "function", v) end
  return v
end

---------------------------------------------------------------------------
-- Library installation helper
---------------------------------------------------------------------------

-- Store the functions of `fns` (name -> value) into Lua table t.
function R.setfuncs(t, fns)
  for k, v in pairs(fns) do
    t.hash[k] = v
  end
  return t
end

-- Build a Lua table from a host array (values 1..n) with field n = count.
function R.fromarray(arr, n)
  local t = newtable()
  for i = 1, n or #arr do t.hash[i] = arr[i] end
  return t
end

return R
