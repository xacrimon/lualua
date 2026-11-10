-- lib/debug.lua: a subset of the debug library.
-- Closures created by compiler.lua are registered in C.FUPS (weak keys):
--   C.FUPS[f] = ups, an array of cells with .names (upvalue names)

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
      lines[#lines + 1] = "\t" .. f.src .. ":" .. f.line .. ": in function <" .. f.src .. ">"
    end
    lines[#lines + 1] = "\t[C]: in ?"
    return table.concat(lines, "\n")
  end

  -- splits a call description such as "global 'f'" into namewhat and name
  local function splitdesc(desc)
    if desc == nil then return nil, nil end
    local kind, name = desc:match("^(%S+) '(.*)'$")
    if kind == "for" then kind = "for iterator" end
    return name, kind
  end

  local function getinfo(a, opts)
    local t = R.newtable()
    local st = R.stack
    if opts ~= nil then
      opts = R.checkstring(opts, 2, "getinfo")
      if opts:find("[^SlnrutfL]") then R.argerror(2, "getinfo", "invalid option") end
    end
    if type(a) == "number" then
      if a < 0 or a > st.n then return nil end
      if a == 0 then return nil end
      local f = st[st.n - a + 1]
      if f then
        t.hash.currentline = f.line
        t.hash.short_src = f.src
        t.hash.source = "@" .. f.src
        t.hash.what = "Lua"
        -- the name is recorded by the caller, one frame up
        local caller = st[st.n - a]
        local name, namewhat = splitdesc(caller and caller.cdesc)
        t.hash.name = name
        t.hash.namewhat = namewhat or ""
      end
    elseif type(a) == "function" then
      t.hash.func = a
      t.hash.what = "Lua"
      t.hash.short_src = "?"
      t.hash.source = "=?"
      t.hash.currentline = -1
    else
      R.argerror(1, "getinfo", "function or level expected")
    end
    return t
  end

  -- upvalue access: the closure must have been created by compiler.lua
  local function getupvalue(f, n)
    n = R.checkinteger(n, 2, "getupvalue")
    local info = C.FUPS[f]
    if not info or n < 1 or n > #info then return nil end
    return info.names[n], info[n].v
  end

  local function setupvalue(f, n, v)
    n = R.checkinteger(n, 2, "setupvalue")
    local info = C.FUPS[f]
    if not info or n < 1 or n > #info then return nil end
    info[n].v = v
    return info.names[n]
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

  R.setfuncs(lib, {
    traceback = traceback,
    getinfo = getinfo,
    getupvalue = getupvalue,
    setupvalue = setupvalue,
    upvalueid = upvalueid,
    upvaluejoin = upvaluejoin,
    getmetatable = function(v) return R.getmt(v) end,
    setmetatable = function(v, mt)
      if R.isTable(v) or R.isUserdata(v) then
        R.setmetatable(v, mt)
      else
        R.typemt[R.type(v)] = mt
      end
      return v
    end,
    sethook = function() end,
    gethook = function() return nil end,
    getlocal = function() return nil end,
  })
  G.hash.debug = lib
end
