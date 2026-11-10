#!/bin/sh
# Prints the first failing location (assertion or error) for suite files.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TESTES=${TESTES:-/home/acrimon/work/lua/testes}
for f in "$@"; do
  out=$(cd "$TESTES" && LUALUA_DEBUG=1 timeout 60 lua "$ROOT/lualua.lua" -e "_port=true;_soft=true;_nomsg=true" "$f" 2>&1)
  rc=$?
  loc=$(echo "$out" | grep -o "assertion failed at [^ ]*" | head -1)
  err=$(echo "$out" | grep "^lua:" | head -1 | cut -c1-200)
  [ $rc -eq 0 ] && echo "PASS $f" || echo "FAIL $f rc=$rc $loc $err"
done
