#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
: "${LORKHAN_CACHE_DIR:=$ROOT/.cache/lorkhan}"
: "${LORKHAN_RUN_MANIFEST:=$ROOT/.runs/prefetch.json}"
PYTHON=${PYTHON:-python3}
exec "$PYTHON" "$ROOT/scripts/bootstrap/bootstrap.py" prefetch --cache-dir "$LORKHAN_CACHE_DIR" --manifest "$LORKHAN_RUN_MANIFEST" "$@"
