-- lualua.lua: command-line entry point, mirroring the standalone `lua` program.
--   lua lualua.lua [options] [script [args]]
--   options: -e stat   execute a string
--            -v        show version
--            -         read the script from stdin
--            --        stop handling options

local here = arg and arg[0] and arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/src/?.lua;" .. package.path

local R = require("runtime")
local I = require("interp")
local L = require("loader")

local function errmsg(e)
  if type(e) == "string" then return e end
  return R.tostring(e)
end

local function die(msg)
  io.stderr:write("lua: ", msg, "\n")
  os.exit(1)
end

local function runchunk(G, src, chunkname, args)
  local f, err = L.load(src, chunkname, G)
  if not f then die(err) end
  local ok, e = pcall(R.call, f, table.unpack(args, 1, args.n))
  if not ok then die(errmsg(e)) end
end

local function main(argv)
  local G = I.newstate()
  -- global `arg` table: script name at 0, options before it at negative indices
  local argt = R.newtable()
  local script
  local scriptargs = { n = 0 }
  local i = 1
  local exec = {}
  local interactive = false
  while i <= argv.n do
    local a = argv[i]
    if a == "--" then
      i = i + 1
      break
    elseif a == "-" then
      break
    elseif a == "-e" then
      i = i + 1
      exec[#exec + 1] = argv[i]
    elseif a == "-v" then
      io.write("Lua 5.5  (lualua)\n")
    elseif a:sub(1, 2) == "-e" then
      exec[#exec + 1] = a:sub(3)
    elseif a:sub(1, 1) == "-" and #a > 1 then
      die("unrecognized option '" .. a .. "'")
    else
      break
    end
    i = i + 1
  end
  argt.hash[0] = argv[0]
  for j = 1, i - 1 do argt.hash[j - i] = argv[j] end
  G.hash.arg = argt

  for _, stat in ipairs(exec) do
    runchunk(G, stat, "=(command line)", { n = 0 })
  end

  if i <= argv.n then
    script = argv[i]
    for j = i + 1, argv.n do
      scriptargs.n = scriptargs.n + 1
      scriptargs[scriptargs.n] = argv[j]
    end
    argt.hash[0] = script
    for j = 1, scriptargs.n do argt.hash[j] = scriptargs[j] end
    local fh = io.open(script, "rb")
    if not fh then die("cannot open " .. script) end
    local src = fh:read("a")
    fh:close()
    if src:sub(1, 3) == "\239\187\191" then src = src:sub(4) end
    if src:sub(1, 1) == "#" then src = "--" .. src end
    runchunk(G, src, "@" .. script, scriptargs)
  elseif #exec == 0 then
    interactive = true
    local src = io.read("a")
    runchunk(G, src, "=stdin", { n = 0 })
  end
  return 0
end

-- Build argv as a host array with n, from the host arg table (arg[0] = script).
local argv = { n = 0 }
do
  local i = 1
  while arg[i] ~= nil do
    argv.n = argv.n + 1
    argv[argv.n] = arg[i]
    i = i + 1
  end
  argv[0] = arg[0]
end
main(argv)
os.exit(0, true)   -- closing the state runs pending finalizers
