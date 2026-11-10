-- lib/string.lua: the Lua 5.5 string library, installed as G.hash.string.
-- Lua patterns, string.format and string.pack/unpack are implemented here.
-- Host primitives are used only as building blocks: string.byte/char/sub/
-- format, math.type/tointeger/floor/log/ult-free arithmetic, table.concat/
-- unpack, select, tostring.

local R = require("runtime")

local sbyte, schar, ssub, sformat = string.byte, string.char, string.sub, string.format
local concat, unpack = table.concat, table.unpack
local mtype, floor, log = math.type, math.floor, math.log
local select, tostring = select, tostring

local checkinteger, optinteger = R.checkinteger, R.optinteger
local checknumber = R.checknumber
local checkstring, optstring = R.checkstring, R.optstring
local rterror, argerror = R.rterror, R.argerror

local MAXSIZE = math.maxinteger
local INF, NAN = math.huge, 0.0 / 0.0
local L_ESC = 37                      -- '%'
local MAXCAPTURES = 32
local MAXCCALLS = 200
local CAP_UNFINISHED, CAP_POSITION = -1, -2

-- Whether the host is little endian (probe through the host string.pack).
local NATIVE_LITTLE = string.pack("=i2", 1) == string.pack("<i2", 1)

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function isdigit(c) return c ~= nil and c >= 48 and c <= 57 end
local function isalpha(c) return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) end
local function isalnum(c) return isalpha(c) or isdigit(c) end
local function isgraph(c) return c >= 33 and c <= 126 end

local function mkset(str)
  local t = {}
  for i = 1, #str do t[sbyte(str, i)] = true end
  return t
end

local function srep(s, n)
  local t = {}
  for i = 1, n do t[i] = s end
  return concat(t)
end

-- First index >= i where byte c occurs in s, or nil.
local function findbyte(s, c, i)
  for j = i, #s do
    if sbyte(s, j) == c then return j end
  end
  return nil
end

local function haszero(s)
  return findbyte(s, 0, 1) ~= nil
end

-- Relative start position (lstrlib.c posrelatI); result >= 1.
local function posrelatI(pos, len)
  if pos > 0 then return pos
  elseif pos == 0 then return 1
  elseif pos < -len then return 1
  else return len + pos + 1 end
end

-- Relative end position (lstrlib.c getendpos); result in [0, len].
local function getendpos(pos, len)
  if pos > len then return len
  elseif pos >= 0 then return pos
  elseif pos < -len then return 0
  else return len + pos + 1 end
end

---------------------------------------------------------------------------
-- Pattern matching
---------------------------------------------------------------------------

local SPECIALS = mkset("^$*+?.([%-")

local CLASS = {
  [97] = isalpha,                                                  -- a
  [99] = function(c) return c < 32 or c == 127 end,                -- c
  [100] = isdigit,                                                 -- d
  [103] = isgraph,                                                 -- g
  [108] = function(c) return c >= 97 and c <= 122 end,             -- l
  [112] = function(c) return isgraph(c) and not isalnum(c) end,    -- p
  [115] = function(c) return c == 32 or (c >= 9 and c <= 13) end,  -- s
  [117] = function(c) return c >= 65 and c <= 90 end,              -- u
  [119] = isalnum,                                                 -- w
  [120] = function(c)                                              -- x
    return isdigit(c) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70)
  end,
  [122] = function(c) return c == 0 end,                           -- z
}

local function match_class(c, cl)
  local lower = (cl >= 65 and cl <= 90) and cl + 32 or cl
  local f = CLASS[lower]
  if f == nil then return cl == c end
  local res = f(c)
  if lower == cl then return res end
  return not res
end

-- p is the index of '[', ec the index of the closing ']'.
local function matchbracketclass(pat, c, p, ec)
  local sig = true
  if sbyte(pat, p + 1) == 94 then    -- '^'
    sig = false
    p = p + 1
  end
  p = p + 1
  while p < ec do
    local pc = sbyte(pat, p)
    if pc == L_ESC then
      p = p + 1
      if match_class(c, sbyte(pat, p)) then return sig end
    elseif sbyte(pat, p + 1) == 45 and p + 2 < ec then   -- range 'a-z'
      p = p + 2
      if pc <= c and c <= sbyte(pat, p) then return sig end
    elseif pc == c then
      return sig
    end
    p = p + 1
  end
  return not sig
end

local function newstate(src, pat)
  return {
    src = src, ls = #src, pat = pat, lp = #pat,
    level = 0, cinit = {}, clen = {}, depth = MAXCCALLS,
  }
end

local function reprep(ms)
  ms.depth = MAXCCALLS
  ms.level = 0
end

-- Index just past the single-character class starting at p.
local function classend(ms, p)
  local pat, lp = ms.pat, ms.lp
  local c = sbyte(pat, p)
  p = p + 1
  if c == L_ESC then
    if p > lp then rterror("malformed pattern (ends with '%')") end
    return p + 1
  elseif c == 91 then    -- '['
    if sbyte(pat, p) == 94 then p = p + 1 end
    repeat
      if p > lp then rterror("malformed pattern (missing ']')") end
      local cc = sbyte(pat, p)
      p = p + 1
      if cc == L_ESC and p <= lp then p = p + 1 end
    until sbyte(pat, p) == 93
    return p + 1
  end
  return p
end

local function singlematch(ms, s, p, ep)
  if s > ms.ls then return false end
  local c = sbyte(ms.src, s)
  local pc = sbyte(ms.pat, p)
  if pc == 46 then return true                                  -- '.'
  elseif pc == L_ESC then return match_class(c, sbyte(ms.pat, p + 1))
  elseif pc == 91 then return matchbracketclass(ms.pat, c, p, ep - 1)
  end
  return pc == c
end

-- %bxy: p is the index of 'x'. Returns index after the balanced part or nil.
local function matchbalance(ms, s, p)
  if p >= ms.lp then rterror("malformed pattern (missing arguments to '%b')") end
  local src, pat = ms.src, ms.pat
  if s > ms.ls or sbyte(src, s) ~= sbyte(pat, p) then return nil end
  local b, e = sbyte(pat, p), sbyte(pat, p + 1)
  local cont = 1
  for i = s + 1, ms.ls do
    local c = sbyte(src, i)
    if c == e then
      cont = cont - 1
      if cont == 0 then return i + 1 end
    elseif c == b then
      cont = cont + 1
    end
  end
  return nil
end

local do_match

local function max_expand(ms, s, p, ep)
  local i = 0
  while singlematch(ms, s + i, p, ep) do i = i + 1 end
  while i >= 0 do
    local res = do_match(ms, s + i, ep + 1)
    if res then return res end
    i = i - 1
  end
  return nil
end

local function min_expand(ms, s, p, ep)
  while true do
    local res = do_match(ms, s, ep + 1)
    if res then return res end
    if not singlematch(ms, s, p, ep) then return nil end
    s = s + 1
  end
end

local function start_capture(ms, s, p, what)
  local level = ms.level
  if level >= MAXCAPTURES then rterror("too many captures") end
  ms.cinit[level + 1] = s
  ms.clen[level + 1] = what
  ms.level = level + 1
  local res = do_match(ms, s, p)
  if res == nil then ms.level = ms.level - 1 end
  return res
end

local function capture_to_close(ms)
  for level = ms.level, 1, -1 do
    if ms.clen[level] == CAP_UNFINISHED then return level end
  end
  rterror("invalid pattern capture")
end

local function end_capture(ms, s, p)
  local l = capture_to_close(ms)
  ms.clen[l] = s - ms.cinit[l]
  local res = do_match(ms, s, p)
  if res == nil then ms.clen[l] = CAP_UNFINISHED end
  return res
end

-- Back-reference %d; d is the byte of the digit.
local function match_capture(ms, s, d)
  local l = d - 48
  if l < 1 or l > ms.level or ms.clen[l] == CAP_UNFINISHED then
    rterror("invalid capture index %" .. l)
  end
  local len = ms.clen[l]
  if len < 0 then return nil end      -- position captures never match
  local init = ms.cinit[l]
  if ms.ls - s + 1 >= len and ssub(ms.src, init, init + len - 1) == ssub(ms.src, s, s + len - 1) then
    return s + len
  end
  return nil
end

-- Core matcher: returns the index just past the match of pattern[p..] at s.
do_match = function(ms, s, p)
  if ms.depth == 0 then rterror("pattern too complex") end
  ms.depth = ms.depth - 1
  local pat, lp = ms.pat, ms.lp
  while p <= lp do
    local np                     -- set when matching continues at np
    local pc = sbyte(pat, p)
    local nc = sbyte(pat, p + 1)
    if pc == 40 then                                   -- '('
      if nc == 41 then
        s = start_capture(ms, s, p + 2, CAP_POSITION)
      else
        s = start_capture(ms, s, p + 1, CAP_UNFINISHED)
      end
    elseif pc == 41 then                               -- ')'
      s = end_capture(ms, s, p + 1)
    elseif pc == 36 and p == lp then                   -- '$' at end
      if s ~= ms.ls + 1 then s = nil end
    elseif pc == L_ESC and nc == 98 then               -- %b
      s = matchbalance(ms, s, p + 2)
      if s then np = p + 4 end
    elseif pc == L_ESC and nc == 102 then              -- %f
      p = p + 2
      if sbyte(pat, p) ~= 91 then rterror("missing '[' after '%f' in pattern") end
      local ep = classend(ms, p)
      local prev = (s == 1) and 0 or sbyte(ms.src, s - 1)
      local cur = (s <= ms.ls) and sbyte(ms.src, s) or 0
      if not matchbracketclass(pat, prev, p, ep - 1) and matchbracketclass(pat, cur, p, ep - 1) then
        np = ep
      else
        s = nil
      end
    elseif pc == L_ESC and isdigit(nc) then           -- back-reference
      s = match_capture(ms, s, nc)
      if s then np = p + 2 end
    else                                               -- single class + suffix
      local ep = classend(ms, p)
      local epc = sbyte(pat, ep)
      if not singlematch(ms, s, p, ep) then
        if epc == 42 or epc == 63 or epc == 45 then    -- '*' '?' '-' accept empty
          np = ep + 1
        else
          s = nil
        end
      elseif epc == 63 then                            -- '?'
        local res = do_match(ms, s + 1, ep + 1)
        if res then s = res else np = ep + 1 end
      elseif epc == 43 then                            -- '+'
        s = max_expand(ms, s + 1, p, ep)
      elseif epc == 42 then                            -- '*'
        s = max_expand(ms, s, p, ep)
      elseif epc == 45 then                            -- '-'
        s = min_expand(ms, s, p, ep)
      else
        s = s + 1
        np = ep
      end
    end
    if np == nil then break end
    p = np
  end
  ms.depth = ms.depth + 1
  return s
end

local function get_onecapture(ms, i, s, e)
  if i > ms.level then
    if i ~= 1 then rterror("invalid capture index %" .. i) end
    return ssub(ms.src, s, e - 1)
  end
  local l = ms.clen[i]
  if l == CAP_UNFINISHED then rterror("unfinished capture") end
  local init = ms.cinit[i]
  if l == CAP_POSITION then return init end
  return ssub(ms.src, init, init + l - 1)
end

-- All captures of the current match (the whole match if there are none
-- and s is given). Returns an array and its count.
local function getcaps(ms, s, e)
  local n = ms.level
  if n == 0 and s then n = 1 end
  local t = {}
  for i = 1, n do t[i] = get_onecapture(ms, i, s, e) end
  return t, n
end

local function nospecials(p)
  for i = 1, #p do
    if SPECIALS[sbyte(p, i)] then return false end
  end
  return true
end

-- Plain search of p in s starting at 1-based init; returns start or nil.
local function lmemfind(s, init, p)
  local lp = #p
  if lp == 0 then return init end
  local first = sbyte(p, 1)
  for i = init, #s - lp + 1 do
    if sbyte(s, i) == first and ssub(s, i, i + lp - 1) == p then return i end
  end
  return nil
end

local function find_aux(find, s, p, init, plain)
  local fname = find and "find" or "match"
  s = checkstring(s, 1, fname)
  p = checkstring(p, 2, fname)
  local ls = #s
  local st = posrelatI(optinteger(init, 3, fname, 1), ls)
  if st > ls + 1 then return nil end
  if find and (R.truthy(plain) or nospecials(p)) then
    local at = lmemfind(s, st, p)
    if at then return at, at + #p - 1 end
    return nil
  end
  local ms = newstate(s, p)
  local anchor = sbyte(p, 1) == 94
  local pstart = anchor and 2 or 1
  local s1 = st
  while true do
    reprep(ms)
    local res = do_match(ms, s1, pstart)
    if res then
      if find then
        local caps, n = getcaps(ms, nil, nil)
        return s1, res - 1, unpack(caps, 1, n)
      end
      local caps, n = getcaps(ms, s1, res)
      return unpack(caps, 1, n)
    end
    if anchor or s1 > ls then return nil end
    s1 = s1 + 1
  end
end

local function str_find(s, p, init, plain)
  return find_aux(true, s, p, init, plain)
end

local function str_match(s, p, init)
  return find_aux(false, s, p, init)
end

local function gmatch(s, p, init)
  s = checkstring(s, 1, "gmatch")
  p = checkstring(p, 2, "gmatch")
  local ls = #s
  local st = posrelatI(optinteger(init, 3, "gmatch", 1), ls)
  if st > ls + 1 then st = ls + 2 end
  local ms = newstate(s, p)
  local src, lastmatch = st, nil
  return function()
    while src <= ls + 1 do
      reprep(ms)
      local e = do_match(ms, src, 1)
      if e and e ~= lastmatch then
        local caps, n = getcaps(ms, src, e)
        src, lastmatch = e, e
        return unpack(caps, 1, n)
      end
      src = src + 1
    end
    return
  end
end

-- Append the expansion of a replacement string news for match [s, e).
local function add_s(ms, buf, s, e, news)
  local i = 1
  while true do
    local j = findbyte(news, L_ESC, i)
    if not j then
      buf[#buf + 1] = ssub(news, i)
      return
    end
    buf[#buf + 1] = ssub(news, i, j - 1)
    local c = sbyte(news, j + 1)
    if c == L_ESC then
      buf[#buf + 1] = "%"
    elseif c == 48 then
      buf[#buf + 1] = ssub(ms.src, s, e - 1)
    elseif c and c >= 49 and c <= 57 then
      buf[#buf + 1] = tostring(get_onecapture(ms, c - 48, s, e))
    else
      rterror("invalid use of '%' in replacement string")
    end
    i = j + 2
  end
end

-- Append the replacement for one match; returns true if the subject changed.
local function add_value(ms, buf, s, e, repl, tr)
  local v
  if tr == "function" then
    local caps, n = getcaps(ms, s, e)
    v = (R.call(repl, unpack(caps, 1, n)))
  elseif tr == "table" then
    v = R.index(repl, (get_onecapture(ms, 1, s, e)))
  else
    add_s(ms, buf, s, e, repl)
    return true
  end
  if v == nil or v == false then
    buf[#buf + 1] = ssub(ms.src, s, e - 1)
    return false
  end
  local tv = R.type(v)
  if tv ~= "string" and tv ~= "number" then
    rterror("invalid replacement value (a " .. tv .. ")")
  end
  buf[#buf + 1] = tostring(v)
  return true
end

local function gsub(src, p, repl, maxn)
  src = checkstring(src, 1, "gsub")
  p = checkstring(p, 2, "gsub")
  local srcl = #src
  local tr = R.type(repl)
  local maxs = optinteger(maxn, 4, "gsub", srcl + 1)
  if tr == "number" then
    repl = tostring(repl)
    tr = "string"
  end
  if tr ~= "string" and tr ~= "function" and tr ~= "table" then
    R.typeerror(3, "gsub", "string/function/table", repl)
  end
  local anchor = sbyte(p, 1) == 94
  local pstart = anchor and 2 or 1
  local ms = newstate(src, p)
  local buf, n, changed = {}, 0, false
  local pos, lastmatch = 1, nil
  while n < maxs do
    reprep(ms)
    local e = do_match(ms, pos, pstart)
    if e and e ~= lastmatch then
      n = n + 1
      changed = add_value(ms, buf, pos, e, repl, tr) or changed
      pos, lastmatch = e, e
    elseif pos <= srcl then
      buf[#buf + 1] = ssub(src, pos, pos)
      pos = pos + 1
    else
      break
    end
    if anchor then break end
  end
  if not changed then return src, n end
  buf[#buf + 1] = ssub(src, pos)
  return concat(buf), n
end

---------------------------------------------------------------------------
-- string.format
---------------------------------------------------------------------------

local FLAGS_F = mkset("-+#0 ")   -- a A e E f F g G
local FLAGS_X = mkset("-#0")     -- o x X
local FLAGS_I = mkset("-+0 ")    -- d i
local FLAGS_U = mkset("-0")      -- u
local FLAGS_C = mkset("-")       -- c p s
local SPAN = mkset("-+#0 123456789.")

local function get2digits(s, i)
  if isdigit(sbyte(s, i)) then
    i = i + 1
    if isdigit(sbyte(s, i)) then i = i + 1 end
  end
  return i
end

-- Validate a conversion spec `full` (flags, width, precision, conversion
-- letter); flags is a set of accepted flag bytes (lstrlib.c checkformat).
local function checkformat(full, flags, precision)
  local i, n = 1, #full
  while i <= n and flags[sbyte(full, i)] do i = i + 1 end
  if sbyte(full, i) ~= 48 then           -- a width cannot start with '0'
    i = get2digits(full, i)
    if sbyte(full, i) == 46 and precision then   -- '.'
      i = get2digits(full, i + 1)
    end
  end
  local c = sbyte(full, i)
  if not (c and isalpha(c)) then
    rterror("invalid conversion specification: '%" .. full .. "'")
  end
end

-- Extract '-' flag, width and precision from a validated spec (no conversion letter).
local function parsespec(spec)
  local i, left, zero = 1, false, false
  while true do
    local c = sbyte(spec, i)
    if c == 45 then left = true
    elseif c == 48 then zero = true
    elseif c ~= 43 and c ~= 32 and c ~= 35 then break
    end
    i = i + 1
  end
  local width, prec = nil, nil
  while isdigit(sbyte(spec, i)) do
    width = (width or 0) * 10 + sbyte(spec, i) - 48
    i = i + 1
  end
  if sbyte(spec, i) == 46 then
    prec = 0
    i = i + 1
    while isdigit(sbyte(spec, i)) do
      prec = prec * 10 + sbyte(spec, i) - 48
      i = i + 1
    end
  end
  return left, zero, width, prec
end

local function pad(s, width, left, zero)
  if width == nil or #s >= width then return s end
  if left then return s .. srep(" ", width - #s) end
  return srep(zero and "0" or " ", width - #s) .. s
end

-- Decimal digits of a negative integer read as unsigned 64-bit.
local function udigits(n)
  local q = (n >> 1) // 5
  local r = n - q * 10
  return sformat("%d", q) .. sformat("%d", r)
end

-- Text after the last ": " of tostring(v): the address of a reference value.
local function addrof(v)
  local s = tostring(v)
  local k = nil
  for i = 1, #s - 1 do
    if sbyte(s, i) == 58 and sbyte(s, i + 1) == 32 then k = i end
  end
  return k and ssub(s, k + 2) or s
end

local function addquoted(s)
  local out = { '"' }
  for i = 1, #s do
    local c = sbyte(s, i)
    if c == 34 or c == 92 or c == 10 then
      out[#out + 1] = "\\" .. schar(c)
    elseif c < 32 or c == 127 then
      if isdigit(sbyte(s, i + 1)) then
        out[#out + 1] = sformat("\\%03d", c)
      else
        out[#out + 1] = sformat("\\%d", c)
      end
    else
      out[#out + 1] = schar(c)
    end
  end
  out[#out + 1] = '"'
  return concat(out)
end

local function addliteral(v, arg)
  local t = R.type(v)
  if t == "string" then
    return addquoted(v)
  elseif t == "number" then
    if mtype(v) == "integer" then
      if v == math.mininteger then return sformat("0x%x", v) end
      return sformat("%d", v)
    end
    if v == INF then return "1e9999" end
    if v == -INF then return "-1e9999" end
    if v ~= v then return "(0/0)" end
    return sformat("%a", v)
  elseif t == "nil" or t == "boolean" then
    return tostring(v)
  end
  argerror(arg, "format", "value has no literal form")
end

-- Format one conversion. `full` is the spec after '%' including the
-- conversion letter `conv` (conv is "" at the end of the format string).
local function formatone(full, conv, args, arg)
  local spec = ssub(full, 1, #full - 1)
  if conv == "c" then
    checkformat(full, FLAGS_C, false)
    local n = checkinteger(args[arg], arg, "format")
    local left, _, width = parsespec(spec)
    return pad(schar(n & 255), width, left, false)
  elseif conv == "d" or conv == "i" then
    local n = checkinteger(args[arg], arg, "format")
    checkformat(full, FLAGS_I, true)
    return sformat("%" .. full, n)
  elseif conv == "u" then
    local n = checkinteger(args[arg], arg, "format")
    checkformat(full, FLAGS_U, true)
    if n >= 0 then return sformat("%" .. spec .. "d", n) end
    local left, zero, width, prec = parsespec(spec)
    local digits = udigits(n)
    if prec and #digits < prec then digits = srep("0", prec - #digits) .. digits end
    return pad(digits, width, left, zero and prec == nil)
  elseif conv == "o" or conv == "x" or conv == "X" then
    local n = checkinteger(args[arg], arg, "format")
    checkformat(full, FLAGS_X, true)
    return sformat("%" .. full, n)
  elseif conv == "a" or conv == "A" then
    checkformat(full, FLAGS_F, true)
    local x = checknumber(args[arg], arg, "format")
    return sformat("%" .. full, x)
  elseif conv == "e" or conv == "E" or conv == "f" or conv == "g" or conv == "G" then
    local x = checknumber(args[arg], arg, "format")
    checkformat(full, FLAGS_F, true)
    return sformat("%" .. full, x)
  elseif conv == "p" then
    local v = args[arg]
    checkformat(full, FLAGS_C, false)
    local left, _, width = parsespec(spec)
    local t = R.type(v)
    if t == "table" or t == "userdata" or t == "function" or t == "thread" then
      return pad(addrof(v), width, left, false)
    end
    return pad("(null)", width, left, false)
  elseif conv == "q" then
    if spec ~= "" then rterror("specifier '%q' cannot have modifiers") end
    return addliteral(args[arg], arg)
  elseif conv == "s" then
    local s = R.tostring(args[arg])
    if spec == "" then return s end
    if haszero(s) then argerror(arg, "format", "string contains zeros") end
    checkformat(full, FLAGS_C, true)
    if findbyte(spec, 46, 1) == nil and #s >= 100 then return s end
    local left, _, width, prec = parsespec(spec)
    if prec and #s > prec then s = ssub(s, 1, prec) end
    return pad(s, width, left, false)
  end
  rterror("invalid conversion '%" .. full .. "' to 'format'")
end

local function str_format(...)
  local top = select("#", ...)
  local args = { ... }
  local fmt = checkstring(args[1], 1, "format")
  local n = #fmt
  local buf = {}
  local i, arg = 1, 1
  while i <= n do
    if sbyte(fmt, i) ~= L_ESC then
      local j = i + 1
      while j <= n and sbyte(fmt, j) ~= L_ESC do j = j + 1 end
      buf[#buf + 1] = ssub(fmt, i, j - 1)
      i = j
    elseif sbyte(fmt, i + 1) == L_ESC then
      buf[#buf + 1] = "%"
      i = i + 2
    else
      i = i + 1
      arg = arg + 1
      if arg > top then R.argerror(arg, "format", "no value") end
      local j = i
      while j <= n and SPAN[sbyte(fmt, j)] do j = j + 1 end
      if j - i + 1 >= 22 then rterror("invalid format (too long)") end   -- MAX_FORMAT - 10
      local full = ssub(fmt, i, j)          -- spec plus conversion letter
      local conv = ssub(fmt, j, j)
      i = j + 1
      buf[#buf + 1] = formatone(full, conv, args, arg)
    end
  end
  return concat(buf)
end

---------------------------------------------------------------------------
-- string.pack / string.packsize / string.unpack
---------------------------------------------------------------------------

-- Round-half-even of a non-negative float, as an integer.
local function roundeven(y)
  local f = y // 1
  local d = y - f
  if d > 0.5 or (d == 0.5 and f % 2 == 1) then f = f + 1 end
  return math.tointeger(f)
end

-- x * 2^e without intermediate overflow/underflow.
local function ldexp(m, e)
  while e > 1000 do m = m * 2.0 ^ 1000; e = e - 1000 end
  while e < -1000 do m = m * 2.0 ^ -1000; e = e + 1000 end
  return m * 2.0 ^ e
end

-- floor(log2(x)) for finite x > 0.
local function floorlog2(x)
  local e = floor(log(x, 2))
  while 2.0 ^ e > x do e = e - 1 end
  while 2.0 ^ (e + 1) <= x do e = e + 1 end
  return e
end

-- IEEE-754 double bits (as a Lua integer) of x.
local function f64bits(x)
  x = x * 1.0
  if x ~= x then return 0x7FF8000000000000 end
  local sign = 0
  if x < 0 or (x == 0 and 1 / x < 0) then
    sign = math.mininteger
    x = -x
  end
  if x == 0 then return sign end
  if x == INF then return sign | 0x7FF0000000000000 end
  local e = floorlog2(x)
  if e < -1022 then                       -- subnormal
    return sign | math.tointeger(ldexp(x, 1074))
  end
  local frac = ldexp(x, -e) - 1.0
  return sign | ((e + 1023) << 52) | math.tointeger(ldexp(frac, 52))
end

-- IEEE-754 single bits of x (x rounded to float precision).
local function f32bits(x)
  x = x * 1.0
  if x ~= x then return 0x7FC00000 end
  local sign = 0
  if x < 0 or (x == 0 and 1 / x < 0) then
    sign = 0x80000000
    x = -x
  end
  if x == 0 then return sign end
  if x == INF then return sign | 0x7F800000 end
  local e = floorlog2(x)
  if e < -126 then                        -- subnormal: units of 2^-149
    return sign | roundeven(ldexp(x, 149))
  end
  local k = roundeven(ldexp(x, 23 - e))   -- in [2^23, 2^24]
  if k == (1 << 24) then
    k = 1 << 23
    e = e + 1
  end
  if e > 127 then return sign | 0x7F800000 end
  return sign | ((e + 127) << 23) | (k - (1 << 23))
end

local function f64from(bits)
  local sign = (bits >> 63) & 1
  local e = (bits >> 52) & 0x7FF
  local f = bits & ((1 << 52) - 1)
  local v
  if e == 0x7FF then
    v = (f ~= 0) and NAN or INF
  elseif e == 0 then
    v = ldexp(f + 0.0, -1074)
  else
    v = ldexp(f + 2.0 ^ 52, e - 1075)
  end
  if sign == 1 then v = -v end
  return v
end

local function f32from(bits)
  local sign = (bits >> 31) & 1
  local e = (bits >> 23) & 0xFF
  local f = bits & ((1 << 23) - 1)
  local v
  if e == 0xFF then
    v = (f ~= 0) and NAN or INF
  elseif e == 0 then
    v = ldexp(f + 0.0, -149)
  else
    v = ldexp(f + 2.0 ^ 23, e - 150)
  end
  if sign == 1 then v = -v end
  return v
end

-- Bytes of integer n in `size` bytes; neg selects sign extension past 8 bytes.
local function packint(n, little, size, neg)
  local t = {}
  for i = 0, size - 1 do
    local b
    if i < 8 then
      b = (n >> (8 * i)) & 0xFF
    else
      b = neg and 0xFF or 0
    end
    t[little and i + 1 or size - i] = schar(b)
  end
  return concat(t)
end

-- Read `size` bytes at 0-based offset p of data as an integer.
local function unpackint(data, p, little, size, signed)
  local res = 0
  local limit = size <= 8 and size or 8
  for i = limit - 1, 0, -1 do
    local k = little and i or (size - 1 - i)
    res = (res << 8) | sbyte(data, p + k + 1)
  end
  if size < 8 then
    if signed then
      local mask = 1 << (size * 8 - 1)
      res = (res ~ mask) - mask
    end
  elseif size > 8 then
    local mask = (not signed or res >= 0) and 0 or 0xFF
    for i = limit, size - 1 do
      local k = little and i or (size - 1 - i)
      if sbyte(data, p + k + 1) ~= mask then
        rterror(size .. "-byte integer does not fit into Lua Integer")
      end
    end
  end
  return res
end

local function newH(fmt, name)
  return { fmt = fmt, pos = 1, little = NATIVE_LITTLE, maxalign = 1, name = name }
end

local function getnum(H, df)
  local c = sbyte(H.fmt, H.pos)
  if not isdigit(c) then return df end
  local a = 0
  repeat
    a = a * 10 + (c - 48)
    H.pos = H.pos + 1
    c = sbyte(H.fmt, H.pos)
  until not (isdigit(c) and a <= (MAXSIZE - 9) // 10)
  return a
end

local function getnumlimit(H, df)
  local sz = getnum(H, df)
  if sz < 1 or sz > 16 then
    rterror("integral size (" .. sz .. ") out of limits [1,16]")
  end
  return sz
end

-- Read the next option: returns its kind and size.
local function getoption(H)
  local c = ssub(H.fmt, H.pos, H.pos)
  H.pos = H.pos + 1
  if c == "b" then return "int", 1
  elseif c == "B" then return "uint", 1
  elseif c == "h" then return "int", 2
  elseif c == "H" then return "uint", 2
  elseif c == "l" or c == "j" then return "int", 8
  elseif c == "L" or c == "J" or c == "T" then return "uint", 8
  elseif c == "f" then return "float", 4
  elseif c == "n" or c == "d" then return "double", 8
  elseif c == "i" then return "int", getnumlimit(H, 4)
  elseif c == "I" then return "uint", getnumlimit(H, 4)
  elseif c == "s" then return "string", getnumlimit(H, 8)
  elseif c == "c" then
    local sz = getnum(H, nil)
    if sz == nil then rterror("missing size for format option 'c'") end
    return "char", sz
  elseif c == "z" then return "zstr", 0
  elseif c == "x" then return "padding", 1
  elseif c == "X" then return "paddalign", 0
  elseif c == " " then return "nop", 0
  elseif c == "<" then H.little = true; return "nop", 0
  elseif c == ">" then H.little = false; return "nop", 0
  elseif c == "=" then H.little = NATIVE_LITTLE; return "nop", 0
  elseif c == "!" then H.maxalign = getnumlimit(H, 8); return "nop", 0
  end
  rterror("invalid format option '" .. c .. "'")
end

-- Option kind, size, and padding needed before it at offset totalsize.
local function getdetails(H, totalsize)
  local opt, size = getoption(H)
  local align = size
  if opt == "paddalign" then
    if H.pos > #H.fmt then argerror(1, H.name, "invalid next option for option 'X'") end
    local o2
    o2, align = getoption(H)
    if o2 == "char" or align == 0 then
      argerror(1, H.name, "invalid next option for option 'X'")
    end
  end
  local ntoalign = 0
  if align > 1 and opt ~= "char" then
    if align > H.maxalign then align = H.maxalign end
    if align & (align - 1) ~= 0 then
      argerror(1, H.name, "format asks for alignment not power of 2")
    end
    local szmoda = totalsize & (align - 1)
    ntoalign = (align - szmoda) & (align - 1)
  end
  return opt, size, ntoalign
end

local function str_pack(...)
  local args = { ... }
  local fmt = checkstring(args[1], 1, "pack")
  local H = newH(fmt, "pack")
  local out, total, arg = {}, 0, 1
  while H.pos <= #fmt do
    local opt, size, ntoalign = getdetails(H, total)
    if size + ntoalign > MAXSIZE - total then argerror(arg, "pack", "result too long") end
    total = total + ntoalign + size
    out[#out + 1] = srep("\0", ntoalign)
    local a = arg + 1          -- argument index for value-consuming options
    if opt == "int" then
      local n = checkinteger(args[a], a, "pack")
      if size < 8 then
        local lim = 1 << (size * 8 - 1)
        if n < -lim or n >= lim then argerror(a, "pack", "integer overflow") end
      end
      out[#out + 1] = packint(n, H.little, size, n < 0)
      arg = a
    elseif opt == "uint" then
      local n = checkinteger(args[a], a, "pack")
      if size < 8 and (n < 0 or n >= (1 << (size * 8))) then
        argerror(a, "pack", "unsigned overflow")
      end
      out[#out + 1] = packint(n, H.little, size, false)
      arg = a
    elseif opt == "float" then
      out[#out + 1] = packint(f32bits(checknumber(args[a], a, "pack")), H.little, 4, false)
      arg = a
    elseif opt == "double" then
      out[#out + 1] = packint(f64bits(checknumber(args[a], a, "pack")), H.little, 8, false)
      arg = a
    elseif opt == "char" then
      local s = checkstring(args[a], a, "pack")
      if #s > size then argerror(a, "pack", "string longer than given size") end
      out[#out + 1] = s .. srep("\0", size - #s)
      arg = a
    elseif opt == "string" then
      local s = checkstring(args[a], a, "pack")
      if size < 8 and #s >= (1 << (size * 8)) then
        argerror(a, "pack", "string length does not fit in given size")
      end
      out[#out + 1] = packint(#s, H.little, size, false) .. s
      total = total + #s
      arg = a
    elseif opt == "zstr" then
      local s = checkstring(args[a], a, "pack")
      if haszero(s) then argerror(a, "pack", "string contains zeros") end
      out[#out + 1] = s .. "\0"
      total = total + #s + 1
      arg = a
    elseif opt == "padding" then
      out[#out + 1] = "\0"
    end
  end
  return concat(out)
end

local function str_packsize(fmt)
  fmt = checkstring(fmt, 1, "packsize")
  local H = newH(fmt, "packsize")
  local total = 0
  while H.pos <= #fmt do
    local opt, size, ntoalign = getdetails(H, total)
    if opt == "string" or opt == "zstr" then
      argerror(1, "packsize", "variable-length format")
    end
    size = size + ntoalign
    if total > MAXSIZE - size then argerror(1, "packsize", "format result too large") end
    total = total + size
  end
  return total
end

local function str_unpack(...)
  local args = { ... }
  local fmt = checkstring(args[1], 1, "unpack")
  local data = checkstring(args[2], 2, "unpack")
  local ld = #data
  local pos = posrelatI(optinteger(args[3], 3, "unpack", 1), ld) - 1
  if pos > ld then argerror(3, "unpack", "initial position out of string") end
  local H = newH(fmt, "unpack")
  local res = {}
  while H.pos <= #fmt do
    local opt, size, ntoalign = getdetails(H, pos)
    if ntoalign + size > ld - pos then argerror(2, "unpack", "data string too short") end
    pos = pos + ntoalign
    if opt == "int" or opt == "uint" then
      res[#res + 1] = unpackint(data, pos, H.little, size, opt == "int")
    elseif opt == "float" then
      res[#res + 1] = f32from(unpackint(data, pos, H.little, 4, false))
    elseif opt == "double" then
      res[#res + 1] = f64from(unpackint(data, pos, H.little, 8, false))
    elseif opt == "char" then
      res[#res + 1] = ssub(data, pos + 1, pos + size)
    elseif opt == "string" then
      local len = unpackint(data, pos, H.little, size, false)
      if len < 0 or len > ld - pos - size then argerror(2, "unpack", "data string too short") end
      res[#res + 1] = ssub(data, pos + size + 1, pos + size + len)
      pos = pos + len
    elseif opt == "zstr" then
      local e = findbyte(data, 0, pos + 1)
      local len = e and (e - pos - 1) or (ld - pos)
      if pos + len >= ld then argerror(2, "unpack", "unfinished string for format 'z'") end
      res[#res + 1] = ssub(data, pos + 1, pos + len)
      pos = pos + len + 1
    end
    pos = pos + size
  end
  res[#res + 1] = pos + 1
  return unpack(res, 1, #res)
end

---------------------------------------------------------------------------
-- Remaining functions
---------------------------------------------------------------------------

local function str_len(s)
  return #checkstring(s, 1, "len")
end

local function str_sub(s, i, j)
  s = checkstring(s, 1, "sub")
  local l = #s
  local st = posrelatI(checkinteger(i, 2, "sub"), l)
  local en = getendpos(optinteger(j, 3, "sub", -1), l)
  if st <= en then return ssub(s, st, en) end
  return ""
end

local function str_byte(s, i, j)
  s = checkstring(s, 1, "byte")
  local pi = optinteger(i, 2, "byte", 1)
  local l = #s
  local posi = posrelatI(pi, l)
  local pose = getendpos(optinteger(j, 3, "byte", pi), l)
  if posi > pose then return end
  if pose - posi >= 2147483647 then rterror("string slice too long") end
  return sbyte(s, posi, pose)
end

local function str_char(...)
  local n = select("#", ...)
  local t = { ... }
  for i = 1, n do
    local c = checkinteger(t[i], i, "char")
    if c < 0 or c > 255 then argerror(i, "char", "value out of range") end
    t[i] = schar(c)
  end
  return concat(t, "", 1, n)
end

local function str_upper(s)
  s = checkstring(s, 1, "upper")
  local t = {}
  for i = 1, #s do
    local c = sbyte(s, i)
    if c >= 97 and c <= 122 then c = c - 32 end
    t[i] = schar(c)
  end
  return concat(t)
end

local function str_lower(s)
  s = checkstring(s, 1, "lower")
  local t = {}
  for i = 1, #s do
    local c = sbyte(s, i)
    if c >= 65 and c <= 90 then c = c + 32 end
    t[i] = schar(c)
  end
  return concat(t)
end

local function str_reverse(s)
  s = checkstring(s, 1, "reverse")
  local t = {}
  for i = 1, #s do t[i] = ssub(s, #s - i + 1, #s - i + 1) end
  return concat(t)
end

local function str_rep(s, n, sep)
  s = checkstring(s, 1, "rep")
  n = checkinteger(n, 2, "rep")
  sep = optstring(sep, 3, "rep", "")
  local l, lsep = #s, #sep
  if n <= 0 or l + lsep == 0 then return "" end
  if l > MAXSIZE - lsep or (l + lsep) > MAXSIZE // n then
    rterror("resulting string too large")
  end
  local t = {}
  for i = 1, n do t[i] = s end
  return concat(t, sep)
end

local function str_dump(f)
  if R.type(f) ~= "function" then argerror(1, "dump", "Lua function expected") end
  rterror("unable to dump given function")
end

---------------------------------------------------------------------------
-- Installer
---------------------------------------------------------------------------

return function(G)
  local lib = R.newtable()
  R.setfuncs(lib, {
    byte = str_byte,
    char = str_char,
    dump = str_dump,
    find = str_find,
    format = str_format,
    gmatch = gmatch,
    gsub = gsub,
    len = str_len,
    lower = str_lower,
    match = str_match,
    pack = str_pack,
    packsize = str_packsize,
    rep = str_rep,
    reverse = str_reverse,
    sub = str_sub,
    unpack = str_unpack,
    upper = str_upper,
  })
  G.hash.string = lib

  local mt = R.newtable()
  mt.hash.__index = lib
  R.typemt.string = mt
end
