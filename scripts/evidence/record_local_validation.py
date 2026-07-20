#!/usr/bin/env python3
"""Record durable, path-sanitized no-game validation evidence for one clean commit."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUN_SCHEMA = ROOT / "schemas/evidence/run-manifest.schema.json"


class RecordingError(RuntimeError):
    pass


def canonical(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def git(*arguments: str) -> str:
    completed = subprocess.run(["git", "-C", str(ROOT), *arguments], check=True, text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return completed.stdout.strip()


def tool_version(command: list[str]) -> str:
    completed = subprocess.run(command, check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    first = completed.stdout.splitlines()[0] if completed.stdout else "unavailable"
    return first.strip()


def add_replacement(replacements: dict[str, str], path: Path | str, label: str) -> None:
    lexical = os.path.abspath(os.fspath(path))
    resolved = os.path.realpath(lexical)
    replacements[lexical] = label
    replacements[resolved] = label


def sanitize(text: str, replacements: dict[str, str]) -> str:
    for raw, replacement in sorted(replacements.items(), key=lambda item: len(item[0]), reverse=True):
        text = text.replace(raw, replacement)
    return text


def record(name: str, command: list[str], output: Path, commit: str,
           replacements: dict[str, str], tools: dict[str, str]) -> dict[str, object]:
    completed = subprocess.run(command, cwd=ROOT, check=False, text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1", "TZ": "UTC", "LANG": "C", "LC_ALL": "C"})
    log = sanitize(completed.stdout, replacements)
    log_path = output / f"{name}.txt"
    log_path.write_text(log, encoding="utf-8")
    if completed.returncode:
        raise RecordingError(f"{name} failed with exit {completed.returncode}; see {log_path}")
    manifest = {
        "schema_version": 1,
        "command": [sanitize(value, replacements) for value in command],
        "inputs": {"validation_commit": commit},
        "outputs": {"log": log_path.name, "log_lines": str(len(log.splitlines()))},
        "result": "success",
        "tools": tools,
    }
    (output / f"{name}.json").write_bytes(canonical(manifest))
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cache-dir", type=Path, help="verified OpenMW cache for an optional strict offline reconstruction")
    args = parser.parse_args()

    if git("status", "--porcelain"):
        raise RecordingError("validation evidence must be recorded from a clean worktree")
    commit = git("rev-parse", "HEAD")
    final_output = args.output.resolve()
    if final_output.exists():
        raise RecordingError(f"output path already exists: {final_output}")

    tools = {"python": sys.version.split()[0], "git": tool_version(["git", "--version"])}
    clang = shutil.which("clang++")
    if clang:
        tools["clang++"] = tool_version([clang, "--version"])

    commands: list[tuple[str, list[str]]] = [
        ("native", [str(ROOT / "scripts/test/native.sh")]),
        ("python-tests", [sys.executable, "-m", "unittest", "discover", "-s", str(ROOT / "tests"), "-v"]),
        ("loopback-tests", [sys.executable, "-m", "unittest", "discover", "-s", str(ROOT / "almsivi/tests"), "-v"]),
        ("lua-structural", [sys.executable, str(ROOT / "almsivi/tests/run.py")]),
        ("evidence", [sys.executable, str(ROOT / "scripts/evidence/validate.py")]),
        ("protocol", [sys.executable, str(ROOT / "scripts/protocol/validate.py")]),
        ("protocol-manifest", [sys.executable, str(ROOT / "scripts/protocol/generate_manifest.py"), "--check"]),
        ("patch-manifest", [sys.executable, str(ROOT / "scripts/patches/openmw.py"), "validate"]),
        ("ci-static", [str(ROOT / "scripts/test/validate-ci.sh")]),
        ("source-audit", [str(ROOT / "scripts/audit/package.sh"), "source-tree"]),
        ("provenance", [sys.executable, str(ROOT / "scripts/audit/package_audit.py"), "--repository", str(ROOT), "provenance"]),
    ]
    with tempfile.TemporaryDirectory(prefix="almsivi-validation-evidence-") as staging_root:
        output = Path(staging_root) / "run"
        output.mkdir()
        replacements: dict[str, str] = {}
        add_replacement(replacements, ROOT, "$REPOSITORY")
        add_replacement(replacements, output, "$EVIDENCE_OUTPUT")
        add_replacement(replacements, final_output, "$EVIDENCE_OUTPUT")
        add_replacement(replacements, sys.executable, "$PYTHON")
        manifests: dict[str, dict[str, object]] = {}
        for name, command in commands:
            manifests[name] = record(name, command, output, commit, replacements, tools)

        if args.cache_dir:
            cache = args.cache_dir.resolve()
            add_replacement(replacements, cache, "$OPENMW_CACHE")
            with tempfile.TemporaryDirectory(prefix="almsivi-evidence-openmw-") as temporary:
                source = Path(temporary) / "openmw"
                raw_manifest = Path(temporary) / "bootstrap.json"
                add_replacement(replacements, source, "$OPENMW_SOURCE")
                add_replacement(replacements, raw_manifest, "$RAW_RUN_MANIFEST")
                command = [sys.executable, str(ROOT / "scripts/bootstrap/bootstrap.py"), "bootstrap",
                           "--cache-dir", str(cache), "--source-dir", str(source), "--manifest", str(raw_manifest)]
                manifests["offline-bootstrap"] = record("offline-bootstrap", command, output, commit, replacements, tools)
                raw = json.loads(raw_manifest.read_text(encoding="utf-8"))
                manifests["offline-bootstrap"]["outputs"].update({
                    "source_commit": raw["outputs"]["source_commit"],
                    "cache_sha256": raw["outputs"]["cache_sha256"],
                })
                (output / "offline-bootstrap.json").write_bytes(canonical(manifests["offline-bootstrap"]))

        index = {
            "schema_version": 1,
            "validation_commit": commit,
            "checks": sorted(manifests),
            "result": "success",
        }
        (output / "index.json").write_bytes(canonical(index))
        final_output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(output, final_output)
    print(f"recorded {len(manifests)} checks for {commit} in {final_output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RecordingError, subprocess.CalledProcessError, KeyError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
