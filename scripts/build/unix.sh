#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

usage() {
  cat <<'EOF'
Usage: unix.sh --state control|patched [options] [-- <extra CMake configure arguments>]
  --source DIR       source root (required; LORKHAN_SOURCE_DIR)
  --build DIR        build root (required; LORKHAN_BUILD_DIR)
  --install DIR      install root (required; LORKHAN_INSTALL_DIR)
  --output DIR       logs/manifests root (required; LORKHAN_OUTPUT_DIR)
  --config NAME      Debug, RelWithDebInfo, or Release (default: RelWithDebInfo)
  --compiler NAME    gcc or clang (default: gcc)
  --target NAME      build target (optional)
  --test-target NAME required declared test target; omitted means CTest discovery
  --expected-pin SHA exact pristine upstream commit (default: pinned OpenMW commit)
  --epoch SECONDS    SOURCE_DATE_EPOCH (default: fixed foundation epoch)
  --generator NAME   CMake generator (default: Ninja)
EOF
}

STATE=${LORKHAN_PATCH_STATE:-}
SOURCE=${LORKHAN_SOURCE_DIR:-}
BUILD=${LORKHAN_BUILD_DIR:-}
INSTALL=${LORKHAN_INSTALL_DIR:-}
OUTPUT=${LORKHAN_OUTPUT_DIR:-}
CONFIG=${LORKHAN_BUILD_CONFIG:-RelWithDebInfo}
COMPILER=${LORKHAN_COMPILER:-gcc}
TARGET=${LORKHAN_BUILD_TARGET:-}
TEST_TARGET=${LORKHAN_REQUIRED_TEST_TARGET:-}
PIN=${LORKHAN_EXPECTED_PIN:-f4bec41444214a7903bebd178389ca22ca13f646}
EPOCH=${SOURCE_DATE_EPOCH:-1784442566}
GENERATOR=${LORKHAN_GENERATOR:-Ninja}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --state) STATE=$2; shift 2 ;;
    --source) SOURCE=$2; shift 2 ;;
    --build) BUILD=$2; shift 2 ;;
    --install) INSTALL=$2; shift 2 ;;
    --output) OUTPUT=$2; shift 2 ;;
    --config) CONFIG=$2; shift 2 ;;
    --compiler) COMPILER=$2; shift 2 ;;
    --target) TARGET=$2; shift 2 ;;
    --test-target) TEST_TARGET=$2; shift 2 ;;
    --expected-pin) PIN=$2; shift 2 ;;
    --epoch) EPOCH=$2; shift 2 ;;
    --generator) GENERATOR=$2; shift 2 ;;
    --) shift; break ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$STATE" in control|patched) ;; *) printf 'error: --state must be control or patched\n' >&2; exit 2 ;; esac
case "$CONFIG" in Debug|RelWithDebInfo|Release) ;; *) printf 'error: unsupported configuration: %s\n' "$CONFIG" >&2; exit 2 ;; esac
case "$COMPILER" in gcc) CC=${CC:-gcc}; CXX=${CXX:-g++} ;; clang) CC=${CC:-clang}; CXX=${CXX:-clang++} ;; *) printf 'error: --compiler must be gcc or clang\n' >&2; exit 2 ;; esac
for value in SOURCE BUILD INSTALL OUTPUT; do eval "path=\$$value"; [ -n "$path" ] || { printf 'error: %s root is required\n' "$value" >&2; exit 2; }; done
for tool in git cmake "$CC" "$CXX"; do command -v "$tool" >/dev/null 2>&1 || { printf 'error: required tool missing: %s\n' "$tool" >&2; exit 127; }; done
[ -d "$SOURCE/.git" ] || { printf 'error: source is not a git work tree: %s\n' "$SOURCE" >&2; exit 2; }

HEAD=$(git -C "$SOURCE" rev-parse HEAD)
[ "$HEAD" = "$PIN" ] || { printf 'error: expected pin %s, found %s\n' "$PIN" "$HEAD" >&2; exit 2; }
STATUS=$(git -C "$SOURCE" status --porcelain=v1 --untracked-files=all)
if [ "$STATE" = control ] && [ -n "$STATUS" ]; then printf 'error: control source is not pristine\n%s\n' "$STATUS" >&2; exit 2; fi
if [ "$STATE" = patched ] && [ -z "$STATUS" ]; then printf 'error: patched state declared but source has no changes\n' >&2; exit 2; fi

mkdir -p "$BUILD" "$INSTALL" "$OUTPUT"
SOURCE=$(CDPATH= cd -- "$SOURCE" && pwd)
BUILD=$(CDPATH= cd -- "$BUILD" && pwd)
INSTALL=$(CDPATH= cd -- "$INSTALL" && pwd)
OUTPUT=$(CDPATH= cd -- "$OUTPUT" && pwd)
case "$BUILD/" in "$SOURCE/"*) printf 'error: build root must be outside source root\n' >&2; exit 2 ;; esac
case "$INSTALL/" in "$SOURCE/"*) printf 'error: install root must be outside source root\n' >&2; exit 2 ;; esac

export SOURCE_DATE_EPOCH=$EPOCH TZ=UTC LC_ALL=C LANG=C
export CC CXX
MAP="-ffile-prefix-map=$SOURCE=/usr/src/lorkhan -fdebug-prefix-map=$SOURCE=/usr/src/lorkhan -ffile-prefix-map=$BUILD=/usr/src/lorkhan-build -fdebug-prefix-map=$BUILD=/usr/src/lorkhan-build"
export CFLAGS="${CFLAGS:+$CFLAGS }$MAP"
export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }$MAP"
export LDFLAGS="${LDFLAGS:-}"

LOG=$OUTPUT/build-$STATE-$COMPILER-$CONFIG.log
MANIFEST=$OUTPUT/build-$STATE-$COMPILER-$CONFIG.txt
COMMAND_LOG=$OUTPUT/.command-$$.log
trap 'rm -f "$COMMAND_LOG"' EXIT HUP INT TERM
run_logged() {
  if "$@" > "$COMMAND_LOG" 2>&1; then code=0; else code=$?; fi
  tee -a "$LOG" < "$COMMAND_LOG"
  rm -f "$COMMAND_LOG"
  return "$code"
}
: > "$LOG"
{
  printf 'state=%s\nconfig=%s\ncompiler=%s\nsource=%s\nbuild=%s\ninstall=%s\npin=%s\nepoch=%s\n' "$STATE" "$CONFIG" "$COMPILER" "$SOURCE" "$BUILD" "$INSTALL" "$PIN" "$EPOCH"
  printf 'status_begin\n%s\nstatus_end\n' "$STATUS"
  cmake --version | sed -n '1p'
  "$CC" --version | sed -n '1p'
} > "$MANIFEST"

if [ "$STATE" = patched ]; then set -- -DLORKHAN_SOURCE_ROOT="$ROOT" "$@"; fi
run_logged cmake -S "$SOURCE" -B "$BUILD" -G "$GENERATOR" -DCMAKE_BUILD_TYPE="$CONFIG" -DCMAKE_INSTALL_PREFIX="$INSTALL" -DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_CXX_FLAGS="$CXXFLAGS" "$@"
if [ -n "$TARGET" ]; then run_logged cmake --build "$BUILD" --config "$CONFIG" --target "$TARGET"; else run_logged cmake --build "$BUILD" --config "$CONFIG"; fi
if [ -n "$TEST_TARGET" ]; then
  cmake --build "$BUILD" --config "$CONFIG" --target help > "$OUTPUT/targets.txt"
  grep -F "$TEST_TARGET" "$OUTPUT/targets.txt" >/dev/null || { printf 'error: declared required target missing: %s\n' "$TEST_TARGET" >&2; exit 3; }
  run_logged cmake --build "$BUILD" --config "$CONFIG" --target "$TEST_TARGET"
elif command -v ctest >/dev/null 2>&1; then
  COUNT=$(ctest --test-dir "$BUILD" -C "$CONFIG" -N 2>/dev/null | sed -n 's/^Total Tests: //p')
  if [ -n "$COUNT" ] && [ "$COUNT" -gt 0 ]; then run_logged ctest --test-dir "$BUILD" -C "$CONFIG" --output-on-failure; else printf 'note: no CTest tests discovered; no test proof claimed\n' | tee -a "$LOG"; fi
fi
run_logged cmake --install "$BUILD" --config "$CONFIG"
