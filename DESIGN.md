# lualua — design notes

Goal: a mostly working Lua 5.5.1 interpreter written in Lua 5.5, run by the
host `lua` (5.5). Reference C implementation and official test suite:
`/home/acrimon/work/lua` (`testes/`, `manual/manual.of`, `src`-level files).

## Boundary: what the host provides vs. what we implement

Host primitives we rely on (they have the right semantics already):
- arithmetic / comparison / concatenation on numbers and strings
- `tonumber(string)` (same conversion rules as `lua_stringtonumber`)
- `math.tointeger`, `math.type`, math functions (`math.sin`, `math.fmod`, ...)
- `tostring(number)` (same `%.14g` formatting as Lua)
- coroutines (`coroutine.create/resume/yield/...`) — a Lua coroutine *is* a host coroutine
- `string.byte/char/sub/format("%...")` as building blocks
- file primitives (`io.open`, `file:read/write/seek`, `os.time/clock/date/remove/rename/getenv`)

Everything with Lua-level meaning is ours: the lexer, parser, scoping,
closures and upvalues, metatables and all metamethods, error messages and
positions, `pcall`/`error`, the standard library logic (patterns, `format`,
`sort`, `pack`, `utf8`, ...).

## Value model (see `src/runtime.lua` header)

| Lua type  | Representation                                                |
|-----------|---------------------------------------------------------------|
| nil, boolean, number, string, function, thread | host values as-is        |
| table     | host table with metatable `R.TableMT`: fields `hash`, `mt`, `n` |
| userdata  | host table with metatable `R.UserdataMT`: fields `payload`, `mt` |

Never store Lua values directly in a host table that is not `t.hash` — the
`hash` field holds every key/value pair of a Lua table. Assigning `nil` to a
key removes it. `R.type(v)` gives the Lua type name (`"table"`, `"userdata"`, ...).

Functions: native library functions are ordinary host functions
`function(...) ... return results end`. Multiple results are host multiple
returns. Use `select("#", ...)` when you need the argument count.

## Library module contract

Each library lives in `src/lib/<name>.lua` and returns an installer:

```lua
-- src/lib/<name>.lua
local R = require("runtime")    -- or: local R = dofile(...) — see loader in lualua.lua
return function(G)              -- G is the global Lua table (R.newtable())
  -- build the library table and store it, e.g.
  local lib = R.newtable()
  R.setfuncs(lib, { insert = tinsert, remove = tremove })
  G.hash.table = lib            -- G.hash.<name> = value (note the .hash)
end
```

Loader: `src/lib/<name>.lua` files are loaded by `src/interp.lua` with
`require` using `package.path` set to the repo's `src/?.lua`, so inside
library files `require("runtime")` returns the runtime module `R`.
Installers get `G` (the global table) and must not touch other libraries.

Helpers in `runtime.lua` (use these, they produce Lua-compatible messages):
- `R.checkinteger(v, n, fname)`, `R.optinteger(v, n, fname, default)`
- `R.checknumber(v, n, fname)`, `R.optnumber(...)`
- `R.checkstring(v, n, fname)` (numbers are converted), `R.optstring(...)`
- `R.checktable(v, n, fname)`, `R.checkfunction(v, n, fname)`
- `R.argerror(n, fname, msg)` -> `bad argument #n to 'fname' (msg)`
- `R.typeerror(n, fname, expected, v)` -> `... expected, got <type>`
- `R.rterror(msg)` — raise with the current Lua position prefix
- `R.throw(v)` — raise a Lua value unchanged (no position)
- `R.setfuncs(t, {name = fn, ...})` — rawly store functions in a Lua table

Semantics helpers that respect metamethods (use them for library code that
must follow Lua 5.5 rules, e.g. `table.insert` uses `lua_seti` semantics):
- `R.index(o, k)`, `R.setindex(o, k, v)`, `R.len(v)` (honours `__len`)
- `R.rawget(t,k)`, `R.rawset(t,k,v)`, `R.rawlen(t)`, `R.next(t,k)`
- `R.call(f, ...)` — call any Lua value (honours `__call`); returns all results
- `R.eq(a,b)`, `R.lt(a,b)`, `R.le(a,b)` — with metamethods
- `R.tostring(v)` — Lua `tostring` (honours `__tostring`/`__name`)
- `R.type(v)`, `R.getmt(v)`, `R.metamethod(v, "__name")`
- `R.newtable()`, `R.newuserdata(payload, mt)`, `R.setmetatable(obj, mt)`

Strings: Lua strings are host strings. The string metatable is
`R.typemt.string`; the string library installer sets it to a Lua table whose
`__index` is the `string` library table (`R.typemt.string = mt`).

Error messages should match Lua 5.5 wording exactly (tests compare them),
e.g. `bad argument #1 to 'rep' (number expected, got nil)`.

## Frames and positions

`R.stack` is the running coroutine's frame stack; compiled Lua functions push
`{src=..., line=...}` frames. Natives push nothing. `R.where(level)` gives the
position prefix. `error(msg, level)` must use `R.where(level)` with level 1
meaning "the Lua function that called error".

## Module layout

```
lualua.lua          CLI entry point: lua lualua.lua [options] [script [args]]
src/runtime.lua     value model, metamethods, arithmetic, errors, arg checks
src/lexer.lua       tokenizer
src/parser.lua      recursive-descent parser -> AST with resolved scopes,
                    global-declaration and goto/label checks
src/compiler.lua    AST -> Lua closures (the "interpreter" proper); activation
                    records A are also the stack frames
src/loader.lua      source text -> Lua function (chunkid, load)
src/interp.lua      builds the global environment, loads libraries
src/lib/base.lua    print, pairs, pcall, load, select, require, collectgarbage, ...
src/lib/string.lua  string library incl. Lua patterns, format, pack/unpack
src/lib/table.lua   table library
src/lib/math.lua    math library (incl. frexp/ldexp and compat functions)
src/lib/utf8.lua    utf8 library
src/lib/os.lua      os library
src/lib/io.lua      io library (files are userdata)
src/lib/coroutine.lua coroutine library (host coroutines, per-coroutine frame stack)
src/lib/debug.lua   partial debug library (getinfo names/lines, upvalue access)
tests/run_testes.sh run files of the official suite (default: all but heavy.lua)
tests/where.sh      report the first failing assertion location per file
```

## Debugging aids

- `LUALUA_DEBUG=1` makes a failing `assert` print its position on stderr.
- Each Lua frame records `src`, `line` and the call-site description `cdesc`
  (used by `debug.getinfo(level, "n")`).

## Status against the official suite

See `git log` for the milestones. Known gaps (not implemented or deviating):

- Closing a suspended coroutine does not run its pending `__close` handlers.
- `global *` (goto scope check against `global` declarations) is not checked.
- Argument errors say `got nil`, not `got no value`.
- `%p` / interned-string identity is not modelled.
- `table.create` does not reserve memory; `collectgarbage("count")` is host-based.
- C-stack overflow in nested `pcall` is not reproduced exactly.
- `require` search-failure messages list only the Lua path templates.

## Lua 5.5 specifics to keep in mind

- `global` is a reserved word. `global [<const>] name, ...`, `global [<const>] *`,
  `global function f`. Name resolution rules are syntactic: inside a `global`
  declaration scope only declared names may be used; `global<const> *` makes
  implicit globals read-only.
- Control variable of numeric `for` is read-only (assignment is a compile error).
- `__call` chains: at most 15 objects.
- An error object of `nil` is replaced by a string message.
- `collectgarbage` options changed (`"param"` option replaces `incremental`/`generational` parameter setters).
