-- os.lua: the os library (follows loslib.c). Host os primitives do the
-- system work; argument handling, date-format validation and table
-- normalisation for os.time are done here.
local R = require("runtime")
local H = os                                    -- host os library

-- strftime conversions accepted by os.date (LUA_STRFTIMEOPTIONS, C99)
local DATE_SINGLE = "aAbBcCdDeFgGhHIjmMnprRStTuUVwWxXyYzZ%"
local DATE_DOUBLE = {}
for c in ("Ec EC Ex EX Ey EY Od Oe OH OI Om OM OS Ou OU OV Ow OW Oy"):gmatch("%S+") do
  DATE_DOUBLE[c] = true
end
local DATE_FIELDS = { "year", "month", "day", "hour", "min", "sec", "yday", "wday", "isdst" }
local LOCALE_CATS = { all = true, collate = true, ctype = true, monetary = true, numeric = true, time = true }
local INT_MAX, INT_MIN = 2147483647, -2147483648

local function os_date(fmt, t)
  fmt = R.optstring(fmt, 1, "date", "%c")
  local tt = (t == nil) and H.time() or R.checkinteger(t, 2, "date")
  local utc = fmt:sub(1, 1) == "!"
  local pre = utc and "!" or ""
  local s = utc and fmt:sub(2) or fmt
  if s == "*t" then
    local ht = H.date(pre .. "*t", tt)
    local r = R.newtable()
    for _, k in ipairs(DATE_FIELDS) do R.rawset(r, k, ht[k]) end
    return r
  end
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c ~= "%" then
      out[#out + 1] = c
      i = i + 1
    else
      local rest = s:sub(i + 1)
      local cc
      if rest ~= "" and DATE_SINGLE:find(rest:sub(1, 1), 1, true) then
        cc = rest:sub(1, 1)
      elseif DATE_DOUBLE[rest:sub(1, 2)] then
        cc = rest:sub(1, 2)
      else
        R.argerror(1, "date", "invalid conversion specifier '%" .. rest .. "'")
      end
      out[#out + 1] = H.date(pre .. "%" .. cc, tt)
      i = i + 1 + #cc
    end
  end
  return table.concat(out)
end

-- Integer field `key` of date table `tab` (getfield in loslib.c). d < 0 means required.
local function getfield(tab, key, d, delta)
  local v = R.index(tab, key)
  local res = R.tointegerv(v)
  if res == nil then
    if v ~= nil then R.rterror("field '" .. key .. "' is not an integer") end
    if d < 0 then R.rterror("field '" .. key .. "' missing in date table") end
    return d
  end
  local ok
  if res >= 0 then ok = res - delta <= INT_MAX else ok = INT_MIN + delta <= res end
  if not ok then R.rterror("field '" .. key .. "' is out-of-bound") end
  return res
end

local function os_time(tab)
  if tab == nil then return H.time() end
  R.checktable(tab, 1, "time")
  local ht = {
    year = getfield(tab, "year", -1, 1900),
    month = getfield(tab, "month", -1, 1),
    day = getfield(tab, "day", -1, 0),
    hour = getfield(tab, "hour", 12, 0),
    min = getfield(tab, "min", 0, 0),
    sec = getfield(tab, "sec", 0, 0),
  }
  local isdst = R.index(tab, "isdst")
  if isdst ~= nil then ht.isdst = R.truthy(isdst) end
  local t = H.time(ht)
  -- update the fields with the normalised values, as mktime does
  local norm = H.date("*t", t)
  for _, k in ipairs(DATE_FIELDS) do R.setindex(tab, k, norm[k]) end
  return t
end

local function os_difftime(t1, t2)
  return H.difftime(R.checkinteger(t1, 1, "difftime"), R.checkinteger(t2, 2, "difftime"))
end

local function os_execute(cmd)
  cmd = R.optstring(cmd, 1, "execute")
  if cmd == nil then return H.execute() end   -- true if there is a shell
  return H.execute(cmd)
end

local function os_exit(status, close)
  local code
  if type(status) == "boolean" then
    code = status and 0 or 1
  else
    code = R.optinteger(status, 1, "exit", 0)
  end
  H.stdout:flush()
  H.exit(code, R.truthy(close))
end

local function os_setlocale(locale, category)
  locale = R.optstring(locale, 1, "setlocale")
  category = R.optstring(category, 2, "setlocale", "all")
  if not LOCALE_CATS[category] then
    R.argerror(2, "setlocale", "invalid option '" .. category .. "'")
  end
  -- only the "C" locale is available
  if locale == nil or locale == "" or locale == "C" or locale == "POSIX" then return "C" end
  return nil
end

return function(G)
  local lib = R.newtable()
  R.setfuncs(lib, {
    clock = H.clock,
    date = os_date,
    difftime = os_difftime,
    execute = os_execute,
    exit = os_exit,
    getenv = function(name) return H.getenv(R.checkstring(name, 1, "getenv")) end,
    remove = function(name) return H.remove(R.checkstring(name, 1, "remove")) end,
    rename = function(from, to)
      return H.rename(R.checkstring(from, 1, "rename"), R.checkstring(to, 2, "rename"))
    end,
    setlocale = os_setlocale,
    time = os_time,
    tmpname = function() return H.tmpname() end,
  })
  G.hash.os = lib
end
