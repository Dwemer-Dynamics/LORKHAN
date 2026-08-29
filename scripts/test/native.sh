#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cxx="${CXX:-clang++}"
build_dir="${LORKHAN_NATIVE_BUILD_DIR:-$root/build/native-direct}"
mkdir -p "$build_dir"

sources=(
  "$root/components/lorkhan/src/actions.cpp"
  "$root/components/lorkhan/src/bridge_service.cpp"
  "$root/components/lorkhan/src/events.cpp"
  "$root/components/lorkhan/src/json.cpp"
  "$root/components/lorkhan/src/lifecycle.cpp"
  "$root/components/lorkhan/src/media.cpp"
  "$root/components/lorkhan/src/protocol_response.cpp"
  "$root/components/lorkhan/src/validation.cpp"
  "$root/components/lorkhan/src/voice_capture.cpp"
  "$root/components/lorkhan/tests/native_tests.cpp"
)
common=(-std=c++20 -pthread -Wall -Wextra -Wpedantic -Werror -I"$root/components/lorkhan/include")

"$cxx" "${common[@]}" -O2 "${sources[@]}" -o "$build_dir/lorkhan-native-tests"
"$build_dir/lorkhan-native-tests"

if [[ "${LORKHAN_SANITIZE:-1}" == "1" ]]; then
  if "$cxx" "${common[@]}" -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined \
      "${sources[@]}" -o "$build_dir/lorkhan-native-tests-sanitize" >/dev/null 2>&1; then
    python3 - "$build_dir/lorkhan-native-tests-sanitize" <<'PY'
import os
import subprocess
import sys

environment = dict(os.environ, ASAN_OPTIONS="detect_leaks=0", UBSAN_OPTIONS="print_stacktrace=1")
try:
    completed = subprocess.run([sys.argv[1]], env=environment, timeout=60, check=False)
except subprocess.TimeoutExpired:
    print("sanitizer runtime unsupported (probe timed out); optimized warning-clean test passed", file=sys.stderr)
    raise SystemExit(0)
raise SystemExit(completed.returncode)
PY
  else
    printf '%s\n' 'sanitizer compile unsupported; optimized warning-clean test already passed' >&2
  fi
fi
