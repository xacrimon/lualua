-- io.lua: the io library (follows liolib.c). A file is a userdata whose
-- payload is { f = host file, kind = "file"|"std"|"pipe", closed = bool,
-- ub = one pushed-back character or nil, lfile = true }. Host file methods
-- perform the raw I/O; format parsing, errors and closing rules live here.
local R = require("runtime")
local H = io                                    -- host io library

local function isFile(v)
  return R.isUserdata(v) and type(v.payload) == "table" and v.payload.lfile == true
end

local function checkmode(m)
  return m:find("^[rwa]%+?b*$") ~= nil
end

local function checkoption(v, n, fname, opts, def)
  local s
  if v == nil and def then s = def else s = R.checkstring(v, n, fname) end
  for _, o in ipairs(opts) do
    if o == s then return s end
  end
  R.argerror(n, fname, "invalid option '" .. s .. "'")
end

-- Message of a failed host open without the "name: " prefix (for opencheck).
local function strerr(msg, name)
  local pre = name .. ": "
  if msg:sub(1, #pre) == pre then return msg:sub(#pre + 1) end
  return msg
end

-- Read primitive: host read returning the value, recording a host error
-- (nil plus message) in the payload so the caller can report it.
local function hread(p, fmt)
  local r, msg, code = p.f:read(fmt)
  if r == nil and msg then p.errmsg, p.errcode = msg, code end
  return r
end

local function getc(p)
  local c = p.ub
  if c then
    p.ub = nil
    return c
  end
  return hread(p, 1)
end

local function read_line(p, chop)
  local pre = p.ub
  p.ub = nil
  if pre == "\n" then return chop and "" or "\n" end
  local line = hread(p, "L")
  if pre then line = pre .. (line or "") end
  if line == nil or line == "" then return nil end
  if chop and line:sub(-1) == "\n" then line = line:sub(1, -2) end
  return line
end

local function read_all(p)
  local pre = p.ub
  p.ub = nil
  return (pre or "") .. (hread(p, "a") or "")
end

local function read_chars(p, n)
  local s = p.ub or ""
  p.ub = nil
  if #s < n then s = s .. (hread(p, n - #s) or "") end
  if s == "" then return nil end
  return s
end

local function test_eof(p)
  local c = getc(p)
  if c == nil then return nil end
  p.ub = c
  return ""
end

local function isdigit(ch, hex)
  if hex then return ch:find("^%x") ~= nil end
  return ch:find("^%d") ~= nil
end

-- Mirrors read_number in liolib.c: scan the longest numeral prefix, push
-- back the look-ahead character, and convert the collected text.
local function read_number(p)
  local c = getc(p)
  while c and c:find("^%s") do c = getc(p) end
  local buf, n, overflow = {}, 0, false
  local function nextc()
    if n >= 200 then
      overflow = true
      return false
    end
    n = n + 1
    buf[n] = c
    c = getc(p)
    return true
  end
  local function test2(a, b)
    if c == a or c == b then return nextc() end
    return false
  end
  local function readdigits(hex)
    local count = 0
    while c and isdigit(c, hex) and nextc() do count = count + 1 end
    return count
  end
  local count, hex = 0, false
  test2("-", "+")
  if test2("0", "0") then
    if test2("x", "X") then hex = true else count = 1 end
  end
  count = count + readdigits(hex)
  if test2(".", ".") then count = count + readdigits(hex) end
  if count > 0 and test2(hex and "p" or "e", hex and "P" or "E") then
    test2("-", "+")
    readdigits(false)
  end
  if c ~= nil then p.ub = c end
  if overflow then return nil end
  return tonumber(table.concat(buf))
end

-- g_read: read the formats fmts[1..nargs]; returns the values, or nil
-- plus message and code on a host error.
local function g_read(p, fname, nargs, fmts)
  p.errmsg = nil
  local res, k = {}, 0
  if nargs == 0 then
    res[1] = read_line(p, true)
    k = 1
  else
    for i = 1, nargs do
      local f = fmts[i]
      local v
      if type(f) == "number" then
        local l = R.checkinteger(f, i, fname)
        if l == 0 then v = test_eof(p) else v = read_chars(p, l) end
      else
        local s = R.checkstring(f, i, fname)
        if s:sub(1, 1) == "*" then s = s:sub(2) end
        local c = s:sub(1, 1)
        if c == "n" then v = read_number(p)
        elseif c == "l" then v = read_line(p, true)
        elseif c == "L" then v = read_line(p, false)
        elseif c == "a" then v = read_all(p)
        else R.argerror(i, fname, "invalid format") end
      end
      k = i
      res[i] = v
      if v == nil then break end
    end
  end
  if p.errmsg then return nil, p.errmsg, p.errcode end
  return table.unpack(res, 1, k)
end

local function g_write(ud, p, fname, nargs, args)
  if p.ub then   -- discard look-ahead before writing
    p.f:seek("cur", -1)
    p.ub = nil
  end
  for i = 1, nargs do
    local s = R.checkstring(args[i], i, fname)
    local ok, msg, code = p.f:write(s)
    if not ok then return nil, msg, code end
  end
  return ud
end

local function aux_close(p)
  if p.kind == "std" then return nil, "cannot close standard file" end
  p.closed = true
  return p.f:close()
end

local function f_tostring(self)
  if not isFile(self) then R.typeerror(1, "tostring", "FILE*", self) end
  local p = self.payload
  if p.closed then return "file (closed)" end
  return tostring(p.f)
end

return function(G)
  local fileMT = R.newtable()
  local methods = R.newtable()
  local defin, defout

  local function newfile(hf, kind)
    return R.newuserdata({ f = hf, kind = kind, closed = false, lfile = true }, fileMT)
  end

  local function checkfile(v, fname)
    if not isFile(v) then R.typeerror(1, fname, "FILE*", v) end
    return v.payload
  end

  -- tofile: a valid, open file handle (error otherwise)
  local function tofile(v, fname)
    local p = checkfile(v, fname)
    if p.closed then R.rterror("attempt to use a closed file") end
    return p
  end

  local function opencheck(name, mode)
    local hf, msg = H.open(name, mode)
    if not hf then
      R.rterror(string.format("cannot open file '%s' (%s)", name, strerr(msg, name)))
    end
    return newfile(hf, "file")
  end

  local function getiofile(which)
    local ud = (which == "input") and defin or defout
    if ud.payload.closed then R.rterror("default " .. which .. " file is closed") end
    return ud, ud.payload
  end

  local function aux_flush(p)
    return p.f:flush()
  end

  -- Iterator of io.lines / f:lines (aux_lines + io_readline).
  local function makeiter(p, toclose, nf, fmts)
    if nf > 250 then R.argerror(252, "lines", "too many arguments") end
    return function()
      if p.closed then R.rterror("file is already closed") end
      local r = table.pack(g_read(p, "lines", nf, fmts))
      if r[1] ~= nil then return table.unpack(r, 1, r.n) end
      if r.n > 1 then R.rterror(r[2]) end   -- host error: message in 2nd result
      if toclose then aux_close(p) end
    end
  end

  -- io.input / io.output (g_iofile)
  local function g_iofile(which, mode, v)
    if v ~= nil then
      local ud
      if type(v) == "string" or type(v) == "number" then
        ud = opencheck(tostring(v), mode)
      else
        tofile(v, which)
        ud = v
      end
      if which == "input" then defin = ud else defout = ud end
    end
    return which == "input" and defin or defout
  end

  -- methods ---------------------------------------------------------------
  R.setfuncs(methods, {
    read = function(self, ...)
      local p = tofile(self, "read")
      return g_read(p, "read", select("#", ...), { ... })
    end,
    write = function(self, ...)
      local p = tofile(self, "write")
      return g_write(self, p, "write", select("#", ...), { ... })
    end,
    lines = function(self, ...)
      local p = tofile(self, "lines")
      local fmts = table.pack(...)
      return makeiter(p, false, fmts.n, fmts)
    end,
    flush = function(self) return aux_flush(tofile(self, "flush")) end,
    seek = function(self, whence, off)
      local p = tofile(self, "seek")
      local op = checkoption(whence, 1, "seek", { "set", "cur", "end" }, "cur")
      local o = R.optinteger(off, 2, "seek", 0)
      if p.ub then   -- logical position excludes the pushed-back character
        p.f:seek("cur", -1)
        p.ub = nil
      end
      local pos, msg, code = p.f:seek(op, o)
      if pos == nil then return nil, msg, code end
      return pos
    end,
    setvbuf = function(self, mode, size)
      local p = tofile(self, "setvbuf")
      local op = checkoption(mode, 1, "setvbuf", { "no", "full", "line" })
      return p.f:setvbuf(op, R.optinteger(size, 2, "setvbuf", 1024))
    end,
    close = function(self) return aux_close(tofile(self, "close")) end,
  })

  local function f_gc(self)
    local p = checkfile(self, "__gc")
    if not p.closed then aux_close(p) end
  end

  R.setfuncs(fileMT, {
    __name = "FILE*",
    __index = methods,
    __gc = f_gc,
    __close = f_gc,
    __tostring = f_tostring,
  })

  -- module functions --------------------------------------------------------
  local function io_close(...)
    local ud = ...
    if select("#", ...) == 0 then ud = defout end
    return aux_close(tofile(ud, "close"))
  end

  local function io_type(...)
    if select("#", ...) == 0 then R.argerror(1, "type", "value expected") end
    local v = ...
    if not isFile(v) then return nil end
    return v.payload.closed and "closed file" or "file"
  end

  local function io_lines(name, ...)
    local ud, p, toclose
    if name == nil then
      ud = defin
      p = tofile(ud, "lines")
      toclose = false
    else
      name = R.checkstring(name, 1, "lines")
      ud = opencheck(name, "r")
      p = ud.payload
      toclose = true
    end
    local fmts = table.pack(...)
    local it = makeiter(p, toclose, fmts.n, fmts)
    if toclose then return it, nil, nil, ud end
    return it
  end

  local function io_open(name, mode)
    name = R.checkstring(name, 1, "open")
    mode = R.optstring(mode, 2, "open", "r")
    if not checkmode(mode) then R.argerror(2, "open", "invalid mode") end
    local hf, msg, code = H.open(name, mode)
    if not hf then return nil, msg, code end
    return newfile(hf, "file")
  end

  local function io_popen(prog, mode)
    prog = R.checkstring(prog, 1, "popen")
    mode = R.optstring(mode, 2, "popen", "r")
    if not (mode == "r" or mode == "w") then R.argerror(2, "popen", "invalid mode") end
    if H.popen == nil then R.rterror("'popen' not supported") end
    local hf, msg, code = H.popen(prog, mode)
    if not hf then return nil, msg, code end
    return newfile(hf, "pipe")
  end

  local function io_tmpfile()
    local hf, msg, code = H.tmpfile()
    if not hf then return nil, msg, code end
    return newfile(hf, "file")
  end

  local stdin = R.newuserdata({ f = H.stdin, kind = "std", closed = false, lfile = true }, fileMT)
  local stdout = R.newuserdata({ f = H.stdout, kind = "std", closed = false, lfile = true }, fileMT)
  local stderr = R.newuserdata({ f = H.stderr, kind = "std", closed = false, lfile = true }, fileMT)
  defin, defout = stdin, stdout

  local lib = R.newtable()
  R.setfuncs(lib, {
    close = io_close,
    flush = function()
      local _, p = getiofile("output")
      return aux_flush(p)
    end,
    input = function(v) return g_iofile("input", "r", v) end,
    lines = io_lines,
    open = io_open,
    output = function(v) return g_iofile("output", "w", v) end,
    popen = io_popen,
    read = function(...)
      local _, p = getiofile("input")
      return g_read(p, "read", select("#", ...), { ... })
    end,
    tmpfile = io_tmpfile,
    type = io_type,
    write = function(...)
      local ud, p = getiofile("output")
      return g_write(ud, p, "write", select("#", ...), { ... })
    end,
  })
  lib.hash.stdin = stdin
  lib.hash.stdout = stdout
  lib.hash.stderr = stderr
  G.hash.io = lib
end
