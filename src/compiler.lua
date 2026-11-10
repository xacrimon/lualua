-- compiler.lua: turns the AST from parser.lua into Lua closures.
--
-- Activation record A (a host table, also the stack frame):
--   A[slot]   value of a local, or a cell {v=value} if the local is captured
--   A.up      array of upvalue cells {v=value}
--   A.va      varargs {n=count, ...} (vararg functions only)
--   A.src, A.line, A.depth   frame information for error positions
--   A[block]  to-be-closed list of a block (blocks with <close> locals)
--
-- Expressions compile to closures f(A) returning exactly one value; "multi"
-- closures return all values. Statements compile to closures f(A) returning
-- nothing (normal), or a signal: BREAK, RETURN(values table), GOTO(label),
-- TAILCALL({fn, argstable, desc}).

local R = require("runtime")

local C = {}

local BREAK, RETURN, GOTO, TAILCALL = 1, 2, 3, 4

local type, select, pcall, error = type, select, pcall, error
local pack, unpack = table.pack, table.unpack
local mtype = math.type
local getmetatable = getmetatable
local TableMT = R.TableMT

local rterror, callx, index, setindex = R.rterror, R.callx, R.index, R.setindex
local lt, le, eq, concat, len = R.lt, R.le, R.eq, R.concat, R.len
local add, sub, mul, div, mod, idiv, pow = R.add, R.sub, R.mul, R.div, R.mod, R.idiv, R.pow
local unm, bnot, band, bor, bxor, shl, shr = R.unm, R.bnot, R.band, R.bor, R.bxor, R.shl, R.shr
local truthy = R.truthy
local rawset = R.rawset

local MAXDEPTH = 195000
-- closure -> its upvalue cells; the cell array also carries .names (upvalue names)
local FUPS = setmetatable({}, { __mode = "k" })
C.FUPS = FUPS
local CURSRC = "?"      -- short chunk name of the chunk being compiled
local CURSOURCE = "?"   -- the chunk name as given to load

-- Description of an expression for error messages ("local 'x'", ...).
-- Number of values in a named vararg table (its field n must be a proper count).
local function vacount(t)
  local n = t.hash.n
  if mtype(n) ~= "integer" or n < 0 or n >= 0x7fffffff then rterror("no proper 'n'") end
  return n
end

local function describe(node)
  local k = node.k
  if k == "local" then return "local '" .. node.name .. "'" end
  if k == "upval" then return "upvalue '" .. node.name .. "'" end
  if k == "index" then
    if node.gname then return "global '" .. node.gname .. "'" end
    if node.key.k == "str" then return "field '" .. node.key.v .. "'" end
  end
  if k == "method" then return (node.field and "field '" or "method '") .. node.name .. "'" end
  return nil
end

local cexpr, cmulti, compile_args, cblock, compile_proto, clearslots

local function isMulti(node)
  local k = node.k
  return k == "call" or k == "method" or k == "vararg"
end

---------------------------------------------------------------------------
-- Expressions
---------------------------------------------------------------------------

local E = {}

E["nil"] = function() return function() return nil end end
E["true"] = function() return function() return true end end
E["false"] = function() return function() return false end end

E.num = function(node)
  local v = node.v
  return function() return v end
end
E.str = E.num

E["local"] = function(node)
  local s = node.var.slot
  if node.var.captured then
    return function(A) return A[s].v end
  end
  return function(A) return A[s] end
end

E.upval = function(node)
  local i = node.idx
  return function(A) return A.up[i].v end
end

E.vararg = function(node)
  if node.var then
    -- named vararg (...name): the variable holds the extra arguments
    local s, cap = node.var.slot, node.var.captured
    return function(A)
      local t = cap and A[s].v or A[s]
      return t.hash[1]
    end
  end
  return function(A) return A.va[1] end
end

E.index = function(node)
  local o = cexpr(node.obj)
  local key = cexpr(node.key)
  local d = describe(node.obj)
  return function(A)
    local ob = o(A)
    return index(ob, key(A), d)
  end
end

E.call = function(node)
  local m = cmulti(node)
  return function(A) return (m(A)) end
end
E.method = E.call

E.paren = function(node)
  return cexpr(node.e)
end

E.func = function(node)
  local c = compile_proto(node.f)
  local udesc = c.udesc
  local nup = #udesc
  return function(A)
    local ups = {}
    for i = 1, nup do
      local u = udesc[i]
      if u.instack then ups[i] = A[u.slot] else ups[i] = A.up[u.idx] end
    end
    return C.newlua(c, ups)
  end
end

E["and"] = function(node)
  local a, b = cexpr(node.a), cexpr(node.b)
  return function(A)
    local x = a(A)
    if x == nil or x == false then return x end
    return b(A)
  end
end

E["or"] = function(node)
  local a, b = cexpr(node.a), cexpr(node.b)
  return function(A)
    local x = a(A)
    if x ~= nil and x ~= false then return x end
    return b(A)
  end
end

E.unop = function(node)
  local op = node.op
  local a = cexpr(node.a)
  local d = describe(node.a)
  if op == "not" then
    return function(A)
      local x = a(A)
      return x == nil or x == false
    end
  elseif op == "-" then
    return function(A)
      local x = a(A)
      if type(x) == "number" then return -x end
      return unm(x, d)
    end
  elseif op == "#" then
    return function(A)
      local x = a(A)
      if type(x) == "string" then return #x end
      return len(x, d)
    end
  elseif op == "~" then
    return function(A)
      return bnot(a(A), d)
    end
  end
  error("unknown unary operator " .. op)
end

local ARITH_SLOW = {
  ["+"] = add, ["-"] = sub, ["*"] = mul, ["/"] = div, ["%"] = mod,
  ["//"] = idiv, ["^"] = pow, ["&"] = band, ["|"] = bor, ["~"] = bxor,
  ["<<"] = shl, [">>"] = shr,
}

E.binop = function(node)
  local op = node.op
  local a, b = cexpr(node.a), cexpr(node.b)
  local da, db = describe(node.a), describe(node.b)
  if op == "+" then
    return function(A)
      local x = a(A)
      local y = b(A)
      if type(x) == "number" and type(y) == "number" then return x + y end
      return add(x, y, da, db)
    end
  elseif op == "-" then
    return function(A)
      local x = a(A)
      local y = b(A)
      if type(x) == "number" and type(y) == "number" then return x - y end
      return sub(x, y, da, db)
    end
  elseif op == "*" then
    return function(A)
      local x = a(A)
      local y = b(A)
      if type(x) == "number" and type(y) == "number" then return x * y end
      return mul(x, y, da, db)
    end
  elseif op == "==" then
    return function(A)
      local x = a(A)
      return eq(x, b(A))
    end
  elseif op == "~=" then
    return function(A)
      local x = a(A)
      return not eq(x, b(A))
    end
  elseif op == "<" then
    return function(A)
      local x = a(A)
      local y = b(A)
      if type(x) == "number" and type(y) == "number" then return x < y end
      return lt(x, y)
    end
  elseif op == "<=" then
    return function(A)
      local x = a(A)
      local y = b(A)
      if type(x) == "number" and type(y) == "number" then return x <= y end
      return le(x, y)
    end
  elseif op == ">" then
    return function(A)
      local x = a(A)
      local y = b(A)
      if type(x) == "number" and type(y) == "number" then return x > y end
      return lt(y, x)
    end
  elseif op == ">=" then
    return function(A)
      local x = a(A)
      local y = b(A)
      if type(x) == "number" and type(y) == "number" then return x >= y end
      return le(y, x)
    end
  elseif op == ".." then
    return function(A)
      local x = a(A)
      local y = b(A)
      if type(x) == "string" and type(y) == "string" then return x .. y end
      return concat(x, y, da, db)
    end
  end
  local f = ARITH_SLOW[op]
  if not f then error("unknown binary operator " .. op) end
  return function(A)
    local x = a(A)
    local y = b(A)
    return f(x, y, da, db)
  end
end

E.table = function(node)
  local items = {}
  local n = #node.items
  for i, it in ipairs(node.items) do
    if it.kind == "pos" then
      if i == n and isMulti(it.value) then
        items[i] = { pos = true, multi = true, fn = cmulti(it.value) }
      else
        items[i] = { pos = true, fn = cexpr(it.value) }
      end
    else
      items[i] = { pos = false, key = cexpr(it.key), val = cexpr(it.value) }
    end
  end
  return function(A)
    local t = R.newtable()
    local h = t.hash
    local idx = 0
    for i = 1, n do
      local it = items[i]
      if it.pos then
        if it.multi then
          local r = pack(it.fn(A))
          for j = 1, r.n do
            idx = idx + 1
            h[idx] = r[j]
          end
        else
          idx = idx + 1
          h[idx] = it.fn(A)
        end
      else
        local k = it.key(A)
        rawset(t, k, it.val(A))
      end
    end
    return t
  end
end

-- Single-value closure for any expression node.
cexpr = function(node)
  local f = E[node.k]
  if not f then error("internal: no expression compiler for " .. tostring(node.k)) end
  return f(node)
end

-- Multi-value closure: calls and varargs return all their values.
cmulti = function(node)
  local k = node.k
  if k == "vararg" then
    if node.var then
      local s, cap = node.var.slot, node.var.captured
      return function(A)
        local t = cap and A[s].v or A[s]
        return unpack(t.hash, 1, vacount(t))
      end
    end
    return function(A)
      local va = A.va
      return unpack(va, 1, va.n)
    end
  elseif k == "call" then
    local f = cexpr(node.fn)
    local argsf = compile_args(node.args)
    local d = describe(node.fn)
    local line = node.line
    return function(A)
      local fv = f(A)
      local a = pack(argsf(A))
      -- the caller records the callee's description and argument count (for
      -- argument error messages and debug.getinfo names)
      A.line = line
      A.cdesc = d
      A.nargs = a.n
      if type(fv) == "function" then return fv(unpack(a, 1, a.n)) end
      return callx(d, fv, unpack(a, 1, a.n))
    end
  elseif k == "method" then
    local o = cexpr(node.obj)
    local argsf = compile_args(node.args)
    local name = node.name
    local d = describe(node.obj)
    local line = node.line
    local mdesc = (node.field and "field '" or "method '") .. name .. "'"
    return function(A)
      local ob = o(A)
      local fv = index(ob, name, d)
      local a = pack(argsf(A))
      A.line = line
      A.cdesc = mdesc
      A.nargs = a.n + 1   -- the receiver counts
      if type(fv) == "function" then return fv(ob, unpack(a, 1, a.n)) end
      return callx(mdesc, fv, ob, unpack(a, 1, a.n))
    end
  end
  return cexpr(node)
end

-- Closure returning all values of an expression list (multi-valued).
compile_args = function(exprs)
  local n = #exprs
  if n == 0 then
    return function() end
  end
  local last = exprs[n]
  local multi = isMulti(last)
  if n == 1 then
    if multi then return cmulti(last) end
    local e = cexpr(last)
    return function(A) return e(A) end
  end
  local fixed = {}
  for i = 1, n - 1 do fixed[i] = cexpr(exprs[i]) end
  local nfix = n - 1
  if not multi then
    local lastf = cexpr(last)
    if nfix == 1 then
      local a = fixed[1]
      return function(A)
        local x = a(A)
        return x, lastf(A)
      end
    end
    return function(A)
      local t = {}
      for i = 1, nfix do t[i] = fixed[i](A) end
      t[n] = lastf(A)
      return unpack(t, 1, n)
    end
  end
  local lastf = cmulti(last)
  return function(A)
    local t = {}
    for i = 1, nfix do t[i] = fixed[i](A) end
    local r = pack(lastf(A))
    for j = 1, r.n do t[nfix + j] = r[j] end
    return unpack(t, 1, nfix + r.n)
  end
end

---------------------------------------------------------------------------
-- Assignment targets
---------------------------------------------------------------------------

-- Compiles an assignable expression into a target descriptor.
local function ctarget(node)
  local k = node.k
  if k == "local" then
    return { kind = "local", slot = node.var.slot, cap = node.var.captured }
  elseif k == "upval" then
    return { kind = "upval", idx = node.idx }
  elseif k == "index" then
    return { kind = "index", o = cexpr(node.obj), key = cexpr(node.key), d = describe(node.obj) }
  end
  error("internal: bad assignment target " .. tostring(k))
end

-- Stores v into a non-index target.
local function storevar(t, A, v)
  if t.kind == "local" then
    if t.cap then A[t.slot].v = v else A[t.slot] = v end
  else
    A.up[t.idx].v = v
  end
end

---------------------------------------------------------------------------
-- Statements
---------------------------------------------------------------------------

local S = {}

-- Registers a to-be-closed value; the list lives in A[blk].
local function checkclose(A, blk, vi, v)
  if v == nil or v == false then return end
  if R.metamethod(v, "__close") == nil then
    rterror("variable '" .. vi.name .. "' got a non-closable value")
  end
  local list = A[blk]
  list[#list + 1] = v
end

S["local"] = function(node, blk)
  local vars = node.vars
  local nv = #vars
  local exprs = node.exprs
  local hasclose = false
  for _, vi in ipairs(vars) do
    if vi.attrib == "close" then hasclose = true end
  end
  if nv == 1 and #exprs == 1 and not isMulti(exprs[1]) then
    local vi = vars[1]
    local e = cexpr(exprs[1])
    local s, cap = vi.slot, vi.captured
    return function(A)
      local v = e(A)
      if cap then A[s] = { v = v } else A[s] = v end
      if hasclose then checkclose(A, blk, vi, v) end
    end
  end
  local explist = compile_args(exprs)
  return function(A)
    local vals = pack(explist(A))
    for i = 1, nv do
      local vi = vars[i]
      local v = vals[i]
      if vi.captured then A[vi.slot] = { v = v } else A[vi.slot] = v end
      if vi.attrib == "close" then checkclose(A, blk, vi, v) end
    end
  end
end

S.localfunc = function(node)
  local vi = node.var
  local mk = E.func({ f = node.f })
  local s = vi.slot
  if vi.captured then
    return function(A)
      local cell = {}
      A[s] = cell
      cell.v = mk(A)
    end
  end
  return function(A) A[s] = mk(A) end
end

S.assign = function(node)
  local targets = node.targets
  local nt = #targets
  if nt == 1 and #node.exprs == 1 and not isMulti(node.exprs[1]) then
    local t = ctarget(targets[1])
    local e = cexpr(node.exprs[1])
    if t.kind == "index" then
      local o, key, d = t.o, t.key, t.d
      return function(A)
        local ob = o(A)
        local k = key(A)
        setindex(ob, k, e(A), d)
      end
    end
    return function(A) storevar(t, A, e(A)) end
  end
  local tg = {}
  for i, t in ipairs(targets) do tg[i] = ctarget(t) end
  local explist = compile_args(node.exprs)
  return function(A)
    local objs, keys = {}, {}
    for i = 1, nt do
      local t = tg[i]
      if t.kind == "index" then
        objs[i] = t.o(A)
        keys[i] = t.key(A)
      end
    end
    local vals = pack(explist(A))
    for i = nt, 1, -1 do
      local t = tg[i]
      if t.kind == "index" then
        setindex(objs[i], keys[i], vals[i], t.d)
      else
        storevar(t, A, vals[i])
      end
    end
  end
end

S.callstat = function(node)
  local c = cmulti(node.call)
  return function(A) c(A) end
end

S["do"] = function(node)
  return cblock(node.body)
end

S["while"] = function(node)
  local cond = cexpr(node.cond)
  local body = cblock(node.body)
  return function(A)
    while truthy(cond(A)) do
      local sig, val = body(A)
      if sig then
        if sig == BREAK then break end
        return sig, val
      end
    end
  end
end

S["repeat"] = function(node)
  -- the condition sees the body's locals, so they are cleared after it
  local body, slots = cblock(node.body, true)
  local cond = cexpr(node.cond)
  return function(A)
    repeat
      local sig, val = body(A)
      if sig then
        if sig == BREAK then break end
        return sig, val
      end
      local done = truthy(cond(A))
      clearslots(A, slots)
    until done
  end
end

S["if"] = function(node)
  local conds, blocks = {}, {}
  for i, c in ipairs(node.conds) do
    conds[i] = cexpr(c)
    blocks[i] = cblock(node.blocks[i])
  end
  local nc = #conds
  local elseb = node.elseblock and cblock(node.elseblock)
  return function(A)
    for i = 1, nc do
      if truthy(conds[i](A)) then return blocks[i](A) end
    end
    if elseb then return elseb(A) end
  end
end

-- Error for a non-numeric 'for' operand (wording of luaG_forerror).
local function forerror(v, what)
  rterror("bad 'for' " .. what .. " (number expected, got " .. R.objtypename(v) .. ")")
end

-- Limit conversion for integer loops (as forlimit in lvm.c).
-- Returns the integer limit, or nil when the loop must be skipped.
local function forlimit(limit, step)
  if mtype(limit) == "integer" then return limit end
  if type(limit) == "string" then limit = tonumber(limit) end
  if type(limit) ~= "number" then forerror(limit, "limit") end
  if limit ~= limit then return nil end
  local f = (step < 0) and math.ceil(limit) or math.floor(limit)
  local i = math.tointeger(f)
  if i then return i end
  if limit > 0 then
    if step < 0 then return nil end
    return math.maxinteger
  else
    if step > 0 then return nil end
    return math.mininteger
  end
end

-- Unsigned integer division (for loop iteration counts).
local function udiv(n, d)
  if d < 0 then
    if math.ult(n, d) then return 0 end
    return 1
  end
  if n >= 0 then return n // d end
  local q = ((n >> 1) // d) << 1
  local r = n - q * d
  if not math.ult(r, d) then q = q + 1 end
  return q
end

-- numeric for-loop operands: numbers, or strings convertible to numbers
local function forcheck(v, what)
  if type(v) == "string" then v = tonumber(v) end
  if type(v) ~= "number" then forerror(v, what) end
  return v
end

S.numfor = function(node)
  local e1, e2 = cexpr(node.e1), cexpr(node.e2)
  local e3 = node.e3 and cexpr(node.e3)
  local vi = node.var
  local s, cap = vi.slot, vi.captured
  local body = cblock(node.body)

  local function setvar(A, v)
    if cap then A[s] = { v = v } else A[s] = v end
  end

  return function(A)
    local init = e1(A)
    local limit = e2(A)
    local step = 1
    if e3 then step = e3(A) end
    if mtype(init) == "integer" and mtype(step) == "integer" then
      if step == 0 then rterror("'for' step is zero") end
      local lim = forlimit(limit, step)
      if lim == nil then return end
      if step > 0 then
        if init > lim then return end
      else
        if init < lim then return end
      end
      local count
      if step > 0 then
        count = udiv(lim - init, step)
      else
        count = udiv(init - lim, -(step + 1) + 1)
      end
      local i = init
      while true do
        setvar(A, i)
        local sig, val = body(A)
        if sig then
          if sig == BREAK then break end
          return sig, val
        end
        if count == 0 then break end
        count = count - 1
        i = i + step
      end
      return
    end
    -- float loop
    local fl = forcheck(limit, "limit") + 0.0
    local fs = forcheck(step, "step") + 0.0
    local fi = forcheck(init, "initial value") + 0.0
    if fs == 0 then rterror("'for' step is zero") end
    local i = fi
    while (fs > 0 and i <= fl) or (fs < 0 and i >= fl) do
      setvar(A, i)
      local sig, val = body(A)
      if sig then
        if sig == BREAK then break end
        return sig, val
      end
      i = i + fs
    end
  end
end

S.genfor = function(node)
  local explist = compile_args(node.exprs)
  local vars = node.vars
  local nv = #vars
  local body = cblock(node.body)
  local iterdesc = "for iterator 'for iterator'"
  local function runloop(A, f, st, ctrl)
    while true do
      local rs = pack(callx(iterdesc, f, st, ctrl))
      local v1 = rs[1]
      if v1 == nil then break end
      ctrl = v1
      for j = 1, nv do
        local vi = vars[j]
        if vi.captured then A[vi.slot] = { v = rs[j] } else A[vi.slot] = rs[j] end
      end
      local sig, val = body(A)
      if sig then
        if sig == BREAK then break end
        return sig, val
      end
    end
  end
  return function(A)
    local vals = pack(explist(A))
    local closing = vals[4]
    if closing == nil or closing == false then
      return runloop(A, vals[1], vals[2], vals[3])
    end
    -- the fourth value is a to-be-closed variable closed when the loop ends
    local h = R.metamethod(closing, "__close")
    if h == nil then rterror("variable '(for state)' got a non-closable value") end
    local ok, sig, val = pcall(runloop, A, vals[1], vals[2], vals[3])
    if ok then
      R.call(h, closing)
      return sig, val
    end
    R.stack.n = A.depth
    pcall(R.call, h, closing, sig)
    error(sig, 0)
  end
end

S["return"] = function(node)
  local exprs = node.exprs
  local n = #exprs
  if n == 1 and not node.notail and (exprs[1].k == "call" or exprs[1].k == "method") then
    local c = exprs[1]
    local argsf = compile_args(c.args)
    if c.k == "call" then
      local f = cexpr(c.fn)
      local d = describe(c.fn)
      local line = c.line
      return function(A)
        local fv = f(A)
        local args = pack(argsf(A))
        A.line = line
        A.cdesc, A.nargs = d, args.n
        return TAILCALL, { fv, args, d }
      end
    else
      local o = cexpr(c.obj)
      local name = c.name
      local d = describe(c.obj)
      local line = c.line
      return function(A)
        local ob = o(A)
        local fv = index(ob, name, d)
        local args = pack(ob, argsf(A))
        A.line = line
        local mdesc = (c.field and "field '" or "method '") .. name .. "'"
        A.cdesc, A.nargs = mdesc, args.n
        return TAILCALL, { fv, args, mdesc }
      end
    end
  end
  local explist = compile_args(exprs)
  return function(A)
    return RETURN, pack(explist(A))
  end
end

S["break"] = function()
  return function() return BREAK end
end

S["goto"] = function(node)
  local name = node.name
  return function() return GOTO, name end
end

S.label = function() return function() end end
S.nop = S.label

S.globaldecl = function(node)
  if not node.exprs or #node.exprs == 0 then
    return function() end
  end
  local env = cexpr(node.env)
  local names = node.names
  local explist = compile_args(node.exprs)
  return function(A)
    local e = env(A)
    local vals = pack(explist(A))
    for i, name in ipairs(names) do
      local v = vals[i]
      if index(e, name) ~= nil then
        rterror("global '" .. name .. "' already defined")
      end
      setindex(e, name, v)
    end
  end
end

-- Compiles a statement; blk is the key of the enclosing block (for <close>).
local function cstat(node, blk)
  local f = S[node.k]
  if not f then error("internal: no statement compiler for " .. tostring(node.k)) end
  return f(node, blk)
end

-- Calls __close on each value in reverse order with error object err.
-- An error raised by a __close replaces err for the remaining calls.
-- Returns the final error object (nil if none).
local function closeall(list, err)
  for i = #list, 1, -1 do
    local v = list[i]
    local h = R.metamethod(v, "__close")
    local ok, e2
    if h == nil then
      -- the metamethod was removed after the variable was declared
      ok, e2 = false, R.where(1) .. "attempt to call a nil value (metamethod 'close')"
    elseif err == nil then
      -- normal exit: the handler may yield
      ok, e2 = pcall(R.call, h, v)
    elseif err == R.CLOSING then
      -- unwinding for coroutine.close: not yieldable, and no error object
      ok, e2 = pcall(R.ccall, h, v)
    else
      -- closing because of an error (recovered by pcall): the handler may yield
      ok, e2 = pcall(R.call, h, v, err)
    end
    if not ok then err = e2 end
  end
  return err
end

-- Compiles a block (a list of statements) into a runner f(A) -> sig, val.
-- Clears the slots of block-local variables when the block exits. Activation
-- records would otherwise keep dead values alive (Lua's collector ignores dead
-- registers), which weak tables and finalizers would observe.
clearslots = function(A, slots)
  for i = 1, #slots do A[slots[i]] = nil end
end

cblock = function(block, noclear)
  local stats = block.stats
  local n = #stats
  local fns, lines = {}, {}
  local labelpos = {}
  local hasclose = false
  for i, s in ipairs(stats) do
    lines[i] = s.line or 0
    if s.k == "label" then labelpos[s.name] = i end
    if s.k == "local" then
      for _, vi in ipairs(s.vars) do
        if vi.attrib == "close" then hasclose = true end
      end
    end
    fns[i] = cstat(s, block)
  end

  local run
  if next(labelpos) == nil then
    run = function(A)
      for i = 1, n do
        A.line = lines[i]
        local sig, val = fns[i](A)
        if sig then return sig, val end
      end
    end
  else
    run = function(A)
      local i = 1
      while i <= n do
        A.line = lines[i]
        local sig, val = fns[i](A)
        if sig then
          if sig == GOTO and labelpos[val] then
            i = labelpos[val]
          else
            return sig, val
          end
        else
          i = i + 1
        end
      end
    end
  end

  -- slots declared directly in this block (and loop variables of its loops)
  local declared = {}
  for _, st in ipairs(stats) do
    if st.k == "local" then
      for _, vi in ipairs(st.vars) do declared[#declared + 1] = vi.slot end
    elseif st.k == "localfunc" then
      declared[#declared + 1] = st.var.slot
    elseif st.k == "numfor" then
      declared[#declared + 1] = st.var.slot
    elseif st.k == "genfor" then
      for _, vi in ipairs(st.vars) do declared[#declared + 1] = vi.slot end
    end
  end
  if #declared > 0 and not noclear then
    local inner = run
    run = function(A)
      local sig, val = inner(A)
      clearslots(A, declared)
      return sig, val
    end
  end
  if hasclose then
    local inner = run
    run = function(A)
      local list = {}
      A[block] = list
      local ok, sig, val = pcall(inner, A)
      if ok then
        local e = closeall(list, nil)
        if e ~= nil then error(e, 0) end
        return sig, val
      end
      R.stack.n = A.depth
      local err = closeall(list, sig)
      error(err, 0)
    end
  end
  return run, declared
end

---------------------------------------------------------------------------
-- Functions
---------------------------------------------------------------------------

-- Compiles a proto once; returns the compiled record used by newlua.
compile_proto = function(proto)
  if proto.compiled then return proto.compiled end
  local params = {}
  for i, vi in ipairs(proto.params) do
    params[i] = { slot = vi.slot, cap = vi.captured }
  end
  local upnames = {}
  for i, u in ipairs(proto.upvals) do upnames[i] = u.name end
  local c = {
    upnames = upnames,
    src = CURSRC,
    source = CURSOURCE,
    lastline = proto.lastline,
    line = proto.line,
    params = params,
    np = #params,
    isvararg = proto.isvararg,
    udesc = proto.upvals,
  }
  if proto.varvar then
    c.varslot = proto.varvar.slot
    c.varcap = proto.varvar.captured
  end
  proto.compiled = c
  c.run = cblock(proto.body)
  return c
end

-- Creates a Lua function value from a compiled proto and its upvalue cells.
function C.newlua(c, ups)
  local run, params, np, isvararg = c.run, c.params, c.np, c.isvararg
  local src, line = c.src, c.line
  local source = c.source
  local varslot, varcap = c.varslot, c.varcap
  ups.names = c.upnames
  ups.source, ups.short, ups.line = source, src, line
  ups.lastline = c.lastline
  local fn = function(...)
    local A = { up = ups, src = src, line = line, source = source }
    if np > 0 then
      local args = { ... }
      for i = 1, np do
        local p = params[i]
        if p.cap then A[p.slot] = { v = args[i] } else A[p.slot] = args[i] end
      end
    end
    if isvararg then
      local nargs = select("#", ...)
      if nargs > np then
        local extra = pack(select(np + 1, ...))
        A.va = extra
      else
        A.va = { n = 0 }
      end
    end
    if varslot then
      -- named vararg: a Lua table with the extra arguments and field n
      local t = R.newtable()
      local va = A.va
      for j = 1, va.n do t.hash[j] = va[j] end
      t.hash.n = va.n
      if varcap then A[varslot] = { v = t } else A[varslot] = t end
    end
    local st = R.stack
    local d = st.n + 1
    if d > MAXDEPTH then rterror("stack overflow") end
    A.depth = d
    st[d] = A
    st.n = d
    local sig, val = run(A)
    if sig == TAILCALL and FUPS[val[1]] == nil then
      -- a native is not a real tail call: call it while this frame is still there
      -- (argument errors then see the right call site)
      local r = pack(callx(val[3], val[1], unpack(val[2], 1, val[2].n)))
      st[d] = nil
      st.n = d - 1
      return unpack(r, 1, r.n)
    end
    st[d] = nil
    st.n = d - 1
    if sig == RETURN then return unpack(val, 1, val.n) end
    if sig == TAILCALL then
      local fv, args, desc = val[1], val[2], val[3]
      return callx(desc, fv, unpack(args, 1, args.n))
    end
    return
  end
  FUPS[fn] = ups
  return fn
end

-- Compiles a parsed chunk (proto) and returns a Lua function whose
-- _ENV upvalue is set to env.
function C.load(proto, src, env, source)
  CURSRC = src
  CURSOURCE = source or src
  local c = compile_proto(proto)
  return C.newlua(c, { { v = env } })
end

return C
