#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
: "${ALMSIVI_CACHE_DIR:=$ROOT/.cache/almsivi}"
: "${ALMSIVI_SOURCE_DIR:=$ROOT/.work/openmw}"
: "${ALMSIVI_RUN_MANIFEST:=$ROOT/.runs/bootstrap.json}"
PYTHON=${PYTHON:-python3}
exec "$PYTHON" "$ROOT/scripts/bootstrap/bootstrap.py" bootstrap --cache-dir "$ALMSIVI_CACHE_DIR" --source-dir "$ALMSIVI_SOURCE_DIR" --manifest "$ALMSIVI_RUN_MANIFEST" "$@"
