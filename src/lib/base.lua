-- lib/base.lua: basic functions (print, pairs, pcall, load, ...) and the
-- package library (require, package.searchers, ...), following lbaselib.c
-- and loadlib.c.

local R = require("runtime")
local loader = require("loader")
local FUPS = require("compiler").FUPS   -- closures created from Lua code

local type, select, tostring, tonumber = type, select, tostring, tonumber
local pack, unpack, concat = table.pack, table.unpack, table.concat
local sbyte, ssub, sfind = string.byte, string.sub, string.find
local pcall = pcall

-- luaL_checkany: argument n must be present (nargs counts the arguments).
local function checkany(nargs, n, fname)
  if nargs < n then R.argerror(n, fname, "value expected") end
end

local function isspace(c)
  return c == 32 or (c >= 9 and c <= 13)
end

-- s with every occurrence of the plain string p replaced by r (luaL_gsub).
local function plaingsub(s, p, r)
  local out, no = {}, 0
  local i, lp = 1, #p
  while true do
    local j = sfind(s, p, i, true)
    if not j then break end
    no = no + 1; out[no] = ssub(s, i, j - 1)
    no = no + 1; out[no] = r
    i = j + lp
  end
  no = no + 1; out[no] = ssub(s, i)
  return concat(out, "", 1, no)
end

-- The message of a failed host io.open without its "name: " prefix.
local function strerr(msg, name)
  local pre = name .. ": "
  if ssub(msg, 1, #pre) == pre then return ssub(msg, #pre + 1) end
  return msg
end

-- luaL_checkoption: the index of option v in opts (def when v is nil).
local function checkoption(v, n, fname, opts, def)
  local s
  if v == nil and def ~= nil then s = def else s = R.checkstring(v, n, fname) end
  for i = 1, #opts do
    if opts[i] == s then return s end
  end
  R.argerror(n, fname, "invalid option '" .. s .. "'")
end

-- The collector parameters are floating-point bytes (lobject.c
-- luaO_codeparam/luaO_applyparam): a value is stored with 5 significant bits.
local function ceillog2(x)   -- ceil(log2(x)) for x >= 1
  local l = 0
  x = x - 1
  while x > 0 do
    l = l + 1
    x = x >> 1
  end
  return l
end

local function codeparam(p)
  if p >= (0x1F << (0xF - 7 - 1)) * 100 then return 0xFF end   -- overflow
  p = (p * 128 + 99) // 100
  if p < 0x10 then return p end   -- subnormal
  local l = ceillog2(p + 1) - 5
  return ((p >> l) - 0x10) | ((l + 1) << 4)
end

local function applyparam(p, x)
  local m, e = p & 0xF, p >> 4
  if e > 0 then
    e = e - 1
    m = m + 0x10
  end
  e = e - 7
  if e >= 0 then return (x * m) << e end
  return (x * m) >> -e
end

return function(G)
  local function print_(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do
      parts[i] = R.tostring((select(i, ...)))
    end
    io.write(concat(parts, "\t", 1, n), "\n")
  end

  local function type_(...)
    checkany(select("#", ...), 1, "type")
    return R.type((...))
  end

  local function tostring_(...)
    checkany(select("#", ...), 1, "tostring")
    return R.tostring((...))
  end

  -- l_str2int in lbaselib.c: an integer numeral in the given base, with
  -- optional surrounding spaces and sign.
  local function tonumber_(...)
    local nargs = select("#", ...)
    local v, base = ...
    if base == nil then
      checkany(nargs, 1, "tonumber")
      return R.tonumber(v)
    end
    base = R.checkinteger(base, 2, "tonumber")
    if type(v) ~= "string" then R.typeerror(1, "tonumber", "string", v) end
    if base < 2 or base > 36 then R.argerror(2, "tonumber", "base out of range") end
    local i, l = 1, #v
    while i <= l and isspace(sbyte(v, i)) do i = i + 1 end
    local neg = false
    local c = sbyte(v, i)
    if c == 45 then neg = true; i = i + 1
    elseif c == 43 then i = i + 1 end
    local n, digits = 0, 0
    while i <= l do
      c = sbyte(v, i)
      local d
      if c >= 48 and c <= 57 then d = c - 48
      elseif c >= 97 and c <= 122 then d = c - 87
      elseif c >= 65 and c <= 90 then d = c - 55
      else break end
      if d >= base then return nil end
      n = n * base + d
      digits = digits + 1
      i = i + 1
    end
    if digits == 0 then return nil end
    while i <= l and isspace(sbyte(v, i)) do i = i + 1 end
    if i <= l then return nil end
    if neg then n = -n end
    return n
  end

  local function next_(t, k)
    R.checktable(t, 1, "next")
    return R.next(t, k)
  end

  -- one shared iterator, so that ipairs(a) == ipairs(b) for the iterator
  local function ipairs_iter(tt, i)
    i = i + 1
    local v
    if R.isTable(tt) then
      v = tt.hash[i]
      if v == nil and tt.mt ~= nil then v = R.noyield(R.index, tt, i) end
    else
      v = R.noyield(R.index, tt, i)
    end
    if v == nil then return nil end
    return i, v
  end

  local function ipairs_(...)
    checkany(select("#", ...), 1, "ipairs")
    return ipairs_iter, (...), 0
  end

  -- pairs returns 4 values: the generator, the state, the initial value and
  -- a to-be-closed object
  local function pairs_(...)
    checkany(select("#", ...), 1, "pairs")
    local t = ...
    local h = R.metamethod(t, "__pairs")
    if h == nil then return next_, t, nil, nil end
    local f, s, c, tbc = R.call(h, t)
    return f, s, c, tbc
  end

  local function select_(n, ...)
    local count = select("#", ...)
    if n == "#" then return count end
    local i = R.checkinteger(n, 1, "select")
    if i < 0 then
      i = count + i
      if i < 0 then R.argerror(1, "select", "index out of range") end
      return select(i + 1, ...)
    elseif i == 0 then
      R.argerror(1, "select", "index out of range")
    end
    return select(i, ...)
  end

  local function rawget_(...)
    local t, k = ...
    R.checktable(t, 1, "rawget")
    checkany(select("#", ...), 2, "rawget")
    return R.rawget(t, k)
  end

  local function rawset_(...)
    local t, k, v = ...
    R.checktable(t, 1, "rawset")
    local nargs = select("#", ...)
    checkany(nargs, 2, "rawset")
    checkany(nargs, 3, "rawset")
    R.rawset(t, k, v)
    return t
  end

  local function rawequal_(...)
    local nargs = select("#", ...)
    checkany(nargs, 1, "rawequal")
    checkany(nargs, 2, "rawequal")
    local a, b = ...
    return a == b
  end

  local function rawlen_(v)
    if type(v) == "string" then return #v end
    if R.isTable(v) then return R.rawlen(v) end
    R.typeerror(1, "rawlen", "table or string", v)
  end

  local function setmetatable_(...)
    local t, mt = ...
    R.checktable(t, 1, "setmetatable")
    if (mt ~= nil and not R.isTable(mt)) or select("#", ...) < 2 then
      R.typeerror(2, "setmetatable", "nil or table", mt)
    end
    if t.mt ~= nil and t.mt.hash.__metatable ~= nil then
      R.rterror("cannot change a protected metatable")
    end
    R.setmetatable(t, mt)
    return t
  end

  local function getmetatable_(...)
    checkany(select("#", ...), 1, "getmetatable")
    local mt = R.getmt((...))
    if mt == nil then return nil end
    local protected = mt.hash.__metatable
    if protected ~= nil then return protected end
    return mt
  end

  local function error_(msg, level)
    level = R.optinteger(level, 2, "error", 1)
    if msg == nil then R.throw("<no error object>") end
    if type(msg) == "string" and level > 0 then
      msg = R.where(level) .. msg
    end
    R.throw(msg)
  end

  local function assert_(...)
    local v = ...
    if v ~= nil and v ~= false then return ... end
    local n = select("#", ...)
    checkany(n, 1, "assert")
    if n < 2 then
      -- LUALUA_DEBUG=1 reports where an assertion failed (debugging aid)
      if os.getenv("LUALUA_DEBUG") then
        io.stderr:write("assertion failed at ", R.where(1), "\n")
        local st = R.stack
        for i = st.n, math.max(1, st.n - 6), -1 do
          io.stderr:write("   frame ", i, " ", tostring(st[i] and st[i].up.c.src), ":", tostring(st[i] and st[i].line), "\n")
        end
      end
      error_("assertion failed!")
    end
    error_((select(2, ...)))   -- as luaB_error with level 1
  end

  -- Runs f(...) in protected mode, restoring the frame stack on error.
  local function pcall_(...)
    checkany(select("#", ...), 1, "pcall")
    local f = ...
    local st = R.stack
    local n = st.n
    local savednat, savednny, savednn, savedf = st.nat, st.nny, st.natnargs, st.natfn
    if FUPS[f] == nil then                  -- a native called directly by pcall
      st.nat = n
      st.natnargs, st.natfn = select("#", ...) - 1, f
    end
    local r = pack(pcall(R.call, ...))
    st.nat, st.nny, st.natnargs, st.natfn = savednat, savednny, savednn, savedf
    if not r[1] then
      r[2] = R.popto(n, r[2])
      if r[2] == R.CLOSING then error(R.CLOSING, 0) end   -- not catchable here
    end
    return unpack(r, 1, r.n)
  end

  -- Runs the message handler. An error inside the handler is handled by the
  -- handler again (as Lua does); after too many nested errors the C stack is "full".
  -- At the C-call limit the handler gets "C stack overflow"; well past it
  -- the result is "error in error handling" (as in ldo.c).
  local MAXHANDLER = 200
  local function runhandler(handler, err, n, depth)
    if depth == MAXHANDLER then err = "C stack overflow" end
    local hr = pack(pcall(R.call, handler, err))
    if hr[1] then return hr[2] end
    local e = R.popto(n, hr[2])
    if depth >= MAXHANDLER + 20 then return "error in error handling" end
    return runhandler(handler, e, n, depth + 1)
  end

  local function xpcall_(f, handler, ...)
    R.checkfunction(handler, 2, "xpcall")
    local st = R.stack
    local n = st.n
    local savednat, savednny = st.nat, st.nny
    if FUPS[f] == nil then st.nat = n end
    local r = pack(pcall(R.call, f, ...))
    st.nat = savednat
    st.nny = savednny
    if r[1] then return unpack(r, 1, r.n) end
    if r[2] == R.CLOSING then
      R.popto(n, nil)
      error(R.CLOSING, 0)   -- not catchable here
    end
    local msg = runhandler(handler, R.popto(n, r[2]), n, 1)
    R.popto(n, nil)   -- the handler's frames are gone
    return false, msg
  end

  -- error for a chunk whose kind (binary or text) is not allowed by mode
  local function chunkmodeerror(src, mode)
    local binary = sbyte(src, 1) == 27
    if binary and not sfind(mode, "b", 1, true) then
      return "attempt to load a binary chunk (mode is '" .. mode .. "')"
    elseif not binary and not sfind(mode, "t", 1, true) then
      return "attempt to load a text chunk (mode is '" .. mode .. "')"
    elseif binary then
      return "binary chunks are not supported"
    end
    return nil
  end

  -- getMode: Lua code cannot use fixed buffers ('B')
  local function getmode(mode, n, fname)
    mode = R.optstring(mode, n, fname, nil)
    if mode ~= nil and sfind(mode, "B", 1, true) then R.argerror(n, fname, "invalid mode") end
    return mode
  end

  -- Compiles src (lua_load) with the environment env, or the globals.
  local function loadchunk(src, chunkname, mode, hasenv, env)
    local merr = chunkmodeerror(src, mode or "bt")
    if merr then return nil, merr end
    local e = G
    if hasenv then e = env end   -- an explicit env argument, even nil
    local f, err = loader.load(src, chunkname, e)
    if not f then return nil, err end
    return f
  end

  -- generic_reader: the pieces of the chunk, up to a nil or empty piece
  local function readall(reader, where)
    local parts, np = {}, 0
    while true do
      local piece = R.ccall(reader)
      if piece == nil then break end
      local tp = type(piece)
      if tp == "number" then piece = tostring(piece)
      elseif tp ~= "string" then R.throw(where .. "reader function must return a string") end
      if piece == "" then break end
      np = np + 1
      parts[np] = piece
    end
    return concat(parts, "", 1, np)
  end

  local function load_(...)
    local nargs = select("#", ...)
    local chunk, chunkname, mode, env = ...
    mode = getmode(mode, 3, "load")
    local src
    local tc = type(chunk)
    if tc == "string" or tc == "number" then
      src = tostring(chunk)
      chunkname = R.optstring(chunkname, 2, "load", src)
    else
      chunkname = R.optstring(chunkname, 2, "load", "=(load)")
      R.checkfunction(chunk, 1, "load")
      -- errors in the reader make the load fail (it runs in protected mode)
      local depth = R.stack.n
      local ok, r = pcall(readall, chunk, R.where(1))
      if not ok then return nil, R.popto(depth, r) end
      src = r
    end
    return loadchunk(src, chunkname, mode, nargs >= 4, env)
  end

  local function readfile(path)
    local fh, err = io.open(path, "rb")
    if not fh then return nil, err end
    local s = fh:read("a")
    fh:close()
    return s
  end

  -- luaL_loadfilex: a UTF-8 byte order mark and a first line starting with
  -- '#' are skipped (the line's newline is kept, so line numbers stay).
  local function loadfilex(path, mode, hasenv, env)
    local src, chunkname
    if path == nil then
      src = io.read("a") or ""
      chunkname = "=stdin"
    else
      local err
      src, err = readfile(path)
      if not src then
        return nil, "cannot open " .. path .. (err and (": " .. strerr(err, path)) or "")
      end
      chunkname = "@" .. path
    end
    if ssub(src, 1, 3) == "\239\187\191" then src = ssub(src, 4) end
    if sbyte(src, 1) == 35 then   -- '#'
      local e = sfind(src, "\n", 1, true)
      src = e and ssub(src, e) or ""
    end
    return loadchunk(src, chunkname, mode, hasenv, env)
  end

  local function loadfile_(...)
    local path, mode, env = ...
    path = R.optstring(path, 1, "loadfile", nil)
    mode = getmode(mode, 2, "loadfile")
    return loadfilex(path, mode, select("#", ...) >= 3, env)
  end

  local function dofile_(path)
    path = R.optstring(path, 1, "dofile", nil)
    local f, err = loadfilex(path, nil, false)
    if not f then R.throw(err) end
    return R.call(f)
  end

  local GCOPTS = { "stop", "restart", "collect", "count", "step", "isrunning",
                   "generational", "incremental", "param" }
  local GCPARAMS = { "minormul", "majorminor", "minormajor", "pause", "stepmul", "stepsize" }
  -- default values (lgc.h); stored only: the host collector does the work
  local gcparams = {
    minormul = codeparam(20), majorminor = codeparam(50), minormajor = codeparam(70),
    pause = codeparam(250), stepmul = codeparam(200), stepsize = codeparam(200 * 48),
  }
  local function collectgarbage_(opt, a, b)
    opt = checkoption(opt, 1, "collectgarbage", GCOPTS, "collect")
    if opt == "count" then
      return (collectgarbage("count"))
    elseif opt == "step" then
      return (collectgarbage("step", R.optinteger(a, 2, "collectgarbage", 0)))
    elseif opt == "isrunning" then
      return (collectgarbage("isrunning"))
    elseif opt == "generational" or opt == "incremental" then
      return (collectgarbage(opt))
    elseif opt == "param" then
      local name = checkoption(a, 2, "collectgarbage", GCPARAMS)
      local value = R.optinteger(b, 3, "collectgarbage", -1)
      local old = applyparam(gcparams[name], 100)
      value = value & 0xFFFFFFFF   -- the C API takes an int
      if value < 0x80000000 then gcparams[name] = codeparam(value) end
      return old
    end
    -- stop, restart, collect (the host fails inside a finalizer, as Lua does)
    return (collectgarbage(opt))
  end

  local warnon = false
  local function warn_(...)
    local n = select("#", ...)
    if n == 0 then R.argerror(1, "warn", "string expected, got no value") end
    local parts = {}
    for i = 1, n do parts[i] = R.checkstring((select(i, ...)), i, "warn") end
    local msg = concat(parts, "", 1, n)
    if n == 1 and sbyte(msg, 1) == 64 then   -- '@': control message
      if msg == "@on" then warnon = true elseif msg == "@off" then warnon = false end
      return
    end
    if warnon then io.stderr:write("Lua warning: ", msg, "\n") end
  end
  -- messages produced by the runtime itself (such as errors in __gc)
  R.emitwarning = function(msg)
    if warnon then io.stderr:write("Lua warning: ", msg, "\n") end
  end

  -- package and require ----------------------------------------------------

  local package = R.newtable()
  local loaded = R.newtable()
  R.loadedtable = loaded   -- used to name library functions in argument errors
  local preload = R.newtable()
  local searchers = R.newtable()

  -- default paths of a standard build (luaconf.h, LUA_ROOT "/usr/local/")
  local LDIR, CDIR = "/usr/local/share/lua/5.5/", "/usr/local/lib/lua/5.5/"
  local PATH_DEFAULT = LDIR .. "?.lua;" .. LDIR .. "?/init.lua;" .. CDIR .. "?.lua;"
    .. CDIR .. "?/init.lua;./?.lua;./?/init.lua"
  local CPATH_DEFAULT = CDIR .. "?.so;" .. CDIR .. "loadall.so;./?.so"
  local DLMSG = "dynamic libraries not enabled; check your Lua installation"

  -- setpath: the environment variable (versioned name first) with ";;"
  -- replaced by the default path, or the default path.
  local function envpath(var, dft)
    local path = os.getenv(var .. "_5_5") or os.getenv(var)
    if path == nil then return dft end
    local mark = sfind(path, ";;", 1, true)
    if mark == nil then return path end
    local out = dft
    if mark > 1 then out = ssub(path, 1, mark - 1) .. ";" .. out end
    if mark < #path - 1 then out = out .. ";" .. ssub(path, mark + 2) end
    return out
  end

  package.hash.loaded = loaded
  package.hash.preload = preload
  package.hash.searchers = searchers
  package.hash.path = envpath("LUA_PATH", PATH_DEFAULT)
  package.hash.cpath = envpath("LUA_CPATH", CPATH_DEFAULT)
  package.hash.config = "/\n;\n?\n!\n-\n"
  G.hash.package = package

  local function readable(filename)
    local fh = io.open(filename, "r")
    if fh == nil then return false end
    fh:close()
    return true
  end

  -- searchpath in loadlib.c: the first readable file name of path, or nil
  -- plus the list of files tried.
  local function searchpath(name, path, sep, dirsep)
    if sep ~= "" and sfind(name, sep, 1, true) then name = plaingsub(name, sep, dirsep) end
    local names = plaingsub(path, "?", name)
    local i, l = 1, #names
    while i <= l + 1 do
      local j = sfind(names, ";", i, true) or (l + 1)
      local filename = ssub(names, i, j - 1)
      if readable(filename) then return filename end
      i = j + 1
    end
    return nil, "no file '" .. plaingsub(names, ";", "'\n\tno file '") .. "'"
  end

  package.hash.searchpath = function(name, path, sep, rep)
    name = R.checkstring(name, 1, "searchpath")
    path = R.checkstring(path, 2, "searchpath")
    sep = R.optstring(sep, 3, "searchpath", ".")
    rep = R.optstring(rep, 4, "searchpath", "/")
    return searchpath(name, path, sep, rep)
  end

  package.hash.loadlib = function(path, init)
    R.checkstring(path, 1, "loadlib")
    R.checkstring(init, 2, "loadlib")
    return nil, DLMSG, "absent"
  end

  local function findfile(name, pname)
    local path = R.index(package, pname)
    if type(path) == "number" then path = tostring(path) end
    if type(path) ~= "string" then R.rterror("'package." .. pname .. "' must be a string") end
    return searchpath(name, path, ".", "/")
  end

  local function checkload(name, f, filename, err)
    if f then return f, filename end
    R.rterror("error loading module '" .. name .. "' from file '" .. filename .. "':\n\t" .. tostring(err))
  end

  local function searcher_preload(name)
    name = R.checkstring(name, 1, "searcher_preload")
    local f = R.index(preload, name)
    if f == nil then return "no field package.preload['" .. name .. "']" end
    return f, ":preload:"
  end

  local function searcher_Lua(name)
    name = R.checkstring(name, 1, "searcher_Lua")
    local filename, tried = findfile(name, "path")
    if filename == nil then return tried end
    local f, err = loadfilex(filename, "bt", false)
    return checkload(name, f, filename, err)
  end

  -- C libraries cannot be loaded: a module file that is found fails to load
  local function searcher_C(name)
    name = R.checkstring(name, 1, "searcher_C")
    local filename, tried = findfile(name, "cpath")
    if filename == nil then return tried end
    return checkload(name, nil, filename, DLMSG)
  end

  local function searcher_Croot(name)
    name = R.checkstring(name, 1, "searcher_Croot")
    local p = sfind(name, ".", 1, true)
    if p == nil then return end   -- is root
    local filename, tried = findfile(ssub(name, 1, p - 1), "cpath")
    if filename == nil then return tried end
    return checkload(name, nil, filename, DLMSG)
  end

  R.setfuncs(searchers, { searcher_preload, searcher_Lua, searcher_C, searcher_Croot })

  local function findloader(name)
    local s = R.index(package, "searchers")
    if not R.isTable(s) then R.rterror("'package.searchers' must be a table") end
    local msg, nm = {}, 0
    local i = 1
    while true do
      local searcher = R.rawget(s, i)
      if searcher == nil then
        R.rterror("module '" .. name .. "' not found:" .. concat(msg, "", 1, nm))
      end
      local f, extra = R.ccall(searcher, name)
      if type(f) == "function" then return f, extra end
      if type(f) == "string" or type(f) == "number" then
        nm = nm + 1; msg[nm] = "\n\t" .. f
      end
      i = i + 1
    end
  end

  local function require_(name)
    name = R.checkstring(name, 1, "require")
    local v = loaded.hash[name]
    if v ~= nil and v ~= false then return v end
    local f, extra = findloader(name)
    local res = R.ccall(f, name, extra)
    if res ~= nil then loaded.hash[name] = res end
    if loaded.hash[name] == nil then loaded.hash[name] = true end
    return loaded.hash[name], extra
  end

  R.setfuncs(G, {
    print = print_,
    type = type_,
    tostring = tostring_,
    tonumber = tonumber_,
    next = next_,
    pairs = pairs_,
    ipairs = ipairs_,
    select = select_,
    rawget = rawget_,
    rawset = rawset_,
    rawequal = rawequal_,
    rawlen = rawlen_,
    setmetatable = setmetatable_,
    getmetatable = getmetatable_,
    assert = assert_,
    error = error_,
    pcall = pcall_,
    xpcall = xpcall_,
    load = load_,
    loadfile = loadfile_,
    dofile = dofile_,
    collectgarbage = collectgarbage_,
    warn = warn_,
    require = require_,
  })
  G.hash._G = G
  G.hash._VERSION = "Lua 5.5"
  loaded.hash._G = G
  loaded.hash.package = package
end
