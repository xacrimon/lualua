-- lexer.lua: tokenizer for Lua 5.5.
--
-- Usage:  local ls = lexer.new(source, chunkname)
--         ls.t  current token type: "name", "string", "number", "<eof>",
--               or the keyword / operator text itself (e.g. "local", "==")
--         ls.v  token value (name text, string contents, number value)
--         ls.line  line where the current token starts
--         ls:advance()  moves to the next token
--         ls:lookahead()  type of the token after the current one
--         ls:error(msg, near)  raise a syntax error

local R = require("runtime")

local M = {}

local sbyte, ssub, schar, sfind = string.byte, string.sub, string.char, string.find
local concat = table.concat

local KEYWORDS = {}
-- 'global' is a contextual keyword (see parser.lua), so it is a plain name here
for w in ([[and break do else elseif end false for function goto if in
  local nil not or repeat return then true until while]]):gmatch("%S+") do
  KEYWORDS[w] = true
end
M.KEYWORDS = KEYWORDS

-- UTF-8 encoding of code points up to 2^31 (as luaO_utf8esc).
local function utf8esc(x)
  if x < 0x80 then return schar(x) end
  local buf = {}
  local mfb = 0x3f
  local n = 0
  repeat
    n = n + 1
    buf[n] = 0x80 | (x & 0x3f)
    x = x >> 6
    mfb = mfb >> 1
  until x <= mfb
  n = n + 1
  buf[n] = ((~mfb << 1) | x) & 0xff
  local out = {}
  for i = n, 1, -1 do out[#out + 1] = schar(buf[i]) end
  return concat(out)
end
M.utf8esc = utf8esc

local Lexer = {}
Lexer.__index = Lexer

-- Scans the token starting at self.pos. Returns type, value, line, startpos.
function Lexer:scan()
  local src = self.src
  local pos = self.pos
  while true do
    local c = sbyte(src, pos)
    if c == nil then
      self.pos = pos
      return "<eof>", nil, self.line, pos
    elseif c == 10 or c == 13 then
      -- newline: \n, \r, \n\r or \r\n count as one line break
      local nc = sbyte(src, pos + 1)
      if (nc == 10 or nc == 13) and nc ~= c then pos = pos + 2 else pos = pos + 1 end
      self.line = self.line + 1
    elseif c == 32 or c == 9 or c == 11 or c == 12 then
      pos = pos + 1
    elseif c == 45 and sbyte(src, pos + 1) == 45 then
      -- comment
      pos = pos + 2
      local lvl = self:longlevel(pos)
      if lvl then
        local _, endpos = self:readlong(pos, lvl, "comment")
        pos = endpos
      else
        local e = sfind(src, "[\n\r]", pos)
        pos = e or (#src + 1)
      end
    else
      break
    end
  end

  local start = pos
  local c = sbyte(src, pos)
  local line = self.line

  -- names and keywords
  if (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 then
    local s, e = sfind(src, "^[%w_]+", pos)
    local name = ssub(src, s, e)
    self.pos = e + 1
    if KEYWORDS[name] then return name, nil, line, start end
    return "name", name, line, start
  end

  -- numerals
  if (c >= 48 and c <= 57) or (c == 46 and (sbyte(src, pos + 1) or 0) >= 48 and (sbyte(src, pos + 1) or 0) <= 57) then
    local e = pos
    local expo = "[Ee]"
    if c == 48 and (sbyte(src, pos + 1) == 120 or sbyte(src, pos + 1) == 88) then
      expo = "[Pp]"
      e = pos + 2
    end
    -- consume a numeral-like run, allowing signs after the exponent mark
    while true do
      local ch = ssub(src, e, e)
      if ch ~= "" and sfind(ch, expo) and (ssub(src, e + 1, e + 1) == "+" or ssub(src, e + 1, e + 1) == "-") then
        e = e + 2
      elseif ch ~= "" and (sfind(ch, "^[%w_]") or ch == ".") then
        e = e + 1
      else
        break
      end
    end
    local text = ssub(src, pos, e - 1)
    local v = tonumber(text)
    self.pos = e
    if v == nil then
      self:error("malformed number", text)
    end
    return "number", v, line, start
  end

  -- long strings
  if c == 91 then -- '['
    local lvl = self:longlevel(pos)
    if lvl then
      local str, endpos = self:readlong(pos, lvl, "string")
      self.pos = endpos
      return "string", str, line, start
    end
    self.pos = pos + 1
    return "[", nil, line, start
  end

  -- short strings
  if c == 34 or c == 39 then
    return self:readstring(pos, c, line)
  end

  -- multi-character operators
  local two = ssub(src, pos, pos + 1)
  if two == "==" or two == "~=" or two == "<=" or two == ">=" or two == "//"
     or two == "::" or two == "<<" or two == ">>" or two == ".." then
    if two == ".." and sbyte(src, pos + 2) == 46 then
      self.pos = pos + 3
      return "...", nil, line, start
    end
    self.pos = pos + 2
    return two, nil, line, start
  end

  if c == 46 and sbyte(src, pos + 1) == 46 and sbyte(src, pos + 2) == 46 then
    self.pos = pos + 3
    return "...", nil, line, start
  end

  local one = ssub(src, pos, pos)
  if sfind("+-*/%^#&~|<>=(){}[];:,.", one, 1, true) then
    self.pos = pos + 1
    return one, nil, line, start
  end

  self.pos = pos + 1
  self:error("unexpected symbol", one)
end

-- If the bracket at pos (pointing at '[' or '=') opens a long bracket,
-- returns its level (number of '='); otherwise nil.
function Lexer:longlevel(pos)
  local src = self.src
  if sbyte(src, pos) ~= 91 then
    -- comments: pos is just after "--"; the bracket must be at pos itself
    if sbyte(src, pos) ~= 91 then return nil end
  end
  local p = pos + 1
  local lvl = 0
  while sbyte(src, p) == 61 do
    lvl = lvl + 1
    p = p + 1
  end
  if sbyte(src, p) == 91 then return lvl end
  return nil
end

-- Reads a long string/comment whose opening bracket starts at pos.
-- Returns the contents and the position after the closing bracket.
function Lexer:readlong(pos, lvl, what)
  local src = self.src
  local p = pos + lvl + 2 -- skip "[", "=" * lvl, "["
  -- skip a first newline
  local c = sbyte(src, p)
  if c == 10 or c == 13 then
    local nc = sbyte(src, p + 1)
    if (nc == 10 or nc == 13) and nc ~= c then p = p + 2 else p = p + 1 end
    self.line = self.line + 1
  end
  local closing = "]" .. string.rep("=", lvl) .. "]"
  local buf = {}
  local startp = p
  while true do
    local s, e = sfind(src, "[%]\n\r]", p)
    if not s then
      self.pos = #src + 1
      self:error("unfinished long " .. what, "<eof>")
    end
    local ch = ssub(src, s, s)
    if ch == "]" then
      if ssub(src, s, s + lvl + 1) == closing then
        buf[#buf + 1] = ssub(src, startp, s - 1)
        return concat(buf), s + lvl + 2
      end
      p = s + 1
    else
      -- newline inside the long string
      buf[#buf + 1] = ssub(src, startp, s - 1)
      local nc = sbyte(src, s + 1)
      local adv
      if (nc == 10 or nc == 13) and nc ~= sbyte(src, s) then adv = 2 else adv = 1 end
      buf[#buf + 1] = "\n"
      self.line = self.line + 1
      p = s + adv
      startp = p
    end
  end
end

-- Reads a quoted string starting at pos (the quote character q).
function Lexer:readstring(pos, q, line)
  local src = self.src
  local buf = {}
  local p = pos + 1
  local startp = p
  while true do
    local s = sfind(src, "[\\\n\r" .. (q == 34 and '"' or "'") .. "]", p)
    if not s then
      self.pos = #src + 1
      self:error("unfinished string", "<eof>")
    end
    local c = sbyte(src, s)
    buf[#buf + 1] = ssub(src, startp, s - 1)
    if c == q then
      self.pos = s + 1
      return "string", concat(buf), line, pos
    elseif c == 10 or c == 13 then
      self.pos = s
      self:error("unfinished string", ssub(src, pos, s - 1))
    else -- backslash
      local e = sbyte(src, s + 1)
      p = s + 2
      if e == nil then
        self.pos = #src + 1
        self:error("unfinished string", "<eof>")
      end
      if e == 110 then buf[#buf + 1] = "\n"
      elseif e == 116 then buf[#buf + 1] = "\t"
      elseif e == 114 then buf[#buf + 1] = "\r"
      elseif e == 97 then buf[#buf + 1] = "\a"
      elseif e == 98 then buf[#buf + 1] = "\b"
      elseif e == 102 then buf[#buf + 1] = "\f"
      elseif e == 118 then buf[#buf + 1] = "\v"
      elseif e == 92 then buf[#buf + 1] = "\\"
      elseif e == 34 then buf[#buf + 1] = '"'
      elseif e == 39 then buf[#buf + 1] = "'"
      elseif e == 10 or e == 13 then
        -- escaped newline
        local nc = sbyte(src, s + 2)
        if (nc == 10 or nc == 13) and nc ~= e then p = s + 3 else p = s + 2 end
        buf[#buf + 1] = "\n"
        self.line = self.line + 1
      elseif e == 120 then -- \xXX
        local h = ssub(src, s + 2, s + 3)
        if not sfind(h, "^%x%x$") then
          -- the message shows the text up to the first offending character
          local bad = sfind(ssub(src, s + 2, s + 2), "%x") and s + 3 or s + 2
          self.pos = bad + 1
          self:error("hexadecimal digit expected", ssub(src, pos, bad))
        end
        buf[#buf + 1] = schar(tonumber(h, 16))
        p = s + 4
      elseif e == 122 then -- \z skips following whitespace
        p = s + 2
        while true do
          local w = sbyte(src, p)
          if w == 10 or w == 13 then
            local nc = sbyte(src, p + 1)
            if (nc == 10 or nc == 13) and nc ~= w then p = p + 2 else p = p + 1 end
            self.line = self.line + 1
          elseif w == 32 or w == 9 or w == 11 or w == 12 then
            p = p + 1
          else
            break
          end
        end
      elseif e == 117 then -- \u{XXX}
        if sbyte(src, s + 2) ~= 123 then
          self.pos = s + 2
          self:error("missing '{' in \\u{xxxx}", ssub(src, pos, s + 2))
        end
        local hs, he = sfind(src, "^%x+", s + 3)
        if not hs then
          self.pos = s + 3
          self:error("hexadecimal digit expected", ssub(src, pos, s + 3))
        end
        local x = tonumber(ssub(src, hs, he), 16)
        if x >= 0x80000000 or #ssub(src, hs, he) > 8 then
          self.pos = he + 1
          self:error("UTF-8 value too large", ssub(src, pos, he))
        end
        if sbyte(src, he + 1) ~= 125 then
          self.pos = he + 1
          self:error("missing '}' in \\u{xxxx}", ssub(src, pos, he + 1))
        end
        buf[#buf + 1] = utf8esc(x)
        p = he + 2
      elseif e >= 48 and e <= 57 then -- \ddd
        local ds, de = sfind(src, "^%d%d?%d?", s + 1)
        local v = tonumber(ssub(src, ds, de))
        if v > 255 then
          -- the message includes the character after the digits
          self.pos = de + 1
          self:error("decimal escape too large", ssub(src, pos, de + 1))
        end
        buf[#buf + 1] = schar(v)
        p = de + 1
      else
        self.pos = s + 1
        self:error("invalid escape sequence", ssub(src, pos, s + 1))
      end
      startp = p
    end
  end
end

-- Raises a syntax error at the current line. `near` is the offending text.
function Lexer:error(msg, near)
  local where = self.chunk .. ":" .. self.line .. ": "
  if near ~= nil then
    error(where .. msg .. " near '" .. tostring(near) .. "'", 0)
  end
  error(where .. msg, 0)
end

-- Text of the current token, for error messages.
local function tokentext(ls)
  if ls.t == "<eof>" then return "<eof>" end
  if ls.t == "name" or ls.t == "number" then return ls.raw end
  if ls.t == "string" then return ls.raw end
  return ls.t
end
M.tokentext = tokentext

-- self.line is the lexer's line counter; self.tl is the line of the current token.
function Lexer:advance()
  local a = self.ahead
  if a then
    self.ahead = nil
    self.t, self.v, self.tl, self.raw = a[1], a[2], a[3], a[4]
  else
    local t, v, tline, startpos = self:scan()
    self.t, self.v, self.tl = t, v, tline
    self.raw = ssub(self.src, startpos, self.pos - 1)
  end
end

-- Type of the token after the current one (scans it, buffering it).
function Lexer:lookahead()
  if not self.ahead then
    local t, v, tline, startpos = self:scan()
    self.ahead = { t, v, tline, ssub(self.src, startpos, self.pos - 1) }
  end
  return self.ahead[1]
end

function M.new(src, chunkname)
  -- (a leading '#' line is skipped by the file loaders, not here)
  local self = setmetatable({ src = src, pos = 1, line = 1, chunk = chunkname }, Lexer)
  self:advance()
  return self
end

return M
