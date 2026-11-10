#!/bin/sh
# Generates tests/adapted/testes: a copy of the official Lua 5.5 test suite with
# the excluded features stubbed out (see tests/stubs.py). The official directory
# is only read, never modified. The stub log is written to tests/adapted/STUBLOG.txt.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OFFICIAL=${OFFICIAL:-/home/acrimon/work/lua/testes}
OUT="$ROOT/tests/adapted"
rm -rf "$OUT" && mkdir -p "$OUT" && cp -r "$OFFICIAL" "$OUT/testes" || exit 1
(cd "$OUT" && python3 "$ROOT/tests/stubs.py" > STUBLOG.txt) || exit 1
echo "adapted suite: $OUT/testes ($(wc -l < "$OUT/STUBLOG.txt") stubs logged)"
