#!/bin/sh
# Regenerates tests/adapted/testes from the official suite (LUA_TESTES, default
# ../lua/testes next to the tcvm checkout) and applies the excluded-feature stubs.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec python3 "$ROOT/tests/make_adapted.py"
