-- lib/debug.lua: a subset of the debug library.
-- Closures created by compiler.lua are registered in C.FUPS (weak keys):
--   C.FUPS[f] = ups, an array of cells with .c (the compiled proto) and .fn

local R = require("runtime")
local C = require("compiler")

return function(G)
  local lib = R.newtable()

  -- userdata wrapping upvalue cells, one per cell, so that upvalueid is stable
  local cellids = setmetatable({}, { __mode = "k" })

  local function traceback(msg, level)
    if msg ~= nil and type(msg) ~= "string" and type(msg) ~= "number" then
      return msg
    end
    local lines = {}
    if msg ~= nil then lines[#lines + 1] = R.tostring(msg) end
    lines[#lines + 1] = "stack traceback:"
    local st = R.stack
    for i = st.n, 1, -1 do
      local f = st[i]
      local src = f.up.c.src
      lines[#lines + 1] = "\t" .. src .. ":" .. f.line .. ": in function <" .. src .. ">"
    end
    lines[#lines + 1] = "\t[C]: in ?"
    return table.concat(lines, "\n")
  end

  -- splits a call description such as "global 'f'" into namewhat and name
  local function splitdesc(desc)
    if not desc then return nil, nil end
    local q = string.find(desc, "'", 1, true)
    return string.sub(desc, q + 1, -2), string.sub(desc, 1, q - 2)
  end

  local GETINFO_OPTS = {}
  for _, c in ipairs({ "S", "l", "n", "r", "u", "t", "f", "L" }) do GETINFO_OPTS[string.byte(c)] = true end

  local function getinfo(a, opts)
    local t = R.newtable()
    local st = R.stack
    if opts ~= nil then
      opts = R.checkstring(opts, 2, "getinfo")
      for i = 1, #opts do
        if not GETINFO_OPTS[string.byte(opts, i)] then R.argerror(2, "getinfo", "invalid option") end
      end
    end
    if type(a) == "number" then
      if a < 0 or a > st.n then return nil end
      if a == 0 then return nil end
      local f = st[st.n - a + 1]
      if f then
        local c = f.up.c
        t.hash.func = f.up.fn
        t.hash.currentline = f.line
        t.hash.short_src = c.src
        t.hash.source = c.source
        t.hash.linedefined = c.line
        t.hash.lastlinedefined = c.lastline
        t.hash.what = (c.line == 0) and "main" or "Lua"
        t.hash.extraargs = f.va and f.va.n or 0
        -- the name is recorded by the caller, one frame up
        local caller = st[st.n - a]
        local name, namewhat = splitdesc(caller and caller.cdesc)
        t.hash.name = name
        t.hash.namewhat = namewhat or ""
      end
    elseif type(a) == "function" then
      t.hash.func = a
      local info = C.FUPS[a]
      if info then
        local c = info.c
        t.hash.what = (c.line == 0) and "main" or "Lua"
        t.hash.short_src = c.src
        t.hash.source = c.source
        t.hash.linedefined = c.line
        t.hash.lastlinedefined = c.lastline
      else
        t.hash.what = "C"
        t.hash.short_src = "[C]"
        t.hash.source = "=[C]"
        t.hash.linedefined = -1
      end
      t.hash.currentline = -1
    else
      R.argerror(1, "getinfo", "function or level expected")
    end
    return t
  end

  -- upvalue access: the closure must have been created by compiler.lua
  local function getupvalue(f, n)
    R.checkfunction(f, 1, "getupvalue")
    n = R.checkinteger(n, 2, "getupvalue")
    local info = C.FUPS[f]
    if not info or n < 1 or n > #info then return nil end
    return info.c.upnames[n], info[n].v
  end

  local function setupvalue(f, n, v)
    R.checkfunction(f, 1, "setupvalue")
    n = R.checkinteger(n, 2, "setupvalue")
    local info = C.FUPS[f]
    if not info or n < 1 or n > #info then return nil end
    info[n].v = v
    return info.c.upnames[n]
  end

  local function upvalueid(f, n)
    n = R.checkinteger(n, 2, "upvalueid")
    local info = C.FUPS[f]
    if not info or n < 1 or n > #info then return nil end
    local cell = info[n]
    local id = cellids[cell]
    if id == nil then
      id = R.newuserdata(cell, nil)
      cellids[cell] = id
    end
    return id
  end

  local function upvaluejoin(f1, n1, f2, n2)
    n1 = R.checkinteger(n1, 2, "upvaluejoin")
    n2 = R.checkinteger(n2, 4, "upvaluejoin")
    local i1, i2 = C.FUPS[f1], C.FUPS[f2]
    if not i1 or n1 < 1 or n1 > #i1 then R.argerror(2, "upvaluejoin", "invalid upvalue index") end
    if not i2 or n2 < 1 or n2 > #i2 then R.argerror(4, "upvaluejoin", "invalid upvalue index") end
    i1[n1] = i2[n2]
  end

  local function unsupported(name)
    R.rterror("debug." .. name .. " is not supported by lualua")
  end

  R.setfuncs(lib, {
    traceback = traceback,
    getinfo = getinfo,
    getupvalue = getupvalue,
    setupvalue = setupvalue,
    upvalueid = upvalueid,
    upvaluejoin = upvaluejoin,
    getmetatable = function(...)
      if select("#", ...) == 0 then R.argerror(1, "getmetatable", "value expected") end
      return R.getmt((...))
    end,
    setmetatable = function(v, mt)
      if mt ~= nil and not R.isTable(mt) then R.typeerror(2, "setmetatable", "nil or table", mt) end
      if R.isTable(v) or R.isUserdata(v) then
        R.setmetatable(v, mt)
      else
        R.typemt[R.type(v)] = mt
      end
      return v
    end,
    -- Hooks, local variable access, the registry and uservalues are not implemented.
    -- Requests that cannot be served raise an error instead of being silently ignored.
    sethook = function(...)
      local hook = ...
      if type(hook) == "thread" then hook = (select(2, ...)) end
      if hook == nil then return end   -- clearing hooks: no hook can be set, so nothing to clear
      unsupported("sethook")
    end,
    gethook = function() return nil end,   -- no hook can be set
    getlocal = function() unsupported("getlocal") end,
    setlocal = function() unsupported("setlocal") end,
    getregistry = function() unsupported("getregistry") end,
    getuservalue = function() unsupported("getuservalue") end,
    setuservalue = function() unsupported("setuservalue") end,
  })
  G.hash.debug = lib
end
