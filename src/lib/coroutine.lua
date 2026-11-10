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
  -- coroutines that have been resumed at least once
  local started = setmetatable({}, { __mode = "k" })
  -- coroutines that have been closed (their error, if any, was reported)
  local closed = setmetatable({}, { __mode = "k" })

  local function checkco(co, n, fname)
    if type(co) ~= "thread" then R.typeerror(n, fname, "coroutine", co) end
    return co
  end

  local function create(f)
    R.checkfunction(f, 1, "create")
    local co = cocreate(function(...)
      local r = pack(pcall(R.call, f, ...))
      if r[1] then return unpack(r, 2, r.n) end
      -- closed by coroutine.close (from inside): the coroutine ends normally
      if r[2] == R.CLOSING then return end
      error(r[2], 0)
    end)
    stacks[co] = { n = 0 }
    return co
  end

  -- Resumes co on its own frame stack. Returns the host results.
  local function resume_raw(co, ...)
    started[co] = true
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
    if (R.stack.nny or 0) > 0 then
      -- raised inside the native yield, so (as in the reference) no position is added
      R.throw("attempt to yield across a C-call boundary")
    end
    local r = pack(coyield(...))
    -- resumed by coroutine.close: unwind the coroutine (running its __close handlers)
    if r[1] == R.CLOSING and r.n == 1 then R.throw(R.CLOSING) end
    return unpack(r, 1, r.n)
  end

  local function status(co)
    checkco(co, 1, "status")
    return costatus(co)
  end

  local function running()
    return corunning()
  end

  local function isyieldable(co)
    if co == nil then
      return coisyieldable() and not ((R.stack.nny or 0) > 0)
    end
    checkco(co, 1, "isyieldable")
    local st = stacks[co]
    return coisyieldable(co) and not (st and (st.nny or 0) > 0)
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
    if co == nil then co = corunning() end   -- default: the running coroutine
    checkco(co, 1, "close")
    local st = costatus(co)
    if st == "dead" and closed[co] then return true end   -- after closing, no more errors
    if st == "suspended" and started[co] then
      -- unwind the suspended coroutine so its pending __close handlers run
      local r = resume_raw(co, R.CLOSING)
      closed[co] = true
      if r[1] or r[2] == R.CLOSING then return true end
      return false, r[2]
    end
    if st == "suspended" or st == "dead" then
      local ok, err = coclose(co)
      closed[co] = true
      if not ok then return false, err end
      return true
    end
    if st == "running" then
      if co == mainthread then R.rterror("cannot close main thread") end
      -- a coroutine closing itself unwinds (running its pending __close handlers)
      R.throw(R.CLOSING)
    end
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
