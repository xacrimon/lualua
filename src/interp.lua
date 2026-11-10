-- interp.lua: creates a global environment with all standard libraries.

local R = require("runtime")

local I = {}

-- base first: it creates the package library and package.loaded
local LIBS = { "base", "coroutine", "string", "table", "math", "utf8", "os", "io", "debug" }

-- Returns a new global table (Lua table) with the standard libraries installed.
function I.newstate()
  local G = R.newtable()
  for _, name in ipairs(LIBS) do
    require("lib." .. name)(G)
    local lib = G.hash[name]
    if lib ~= nil then R.loadedtable.hash[name] = lib end
  end
  return G
end

return I
