#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEST_ROOT=${LORKHAN_LUA_TEST_ROOT:-$ROOT/lorkhan/files/scripts/LORKHAN/tests}
REQUIRED=${LORKHAN_REQUIRE_LUA_TESTS:-0}
LUA=${LUA:-}
if [ -z "$LUA" ]; then
  for name in luajit lua5.4 lua54 lua5.3 lua; do if command -v "$name" >/dev/null 2>&1; then LUA=$name; break; fi; done
fi
if [ ! -d "$TEST_ROOT" ]; then
  [ "$REQUIRED" = 1 ] && { printf 'error: required Lua test root missing: %s\n' "$TEST_ROOT" >&2; exit 3; }
  printf 'skip: Lua test root not present; no Lua proof claimed\n'; exit 0
fi
if [ -z "$LUA" ]; then
  [ "$REQUIRED" = 1 ] && { printf 'error: Lua interpreter required but unavailable\n' >&2; exit 127; }
  printf 'skip: Lua interpreter unavailable; no Lua proof claimed\n'; exit 0
fi
if [ -f "$TEST_ROOT/run.lua" ]; then
  "$LUA" "$TEST_ROOT/run.lua"
  exit 0
fi
find "$TEST_ROOT" -type f -name '*_test.lua' -print | LC_ALL=C sort | while IFS= read -r test; do "$LUA" "$test"; done
if ! find "$TEST_ROOT" -type f -name '*_test.lua' -print -quit | grep . >/dev/null; then
  [ "$REQUIRED" = 1 ] && { printf 'error: required Lua tests not found\n' >&2; exit 3; }
  printf 'skip: no Lua test entrypoints discovered; no Lua proof claimed\n'
fi
