#!/usr/bin/env python3
from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/lib"))
from almsivi_foundation import canonical_json, read_json, write_json
from almsivi_packaging import (PackagingError, archive_manifest, content_manifest, create_tar, create_zip,
                               enforce_allowlist, generate_spdx, install_plan, package_set_linkage,
                               release_name_guard, sha256sums, source_date_epoch, uninstall_plan,
                               validate_spdx, write_release_manifest)


def package(args: argparse.Namespace) -> None:
    root = Path(args.repository).resolve()
    input_root = Path(args.input).resolve()
    output_dir = Path(args.output_dir).resolve()
    policy = read_json(root / args.policy)
    epoch = source_date_epoch(args.epoch)
    release_name_guard(args.name, root, policy, args.kind)
    manifest = content_manifest(input_root)
    enforce_allowlist(manifest["files"], policy[f"{args.kind}_allowlist"], policy["denylist"])
    linkage = package_set_linkage(root, policy)
    suffix = ".zip" if args.format == "zip" else ".tar"
    output_dir.mkdir(parents=True, exist_ok=True)
    archive = output_dir / f"{args.name}{suffix}"
    namespace = f"https://almsivi.invalid/spdx/{linkage['almsivi_commit']}/{args.name}"
    sbom = generate_spdx(args.name, namespace, args.version, manifest["files"], linkage)
    validate_spdx(sbom, manifest["files"])
    with tempfile.TemporaryDirectory(prefix="almsivi-package-") as temporary:
        stage = Path(temporary) / "stage"
        shutil.copytree(input_root, stage, symlinks=True)
        write_json(stage / "sbom/almsivi.spdx.json", sbom)
        staged_manifest = content_manifest(stage)
        enforce_allowlist(staged_manifest["files"], policy[f"{args.kind}_allowlist"], policy["denylist"])
        if args.format == "zip":
            create_zip(stage, archive, epoch)
        else:
            create_tar(stage, archive, epoch)
    archive_doc = archive_manifest(archive)
    write_json(output_dir / f"{args.name}.content-manifest.json", {"schema_version": 1, "files": archive_doc["files"]})
    write_release_manifest(output_dir / f"{args.name}.release-manifest.json", args.name, args.kind,
                           epoch, archive, linkage, archive_doc["files"])
    write_json(output_dir / f"{args.name}.spdx.json", sbom)
    files = [archive, output_dir / f"{args.name}.content-manifest.json",
             output_dir / f"{args.name}.release-manifest.json", output_dir / f"{args.name}.spdx.json"]
    if args.kind == "source":
        source_manifest = output_dir / f"{args.name}.source-manifest.json"
        write_json(source_manifest, {"schema_version": 1, "archive": archive.name,
                                     "archive_sha256": archive_doc["sha256"], "linkage": linkage,
                                     "rebuild_inputs": policy["source_rebuild_required"],
                                     "files": archive_doc["files"]})
        files.append(source_manifest)
    (output_dir / "SHA256SUMS").write_bytes(sha256sums(files))
    print(archive)


def ownership(args: argparse.Namespace) -> None:
    archive = Path(args.archive).resolve()
    from almsivi_packaging import inspect_archive
    plan = install_plan(inspect_archive(archive), Path(args.install_root))
    uninstall = uninstall_plan(plan, Path(args.install_root))
    document = {"install": plan, "uninstall": uninstall}
    if args.output:
        write_json(Path(args.output), document)
    else:
        sys.stdout.buffer.write(canonical_json(document))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Deterministic ALMSIVI package builder")
    sub = result.add_subparsers(dest="command", required=True)
    build = sub.add_parser("build")
    build.add_argument("--repository", default=str(ROOT))
    build.add_argument("--policy", default="config/packaging/policy.json")
    build.add_argument("--input", required=True)
    build.add_argument("--output-dir", required=True)
    build.add_argument("--name", required=True)
    build.add_argument("--version", required=True)
    build.add_argument("--kind", choices=("runtime", "source"), required=True)
    build.add_argument("--format", choices=("zip", "tar"), required=True)
    build.add_argument("--epoch", default=None)
    build.set_defaults(handler=package)
    own = sub.add_parser("ownership-dry-run")
    own.add_argument("archive")
    own.add_argument("install_root")
    own.add_argument("--output")
    own.set_defaults(handler=ownership)
    return result


if __name__ == "__main__":
    try:
        arguments = parser().parse_args()
        arguments.handler(arguments)
    except PackagingError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
