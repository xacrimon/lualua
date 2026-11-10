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

Test workflow:
- `tests/make_adapted.sh` regenerates `tests/adapted/testes` from the official
  suite (`/home/acrimon/work/lua/testes`) and applies the exclusion stubs; the
  log is `tests/adapted/STUBLOG.txt`. The official directory is never modified.
- `tests/run_testes.sh` runs the adapted suite (default); `tests/where.sh <file>`
  reports the first failing assertion.
- Excluded (stubbed, tagged `STUB[category]`): `debug` (debug library behaviour,
  section by section; `db.lua` keeps its sections of plain Lua), `dump`
  (`string.dump` and binary chunks), `pointer` (address identity, string
  interning), `memory` (`collectgarbage("count")` measurements).
- The adapted copy keeps the official line numbers: the stub prelude shares the
  first line of each file.

Debug library, as implemented (`src/lib/debug.lua`) and as stubbed:
- `getinfo`: `what`, `source`, `short_src`, `currentline`, `linedefined`,
  `lastlinedefined`, `func`, `name`/`namewhat` (from call descriptions) are
  supported. Missing: `activelines` (`L`), `nparams`, `nups`, `isvararg`,
  `istailcall`, `ftransfer`/`ntransfer`, `nparams` for C functions, and
  name/namewhat `metamethod` and `for iterator` for frames not on the stack.
- `sethook`, `gethook`: accepted but inert (no events are delivered; `gethook`
  returns nothing). Line, call, return and count hooks are not implemented.
- `getlocal`: always returns nothing. `setlocal`, `getuservalue`,
  `setuservalue`, `debug.getregistry` are not provided.
- `traceback`: one line per Lua frame without level or thread arguments; not
  the reference layout.
- Upvalue functions work only for closures created by `compiler.lua`.

Known gaps that remain (not excluded):
- Argument errors: a missing argument is "no value" only when the caller's
  argument count is known (Lua calls and natives called by `pcall`/`ccall`).
- Call-site naming is approximated: `method` vs `field` uses a per-function
  constant index (more than 255 constants gives `field`).
- Deep recursion to the frame limit is slow (about a minute for
  `cstack.lua`): frames are heavier than the reference's.
- `coroutine.isyieldable` and yields across library callbacks model only
  `gsub` and `table.sort`; other natives that call Lua (`tostring` with
  `__tostring`, `load`'s reader, ...) let a yield through where the reference
  raises "attempt to yield across a C-call boundary".
- Finalizers run from the host collector, so their timing and order are the
  host's, not the reference's. An error inside `__gc` is discarded. The
  reference reports it through `warn` when warnings are on ("error in __gc
  (...)"); with warnings off, both discard it.
- `collectgarbage("param")` stores the values and returns them but does not
  change the collector. `collectgarbage("count")` is the host's memory figure.
- Lua call depth is capped at 50000 frames (`MAXDEPTH` in `compiler.lua`); the
  reference overflows by stack size, so the depth at which "stack overflow"
  appears differs.
- In `db.lua`, the line-trace helper `test` (lines 19-29) no longer checks
  anything, because its `assert(#l == 0)` is stubbed. The `test([[...]], {...})`
  calls that remain in the file therefore verify nothing (the large-gap loop
  that also uses `test` is stubbed as a whole).

## Lua 5.5 specifics to keep in mind

- `global` is a contextual keyword: it starts a declaration only before a name, `*`,
  `<` or `function` (otherwise it is an ordinary name, as with LUA_COMPAT_GLOBAL). `global [<const>] name, ...`, `global [<const>] *`,
  `global function f`. Name resolution rules are syntactic: inside a `global`
  declaration scope only declared names may be used; `global<const> *` makes
  implicit globals read-only.
- Control variable of numeric `for` is read-only (assignment is a compile error).
- `__call` chains: at most 15 objects.
- An error object of `nil` is replaced by a string message.
- Finalizers (`__gc`) run through host finalizers (tables and userdata whose
  metatable has `__gc` when set get a finalizable host metatable); closing the
  state at exit runs the pending ones.
- `collectgarbage` options changed (`"param"` option replaces `incremental`/`generational` parameter setters).
