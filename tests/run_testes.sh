#!/bin/sh
# Runs files of the official Lua 5.5 test suite with lualua.
# usage: tests/run_testes.sh [file.lua ...]   (default: all files in testes)
# TESTES env var overrides the suite location.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TESTES=${TESTES:-/home/acrimon/work/lua/testes}
files="$*"
[ -z "$files" ] && files=$(cd "$TESTES" && ls *.lua | grep -v '^all.lua$')
pass=0; fail=0
for f in $files; do
  out=$(cd "$TESTES" && timeout 120 lua "$ROOT/lualua.lua" -e "_port=true;_soft=true;_nomsg=true" "$f" 2>&1)
  rc=$?
  if [ $rc -eq 0 ]; then pass=$((pass+1)); echo "PASS $f"
  else fail=$((fail+1)); echo "FAIL $f (rc=$rc): $(echo "$out" | grep -v "^+$" | tail -n 2 | cut -c1-200 | tr "\n" " ")"; fi
done
echo "passed $pass, failed $fail"
