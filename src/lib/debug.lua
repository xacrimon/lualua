-- lib/debug.lua: a small subset of the debug library.

local R = require("runtime")

return function(G)
  local lib = R.newtable()

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

  local function getinfo(a, b)
    local t = R.newtable()
    local st = R.stack
    if type(a) == "number" then
      local i = st.n - a + 1
      local f = st[i]
      if a > st.n then return nil end
      if f then
        t.hash.currentline = f.line
        t.hash.short_src = f.src
        t.hash.source = "@" .. f.src
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

  R.setfuncs(lib, {
    traceback = traceback,
    getinfo = getinfo,
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
    getupvalue = function() return nil end,
  })
  G.hash.debug = lib
end
