#!/bin/sh
# Regenerates tests/adapted/testes from the official suite (LUA_TESTES, default
# /home/acrimon/work/lua/testes) and applies the excluded-feature stubs.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec python3 "$ROOT/tests/make_adapted.py"
