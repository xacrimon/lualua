-- loader.lua: turns source text into Lua functions (used by load, loadfile,
-- dofile, require and the command-line interpreter).

local R = require("runtime")
local parser = require("parser")
local C = require("compiler")

local ssub, sfind = string.sub, string.find

local L = {}

-- Short printable form of a chunk name, as luaO_chunkid does.
function L.chunkid(source)
  local first = ssub(source, 1, 1)
  if first == "=" then
    return ssub(source, 2, 60)
  elseif first == "@" then
    local f = ssub(source, 2)
    if #f <= 59 then return f end
    return "..." .. ssub(f, -56)
  end
  local nl = sfind(source, "\n", 1, true)   -- only '\n' ends the shown line
  local line = nl and ssub(source, 1, nl - 1) or source
  if nl == nil and #line < 45 then
    return '[string "' .. line .. '"]'
  end
  return '[string "' .. ssub(line, 1, 45) .. '..."]'
end

-- Compiles source into a Lua function whose _ENV is env.
-- Returns the function, or nil and an error message.
function L.load(src, chunkname, env)
  local short = L.chunkid(chunkname)
  R.chunknames[short] = true   -- positions in this chunk are Lua positions
  local ok, proto = pcall(parser.parse, src, short)
  if not ok then return nil, proto end
  return C.load(proto, short, env, chunkname)
end

return L
