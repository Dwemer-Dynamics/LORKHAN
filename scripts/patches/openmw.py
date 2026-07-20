#!/usr/bin/env python3
"""Generate, apply, verify, and audit the exact-pin OpenMW patch series."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/lib"))

from almsivi_foundation import FoundationError, read_json, require_tool, validate_pin
from openmw_patches import (apply_series, audit, build_artifacts, load_manifest, validate_manifest,
                            verify_result, write_artifacts)

PATCH_ROOT = ROOT / "openmw-patches"


def ids(path: Path, key: str) -> set[str]:
    value = read_json(path)
    rows = value[key]
    return {row["id"] for row in rows}


def provenance_paths(path: Path) -> dict[str, set[str]]:
    return {row["id"]: set(row["target_paths"]) for row in read_json(path)["records"]}


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    sub = result.add_subparsers(dest="command", required=True)
    generate = sub.add_parser("generate", help="generate canonical artifacts from an exact-pin edited tree")
    generate.add_argument("--base", type=Path, required=True)
    generate.add_argument("--source", type=Path, required=True)
    apply = sub.add_parser("apply", help="apply the declared series to a pristine exact-pin tree")
    apply.add_argument("--source", type=Path, required=True)
    verify = sub.add_parser("verify", help="verify a patched source tree")
    verify.add_argument("--source", type=Path, required=True)
    audit_parser = sub.add_parser("audit", help="rebuild and compare all tracked patch metadata")
    audit_parser.add_argument("--base", type=Path, required=True)
    sub.add_parser("validate", help="validate tracked manifests and artifact hashes")
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        git = require_tool("git")
        pin = read_json(ROOT / "config/source-pins/openmw.json")
        validate_pin(pin)
        provenance = provenance_paths(ROOT / "docs/evidence/file-provenance-ledger.json")
        tests = ids(ROOT / "docs/evidence/proof-ledger.json", "rows")
        spec = read_json(PATCH_ROOT / "patch-spec.json")
        if args.command == "generate":
            generated = build_artifacts(args.base.resolve(), args.source.resolve(), spec, pin,
                                        provenance, tests, git)
            write_artifacts(PATCH_ROOT, *generated)
        else:
            manifest = load_manifest(PATCH_ROOT)
            if args.command == "apply":
                apply_series(args.source.resolve(), PATCH_ROOT, manifest, pin, provenance, tests, git)
            elif args.command == "verify":
                validate_manifest(PATCH_ROOT, manifest, pin, provenance, tests)
                verify_result(args.source.resolve(), manifest, pin, git)
            elif args.command == "audit":
                audit(args.base.resolve(), PATCH_ROOT, spec, manifest, pin, provenance, tests, git)
            else:
                validate_manifest(PATCH_ROOT, manifest, pin, provenance, tests)
        print(f"OpenMW patch {args.command}: success")
        return 0
    except (FoundationError, OSError, KeyError, TypeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
