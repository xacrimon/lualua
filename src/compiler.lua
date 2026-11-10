-- compiler.lua: turns the AST from parser.lua into Lua closures.
--
-- Activation record A (a host table, also the stack frame):
--   A[slot]   value of a local, or a cell {v=value} if the local is captured;
--             parameters are slots 1..np
--   A.up      array of upvalue cells {v=value}; A.up.c is the compiled proto
--             (src, source, line, ...) and A.up.fn the closure
--   A.va      varargs {n=count, ...} (vararg functions only; never modified)
--   A.line               current line
--   A.cdesc, A.nargs     description and argument count of the latest call
--   A[block]  to-be-closed list of a block (blocks with <close> locals)
--
-- Expressions compile to closures f(A) returning exactly one value; "multi"
-- closures return all values. Statements compile to closures f(A) returning
-- nothing (normal), or a signal: BREAK, GOTO(label), RETURN0, RETURN1(value),
-- RETURN(values table), TAILCALL(callee; arguments in the TN/T1.. variables).

local R = require("runtime")

local C = {}

local BREAK, RETURN, GOTO, TAILCALL, RETURN0, RETURN1 = 1, 2, 3, 4, 5, 6

-- Arguments of the pending tail call: TN values T1..T3, or (TN < 0) the packed
-- table T1; TD describes the callee. A tail-call statement sets them and returns
-- TAILCALL to the function, which reads them right away: no Lua code runs in
-- between, since a return in the scope of a to-be-closed variable is not a tail call.
local TN, T1, T2, T3, TD = 0, nil, nil, nil, nil

local type, select, pcall, error = type, select, pcall, error
local pack, unpack = table.pack, table.unpack
local mtype = math.type

local rterror, callx, index, setindex = R.rterror, R.callx, R.index, R.setindex
local lt, le, eq, concat, len = R.lt, R.le, R.eq, R.concat, R.len
local add, sub, mul, div, mod, idiv, pow = R.add, R.sub, R.mul, R.div, R.mod, R.idiv, R.pow
local unm, bnot, band, bor, bxor, shl, shr = R.unm, R.bnot, R.band, R.bor, R.bxor, R.shl, R.shr
local rawset = R.rawset

local MAXDEPTH = 50000   -- Lua-to-Lua call depth limit (reached sooner than the reference; see DESIGN.md)
-- closure -> its upvalue cells; the cell array also carries .c (the compiled
-- proto: upnames, src, source, line, lastline) and .fn (the closure)
local FUPS = setmetatable({}, { __mode = "k" })
C.FUPS = FUPS
local CURSRC = "?"      -- short chunk name of the chunk being compiled
local CURSOURCE = "?"   -- the chunk name as given to load

-- Number of values in a named vararg table (its field n must be a proper count).
local function vacount(t)
  local n = t.hash.n
  if mtype(n) ~= "integer" or n < 0 or n >= 0x7fffffff then rterror("no proper 'n'") end
  return n
end

-- Description of an expression for error messages ("local 'x'", ...), as
-- getobjname in ldebug.c names the register holding it.
local function describe(node)
  local k = node.k
  if k == "local" then return "local '" .. node.name .. "'" end
  if k == "upval" then return "upvalue '" .. node.name .. "'" end
  if k == "str" then return "constant '" .. node.v .. "'" end
  if k == "paren" then return describe(node.e) end
  if k == "index" then
    if node.gname then return "global '" .. node.gname .. "'" end
    local key = node.key
    if key.k == "str" then return "field '" .. key.v .. "'" end
    -- small non-negative integer constants use GETI; other keys are registers
    if key.k == "num" and mtype(key.v) == "integer" and key.v >= 0 and key.v <= 255 then
      return "field 'integer index'"
    end
    return "field '?'"
  end
  if k == "method" then return (node.field and "field '" or "method '") .. node.name .. "'" end
  return nil
end

local cexpr, cmulti, compile_args, fixedargs, cblock, compile_proto, clearslots

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
  local line = node.line
  return function(A)
    local ob = o(A)
    local k = key(A)
    A.line = line
    return index(ob, k, d)
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
  local line = node.line
  if op == "not" then
    return function(A)
      local x = a(A)
      return x == nil or x == false
    end
  elseif op == "-" then
    return function(A)
      local x = a(A)
      if type(x) == "number" then return -x end
      A.line = line
      return unm(x, d)
    end
  elseif op == "#" then
    return function(A)
      local x = a(A)
      if type(x) == "string" then return #x end
      A.line = line
      return len(x, d)
    end
  elseif op == "~" then
    return function(A)
      local x = a(A)
      A.line = line
      return bnot(x, d)
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
  local line = node.line   -- errors of this operation report the operator's line
  if op == "+" then
    return function(A)
      local x = a(A)
      local y = b(A)
      if type(x) == "number" and type(y) == "number" then return x + y end
      A.line = line; return add(x, y, da, db)
    end
  elseif op == "-" then
    return function(A)
      local x = a(A)
      local y = b(A)
      if type(x) == "number" and type(y) == "number" then return x - y end
      A.line = line; return sub(x, y, da, db)
    end
  elseif op == "*" then
    return function(A)
      local x = a(A)
      local y = b(A)
      if type(x) == "number" and type(y) == "number" then return x * y end
      A.line = line; return mul(x, y, da, db)
    end
  elseif op == "==" then
    return function(A)
      local x = a(A)
      local y = b(A)
      if x == y then return true end
      -- only two tables or two userdata can have __eq
      if type(x) ~= "table" or type(y) ~= "table" then return false end
      A.line = line; return eq(x, y)
    end
  elseif op == "~=" then
    return function(A)
      local x = a(A)
      local y = b(A)
      if x == y then return false end
      if type(x) ~= "table" or type(y) ~= "table" then return true end
      A.line = line; return not eq(x, y)
    end
  elseif op == "<" then
    return function(A)
      local x = a(A)
      local y = b(A)
      if type(x) == "number" and type(y) == "number" then return x < y end
      A.line = line; return lt(x, y)
    end
  elseif op == "<=" then
    return function(A)
      local x = a(A)
      local y = b(A)
      if type(x) == "number" and type(y) == "number" then return x <= y end
      A.line = line; return le(x, y)
    end
  elseif op == ">" then
    return function(A)
      local x = a(A)
      local y = b(A)
      if type(x) == "number" and type(y) == "number" then return x > y end
      A.line = line; return lt(y, x)
    end
  elseif op == ">=" then
    return function(A)
      local x = a(A)
      local y = b(A)
      if type(x) == "number" and type(y) == "number" then return x >= y end
      A.line = line; return le(y, x)
    end
  elseif op == ".." then
    return function(A)
      local x = a(A)
      local y = b(A)
      if type(x) == "string" and type(y) == "string" then return x .. y end
      A.line = line; return concat(x, y, da, db)
    end
  end
  local f = ARITH_SLOW[op]
  if not f then error("unknown binary operator " .. op) end
  return function(A)
    local x = a(A)
    local y = b(A)
    A.line = line; return f(x, y, da, db)
  end
end

E.table = function(node)
  local items = {}
  local n = #node.items
  for i, it in ipairs(node.items) do
    if it.kind == "pos" then
      if i == n and it.value.k == "vararg" and not it.value.var then
        items[i] = { pos = true, multi = true, va = true }
      elseif i == n and isMulti(it.value) then
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
        if it.va then
          local va = A.va
          for j = 1, va.n do h[idx + j] = va[j] end
          idx = idx + va.n
        elseif it.multi then
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
    -- the caller records the callee's description and argument count (for
    -- argument error messages and debug.getinfo names)
    local f = cexpr(node.fn)
    local d = describe(node.fn)
    local line = node.line
    local fa = fixedargs(node.args, 3)
    if fa then
      local n, a1, a2, a3 = #fa, fa[1], fa[2], fa[3]
      if n == 0 then
        return function(A)
          local fv = f(A)
          A.line = line; A.cdesc = d; A.nargs = 0
          if type(fv) == "function" then return fv() end
          return callx(d, fv)
        end
      elseif n == 1 then
        return function(A)
          local fv = f(A)
          local x = a1(A)
          A.line = line; A.cdesc = d; A.nargs = 1
          if type(fv) == "function" then return fv(x) end
          return callx(d, fv, x)
        end
      elseif n == 2 then
        return function(A)
          local fv = f(A)
          local x = a1(A)
          local y = a2(A)
          A.line = line; A.cdesc = d; A.nargs = 2
          if type(fv) == "function" then return fv(x, y) end
          return callx(d, fv, x, y)
        end
      end
      return function(A)
        local fv = f(A)
        local x = a1(A)
        local y = a2(A)
        local z = a3(A)
        A.line = line; A.cdesc = d; A.nargs = 3
        if type(fv) == "function" then return fv(x, y, z) end
        return callx(d, fv, x, y, z)
      end
    end
    local argsf = compile_args(node.args)
    local function site(A, fv, ...)
      A.line = line; A.cdesc = d; A.nargs = select("#", ...)
      if type(fv) == "function" then return fv(...) end
      return callx(d, fv, ...)
    end
    return function(A)
      local fv = f(A)
      return site(A, fv, argsf(A))
    end
  elseif k == "method" then
    local o = cexpr(node.obj)
    local name = node.name
    local d = describe(node.obj)
    local line = node.line
    local mdesc = (node.field and "field '" or "method '") .. name .. "'"
    local fa = fixedargs(node.args, 2)
    if fa then
      local n, a1, a2 = #fa, fa[1], fa[2]
      if n == 0 then
        return function(A)
          local ob = o(A)
          local fv = index(ob, name, d)
          A.line = line; A.cdesc = mdesc; A.nargs = 1   -- the receiver counts
          if type(fv) == "function" then return fv(ob) end
          return callx(mdesc, fv, ob)
        end
      elseif n == 1 then
        return function(A)
          local ob = o(A)
          local fv = index(ob, name, d)
          local x = a1(A)
          A.line = line; A.cdesc = mdesc; A.nargs = 2
          if type(fv) == "function" then return fv(ob, x) end
          return callx(mdesc, fv, ob, x)
        end
      end
      return function(A)
        local ob = o(A)
        local fv = index(ob, name, d)
        local x = a1(A)
        local y = a2(A)
        A.line = line; A.cdesc = mdesc; A.nargs = 3
        if type(fv) == "function" then return fv(ob, x, y) end
        return callx(mdesc, fv, ob, x, y)
      end
    end
    local argsf = compile_args(node.args)
    local function site(A, fv, ob, ...)
      A.line = line; A.cdesc = mdesc; A.nargs = select("#", ...) + 1
      if type(fv) == "function" then return fv(ob, ...) end
      return callx(mdesc, fv, ob, ...)
    end
    return function(A)
      local ob = o(A)
      local fv = index(ob, name, d)
      return site(A, fv, ob, argsf(A))
    end
  end
  return cexpr(node)
end

-- Closure returning all values of the expression list exprs[i..] (multi-valued).
compile_args = function(exprs, i)
  i = i or 1
  local n = #exprs
  if i > n then
    return function() end
  end
  local last = exprs[n]
  local lastf = isMulti(last) and cmulti(last) or cexpr(last)
  if i == n then return lastf end
  local a = cexpr(exprs[i])
  if i + 1 == n then
    return function(A)
      local x = a(A)
      return x, lastf(A)
    end
  end
  local b = cexpr(exprs[i + 1])
  if i + 2 == n then
    return function(A)
      local x = a(A)
      local y = b(A)
      return x, y, lastf(A)
    end
  end
  local rest = compile_args(exprs, i + 2)
  return function(A)
    local x = a(A)
    local y = b(A)
    return x, y, rest(A)
  end
end

-- Single-value closures of the arguments when there are at most `max` and the
-- last one is not multi-valued (calls with a fixed argument count); else nil.
fixedargs = function(exprs, max)
  local n = #exprs
  if n > max or (n > 0 and isMulti(exprs[n])) then return nil end
  local fs = {}
  for i = 1, n do fs[i] = cexpr(exprs[i]) end
  return fs
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
    local s = vi.slot
    if hasclose then
      local cap = vi.captured
      return function(A)
        local v = e(A)
        if cap then A[s] = { v = v } else A[s] = v end
        checkclose(A, blk, vi, v)
      end
    end
    if vi.captured then
      return function(A) A[s] = { v = e(A) } end
    end
    return function(A) A[s] = e(A) end
  end
  local explist = compile_args(exprs)
  local function set(A, vi, v)
    if vi.captured then A[vi.slot] = { v = v } else A[vi.slot] = v end
    if vi.attrib == "close" then checkclose(A, blk, vi, v) end
  end
  if nv <= 3 then
    local vi1, vi2, vi3 = vars[1], vars[2], vars[3]
    return function(A)
      local v1, v2, v3 = explist(A)
      set(A, vi1, v1)
      if vi2 then set(A, vi2, v2) end
      if vi3 then set(A, vi3, v3) end
    end
  end
  return function(A)
    local vals = pack(explist(A))
    for i = 1, nv do set(A, vars[i], vals[i]) end
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
  -- the stores happen after the values are computed, on the line where they end
  local sline = node.sline or node.line
  if nt == 1 and #node.exprs == 1 and not isMulti(node.exprs[1]) then
    local t = ctarget(targets[1])
    local e = cexpr(node.exprs[1])
    if t.kind == "index" then
      local o, key, d = t.o, t.key, t.d
      return function(A)
        local ob = o(A)
        local k = key(A)
        local v = e(A)
        A.line = sline
        setindex(ob, k, v, d)
      end
    end
    local s = t.slot
    if t.kind == "upval" then
      local idx = t.idx
      return function(A) A.up[idx].v = e(A) end
    elseif t.cap then
      return function(A) A[s].v = e(A) end
    end
    return function(A) A[s] = e(A) end
  end
  local tg = {}
  for i, t in ipairs(targets) do tg[i] = ctarget(t) end
  local explist = compile_args(node.exprs)
  if nt <= 3 then
    local t1, t2, t3 = tg[1], tg[2], tg[3]
    local function store(A, t, o, k, v)
      if t.kind == "index" then setindex(o, k, v, t.d) else storevar(t, A, v) end
    end
    return function(A)
      local o1, k1, o2, k2, o3, k3
      if t1.kind == "index" then o1 = t1.o(A); k1 = t1.key(A) end
      if t2 and t2.kind == "index" then o2 = t2.o(A); k2 = t2.key(A) end
      if t3 and t3.kind == "index" then o3 = t3.o(A); k3 = t3.key(A) end
      local v1, v2, v3 = explist(A)
      A.line = sline
      if t3 then store(A, t3, o3, k3, v3) end
      if t2 then store(A, t2, o2, k2, v2) end
      store(A, t1, o1, k1, v1)
    end
  end
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
    A.line = sline
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
    -- host truthiness is Lua truthiness; the value is not kept in a live
    -- local, which would keep it from being collected while the body runs
    while cond(A) do
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
      local continue = not cond(A)
      clearslots(A, slots)
    until not continue
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
      if conds[i](A) then return blocks[i](A) end
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
  -- errors in the iterator call report the line where the explist starts
  local iterline = (node.exprs[1] and node.exprs[1].line) or node.line
  local function setvar(A, vi, v)
    if vi.captured then A[vi.slot] = { v = v } else A[vi.slot] = v end
  end
  local runloop
  if nv <= 3 then
    local vi1, vi2, vi3 = vars[1], vars[2], vars[3]
    runloop = function(A, f, st, ctrl)
      while true do
        A.line = iterline
        A.cdesc = iterdesc; A.nargs = 2
        local v1, v2, v3
        if type(f) == "function" then v1, v2, v3 = f(st, ctrl)
        else v1, v2, v3 = callx(iterdesc, f, st, ctrl) end
        if v1 == nil then break end
        ctrl = v1
        setvar(A, vi1, v1)
        if vi2 then setvar(A, vi2, v2) end
        if vi3 then setvar(A, vi3, v3) end
        local sig, val = body(A)
        if sig then
          if sig == BREAK then break end
          return sig, val
        end
      end
    end
  else
    runloop = function(A, f, st, ctrl)
      while true do
        A.line = iterline
        A.cdesc = iterdesc; A.nargs = 2
        local rs = pack(callx(iterdesc, f, st, ctrl))
        local v1 = rs[1]
        if v1 == nil then break end
        ctrl = v1
        for j = 1, nv do setvar(A, vars[j], rs[j]) end
        local sig, val = body(A)
        if sig then
          if sig == BREAK then break end
          return sig, val
        end
      end
    end
  end
  return function(A)
    local f, st, ctrl, closing = explist(A)
    if closing == nil or closing == false then
      return runloop(A, f, st, ctrl)
    end
    -- the fourth value is a to-be-closed variable closed when the loop ends
    local h = R.metamethod(closing, "__close")
    if h == nil then rterror("variable '(for state)' got a non-closable value") end
    local depth = R.stack.n   -- this frame is the top one
    local ok, sig, val = pcall(runloop, A, f, st, ctrl)
    if ok then
      R.call(h, closing)
      return sig, val
    end
    sig = R.popto(depth, sig)
    local cok, cerr = pcall(R.call, h, closing, sig)
    if not cok then sig = R.popto(depth, cerr) end
    error(sig, 0)
  end
end

S["return"] = function(node)
  local exprs = node.exprs
  local n = #exprs
  local e1 = exprs[1]
  if n == 1 and not node.notail and (e1.k == "call" or e1.k == "method") then
    local line = e1.line
    if e1.k == "call" then
      local f = cexpr(e1.fn)
      local d = describe(e1.fn)
      local fa = fixedargs(e1.args, 3)
      if fa then
        local na, a1, a2, a3 = #fa, fa[1], fa[2], fa[3]
        return function(A)
          local fv = f(A)
          local x, y, z
          if na >= 1 then x = a1(A) end
          if na >= 2 then y = a2(A) end
          if na >= 3 then z = a3(A) end
          A.line = line; A.cdesc = d; A.nargs = na
          TN, T1, T2, T3, TD = na, x, y, z, d
          return TAILCALL, fv
        end
      end
      local argsf = compile_args(e1.args)
      return function(A)
        local fv = f(A)
        local args = pack(argsf(A))
        A.line = line; A.cdesc = d; A.nargs = args.n
        TN, T1, TD = -1, args, d
        return TAILCALL, fv
      end
    end
    local o = cexpr(e1.obj)
    local name = e1.name
    local d = describe(e1.obj)
    local mdesc = (e1.field and "field '" or "method '") .. name .. "'"
    local fa = fixedargs(e1.args, 2)
    if fa then
      local na, a1, a2 = #fa, fa[1], fa[2]
      return function(A)
        local ob = o(A)
        local fv = index(ob, name, d)
        local x, y
        if na >= 1 then x = a1(A) end
        if na >= 2 then y = a2(A) end
        A.line = line; A.cdesc = mdesc; A.nargs = na + 1
        TN, T1, T2, T3, TD = na + 1, ob, x, y, mdesc
        return TAILCALL, fv
      end
    end
    local argsf = compile_args(e1.args)
    return function(A)
      local ob = o(A)
      local fv = index(ob, name, d)
      local args = pack(ob, argsf(A))
      A.line = line; A.cdesc = mdesc; A.nargs = args.n
      TN, T1, TD = -1, args, mdesc
      return TAILCALL, fv
    end
  end
  if n == 0 then
    return function() return RETURN0 end
  elseif n == 1 and not isMulti(e1) then
    local e = cexpr(e1)
    return function(A) return RETURN1, e(A) end
  elseif n == 1 and e1.k == "vararg" and not e1.var then
    return function(A) return RETURN, A.va end
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
  local depth = R.stack.n
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
    if not ok then err = R.popto(depth, e2) end
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
  elseif not hasclose then
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
  else
    -- a backward goto leaves the scope of the to-be-closed variables declared
    -- after its label: they are closed by the jump
    local labelat = {}
    for name, i in pairs(labelpos) do labelat[i] = name end
    run = function(A)
      local list = A[block]
      local marks = {}   -- label -> number of tbc values when the label was passed
      local i = 1
      while i <= n do
        A.line = lines[i]
        local lb = labelat[i]
        if lb then marks[lb] = #list end
        local sig, val = fns[i](A)
        if sig then
          local p = sig == GOTO and labelpos[val]
          if not p then return sig, val end
          local m = marks[val]
          if m and #list > m then
            local leaving = {}
            for k = m + 1, #list do
              leaving[k - m] = list[k]
              list[k] = nil
            end
            local e = closeall(leaving, nil)
            if e ~= nil then error(e, 0) end
          end
          i = p
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
      local depth = R.stack.n   -- this frame is the top one
      local ok, sig, val = pcall(inner, A)
      if ok then
        local e = closeall(list, nil)
        if e ~= nil then error(e, 0) end
        return sig, val
      end
      local err = closeall(list, R.popto(depth, sig))
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
  local caps   -- slots of the captured parameters, or nil
  for _, vi in ipairs(proto.params) do
    if vi.captured then
      caps = caps or {}
      caps[#caps + 1] = vi.slot
    end
  end
  local upnames = {}
  for i, u in ipairs(proto.upvals) do upnames[i] = u.name end
  local c = {
    upnames = upnames,
    src = CURSRC,
    source = CURSOURCE,
    lastline = proto.lastline,
    line = proto.line,
    np = #proto.params,
    caps = caps,
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

local EMPTYVA = { n = 0 }   -- the varargs of a call without extra arguments

-- Results of the pending tail call's arguments (see TN).
local function tailargs(n, a1, a2, a3)
  if n == 1 then return a1
  elseif n == 2 then return a1, a2
  elseif n == 3 then return a1, a2, a3
  elseif n == 0 then return end
  return unpack(a1, 1, a1.n)
end

local function popret(st, d, ...)
  st[d] = nil
  st.n = d - 1
  return ...
end

-- Ends the call of the frame at depth d with the signal of its body.
local function leave(st, d, sig, val)
  if sig == RETURN1 then
    st[d] = nil
    st.n = d - 1
    return val
  elseif sig == TAILCALL then
    local n, desc, a1, a2, a3 = TN, TD, T1, T2, T3
    T1, T2, T3, TD = nil, nil, nil, nil
    if FUPS[val] == nil then
      -- a native is not a real tail call: call it while this frame is still there
      -- (argument errors then see the right call site)
      return popret(st, d, callx(desc, val, tailargs(n, a1, a2, a3)))
    end
    st[d] = nil
    st.n = d - 1
    return val(tailargs(n, a1, a2, a3))
  end
  st[d] = nil
  st.n = d - 1
  if sig == RETURN then return unpack(val, 1, val.n) end
end

-- Pushes the new frame A and runs the body. caps lists captured parameters.
local function enter(A, run, caps)
  if caps then
    for i = 1, #caps do
      local s = caps[i]
      A[s] = { v = A[s] }
    end
  end
  local st = R.stack
  local d = st.n + 1
  if d > MAXDEPTH then rterror("stack overflow") end
  st[d] = A
  st.n = d
  return leave(st, d, run(A))
end

-- Creates a Lua function value from a compiled proto and its upvalue cells.
-- Functions with up to 3 parameters bind them directly as the first array
-- items of the frame; the frame fields are created with the frame.
function C.newlua(c, ups)
  ups.c = c
  local run, line, caps, np, isvararg = c.run, c.line, c.caps, c.np, c.isvararg
  local fn
  if c.varslot or np > 3 then
    local varslot, varcap = c.varslot, c.varcap
    fn = function(...)
      local nargs = select("#", ...)
      local A = { ... }
      for i = np + 1, nargs do A[i] = nil end   -- only the parameters are locals
      A.up, A.line, A.cdesc, A.nargs = ups, line, false, 0
      if isvararg then
        A.va = (nargs > np) and pack(select(np + 1, ...)) or EMPTYVA
      end
      if varslot then
        -- named vararg: a Lua table with the extra arguments and field n
        local t = R.newtable()
        local va = A.va
        for j = 1, va.n do t.hash[j] = va[j] end
        t.hash.n = va.n
        if varcap then A[varslot] = { v = t } else A[varslot] = t end
      end
      return enter(A, run, caps)
    end
  elseif not isvararg then
    if np == 0 then
      fn = function()
        return enter({ up = ups, line = line, cdesc = false, nargs = 0 }, run, caps)
      end
    elseif np == 1 then
      fn = function(a1)
        return enter({ a1, up = ups, line = line, cdesc = false, nargs = 0 }, run, caps)
      end
    elseif np == 2 then
      fn = function(a1, a2)
        return enter({ a1, a2, up = ups, line = line, cdesc = false, nargs = 0 }, run, caps)
      end
    else
      fn = function(a1, a2, a3)
        return enter({ a1, a2, a3, up = ups, line = line, cdesc = false, nargs = 0 }, run, caps)
      end
    end
  else
    if np == 0 then
      fn = function(...)
        local va = (select("#", ...) > 0) and pack(...) or EMPTYVA
        return enter({ up = ups, line = line, cdesc = false, nargs = 0, va = va }, run, caps)
      end
    elseif np == 1 then
      fn = function(a1, ...)
        local va = (select("#", ...) > 0) and pack(...) or EMPTYVA
        return enter({ a1, up = ups, line = line, cdesc = false, nargs = 0, va = va }, run, caps)
      end
    elseif np == 2 then
      fn = function(a1, a2, ...)
        local va = (select("#", ...) > 0) and pack(...) or EMPTYVA
        return enter({ a1, a2, up = ups, line = line, cdesc = false, nargs = 0, va = va }, run, caps)
      end
    else
      fn = function(a1, a2, a3, ...)
        local va = (select("#", ...) > 0) and pack(...) or EMPTYVA
        return enter({ a1, a2, a3, up = ups, line = line, cdesc = false, nargs = 0, va = va },
                     run, caps)
      end
    end
  end
  ups.fn = fn
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
