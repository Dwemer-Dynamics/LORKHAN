#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/lib"))
from almsivi_foundation import read_json, sha256_file, write_json
from almsivi_packaging import (PackagingError, apply_suppressions, audit_archive_content, audit_notices,
                               audit_source_inputs, audit_tree, load_suppressions, normalized_archive_comparison,
                               tracked_implementation_paths, validate_package_set, validate_provenance, validate_spdx)


def audit(args: argparse.Namespace) -> None:
    repository = Path(args.repository).resolve()
    archive = Path(args.archive).resolve()
    policy = read_json(repository / args.policy)
    entries, findings = audit_archive_content(archive, policy[f"{args.kind}_allowlist"], policy["denylist"])
    if args.kind == "runtime":
        findings.extend(audit_notices(entries, policy["notices_required"], archive.name, sha256_file(archive)))
    else:
        findings.extend(audit_source_inputs(entries, policy["source_rebuild_required"], archive.name,
                                            sha256_file(archive)))
    if args.sbom:
        try:
            validate_spdx(read_json(Path(args.sbom)), entries)
        except PackagingError as exc:
            findings.append({"audit": "sbom", "path": Path(args.sbom).name,
                             "sha256": sha256_file(Path(args.sbom)), "message": str(exc)})
    suppressions = load_suppressions(repository / args.suppressions, policy["reviewer"])
    findings = apply_suppressions(findings, suppressions)
    result = {"schema_version": 1, "archive": archive.name, "kind": args.kind,
              "archive_sha256": sha256_file(archive), "result": "pass" if not findings else "fail",
              "findings": findings}
    if args.output:
        write_json(Path(args.output), result)
    if findings:
        raise PackagingError("; ".join(f"{item['audit']}:{item['path']}:{item['message']}" for item in findings))
    print(f"audit passed: {archive}")


def source_tree(args: argparse.Namespace) -> None:
    repository = Path(args.repository).resolve()
    findings = audit_tree(repository)
    result = {"schema_version": 1, "root": ".", "result": "pass" if not findings else "fail",
              "findings": findings}
    if args.output:
        write_json(Path(args.output), result)
    if findings:
        raise PackagingError("; ".join(f"{item['audit']}:{item['path']}:{item['message']}" for item in findings))
    print(f"source-tree audit passed: {repository} (zero findings)")


def package_set(args: argparse.Namespace) -> None:
    validate_package_set(read_json(Path(args.runtime_manifest)), read_json(Path(args.source_manifest)),
                         Path(args.runtime_archive), Path(args.source_archive))
    print("package set linkage passed")


def provenance(args: argparse.Namespace) -> None:
    repository = Path(args.repository).resolve()
    policy = read_json(repository / args.policy)
    ledger = repository / policy["provenance_ledger"] if args.ledger is None else Path(args.ledger)
    required = tracked_implementation_paths(repository)
    required.update(args.paths)
    validate_provenance(read_json(ledger), required, reject_unexpected=True)
    print("provenance passed")


def compare(args: argparse.Namespace) -> None:
    result = normalized_archive_comparison(Path(args.first), Path(args.second))
    if args.output:
        write_json(Path(args.output), result)
    if not result["normalized_equal"] or (args.require_raw and not result["raw_equal"]):
        raise PackagingError(f"reproducibility mismatch: raw={result['raw_equal']} normalized={result['normalized_equal']}")
    print(f"reproducible: raw={result['raw_equal']} normalized={result['normalized_equal']}")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Fail-closed ALMSIVI package audits")
    result.add_argument("--repository", default=str(ROOT))
    sub = result.add_subparsers(dest="command", required=True)
    one = sub.add_parser("archive")
    one.add_argument("archive")
    one.add_argument("--kind", choices=("runtime", "source"), required=True)
    one.add_argument("--policy", default="config/packaging/policy.json")
    one.add_argument("--suppressions", default="config/packaging/suppressions.json")
    one.add_argument("--sbom")
    one.add_argument("--output")
    one.set_defaults(handler=audit)
    source = sub.add_parser("source-tree")
    source.add_argument("--output")
    source.set_defaults(handler=source_tree)
    links = sub.add_parser("package-set")
    links.add_argument("runtime_archive"); links.add_argument("runtime_manifest")
    links.add_argument("source_archive"); links.add_argument("source_manifest")
    links.set_defaults(handler=package_set)
    prov = sub.add_parser("provenance")
    prov.add_argument("paths", nargs="*"); prov.add_argument("--ledger")
    prov.add_argument("--policy", default="config/packaging/policy.json")
    prov.set_defaults(handler=provenance)
    comparison = sub.add_parser("compare")
    comparison.add_argument("first"); comparison.add_argument("second")
    comparison.add_argument("--require-raw", action="store_true"); comparison.add_argument("--output")
    comparison.set_defaults(handler=compare)
    return result


if __name__ == "__main__":
    try:
        args = parser().parse_args()
        args.handler(args)
    except PackagingError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
