-- utf8.lua: utf8 library, following lutf8lib.c (Lua 5.5).
-- Byte positions are 1-based here; the C code's 0-based pointer arithmetic
-- is translated with care at each use.
local R = require("runtime")

local MAXUNICODE = 0x10FFFF
local MAXUTF = 0x7FFFFFFF
local MSGInvalid = "invalid UTF-8 code"
-- minimum value per sequence length (index = count + 1); count 0 always fails
local LIMITS = { math.maxinteger, 0x80, 0x800, 0x10000, 0x200000, 0x4000000 }

local function byteat(s, k)
  return string.byte(s, k) or 0   -- 0 past the end, like the C terminator
end

local function iscont(c)
  return (c & 0xC0) == 0x80
end

-- translate a relative string position (negative counts from the end)
local function posrelat(pos, len)
  if pos >= 0 then return pos end
  if pos < -len then return 0 end
  return len + pos + 1
end

-- Decode the sequence starting at byte i. Returns code and the index of the
-- byte after it, or nil if the sequence is invalid.
local function decode(s, i, strict)
  local c = byteat(s, i)
  if c < 0x80 then return c, i + 1 end
  if c >= 0xFE then return nil end
  local count, res = 0, 0
  while (c & 0x40) ~= 0 do
    count = count + 1
    local cc = byteat(s, i + count)
    if not iscont(cc) then return nil end
    res = (res << 6) | (cc & 0x3F)
    c = c << 1
  end
  res = res | ((c & 0x7F) << (count * 5))
  if res > MAXUTF or res < LIMITS[count + 1] then return nil end
  if strict and (res > MAXUNICODE or (0xD800 <= res and res <= 0xDFFF)) then
    return nil
  end
  return res, i + count + 1
end

local function utflen(s, i, j, lax)
  s = R.checkstring(s, 1, "len")
  local len = #s
  local posi = posrelat(R.optinteger(i, 2, "len", 1), len)
  local posj = posrelat(R.optinteger(j, 3, "len", -1), len)
  if not (1 <= posi and posi <= len + 1) then
    R.argerror(2, "len", "initial position out of bounds")
  end
  if posj > len then R.argerror(3, "len", "final position out of bounds") end
  local strict = not R.truthy(lax)
  local n, p = 0, posi
  while p <= posj do
    local _, nxt = decode(s, p, strict)
    if nxt == nil then return nil, p end   -- fail, plus position of the error
    p = nxt
    n = n + 1
  end
  return n
end

local function codepoint(s, i, j, lax)
  s = R.checkstring(s, 1, "codepoint")
  local len = #s
  local posi = posrelat(R.optinteger(i, 2, "codepoint", 1), len)
  local pose = posrelat(R.optinteger(j, 3, "codepoint", posi), len)
  if posi < 1 then R.argerror(2, "codepoint", "out of bounds") end
  if pose > len then R.argerror(3, "codepoint", "out of bounds") end
  if posi > pose then return end
  if pose - posi >= 2147483647 then R.rterror("string slice too long") end
  local strict = not R.truthy(lax)
  local out, n, p = {}, 0, posi
  while p <= pose do
    local code, nxt = decode(s, p, strict)
    if code == nil then R.rterror(MSGInvalid) end
    n = n + 1
    out[n] = code
    p = nxt
  end
  return table.unpack(out, 1, n)
end

-- Encode x (0 <= x <= MAXUTF) as UTF-8, up to 6 bytes (luaO_utf8esc).
local function utf8esc(x)
  if x < 0x80 then return string.char(x) end
  local s, mfb = "", 0x3F
  repeat
    s = string.char(0x80 | (x & 0x3F)) .. s
    x = x >> 6
    mfb = mfb >> 1
  until x <= mfb
  return string.char(((~mfb << 1) | x) & 0xFF) .. s
end

local function char(...)
  local args = { ... }
  local out = {}
  for k = 1, select("#", ...) do
    local code = R.checkinteger(args[k], k, "char")
    if code < 0 or code > MAXUTF then R.argerror(k, "char", "value out of range") end
    out[k] = utf8esc(code)
  end
  return table.concat(out)
end

local function offset(s, n, i)
  s = R.checkstring(s, 1, "offset")
  n = R.checkinteger(n, 2, "offset")
  local len = #s
  local posi = (n >= 0) and 1 or len + 1
  posi = posrelat(R.optinteger(i, 3, "offset", posi), len)
  if not (1 <= posi and posi <= len + 1) then
    R.argerror(3, "offset", "position out of bounds")
  end
  posi = posi - 1   -- 0-based from here on; byte at 0-based p is byteat(s, p + 1)
  local function cont(p) return iscont(byteat(s, p + 1)) end

  if n == 0 then
    -- find beginning of current byte sequence
    while posi > 0 and cont(posi) do posi = posi - 1 end
  else
    if cont(posi) then R.rterror("initial position is a continuation byte") end
    if n < 0 then
      while n < 0 and posi > 0 do
        repeat posi = posi - 1 until not (posi > 0 and cont(posi))
        n = n + 1
      end
    else
      n = n - 1
      while n > 0 and posi < len do
        repeat posi = posi + 1 until not cont(posi)
        n = n - 1
      end
    end
  end
  if n ~= 0 then return nil end   -- did not find the given character

  local first = posi + 1
  if (byteat(s, posi + 1) & 0x80) ~= 0 then   -- multi-byte character
    if iscont(byteat(s, posi + 1)) then
      R.rterror("initial position is a continuation byte")
    end
    while cont(posi + 1) do posi = posi + 1 end
  end
  return first, posi + 1
end

local function make_iter(strict)
  return function(s, n)
    s = R.checkstring(s, 1, "for iterator")
    local len = #s
    local p = R.tointeger(n) or 0
    if p < 0 then return end                 -- unsigned in C: out of range
    while p < len and iscont(byteat(s, p + 1)) do p = p + 1 end
    if p >= len then return end              -- no more codepoints
    local code, nxt = decode(s, p + 1, strict)
    if code == nil or iscont(byteat(s, nxt)) then R.rterror(MSGInvalid) end
    return p + 1, code
  end
end

local iter_strict = make_iter(true)
local iter_lax = make_iter(false)

local function codes(s, lax)
  s = R.checkstring(s, 1, "codes")
  if iscont(byteat(s, 1)) then R.argerror(1, "codes", MSGInvalid) end
  local iter = R.truthy(lax) and iter_lax or iter_strict
  return iter, s, 0
end

return function(G)
  local lib = R.newtable()
  R.setfuncs(lib, {
    offset = offset,
    codepoint = codepoint,
    char = char,
    len = utflen,
    codes = codes,
  })
  lib.hash.charpattern = "[\0-\x7F\xC2-\xFD][\x80-\xBF]*"
  G.hash.utf8 = lib
end
