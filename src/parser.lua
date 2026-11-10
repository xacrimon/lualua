-- parser.lua: recursive-descent parser for Lua 5.5.
--
-- Produces an AST in which every name is already resolved:
--   local variable  -> {k="local", var=VarInfo}
--   upvalue         -> {k="upval", idx=i}          (index into the closure's upvalues)
--   global          -> {k="index", obj=<_ENV expr>, key={k="str",v=name}, gname=name}
-- Each function is a proto:
--   {params={VarInfo...}, isvararg, body=Block, nslots, upvals={UpDesc...}, line, lastline}
-- A local's VarInfo.captured is true if an inner function refers to it; the
-- compiler boxes such variables in cells so each activation gets fresh ones.
--
-- Global declarations (Lua 5.5 "global" statement) are checked here, syntactically:
-- a free name must be covered by an enclosing declaration.

local lexer = require("lexer")

local M = {}

local ls          -- current lexer
local fs          -- current function state
local gdecls      -- stack of global-declaration entries (lexically scoped)

---------------------------------------------------------------------------
-- Errors
---------------------------------------------------------------------------

local function nearText()
  local t = lexer.tokentext(ls)
  if ls.t == "<eof>" then return "<eof>" end
  return "'" .. t .. "'"
end

local function syntaxerror(msg)
  error(ls.chunk .. ":" .. ls.tl .. ": " .. msg .. " near " .. nearText(), 0)
end

local function errorat(msg, line)
  error(ls.chunk .. ":" .. line .. ": " .. msg, 0)
end

local function check(t)
  if ls.t ~= t then syntaxerror("'" .. t .. "' expected") end
end

local function checknext(t)
  check(t)
  ls:advance()
end

-- Expects `what` closing `who` opened at line `line`.
local function checkmatch(what, who, line)
  if ls.t == what then
    ls:advance()
  elseif line == ls.tl then
    syntaxerror("'" .. what .. "' expected")
  else
    syntaxerror("'" .. what .. "' expected (to close '" .. who .. "' at line " .. line .. ")")
  end
end

local function checkname()
  if ls.t ~= "name" then syntaxerror("<name> expected") end
  local v = ls.v
  ls:advance()
  return v
end

local function testnext(t)
  if ls.t == t then
    ls:advance()
    return true
  end
  return false
end

---------------------------------------------------------------------------
-- Scopes
---------------------------------------------------------------------------

-- Index of string constant s in the current function's constant table (as
-- Lua's compiler numbers constants). Used to pick "method" or "field" naming.
local function addconst(s)
  local t = fs.consts
  if t == nil then t = {}; fs.consts = t; fs.nconsts = 0 end
  if t[s] == nil then
    fs.nconsts = fs.nconsts + 1
    t[s] = fs.nconsts
  end
  return t[s]
end

local function newfs(parent, isvararg)
  return {
    parent = parent,
    actvars = {},    -- active local VarInfos (stack)
    upvals = {},     -- upvalue descriptions
    nslots = 0,
    isvararg = isvararg,
    block = nil,     -- innermost open block
  }
end

local function newvarinfo(name, attrib)
  fs.nslots = fs.nslots + 1
  return { name = name, slot = fs.nslots, attrib = attrib, captured = false }
end

local function openblock(isloop)
  local b = {
    parent = fs.block,
    nactive = #fs.actvars,
    ngdecl = #gdecls,
    labels = {},     -- name -> true
    gotos = {},      -- pending gotos: {name=, line=}
    isloop = isloop,
    stats = nil,
  }
  fs.block = b
  return b
end

local function closeblock(b)
  -- pending gotos not matched by a label of this block move outward
  for i = #b.gotos, 1, -1 do
    local g = b.gotos[i]
    if b.labels[g.name] then
      table.remove(b.gotos, i)
    end
  end
  if b.parent then
    -- pending gotos leave this block: they only see the locals of the enclosing block
    for _, g in ipairs(b.gotos) do
      g.nactive = b.nactive
      table.insert(b.parent.gotos, g)
    end
  else
    if #b.gotos > 0 then
      local g = b.gotos[1]
      errorat("no visible label '" .. g.name .. "' for <goto> at line " .. g.line, g.line)
    end
  end
  for i = #fs.actvars, b.nactive + 1, -1 do fs.actvars[i] = nil end
  for i = #gdecls, b.ngdecl + 1, -1 do gdecls[i] = nil end
  fs.block = b.parent
end

-- Finds the visible declaration of name in function state f: a local VarInfo,
-- the string "global" if a global declaration (pseudo entry) is nearer, or nil.
local function findlocal(f, name)
  local av = f.actvars
  for i = #av, 1, -1 do
    if av[i].name == name then
      if av[i].pseudo then return "global" end
      return av[i]
    end
  end
  return nil
end

-- Finds (or creates) an upvalue named `name` for function state f.
-- Returns its index, or nil if no enclosing function declares it.
local function findupval(f, name)
  for i, u in ipairs(f.upvals) do
    if u.name == name then return i end
  end
  local p = f.parent
  if p == nil then return nil end
  local vi = findlocal(p, name)
  if vi == "global" then return nil end
  if vi then
    vi.captured = true
    f.upvals[#f.upvals + 1] = { name = name, instack = true, slot = vi.slot, var = vi }
    return #f.upvals
  end
  local idx = findupval(p, name)
  if idx then
    f.upvals[#f.upvals + 1] = { name = name, instack = false, idx = idx }
    return #f.upvals
  end
  return nil
end

-- Global-declaration check for a free name. Returns the attribute ("const" or nil)
-- or raises "not declared".
local function globalattrib(name, line, nothrow)
  local explicit = false
  for _, e in ipairs(gdecls) do
    if not e.implicit then explicit = true break end
  end
  for i = #gdecls, 1, -1 do
    local e = gdecls[i]
    if not (e.implicit and explicit) then
      if e.all then return e.attrib end
      if e.names[name] ~= nil then return e.names[name] or nil end
    end
  end
  if nothrow then return nil end
  errorat("variable '" .. name .. "' not declared", line)
end

-- Resolves a name in the current scope to an expression node.
local function singlevar(name, line)
  local vi = findlocal(fs, name)
  if vi and vi ~= "global" then return { k = "local", var = vi, name = name } end
  addconst(name)
  local ui = (vi == nil) and findupval(fs, name) or nil
  if ui then return { k = "upval", idx = ui, name = name } end
  -- a global
  local attrib = globalattrib(name, line)
  -- _ENV declared by a global statement is itself a global: globals cannot use it
  for _, e in ipairs(gdecls) do
    if name ~= "_ENV" and not e.implicit and e.names["_ENV"] ~= nil then
      errorat("_ENV is global when accessing variable '" .. name .. "'", line)
    end
  end
  -- (a free _ENV cannot be looked up in itself)
  local env = (name == "_ENV") and { k = "nil" } or singlevar("_ENV", line)
  return { k = "index", obj = env, key = { k = "str", v = name }, gname = name,
           attrib = attrib, line = line }
end

---------------------------------------------------------------------------
-- Expressions
---------------------------------------------------------------------------

local expr, statlist, block_follow, funcbody, tablecons

local BINPRI = {
  ["or"] = { 1, 1 }, ["and"] = { 2, 2 },
  ["<"] = { 3, 3 }, [">"] = { 3, 3 }, ["<="] = { 3, 3 }, [">="] = { 3, 3 },
  ["~="] = { 3, 3 }, ["=="] = { 3, 3 },
  ["|"] = { 4, 4 }, ["~"] = { 5, 5 }, ["&"] = { 6, 6 },
  ["<<"] = { 7, 7 }, [">>"] = { 7, 7 },
  [".."] = { 9, 8 },
  ["+"] = { 10, 10 }, ["-"] = { 10, 10 },
  ["*"] = { 11, 11 }, ["/"] = { 11, 11 }, ["//"] = { 11, 11 }, ["%"] = { 11, 11 },
  ["^"] = { 14, 13 },
}
local UNARY_PRI = 12

local function explist()
  local list = { expr() }
  while testnext(",") do
    list[#list + 1] = expr()
  end
  return list
end

local function primaryexp()
  local line = ls.tl
  if ls.t == "name" then
    local name = ls.v
    ls:advance()
    return singlevar(name, line)
  elseif ls.t == "(" then
    ls:advance()
    local e = expr()
    checkmatch(")", "(", line)
    return { k = "paren", e = e, line = line }
  end
  syntaxerror("unexpected symbol")
end

local function callargs()
  local line = ls.tl
  if ls.t == "string" then
    local s = ls.v
    ls:advance()
    return { { k = "str", v = s } }, line
  elseif ls.t == "{" then
    return { tablecons() }, line
  elseif ls.t == "(" then
    ls:advance()
    local args = {}
    if ls.t ~= ")" then args = explist() end
    checkmatch(")", "(", line)
    return args, line
  end
  syntaxerror("function arguments expected")
end

local function suffixedexp()
  local e = primaryexp()
  while true do
    local t = ls.t
    local line = ls.tl
    if t == "." then
      ls:advance()
      local name = checkname()
      e = { k = "index", obj = e, key = { k = "str", v = name }, line = line }
    elseif t == "[" then
      ls:advance()
      local key = expr()
      checknext("]")
      e = { k = "index", obj = e, key = key, line = line }
    elseif t == ":" then
      ls:advance()
      local name = checkname()
      -- Lua uses a SELF instruction only for small constant indices; beyond that
      -- the call is named as a field
      local field = addconst(name) > 255
      local args, cline = callargs()
      e = { k = "method", obj = e, name = name, args = args, line = cline, field = field }
    elseif t == "(" or t == "string" or t == "{" then
      local args, cline = callargs()
      e = { k = "call", fn = e, args = args, line = cline }
    else
      return e
    end
  end
end

-- Table constructor. Items: {kind="pos", value=} | {kind="kv", key=, value=}
tablecons = function()
  local line = ls.tl
  checknext("{")
  local items = {}
  while ls.t ~= "}" do
    if ls.t == "name" and ls:lookahead() == "=" then
      local name = ls.v
      ls:advance()
      ls:advance()
      items[#items + 1] = { kind = "kv", key = { k = "str", v = name }, value = expr() }
    elseif ls.t == "[" then
      ls:advance()
      local key = expr()
      checknext("]")
      checknext("=")
      items[#items + 1] = { kind = "kv", key = key, value = expr() }
    else
      items[#items + 1] = { kind = "pos", value = expr() }
    end
    if not testnext(",") and not testnext(";") then break end
  end
  checkmatch("}", "{", line)
  return { k = "table", items = items, line = line }
end

local function simpleexp()
  local t = ls.t
  local line = ls.tl
  if t == "number" then
    local v = ls.v
    ls:advance()
    return { k = "num", v = v }
  elseif t == "string" then
    local v = ls.v
    ls:advance()
    return { k = "str", v = v }
  elseif t == "nil" then ls:advance() return { k = "nil" }
  elseif t == "true" then ls:advance() return { k = "true" }
  elseif t == "false" then ls:advance() return { k = "false" }
  elseif t == "..." then
    if not fs.isvararg then
      syntaxerror("cannot use '...' outside a vararg function")
    end
    ls:advance()
    return { k = "vararg", line = line, var = fs.varvar }
  elseif t == "{" then
    return tablecons()
  elseif t == "function" then
    ls:advance()
    local f = funcbody(false, line)
    return { k = "func", f = f, line = line }
  end
  return suffixedexp()
end

local function subexpr(limit)
  local e
  local t = ls.t
  if t == "not" or t == "-" or t == "#" or t == "~" then
    local line = ls.tl
    ls:advance()
    local a = subexpr(UNARY_PRI)
    e = { k = "unop", op = t, a = a, line = line }
  else
    e = simpleexp()
  end
  while true do
    local op = ls.t
    local pri = BINPRI[op]
    if not pri or pri[1] <= limit then break end
    local line = ls.tl
    ls:advance()
    local b = subexpr(pri[2])
    if op == "and" then
      e = { k = "and", a = e, b = b, line = line }
    elseif op == "or" then
      e = { k = "or", a = e, b = b, line = line }
    else
      e = { k = "binop", op = op, a = e, b = b, line = line }
    end
  end
  return e
end

expr = function()
  return subexpr(0)
end

---------------------------------------------------------------------------
-- Blocks and statements
---------------------------------------------------------------------------

block_follow = function(withuntil)
  local t = ls.t
  return t == "else" or t == "elseif" or t == "end" or t == "<eof>"
      or (withuntil and t == "until")
end

-- Parses statements until a block-follow token; returns the block node.
local function block(isloop)
  local b = openblock(isloop)
  local stats = statlist()
  b.stats = stats
  closeblock(b)
  return { k = "block", stats = stats, labels = b.labels }
end

local function attrib()
  if testnext("<") then
    local name = checkname()
    checknext(">")
    if name ~= "const" and name ~= "close" then
      errorat("unknown attribute '" .. name .. "'", ls.tl)
    end
    return name
  end
  return nil
end

-- Parses 'local' name list with attributes; returns list of VarInfo (not yet active).
local function localnames()
  local names = {}
  local closecount = 0
  local prefix = attrib()   -- attribute before the list applies to all names
  repeat
    local name = checkname()
    local at = attrib() or prefix
    if at == "close" then
      closecount = closecount + 1
      if closecount > 1 then syntaxerror("multiple to-be-closed variables in local list") end
    end
    names[#names + 1] = { name = name, attrib = at }
  until not testnext(",")
  return names
end

local function activate(vi)
  fs.actvars[#fs.actvars + 1] = vi
end

local function localstat(line)
  local names = localnames()
  local exprs = {}
  if testnext("=") then exprs = explist() end
  local vars = {}
  for i, n in ipairs(names) do
    vars[i] = newvarinfo(n.name, n.attrib)
  end
  for _, vi in ipairs(vars) do activate(vi) end
  return { k = "local", vars = vars, exprs = exprs, line = line }
end

-- Global declaration statement: 'global' [attrib] '*' | 'global' [attrib] namelist ['=' explist]
-- Declared global names are scope entries like locals (for goto checks), so
-- each gets a pseudo entry; '*' names the collective declaration.
local function pseudoscope(name)
  activate({ name = name, attrib = nil, slot = 0, captured = false, pseudo = true })
end

local function globalstat(line)
  local prefix = attrib()
  if prefix == "close" then errorat("global variables cannot be to-be-closed", line) end
  if ls.t == "*" then
    ls:advance()
    local entry = { all = true, attrib = prefix, names = {} }
    gdecls[#gdecls + 1] = entry
    pseudoscope("*")
    return { k = "nop" }
  end
  local names = {}
  local namelist = {}
  repeat
    local name = checkname()
    local at = attrib()
    if at == "close" then errorat("global variables cannot be to-be-closed", line) end
    namelist[#namelist + 1] = name
    names[name] = at or prefix or false
  until not testnext(",")
  local entry = { all = false, names = names }
  local exprs = nil
  if testnext("=") then
    exprs = explist()
  end
  -- declaration is in scope after the statement
  gdecls[#gdecls + 1] = entry
  for _, name in ipairs(namelist) do pseudoscope(name) end
  return { k = "globaldecl", names = namelist, attribs = names, exprs = exprs or {},
           env = singlevar("_ENV", line), line = line }
end

local checkassignable   -- defined with the expression statements below

local function funcname_stat(line)
  -- funcname: Name {'.' Name} [':' Name]
  local name = checkname()
  local target = singlevar(name, line)
  local fullname = name
  local ismethod = false
  while ls.t == "." do
    ls:advance()
    local key = checkname()
    fullname = fullname .. "." .. key
    target = { k = "index", obj = target, key = { k = "str", v = key }, line = line }
  end
  if ls.t == ":" then
    ls:advance()
    local key = checkname()
    fullname = fullname .. ":" .. key
    target = { k = "index", obj = target, key = { k = "str", v = key }, line = line }
    ismethod = true
  end
  checkassignable({ target }, line)
  local f = funcbody(ismethod, line, fullname)
  return { k = "assign", targets = { target }, exprs = { { k = "func", f = f, line = line } }, line = line }
end

-- Rejects assignments to read-only variables (const/close locals and
-- upvalues, and const globals) and to non-assignable expressions.
checkassignable = function(targets, line)
  for _, t in ipairs(targets) do
    if t.k ~= "local" and t.k ~= "upval" and t.k ~= "index" then
      syntaxerror("syntax error")
    end
    if t.k == "local" and t.var.attrib then
      errorat("attempt to assign to const variable '" .. t.var.name .. "'", line)
    elseif t.k == "upval" then
      -- an upvalue refers to the nearest enclosing local of that name
      local f, found = fs.parent, nil
      while f and not found do
        found = findlocal(f, t.name)
        f = f.parent
      end
      if found and found.attrib then
        errorat("attempt to assign to const variable '" .. t.name .. "'", line)
      end
    elseif t.k == "index" and t.attrib then
      errorat("attempt to assign to const variable '" .. t.gname .. "'", line)
    end
  end
end

local function exprstat(line)
  local e = suffixedexp()
  if ls.t == "=" or ls.t == "," then
    local targets = { e }
    while testnext(",") do
      targets[#targets + 1] = suffixedexp()
    end
    checknext("=")
    local exprs = explist()
    checkassignable(targets, line)
    return { k = "assign", targets = targets, exprs = exprs, line = line }
  end
  -- must be a function call
  if e.k ~= "call" and e.k ~= "method" then
    syntaxerror("syntax error")
  end
  return { k = "callstat", call = e, line = line }
end

local function retstat(line)
  ls:advance()
  local exprs = {}
  if not block_follow(true) and ls.t ~= ";" then
    exprs = explist()
  end
  testnext(";")
  -- a return inside the scope of a to-be-closed variable is not a tail call
  local notail = (fs.genfor or 0) > 0
  for _, vi in ipairs(fs.actvars) do
    if vi.attrib == "close" then notail = true end
  end
  return { k = "return", exprs = exprs, line = line, notail = notail }
end

local function ifstat(line)
  local conds, blocks = {}, {}
  local elseblock = nil
  -- 'if' already current
  ls:advance()
  conds[1] = expr()
  checknext("then")
  blocks[1] = block(false)
  while ls.t == "elseif" do
    ls:advance()
    conds[#conds + 1] = expr()
    checknext("then")
    blocks[#blocks + 1] = block(false)
  end
  if testnext("else") then
    elseblock = block(false)
  end
  checkmatch("end", "if", line)
  return { k = "if", conds = conds, blocks = blocks, elseblock = elseblock, line = line }
end

local function whilestat(line)
  ls:advance()
  local cond = expr()
  checknext("do")
  local body = block(true)
  checkmatch("end", "while", line)
  return { k = "while", cond = cond, body = body, line = line }
end

local function forstat(line)
  ls:advance()
  local n1 = checkname()
  if ls.t == "=" then
    ls:advance()
    local e1 = expr()
    checknext(",")
    local e2 = expr()
    local e3 = nil
    if testnext(",") then e3 = expr() end
    checknext("do")
    -- the loop variable is a read-only local of the body
    local b = openblock(true)
    local vi = newvarinfo(n1, "const")
    activate(vi)
    local stats = statlist()
    b.stats = stats
    closeblock(b)
    local body = { k = "block", stats = stats, labels = b.labels }
    checkmatch("end", "for", line)
    return { k = "numfor", var = vi, e1 = e1, e2 = e2, e3 = e3, body = body, line = line }
  elseif ls.t == "," or ls.t == "in" then
    local names = { n1 }
    while testnext(",") do names[#names + 1] = checkname() end
    checknext("in")
    local exprs = explist()
    checknext("do")
    local b = openblock(true)
    local vars = {}
    for i, n in ipairs(names) do
      vars[i] = newvarinfo(n, i == 1 and "const" or nil)
    end
    for _, vi in ipairs(vars) do activate(vi) end
    -- the loop's fourth value is a to-be-closed value: returns inside are not tail calls
    fs.genfor = (fs.genfor or 0) + 1
    local stats = statlist()
    fs.genfor = fs.genfor - 1
    b.stats = stats
    closeblock(b)
    local body = { k = "block", stats = stats, labels = b.labels }
    checkmatch("end", "for", line)
    return { k = "genfor", vars = vars, exprs = exprs, body = body, line = line }
  end
  syntaxerror("'=' or 'in' expected")
end

local function repeatstat(line)
  ls:advance()
  local b = openblock(true)
  b.isrepeat = true
  local stats = statlist()
  b.stats = stats
  checkmatch("until", "repeat", line)
  local cond = expr()    -- the condition sees the body's locals
  closeblock(b)
  return { k = "repeat", body = { k = "block", stats = stats, labels = b.labels }, cond = cond, line = line }
end

local function localfuncstat(line)
  local name = checkname()
  local vi = newvarinfo(name, nil)
  activate(vi)   -- the function can refer to itself
  local f = funcbody(false, line, name)
  return { k = "localfunc", var = vi, f = f, line = line }
end

local function localstat_entry(line)
  ls:advance() -- 'local'
  if testnext("function") then
    return localfuncstat(line)
  end
  return localstat(line)
end

local function statement()
  local line = ls.tl
  local t = ls.t
  if t == ";" then
    ls:advance()
    return { k = "nop" }
  elseif t == "if" then
    return ifstat(line)
  elseif t == "while" then
    return whilestat(line)
  elseif t == "do" then
    ls:advance()
    local body = block(false)
    checkmatch("end", "do", line)
    return { k = "do", body = body, line = line }
  elseif t == "for" then
    return forstat(line)
  elseif t == "repeat" then
    return repeatstat(line)
  elseif t == "function" then
    ls:advance()
    return funcname_stat(line)
  elseif t == "local" then
    return localstat_entry(line)
  elseif t == "name" and ls.v == "global" and
         (ls:lookahead() == "name" or ls:lookahead() == "*" or ls:lookahead() == "<"
          or ls:lookahead() == "function") then
    -- 'global' starts a declaration only when a name, '*', '<' or 'function' follows
    ls:advance()
    if ls.t == "function" then
      ls:advance()
      local name = checkname()
      -- a name already declared const cannot be defined by a function statement
      -- only an explicit const declaration of this name is an error;
      -- a '*' declaration is shadowed by the new one
      for i = #gdecls, 1, -1 do
        local e = gdecls[i]
        if e.names[name] ~= nil then
          if e.names[name] then
            errorat("attempt to assign to const variable '" .. name .. "'", line)
          end
          break
        end
      end
      gdecls[#gdecls + 1] = { all = false, names = { [name] = false } }
      pseudoscope(name)   -- the name now refers to the global, even over a local
      local f = funcbody(false, line, name)
      return { k = "assign", targets = { singlevar(name, line) }, exprs = { { k = "func", f = f, line = line } }, line = line }
    end
    return globalstat(line)
  elseif t == "::" then
    ls:advance()
    local name = checkname()
    checknext("::")
    local b = fs.block
    -- a label may not repeat a name visible from its own or an enclosing block
    local bb = b
    while bb do
      if bb.labels[name] then
        errorat("label '" .. name .. "' already defined on line " .. bb.labels[name], line)
      end
      bb = bb.parent
    end
    b.labels[name] = line
    while ls.t == ";" do ls:advance() end   -- void statements do not count
    return { k = "label", name = name, line = line, nact = #fs.actvars }
  elseif t == "return" then
    return retstat(line)
  elseif t == "break" then
    ls:advance()
    return { k = "break", line = line }
  elseif t == "goto" then
    ls:advance()
    local name = checkname()
    local b = fs.block
    b.gotos[#b.gotos + 1] = { name = name, line = line, nactive = #fs.actvars }
    return { k = "goto", name = name, line = line }
  end
  return exprstat(line)
end

-- Checks that no pending forward goto jumps into the scope of a local.
-- A label followed only by labels (void statements) at the end of its block
-- sees the locals of the block's start only.
local function checklabels(stats, b)
  for i, s in ipairs(stats) do
    if s.k == "label" then
      -- (not for repeat-until bodies: the condition sees the body's locals)
      local atend = not b.isrepeat
      for j = i + 1, #stats do
        if stats[j].k ~= "label" then atend = false break end
      end
      local nact = atend and b.nactive or s.nact
      for _, g in ipairs(b.gotos) do
        if g.name == s.name and g.nactive < nact then
          errorat("<goto " .. s.name .. "> at line " .. g.line ..
                  " jumps into the scope of '" .. fs.actvars[g.nactive + 1].name .. "'", g.line)
        end
      end
    end
  end
end

statlist = function()
  local stats = {}
  while not block_follow(true) do
    if ls.t == "return" then
      stats[#stats + 1] = retstat(ls.tl)
      break
    end
    local s = statement()
    if s.k ~= "nop" then stats[#stats + 1] = s end
  end
  checklabels(stats, fs.block)
  return stats
end

---------------------------------------------------------------------------
-- Functions
---------------------------------------------------------------------------

-- Parses '(' params ')' and the body; `name` is for error messages only.
funcbody = function(ismethod, line, name)
  local params = {}
  local isvararg = false
  local varvar = nil
  -- new function state
  local outer = fs
  local newf = newfs(outer, false)
  fs = newf
  local savedgd = #gdecls
  local b = openblock(false)
  if ismethod then
    params[#params + 1] = newvarinfo("self", nil)
    activate(params[#params])
  end
  checknext("(")
  if ls.t ~= ")" then
    repeat
      if ls.t == "name" then
        local pn = ls.v
        ls:advance()
        local vi = newvarinfo(pn, nil)
        params[#params + 1] = vi
        activate(vi)
      elseif ls.t == "..." then
        ls:advance()
        isvararg = true
        -- Lua 5.5 named vararg: '...name' binds a table with the extra arguments
        if ls.t == "name" then
          varvar = newvarinfo(ls.v, "const")   -- the vararg name is read-only
          ls:advance()
          activate(varvar)
        end
        break
      else
        syntaxerror("<name> expected")
      end
    until not testnext(",")
  end
  newf.isvararg = isvararg
  newf.varvar = varvar
  checknext(")")
  local stats = statlist()
  b.stats = stats
  local lastline = ls.tl
  checkmatch("end", "function", line)
  closeblock(b)
  while #gdecls > savedgd do gdecls[#gdecls] = nil end
  fs = outer
  return {
    name = name or "anonymous",
    params = params,
    isvararg = isvararg,
    varvar = varvar,
    body = { k = "block", stats = stats, labels = b.labels },
    nslots = newf.nslots,
    upvals = newf.upvals,
    line = line,
    lastline = lastline,
  }
end

---------------------------------------------------------------------------
-- Entry point
---------------------------------------------------------------------------

-- Parses a chunk. Returns the main function proto (vararg, upvalue 1 = _ENV).
-- chunkname is the already-formatted short source used in messages.
function M.parse(src, chunkname)
  ls = lexer.new(src, chunkname)
  gdecls = { { all = true, names = {}, implicit = true, attrib = nil } }
  local mainf = newfs(nil, true)
  mainf.upvals[1] = { name = "_ENV", instack = false, idx = 1 }
  fs = mainf
  local b = openblock(false)
  local stats = statlist()
  b.stats = stats
  if ls.t ~= "<eof>" then
    syntaxerror("'<eof>' expected")
  end
  closeblock(b)
  return {
    name = "main chunk",
    params = {},
    isvararg = true,
    body = { k = "block", stats = stats, labels = b.labels },
    nslots = mainf.nslots,
    upvals = mainf.upvals,
    line = 0,
    lastline = ls.tl,
  }
end

return M
