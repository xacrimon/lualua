#!/usr/bin/env python3
"""Generates tests/adapted/testes: a copy of the official Lua 5.5 suite with
stubs for excluded features. Each stub is tagged STUB[category] in the file and
recorded in tests/adapted/STUBLOG.txt. The official suite is never modified.

Categories (excluded features, stubbed rather than implemented):
  debug    debug library functionality (getinfo details, upvalueid, setuservalue, light userdata)
  dump     string.dump and binary chunks
  pointer  pointer / address identity (%p, string internalization)
  memory   collectgarbage("count") memory measurements

Stubs are located by unique text fragments, not line numbers. A stub either
turns the first assert( on a line into _stub( (the argument is still evaluated),
or comments out a block of lines.
"""
import glob, os, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.environ.get("LUA_TESTES", "/home/acrimon/work/lua/testes")
OUT = os.path.join(HERE, "adapted")
DST = os.path.join(OUT, "testes")
LOG = os.path.join(OUT, "STUBLOG.txt")
# no newline: the prelude shares the first line, so line numbers match the official suite
PRELUDE = "function _stub(...) return ... end "
log = []


def read(path):
    return open(path, encoding="latin-1").read().split("\n")


def write(path, lines):
    open(path, "w", encoding="latin-1").write("\n".join(lines))


def stub(f, fragment, cat, note, nth=None):
    """Turns the assert( on the (unique, or nth) line containing fragment into _stub(."""
    path = os.path.join(DST, f)
    lines = read(path)
    hits = [i for i, l in enumerate(lines) if fragment in l]
    if nth is None and len(hits) != 1:
        sys.exit(f"{f}: fragment {fragment!r} matched {len(hits)} lines")
    i = hits[nth] if nth is not None else hits[0]
    if "assert(" not in lines[i]:
        sys.exit(f"{f}: no assert( on matched line: {lines[i]!r}")
    lines[i] = lines[i].replace("assert(", "_stub(", 1) + f"  -- STUB[{cat}] {note}"
    write(path, lines)
    log.append(f"{f}: [{cat}] {note}")


def block(f, start, end, cat, note, plus=0, inclusive=True, next_line=None):
    """Comments out lines from the line containing start to the line containing end
    (inclusive by default; the end line is the last line of the statement).
    With next_line, start must be a line equal to start (stripped) whose following
    line contains next_line (for bare keywords such as 'do')."""
    path = os.path.join(DST, f)
    lines = read(path)
    if next_line is None:
        s = [i for i, l in enumerate(lines) if start in l]
    else:
        s = [i for i, l in enumerate(lines)
             if l.strip() == start and i + 1 < len(lines) and next_line in lines[i + 1]]
    e = [i for i, l in enumerate(lines) if end in l]
    if len(s) != 1 or len(e) != 1 or e[0] <= s[0]:
        sys.exit(f"{f}: block markers not unique/ordered: {len(s)} {len(e)}")
    stop = e[0] + (1 if inclusive else 0) + plus
    for j in range(s[0], min(stop, len(lines))):
        lines[j] = "-- STUB[" + cat + "] " + lines[j]
    write(path, lines)
    log.append(f"{f}: [{cat}] {note} (lines {s[0]+1}-{stop})")


def stmt(f, fragment, cat, note):
    """Comments out a whole (possibly multi-line) statement that starts on the line
    containing fragment, up to the line where its parentheses balance again."""
    path = os.path.join(DST, f)
    lines = read(path)
    hits = [i for i, l in enumerate(lines) if fragment in l]
    if len(hits) != 1:
        sys.exit(f"{f}: fragment {fragment!r} matched {len(hits)} lines")
    s = hits[0]
    depth, j = 0, s
    while True:
        depth += lines[j].count("(") - lines[j].count(")")
        if depth <= 0:
            break
        j += 1
        if j >= len(lines):
            sys.exit(f"{f}: unbalanced statement at line {s+1}")
    for k in range(s, j + 1):
        lines[k] = "-- STUB[" + cat + "] " + lines[k]
    write(path, lines)
    log.append(f"{f}: [{cat}] {note} (lines {s+1}-{j+1})")


def comment_all(f, fragment, cat, note):
    """Comments out every line containing fragment (for one-line statements)."""
    path = os.path.join(DST, f)
    lines = read(path)
    hits = [i for i, l in enumerate(lines) if fragment in l]
    if not hits:
        sys.exit(f"{f}: fragment {fragment!r} matched no lines")
    for i in hits:
        if lines[i].count("(") != lines[i].count(")"):
            sys.exit(f"{f}:{i+1}: not a balanced one-line statement: {lines[i]!r}")
        lines[i] = "-- STUB[" + cat + "] " + lines[i]
    write(path, lines)
    log.append(f"{f}: [{cat}] {note} (lines {', '.join(str(i+1) for i in hits)})")






def replace_once(f, old, new, cat, note):
    """Replaces the single occurrence of old by new, tagged with a STUB comment."""
    path = os.path.join(DST, f)
    text = open(path, encoding="latin-1").read()
    if text.count(old) != 1:
        sys.exit(f"{f}: replace target matched {text.count(old)} times")
    text = text.replace(old, new + f"  -- STUB[{cat}] {note}")
    open(path, "w", encoding="latin-1").write(text)
    log.append(f"{f}: [{cat}] {note}")


def stub_db():
    """db.lua tests the debug library almost throughout, so its debug assertions are
    stubbed section by section; sections that test only ordinary Lua keep running.
    Blocks are commented out whole (their assertions depend on debug features)."""
    F = "db.lua"
    # line hooks (debug.sethook) are not delivered: the trace helper cannot check events
    stub(F, "  assert(#l == 0)", "debug", "line hook trace helper: no hook events delivered")
    replace_once(F, 'debug.sethook(f,"l"); load(s)(); debug.sethook()', "load(s)()", "debug",
                 "line hook not set (sethook unsupported); the chunk still runs")
    comment_all(F, 'debug.sethook(function () end, "l")', "debug", "line hook on a coroutine (sethook unsupported)")
    comment_all(F, 'debug.sethook(function () count = count + 1 end, "", 1)', "debug",
                "count hook not set (sethook unsupported); the checks on values still run")
    # getinfo activelines (the 'L' option) is not implemented
    stmt(F, "assert(b.activelines[b.linedefined + 1] and", "debug", "getinfo activelines (L option)")
    stmt(F, "assert(not b.activelines[b.linedefined] and", "debug", "getinfo activelines (L option)")
    block(F, "--  bug in 5.4.4-5.4.6: activelines in vararg functions", "assert(#actl == 0)",
          "dump", "activelines of a dumped function without debug info", plus=1)
    block(F, "do   -- testing line info/trace with large gaps in source", "test(s, {1, 2 + i, 2 + i + j",
          "debug", "line trace (debug.sethook) with large gaps", plus=3)
    block(F, "do   -- testing active lines", "print'+'", "debug", "activelines (L option)", inclusive=False)
    stub(F, 'assert(g.what == "Lua" and g.func == f and g.namewhat', "debug", "getinfo namewhat of a function value")
    # upvalues of C closures are named "" (C closure upvalue names)
    stub(F, 'assert(debug.getupvalue(string.gmatch("x", "x"), 1) == "")', "debug", "upvalue of a C closure (empty name)")
    # getlocal / setlocal
    block(F, "-- invalid levels in [gs]etlocal", "assert(not pcall(debug.setlocal, -1, 1, 10))",
          "debug", "getlocal/setlocal: levels")
    block(F, "-- parameter names", "foo(table.unpack(a))", "debug", "getlocal/setlocal: parameter names and varargs")
    block(F, "do   -- test hook presence in debug info", "_ENV.a = nil", "debug", "hook presence in debug info")
    stmt(F, "assert(getmetatable(debug.getregistry()._HOOKKEY)", "debug", "hook table weak keys (registry)")
    # line/call hooks, currentline, C temporaries, global declarations seen by getlocal
    block(F, "a = {}; local L = nil", "assert(g(0,0) == 30)", "debug",
          "line/call hooks (debug.sethook), currentline, C temporaries")
    block(F, "-- minimal tests for setuservalue/getuservalue", "assert(a == nil and not b)", "debug",
          "setuservalue/getuservalue", plus=1)
    block(F, "-- testing access to function arguments", "_G.XX = nil", "debug",
          "call/line hooks and collectlocals")
    block(F, "-- testing access to local variables in return hook (bug in 5.2)", "  assert(X)", "debug",
          "return hook access to locals", plus=2)
    block(F, "do  print(\"testing inspection of parameters/returned values\")", "eqseq(inp, {20}); eqseq(out, {10, 0})",
          "debug", "inspection of parameters and returned values (hooks)", plus=3)
    # hooks: count, tail calls, local function information
    block(F, "-- testing count hooks", "local g, g1", "debug", "count hooks", inclusive=False)
    block(F, "-- tests for tail calls", "foo(lim)", "debug", "tail call information and hooks")
    block(F, "-- testing local function information", "assert(a == 2)", "debug", "local function information (hooks)")
    # traceback
    block(F, "-- testing traceback", 'assert(st == true and string.find(msg, "pcall"))', "debug",
          "traceback text and C-function names", plus=1)
    block(F, "-- testing nparams, nups e isvararg", "assert(t.isvararg == true and t.nparams == 0 and t.nups > 0)",
          "debug", "getinfo nparams, nups, isvararg")
    # coroutines
    block(F, "-- testing debugging of coroutines", "checktraceback(co, {})", "debug",
          "coroutine traceback and getinfo/getlocal")
    block(F, "-- check get/setlocal in coroutines", "assert(a and b == 30)", "debug",
          "getlocal/setlocal in coroutines")
    block(F, "-- check traceback of suspended", "t[1] = \"'error'\"", "debug",
          "traceback of suspended and dead coroutines", plus=1)
    stmt(F, 'assert(type(debug.getregistry()) == "table")', "debug", "debug.getregistry")
    # tag methods, iterators, finalizers
    block(F, "-- test tagmethod information", 'assert(~a == "bnot")', "debug", "metamethod names (getinfo)")
    block(F, "do   -- testing for-iterator name", "for i in f do end", "debug", "for iterator name", plus=1)
    block(F, "do   -- testing debug info for finalizers", 'assert(name == "__gc")', "debug",
          "finalizer debug info (getinfo namewhat)", plus=1)
    block(F, "do", "coroutine.wrap(checkdeep)(d, l)", "debug", "traceback sizes (debug.traceback levels)",
          plus=4, next_line='print("testing traceback sizes")')
    # stripped chunks and binary dumps
    block(F, 'print("testing debug functions on chunk without debug info")', "assert(f() == 13)", "dump",
          "debug information of stripped chunks (string.dump)")
    block(F, "do   -- bug in 5.4.0: line hooks in stripped code", "assert(line == nil)", "dump",
          "line hooks in stripped code", plus=1)
    block(F, "do   -- tests for 'source' in binary dumps", "debug.getinfo(h).source == '=?')", "dump",
          "source in binary dumps", plus=1)


def main():
    if os.path.exists(DST):
        shutil.rmtree(DST)
    shutil.copytree(SRC, DST)
    for f in glob.glob(os.path.join(DST, "*.lua")):
        s = open(f, encoding="latin-1").read()
        if s.startswith("#"):
            # keep a shebang line first (the loader skips it only at the start of a file)
            first, _, rest = s.partition("\n")
            open(f, "w", encoding="latin-1").write(first + "\n" + PRELUDE + rest)
        else:
            open(f, "w", encoding="latin-1").write(PRELUDE + s)

    # pointer identity
    stub("pm.lua", 'string.format("%p", s) ~= string.format("%p", r)', "pointer", "%p address comparison")
    stub("strings.lua", "topointer(s1) ~= topointer(s2)", "pointer", "long strings not internalized")
    stub("literals.lua", "getadd(sd) ~= a1", "pointer", "short-string internalization")

    # memory measurements
    stub("sort.lua", "memdiff > N * 4", "memory", "table.create memory accounting")
    stub("sort.lua", "memdiff > 1024 * 12", "memory", "table.create memory accounting (zero-size)")
    stub("vararg.lua", 'assert(m == collectgarbage"count")', "memory", "no allocation check")
    stub("gc.lua", 'collectgarbage("count") <= m + 1', "memory", "everything collected (memory count)")

    stub_db()

    # debug library
    stub("closure.lua", "debug.upvalueid(string.gmatch", "debug", "upvalueid of a C closure")

    comment_all("locals.lua", "assert(debug.getinfo(2).name", "debug", "getinfo name of calling function")
    comment_all("coroutine.lua", 'assert(X == 43 and Y.what == "C")', "debug", "getinfo what of a C frame")
    block("coroutine.lua", "local function dotrace (event)", "assert(v == correcttrace[k])",
          "debug", "debug.sethook trace of a coroutine", plus=1)
    comment_all("locals.lua", "in metamethod 'close'", "debug", "traceback text")
    block("locals.lua", "-- '__close' vs. return hooks in C functions", "checktable(t, {10, 20})",
          "debug", "hooks (debug.sethook) and T.testC")
    comment_all("locals.lua", "debug.getlocal(2", "debug", "getlocal inside a __close handler")
    comment_all("locals.lua", 'assert(res[1] == "x" and res[2] == "i"', "debug", "getlocal results")
    block("locals.lua", "-- '__close' vs. return hooks in Lua functions", '"return close", "return foo"})',
          "debug", "hooks (debug.sethook) in Lua functions", plus=1)

    # string.dump and binary chunks
    block("calls.lua", "-- another small bug (in 5.2.1)", 'assert(type(f) == "function" and f() == 1)',
          "dump", "string.dump and binary chunk load")
    block("calls.lua", "do   -- another bug (in 5.4.0)", 'print("testing binary chunks")',
          "dump", "string.dump / binary chunk section", inclusive=False)
    block("calls.lua", 'print("testing binary chunks")', "print('OK')",
          "dump", "binary chunk tests to end of file", inclusive=False)
    block("files.lua", "assert(io.write(string.dump(function () return 10", 'assert(a == 10 and b == "\\0alo\\255" and c == "hi")',
          "dump", "loading binary chunks (string.dump)", plus=1)
    block("files.lua", "-- save function with no upvalues", 'assert(type(f) == "function" and f() == 1)',
          "dump", "binary chunk without upvalues", plus=1)
    block("files.lua", "-- loading binary file with initial comment", 'assert(a == 20 and b == "\\0\\0\\0" and c == nil)',
          "dump", "binary chunk with initial comment", plus=1)
    block("files.lua", "do   -- testing closing file in line iteration", 'assert(st == false and io.type(msg) == "closed file")',
          "debug", "closing a file from a loop via debug.getlocal", plus=2)
    block("errors.lua", "-- passing light userdata instead of full userdata", '"light userdata")',
          "debug", "light userdata via debug.setuservalue")
    block("errors.lua", "-- errors in functions without debug info", "-- tests for field accesses after RK limit",
          "dump", "string.dump of stripped functions", inclusive=False)

    os.makedirs(OUT, exist_ok=True)
    with open(LOG, "w", encoding="latin-1") as fh:
        fh.write("\n".join(log) + "\n")
    print("\n".join(log))
    print(f"adapted suite: {DST}")
    print(f"stub log: {LOG}")


if __name__ == "__main__":
    main()
