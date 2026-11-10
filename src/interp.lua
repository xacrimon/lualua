-- interp.lua: creates a global environment with all standard libraries.

local R = require("runtime")

local I = {}

local LIBS = { "base", "coroutine", "string", "table", "math", "utf8", "os", "io", "debug" }

-- Returns a new global table (Lua table) with the standard libraries installed.
function I.newstate()
  local G = R.newtable()
  for _, name in ipairs(LIBS) do
    local ok, install = pcall(require, "lib." .. name)
    if ok then
      install(G)
    elseif not tostring(install):find("not found", 1, true) then
      error(install, 0)
    end
  end
  return G
end

return I
