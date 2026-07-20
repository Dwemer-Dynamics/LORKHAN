#!/usr/bin/env python3
"""Generate or verify the deterministic local protocol file manifest."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ALMSIVI = ROOT / "almsivi"
MANIFEST = ALMSIVI / "MANIFEST.json"
SUMS = ALMSIVI / "SHA256SUMS"
INCLUDED_ROOTS = (ALMSIVI / "schemas" / "v1", ALMSIVI / "fixtures" / "v1")


def canonical_json(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def source_files() -> list[Path]:
    files: list[Path] = []
    for directory in INCLUDED_ROOTS:
        files.extend(path for path in directory.rglob("*") if path.is_file())
    return sorted(files, key=lambda path: path.relative_to(ROOT).as_posix())


def build() -> tuple[bytes, bytes]:
    records = []
    sum_lines = []
    for path in source_files():
        data = path.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        relative = path.relative_to(ROOT).as_posix()
        records.append({"bytes": len(data), "path": relative, "sha256": digest})
        sum_lines.append(f"{digest}  {relative}\n")
    manifest = {
        "cross_repository_byte_parity": "locally-proven",
        "format": "almsivi.protocol-manifest.v1",
        "hash": "sha256",
        "files": records,
    }
    return canonical_json(manifest), "".join(sum_lines).encode("ascii")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail unless generated files are current")
    args = parser.parse_args()
    manifest, sums = build()
    if args.check:
        failures = []
        if not MANIFEST.exists() or MANIFEST.read_bytes() != manifest:
            failures.append(MANIFEST.relative_to(ROOT).as_posix())
        if not SUMS.exists() or SUMS.read_bytes() != sums:
            failures.append(SUMS.relative_to(ROOT).as_posix())
        if failures:
            parser.error("stale or missing generated file(s): " + ", ".join(failures))
        print(f"verified {len(source_files())} protocol files")
        return 0
    MANIFEST.write_bytes(manifest)
    SUMS.write_bytes(sums)
    print(f"generated manifest for {len(source_files())} protocol files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
