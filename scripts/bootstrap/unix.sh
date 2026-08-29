#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
: "${LORKHAN_CACHE_DIR:=$ROOT/.cache/lorkhan}"
: "${LORKHAN_SOURCE_DIR:=$ROOT/.work/openmw}"
: "${LORKHAN_RUN_MANIFEST:=$ROOT/.runs/bootstrap.json}"
PYTHON=${PYTHON:-python3}
exec "$PYTHON" "$ROOT/scripts/bootstrap/bootstrap.py" bootstrap --cache-dir "$LORKHAN_CACHE_DIR" --source-dir "$LORKHAN_SOURCE_DIR" --manifest "$LORKHAN_RUN_MANIFEST" "$@"
