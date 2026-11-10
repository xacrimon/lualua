-- lib/coroutine.lua: coroutines are host coroutines. Each one owns a frame
-- stack (R.stack) which is swapped in while it runs.

local R = require("runtime")

local cocreate, coresume, coyield = coroutine.create, coroutine.resume, coroutine.yield
local costatus, corunning, coisyieldable, coclose = coroutine.status, coroutine.running,
  coroutine.isyieldable, coroutine.close
local pack, unpack = table.pack, table.unpack

return function(G)
  -- frame stacks of coroutines, keyed by the host coroutine
  local stacks = setmetatable({}, { __mode = "k" })

  local function checkco(co, n, fname)
    if type(co) ~= "thread" then R.typeerror(n, fname, "coroutine", co) end
    return co
  end

  local function create(f)
    R.checkfunction(f, 1, "create")
    local co = cocreate(function(...) return R.call(f, ...) end)
    stacks[co] = { n = 0 }
    return co
  end

  -- Resumes co on its own frame stack. Returns the host results.
  local function resume_raw(co, ...)
    local saved = R.stack
    local st = stacks[co]
    if st == nil then st = { n = 0 }; stacks[co] = st end
    R.stack = st
    local r = pack(coresume(co, ...))
    R.stack = saved
    return r
  end

  local function resume(co, ...)
    checkco(co, 1, "resume")
    local r = resume_raw(co, ...)
    return unpack(r, 1, r.n)
  end

  local function yield(...)
    return coyield(...)
  end

  local function status(co)
    checkco(co, 1, "status")
    return costatus(co)
  end

  local function running()
    return corunning()
  end

  local function isyieldable(co)
    if co == nil then return coisyieldable() end
    checkco(co, 1, "isyieldable")
    return coisyieldable(co)
  end

  local function wrap(f)
    R.checkfunction(f, 1, "wrap")
    local co = create(f)
    return function(...)
      local r = resume_raw(co, ...)
      if not r[1] then
        local err = r[2]
        R.throw(err)
      end
      return unpack(r, 2, r.n)
    end
  end

  local mainthread = corunning()

  local function close(co)
    checkco(co, 1, "close")
    local st = costatus(co)
    if st == "suspended" or st == "dead" then
      local ok, err = coclose(co)
      if not ok then return false, err end
      return true
    end
    if st == "running" and co == mainthread then R.rterror("cannot close main thread") end
    R.rterror("cannot close a " .. st .. " coroutine")
  end

  local lib = R.newtable()
  R.setfuncs(lib, {
    create = create,
    resume = resume,
    yield = yield,
    status = status,
    running = running,
    isyieldable = isyieldable,
    wrap = wrap,
    close = close,
  })
  G.hash.coroutine = lib
end
