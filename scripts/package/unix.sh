#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH is required}"
exec python3 "$ROOT/scripts/package/package.py" "$@"
