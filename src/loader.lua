-- loader.lua: turns source text into Lua functions (used by load, loadfile,
-- dofile, require and the command-line interpreter).

local parser = require("parser")
local C = require("compiler")

local L = {}

-- Short printable form of a chunk name, as luaO_chunkid does.
function L.chunkid(source)
  local first = source:sub(1, 1)
  if first == "=" then
    return source:sub(2, 60)
  elseif first == "@" then
    local f = source:sub(2)
    if #f <= 59 then return f end
    return "..." .. f:sub(-56)
  end
  local line = source:match("^[^\n\r]*")
  if #line == #source and #line <= 45 then
    return '[string "' .. line .. '"]'
  end
  return '[string "' .. line:sub(1, 45) .. '..."]'
end

-- Compiles source into a Lua function whose _ENV is env.
-- Returns the function, or nil and an error message.
function L.load(src, chunkname, env)
  local short = L.chunkid(chunkname)
  local ok, proto = pcall(parser.parse, src, short)
  if not ok then return nil, proto end
  return C.load(proto, short, env, chunkname)
end

return L
