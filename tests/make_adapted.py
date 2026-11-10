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
PRELUDE = "function _stub(...) return ... end\n"
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


def block(f, start, end, cat, note, plus=0):
    """Comments out lines from the line containing start up to (not including) the line containing end."""
    path = os.path.join(DST, f)
    lines = read(path)
    s = [i for i, l in enumerate(lines) if start in l]
    e = [i for i, l in enumerate(lines) if end in l]
    if len(s) != 1 or len(e) != 1 or e[0] <= s[0]:
        sys.exit(f"{f}: block markers not unique/ordered: {len(s)} {len(e)}")
    for j in range(s[0], min(e[0] + plus, len(lines))):
        lines[j] = "-- STUB[" + cat + "] " + lines[j]
    write(path, lines)
    log.append(f"{f}: [{cat}] {note} (lines {s[0]+1}-{e[0]+plus})")


def replace_once(f, old, new, cat, note):
    path = os.path.join(DST, f)
    text = open(path, encoding="latin-1").read()
    if text.count(old) != 1:
        sys.exit(f"{f}: replace target matched {text.count(old)} times")
    text = text.replace(old, new + f"  -- STUB[{cat}] {note}")
    open(path, "w", encoding="latin-1").write(text)
    log.append(f"{f}: [{cat}] {note}")


def main():
    if os.path.exists(DST):
        shutil.rmtree(DST)
    shutil.copytree(SRC, DST)
    for f in glob.glob(os.path.join(DST, "*.lua")):
        s = open(f, encoding="latin-1").read()
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

    # debug library
    stub("closure.lua", "debug.upvalueid(string.gmatch", "debug", "upvalueid of a C closure")
    stub("db.lua", "assert(b.name == nil and b.what", "debug", "getinfo 'SfL' fields of a Lua function")
    block("db.lua", "assert(b.activelines[b.linedefined + 1] and", "b.activelines[b.lastlinedefined])",
          "debug", "getinfo 'L' activelines")
    block("db.lua", "assert(not b.activelines[b.linedefined] and", "not b.activelines[b.lastlinedefined + 1])",
          "debug", "getinfo 'L' activelines")
    block("errors.lua", "-- passing light userdata instead of full userdata", '"light userdata")',
          "debug", "light userdata via debug.setuservalue")

    # string.dump and binary chunks
    block("calls.lua", "-- another small bug (in 5.2.1)", 'assert(type(f) == "function" and f() == 1)',
          "dump", "string.dump and binary chunk load")
    block("calls.lua", "do   -- another bug (in 5.4.0)", 'print("testing binary chunks")',
          "dump", "string.dump / binary chunk section")
    block("calls.lua", 'print("testing binary chunks")', "print('OK')",
          "dump", "binary chunk tests to end of file")
    block("db.lua", "--  without debug information", "assert(#actl == 0)   -- no line info",
          "dump", "string.dump of stripped code", plus=2)
    block("db.lua", "-- dump/load a function without debug info", 'print"OK"',
          "dump", "string.dump / stripped debug info section")
    block("errors.lua", "-- errors in functions without debug info", "-- tests for field accesses after RK limit",
          "dump", "string.dump of stripped functions")

    os.makedirs(OUT, exist_ok=True)
    with open(LOG, "w", encoding="latin-1") as fh:
        fh.write("\n".join(log) + "\n")
    print("\n".join(log))
    print(f"adapted suite: {DST}")
    print(f"stub log: {LOG}")


if __name__ == "__main__":
    main()
