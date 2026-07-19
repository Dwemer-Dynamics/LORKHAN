#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/lib"))
from almsivi_foundation import FoundationError, read_json, validate_pin
from json_schema import SchemaError, validate

PAIRS = (
    ("config/source-pins/openmw.json", "schemas/evidence/source-pin.schema.json"),
    ("docs/evidence/source-ledger.json", "schemas/evidence/source-ledger.schema.json"),
    ("docs/evidence/component-ledger.json", "schemas/evidence/component-ledger.schema.json"),
    ("docs/evidence/proof-ledger.json", "schemas/evidence/proof-ledger.schema.json"),
)

try:
    for document, schema in PAIRS:
        validate(read_json(ROOT / document), read_json(ROOT / schema))
        print(f"valid: {document}")
    validate_pin(read_json(ROOT / "config/source-pins/openmw.json"))
except (FoundationError, SchemaError) as exc:
    print(f"error: {exc}", file=sys.stderr)
    raise SystemExit(2)
