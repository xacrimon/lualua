-- lib/base.lua: basic functions (print, pairs, pcall, load, ...) and require.

local R = require("runtime")
local loader = require("loader")
local FUPS = require("compiler").FUPS   -- closures created from Lua code

local type, select, tostring, tonumber = type, select, tostring, tonumber
local pack, unpack = table.pack, table.unpack
local pcall = pcall

return function(G)
  local function print_(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do
      parts[i] = R.tostring((select(i, ...)))
    end
    io.write(table.concat(parts, "\t"), "\n")
  end

  local function type_(...)
    if select("#", ...) == 0 then R.argerror(1, "type", "value expected") end
    return R.type((...))
  end

  local function tostring_(...)
    if select("#", ...) == 0 then R.argerror(1, "tostring", "value expected") end
    return R.tostring((...))
  end

  local function tonumber_(...)
    local nargs = select("#", ...)
    local v, base = ...
    if nargs == 0 then R.argerror(1, "tonumber", "value expected") end
    if base == nil then
      return R.tonumber(v)
    end
    base = R.checkinteger(base, 2, "tonumber")
    if type(v) ~= "string" then R.typeerror(1, "tonumber", "string", v) end
    if base < 2 or base > 36 then R.argerror(2, "tonumber", "base out of range") end
    local s = v:match("^%s*(.-)%s*$")
    local neg = false
    if s:sub(1, 1) == "-" then neg = true; s = s:sub(2)
    elseif s:sub(1, 1) == "+" then s = s:sub(2) end
    if s == "" then return nil end
    local n = 0
    for i = 1, #s do
      local c = s:byte(i)
      local d
      if c >= 48 and c <= 57 then d = c - 48
      elseif c >= 97 and c <= 122 then d = c - 87
      elseif c >= 65 and c <= 90 then d = c - 55
      else return nil end
      if d >= base then return nil end
      n = n * base + d
    end
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
    local v = R.index(tt, i)
    if v == nil then return nil end
    return i, v
  end

  local function ipairs_(...)
    if select("#", ...) == 0 then R.argerror(1, "ipairs", "table expected, got no value") end
    return ipairs_iter, (...), 0
  end

  local function pairs_(t)
    local h = R.metamethod(t, "__pairs")
    if h ~= nil then
      return R.call(h, t)
    end
    R.checktable(t, 1, "pairs")
    return next_, t, nil
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

  local function rawget_(t, k)
    R.checktable(t, 1, "rawget")
    return R.rawget(t, k)
  end

  local function rawset_(t, k, v)
    R.checktable(t, 1, "rawset")
    R.rawset(t, k, v)
    return t
  end

  local function rawequal_(a, b)
    return a == b
  end

  local function rawlen_(v)
    if type(v) == "string" then return #v end
    if R.isTable(v) then return R.rawlen(v) end
    R.argerror(1, "rawlen", "table or string expected")
  end

  local function setmetatable_(t, mt)
    R.checktable(t, 1, "setmetatable")
    if mt ~= nil and not R.isTable(mt) then
      R.typeerror(2, "setmetatable", "nil or table", mt)
    end
    if t.mt ~= nil and t.mt.hash.__metatable ~= nil then
      R.rterror("cannot change a protected metatable")
    end
    R.setmetatable(t, mt)
    return t
  end

  local function getmetatable_(v)
    local mt = R.getmt(v)
    if mt == nil then return nil end
    local protected = mt.hash.__metatable
    if protected ~= nil then return protected end
    return mt
  end

  local function assert_(...)
    local n = select("#", ...)
    if n == 0 then R.argerror(1, "assert", "value expected") end
    local v = ...
    if v ~= nil and v ~= false then return ... end
    if n < 2 then
      -- LUALUA_DEBUG=1 reports where an assertion failed (debugging aid)
      if os.getenv("LUALUA_DEBUG") then io.stderr:write("assertion failed at ", R.where(1), "\n") end
      R.throw("assertion failed!")
    end
    R.throw((select(2, ...)))
  end

  local function error_(msg, level)
    if msg == nil then R.throw("<no error object>") end
    level = R.optinteger(level, 2, "error", 1)
    if type(msg) == "string" and level > 0 then
      msg = R.where(level) .. msg
    end
    R.throw(msg)
  end

  -- Runs f(...) in protected mode, restoring the frame stack on error.
  local function pcall_(f, ...)
    local st = R.stack
    local n = st.n
    local savednat = st.nat
    if FUPS[f] == nil then st.nat = n end   -- a native called directly by pcall
    local r = pack(pcall(R.call, f, ...))
    st.nat = savednat
    if not r[1] then
      st.n = n
    end
    return unpack(r, 1, r.n)
  end

  local function xpcall_(f, handler, ...)
    local st = R.stack
    local n = st.n
    local savednat = st.nat
    if FUPS[f] == nil then st.nat = n end
    local r = pack(pcall(R.call, f, ...))
    st.nat = savednat
    if r[1] then return unpack(r, 1, r.n) end
    st.n = n
    local hr = pack(pcall(R.call, handler, r[2]))
    st.n = n
    if not hr[1] then
      -- an error inside the message handler
      return false, "error in error handling"
    end
    return false, hr[2]
  end

  local function load_(chunk, chunkname, mode, ...)
    local src
    if type(chunk) == "string" then
      src = chunk
      chunkname = chunkname or chunk
    elseif type(chunk) == "function" then
      local parts = {}
      while true do
        local piece = R.call(chunk)
        if piece == nil or piece == "" then break end
        if type(piece) ~= "string" then
          return nil, "reader function must return a string"
        end
        parts[#parts + 1] = piece
      end
      src = table.concat(parts)
      chunkname = chunkname or "=(load)"
    else
      R.typeerror(1, "load", "string", chunk)
    end
    if mode ~= nil then
      mode = R.checkstring(mode, 3, "load")
      -- only text chunks are supported (no precompiled binary chunks)
      if not mode:find("t", 1, true) then
        return nil, "attempt to load a text chunk (mode is '" .. mode .. "')"
      end
    end
    local e = G
    if select("#", ...) >= 1 then e = (...) end   -- explicit env argument (even nil)
    local f, err = loader.load(src, chunkname or src, e)
    if not f then return nil, err end
    return f
  end

  local function readfile(path)
    local fh, err = io.open(path, "rb")
    if not fh then return nil, err end
    local s = fh:read("a")
    fh:close()
    return s
  end

  local function loadfile_(path, mode, ...)
    local src, err
    if path == nil then
      src = io.read("a")
      path = "=stdin"
    else
      src, err = readfile(path)
      if not src then return nil, "cannot open " .. path .. (err and (": " .. err:gsub("^[^:]*: ", "")) or "") end
      path = "@" .. path
    end
    if src:sub(1, 1) == "#" then
      src = "--" .. src
    end
    local e = G
    if select("#", ...) >= 1 then e = (...) end
    local f, lerr = loader.load(src, path, e)
    if not f then return nil, lerr end
    return f
  end

  local function dofile_(path)
    local f, err = loadfile_(path)
    if not f then R.throw(err) end
    return f()
  end

  local gcparams = { pause = 200, stepmul = 100, stepsize = 13, minormul = 20, majormul = 100 }
  local gcmode = "incremental"
  local function collectgarbage_(opt, ...)
    opt = R.optstring(opt, 1, "collectgarbage", "collect")
    if opt == "count" then
      local kb = collectgarbage("count")
      return kb, 0
    elseif opt == "collect" or opt == "step" or opt == "isrunning" or opt == "stop"
        or opt == "restart" or opt == "incremental" or opt == "generational" then
      return collectgarbage(opt)
    elseif opt == "param" then
      -- collector parameters: stored and returned, not used
      local name = R.optstring(select(1, ...), 2, "collectgarbage", nil)
      local value = select(2, ...)
      local old = gcparams[name or "pause"] or 0
      if name ~= nil and value ~= nil then gcparams[name] = value end
      return old
    elseif opt == "incremental" or opt == "generational" then
      local old = gcmode
      gcmode = opt
      return old
    end
    R.argerror(1, "collectgarbage", "invalid option '" .. opt .. "'")
  end

  local warnon = false
  local function warn_(...)
    local n = select("#", ...)
    if n == 0 then R.argerror(1, "warn", "string expected, got no value") end
    local parts = {}
    for i = 1, n do parts[i] = R.checkstring((select(i, ...)), i, "warn") end
    local msg = table.concat(parts)
    if n == 1 and msg:sub(1, 1) == "@" then
      if msg == "@on" then warnon = true elseif msg == "@off" then warnon = false end
      return
    end
    if warnon then io.stderr:write("Lua warning: ", msg, "\n") end
  end

  -- package and require ----------------------------------------------------

  local package = R.newtable()
  local loaded = R.newtable()
  local preload = R.newtable()
  package.hash.loaded = loaded
  package.hash.preload = preload
  package.hash.path = "/usr/local/share/lua/5.5/?.lua;/usr/local/share/lua/5.5/?/init.lua;./?.lua;./?/init.lua"
  package.hash.cpath = ""
  package.hash.config = "/\n;\n?\n!\n-\n"
  G.hash.package = package

  local function searchpath(name, path)
    local fname = name:gsub("%.", "/")
    local tried = {}
    for template in path:gmatch("[^;]+") do
      local candidate = template:gsub("%?", fname)
      local fh = io.open(candidate, "r")
      if fh then
        fh:close()
        return candidate
      end
      tried[#tried + 1] = "\n\tno file '" .. candidate .. "'"
    end
    return nil, table.concat(tried)
  end

  package.hash.searchpath = function(name, path)
    name = R.checkstring(name, 1, "searchpath")
    path = R.checkstring(path, 2, "searchpath")
    local file, tried = searchpath(name, path)
    if file then return file end
    return nil, tried
  end

  local function require_(name)
    name = R.checkstring(name, 1, "require")
    local v = loaded.hash[name]
    if v ~= nil then return v end
    local pre = preload.hash[name]
    local loader_fn, extra
    if pre ~= nil then
      loader_fn, extra = pre, ":preload:"
    else
      local path = package.hash.path
      if type(path) ~= "string" then R.rterror("'package.path' must be a string") end
      local file, tried = searchpath(name, path)
      if not file then
        -- C modules are not loadable here, but the message lists their search too
        local cpath = package.hash.cpath
        local _, ctried = searchpath(name, type(cpath) == "string" and cpath or "")
        R.rterror("module '" .. name .. "' not found:\n\tno field package.preload['" .. name .. "']"
                  .. tried .. (ctried or ""))
      end
      local src = readfile(file)
      local f, err = loader.load(src, "@" .. file, G)
      if not f then R.rterror("error loading module '" .. name .. "' from file '" .. file .. "':\n\t" .. tostring(err)) end
      loader_fn, extra = f, file
    end
    local res = R.call(loader_fn, name, extra)
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
