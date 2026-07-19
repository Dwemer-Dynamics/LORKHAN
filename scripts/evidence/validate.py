#!/usr/bin/env python3
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

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


def validate_proof_evidence(document: dict, root: Path = ROOT) -> None:
    row_ids: set[str] = set()
    for row in document["rows"]:
        row_id = row["id"]
        if row_id in row_ids:
            raise FoundationError(f"duplicate proof row ID: {row_id}")
        row_ids.add(row_id)
        seen: set[str] = set()
        for value in row["evidence"]:
            if value in seen:
                raise FoundationError(f"duplicate proof evidence path for {row_id}: {value}")
            seen.add(value)
            path = PurePosixPath(value)
            if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
                raise FoundationError(f"unsafe proof evidence path for {row_id}: {value}")
            target = root.joinpath(*path.parts)
            if not target.exists():
                raise FoundationError(f"proof evidence path does not exist for {row_id}: {value}")


def validate_run_bundles(root: Path = ROOT) -> None:
    runs = root / "docs/evidence/runs"
    if not runs.exists():
        return
    schema = read_json(root / "schemas/evidence/run-manifest.schema.json")
    forbidden = re.compile(r"(?:/Users/|/home/|[A-Z]:\\Users\\)")
    for directory in sorted(path for path in runs.iterdir() if path.is_dir()):
        index_path = directory / "index.json"
        if not index_path.is_file():
            raise FoundationError(f"evidence run has no index: {directory.relative_to(root)}")
        index = read_json(index_path)
        if set(index) != {"schema_version", "validation_commit", "checks", "result"} \
                or index["schema_version"] != 1 or index["result"] != "success":
            raise FoundationError(f"invalid evidence run index: {index_path.relative_to(root)}")
        commit = index["validation_commit"]
        if not isinstance(commit, str) or re.fullmatch(r"[0-9a-f]{40}", commit) is None:
            raise FoundationError(f"invalid evidence validation commit: {commit!r}")
        exists = subprocess.run(["git", "-C", str(root), "cat-file", "-e", f"{commit}^{{commit}}"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if exists.returncode:
            raise FoundationError(f"evidence validation commit does not exist: {commit}")
        checks = index["checks"]
        if not isinstance(checks, list) or not checks or len(set(checks)) != len(checks):
            raise FoundationError(f"evidence run checks must be nonempty and unique: {index_path.relative_to(root)}")
        for name in checks:
            if not isinstance(name, str) or re.fullmatch(r"[a-z0-9-]+", name) is None:
                raise FoundationError(f"unsafe evidence check name: {name!r}")
            manifest_path = directory / f"{name}.json"
            if not manifest_path.is_file():
                raise FoundationError(f"evidence manifest missing: {manifest_path.relative_to(root)}")
            manifest = read_json(manifest_path)
            validate(manifest, schema)
            if manifest["result"] != "success" or manifest["inputs"].get("validation_commit") != commit:
                raise FoundationError(f"evidence manifest result/commit mismatch: {manifest_path.relative_to(root)}")
            log_name = manifest["outputs"].get("log")
            if not isinstance(log_name, str) or PurePosixPath(log_name).name != log_name or not log_name.endswith(".txt"):
                raise FoundationError(f"unsafe evidence log reference: {manifest_path.relative_to(root)}")
            log_path = directory / log_name
            if not log_path.is_file():
                raise FoundationError(f"evidence log missing: {log_path.relative_to(root)}")
            text = log_path.read_text(encoding="utf-8")
            if forbidden.search(text):
                raise FoundationError(f"host path leaked into evidence log: {log_path.relative_to(root)}")


def main() -> int:
    try:
        for document, schema in PAIRS:
            validate(read_json(ROOT / document), read_json(ROOT / schema))
            print(f"valid: {document}")
        pin = read_json(ROOT / "config/source-pins/openmw.json")
        validate_pin(pin)
        provenance_document = read_json(ROOT / "docs/evidence/file-provenance-ledger.json")
        validate_provenance_coverage(provenance_document, required_provenance_paths())
        proof_document = read_json(ROOT / "docs/evidence/proof-ledger.json")
        validate_proof_evidence(proof_document)
        validate_run_bundles()
        provenance = {row["id"]: set(row["target_paths"]) for row in provenance_document["records"]}
        tests = {row["id"] for row in proof_document["rows"]}
        validate_manifest(ROOT / "openmw-patches", load_manifest(ROOT / "openmw-patches"), pin, provenance, tests)
    except (FoundationError, PackagingError, SchemaError, subprocess.CalledProcessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
