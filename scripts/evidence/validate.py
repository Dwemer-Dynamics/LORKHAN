#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/lib"))
from almsivi_foundation import FoundationError, read_json, validate_pin
from almsivi_packaging import PackagingError, tracked_implementation_paths, validate_provenance
from json_schema import SchemaError, validate
from openmw_patches import load_manifest, validate_manifest

PAIRS = (
    ("config/source-pins/openmw.json", "schemas/evidence/source-pin.schema.json"),
    ("docs/evidence/source-ledger.json", "schemas/evidence/source-ledger.schema.json"),
    ("docs/evidence/component-ledger.json", "schemas/evidence/component-ledger.schema.json"),
    ("docs/evidence/proof-ledger.json", "schemas/evidence/proof-ledger.schema.json"),
    ("docs/evidence/file-provenance-ledger.json", "schemas/evidence/file-provenance-ledger.schema.json"),
    ("openmw-patches/patch-manifest.json", "schemas/evidence/patch-manifest.schema.json"),
)
def required_provenance_paths(root: Path = ROOT) -> set[str]:
    try:
        return tracked_implementation_paths(root)
    except PackagingError as exc:
        raise FoundationError(str(exc)) from exc


def validate_provenance_coverage(document: dict, required: set[str]) -> None:
    try:
        validate_provenance(document, required, reject_unexpected=True)
    except PackagingError as exc:
        message = str(exc).replace("source provenance missing", "provenance coverage missing tracked implementation paths")
        message = message.replace("source provenance includes", "provenance coverage includes")
        message = message.replace("duplicate provenance target path", "provenance overlap")
        raise FoundationError(message) from exc


def main() -> int:
    try:
        for document, schema in PAIRS:
            validate(read_json(ROOT / document), read_json(ROOT / schema))
            print(f"valid: {document}")
        pin = read_json(ROOT / "config/source-pins/openmw.json")
        validate_pin(pin)
        provenance_document = read_json(ROOT / "docs/evidence/file-provenance-ledger.json")
        validate_provenance_coverage(provenance_document, required_provenance_paths())
        provenance = {row["id"]: set(row["target_paths"]) for row in provenance_document["records"]}
        tests = {row["id"] for row in read_json(ROOT / "docs/evidence/proof-ledger.json")["rows"]}
        validate_manifest(ROOT / "openmw-patches", load_manifest(ROOT / "openmw-patches"), pin, provenance, tests)
    except (FoundationError, SchemaError, subprocess.CalledProcessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
