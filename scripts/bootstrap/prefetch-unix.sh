#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
: "${ALMSIVI_CACHE_DIR:=$ROOT/.cache/almsivi}"
: "${ALMSIVI_RUN_MANIFEST:=$ROOT/.runs/prefetch.json}"
PYTHON=${PYTHON:-python3}
exec "$PYTHON" "$ROOT/scripts/bootstrap/bootstrap.py" prefetch --cache-dir "$ALMSIVI_CACHE_DIR" --manifest "$ALMSIVI_RUN_MANIFEST" "$@"
