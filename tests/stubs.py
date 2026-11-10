# Applies stubs to the adapted copy of the official suite.
# Each stub is located by a unique text fragment, not a line number.
#  mode "assert": the first assert( on the matching line becomes _stub( (arguments still evaluated)
#  mode "comment": the matching line (or block to the given end fragment) is commented out
import sys, glob
ROOT = "testes"
PRELUDE = "function _stub(...) return ... end\n"
log = []

def read(f):
    return open(f, encoding="latin-1").read().split("\n")

def write(f, lines):
    open(f, "w", encoding="latin-1").write("\n".join(lines))

def stub(f, fragment, cat, note, mode="assert", until=None, nth=None):
    path = f"{ROOT}/{f}"
    lines = read(path)
    hits = [i for i, l in enumerate(lines) if fragment in l]
    if nth is None and len(hits) != 1:
        sys.exit(f"{f}: fragment {fragment!r} matched {len(hits)} lines")
    i = hits[nth] if nth is not None else hits[0]
    if mode == "assert":
        if "assert(" not in lines[i]:
            sys.exit(f"{f}: no assert( on matched line: {lines[i]!r}")
        lines[i] = lines[i].replace("assert(", "_stub(", 1) + f"  -- STUB[{cat}] {note}"
    else:
        end = i
        if until:
            end = next(j for j in range(i, len(lines)) if until in lines[j])
        for j in range(i, end + 1):
            lines[j] = "-- STUB[" + cat + "] " + lines[j]
    write(path, lines)
    log.append(f"{f}: [{cat}] {note}")


def block(f, start, end, cat, note, plus=0):
    """Comment out lines from the line containing `start` up to (not including) the line containing `end`."""
    path = f"{ROOT}/{f}"
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
    path = f"{ROOT}/{f}"
    text = open(path, encoding="latin-1").read()
    if text.count(old) != 1:
        sys.exit(f"{f}: replace target matched {text.count(old)} times")
    text = text.replace(old, new + f"  -- STUB[{cat}] {note}")
    open(path, "w", encoding="latin-1").write(text)
    log.append(f"{f}: [{cat}] {note}")

# fresh prelude on every file
for f in glob.glob(f"{ROOT}/*.lua"):
    s = open(f, encoding="latin-1").read()
    open(f, "w", encoding="latin-1").write(PRELUDE + s)

# --- pointer identity (string addresses / %p) ---
stub("pm.lua", 'string.format("%p", s) ~= string.format("%p", r)', "pointer", "%p address comparison")
stub("strings.lua", "topointer(s1) ~= topointer(s2)", "pointer", "long strings not internalized")
stub("literals.lua", "getadd(sd) ~= a1", "pointer", "short-string internalization")

# --- collectgarbage("count") memory checks ---
stub("sort.lua", "memdiff > N * 4", "memory", "table.create memory accounting")
stub("vararg.lua", 'assert(m == collectgarbage"count")', "memory", "no allocation check")
# (fragment above has no '_stub' mismatch: assert( is on the same line)

# --- debug library ---
stub("closure.lua", "debug.upvalueid(string.gmatch", "debug", "upvalueid of a C closure")
stub("db.lua", "b.activelines[b.linedefined + 1]", "debug", "getinfo 'L' activelines", mode="comment", until="b.activelines[b.lastlinedefined])")

# --- debug library (continued) ---
stub("db.lua", "assert(b.name == nil and b.what", "debug", "getinfo 'SfL' fields of a Lua function")
stub("db.lua", "assert(not b.activelines[b.linedefined] and", "debug", "getinfo 'L' activelines", mode="comment", until="not b.activelines[b.lastlinedefined + 1])")
# string.dump / binary chunks
stub("calls.lua", "-- another small bug (in 5.2.1)", "dump", "string.dump and binary chunk load", mode="comment", until='assert(type(f) == "function" and f() == 1)')
# light userdata (uses debug.setuservalue)
stub("errors.lua", "-- passing light userdata instead of full userdata", "debug", "light userdata via debug.setuservalue", mode="comment", until='"light userdata")')
# weak tables ('kv' mode count after collection)
stub("gc.lua", "assert(i == 4)", "weak", "kv-weak table entry count after collectgarbage")
# memory accounting
stub("sort.lua", "memdiff > 1024 * 12", "memory", "table.create memory accounting")

# dump / binary-chunk blocks (whole sections, so they are removed together)
block("calls.lua", "do   -- another bug (in 5.4.0)", 'print("testing binary chunks")', "dump", "string.dump / binary chunk section")
block("calls.lua", 'print("testing binary chunks")', "print('OK')", "dump", "binary chunk tests to end of file")
block("db.lua", "--  without debug information", "assert(#actl == 0)   -- no line info", "dump", "string.dump of stripped code", plus=2)
block("db.lua", "-- dump/load a function without debug info", 'print"OK"', "dump", "string.dump / stripped debug info section")
block("errors.lua", "-- errors in functions without debug info", "-- tests for field accesses after RK limit", "dump", "string.dump of stripped functions")
stub("gc.lua", "assert(next(a) == string.rep('$', 11))", "weak", "kv-weak table cleared after collectgarbage")

# finalizer waits (GC1/GC2 loop until a __gc finalizer runs; finalizers are not implemented)
replace_once("gc.lua", "local function GC1 ()", "local function GC1 () do return end", "finalizers", "GC1 waits for __gc")
replace_once("gc.lua", "local function GC2 ()", "local function GC2 () do return end", "finalizers", "GC2 waits for __gc")
# ephemeron/weak cleanup checks (weak semantics; stubbed one at a time, in file order)
stub("gc.lua", "assert(next(a) == nil)", "weak", "ephemeron cleanup after collection", nth=0)
stub("gc.lua", "assert(m==10)", "finalizers", "__gc finalizer side effect after collection")
stub("gc.lua", 'collectgarbage("count") <= m + 1', "memory", "everything collected (memory count)")
stub("gc.lua", "assert(collected)", "finalizers", "__gc on collected thread/closure")
stub("gc.lua", "assert(not res)", "finalizers", "collector reentrancy from __gc")
print("\n".join(log))
