#!/usr/bin/env python3
"""Prefetch or offline-materialize the exact OpenMW source pin."""
from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "lib"))

from almsivi_foundation import (FoundationError, cache_index_path, canonical_json, clean_git_environment,
                               git_version, materialize_bundle, read_json, require_tool, run, run_manifest,
                               sha256_file, validate_pin, verify_cache, write_json)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("mode", choices=("prefetch", "bootstrap"))
    result.add_argument("--pin", type=Path, default=ROOT / "config/source-pins/openmw.json")
    result.add_argument("--cache-dir", type=Path, required=True)
    result.add_argument("--source-dir", type=Path)
    result.add_argument("--manifest", type=Path, required=True)
    result.add_argument("--repository", help="override repository only for controlled tests/mirrors")
    return result


def prefetch(pin: dict, cache_dir: Path, repository: str, git: str) -> tuple[Path, dict]:
    validate_pin(pin)
    cache_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="almsivi-prefetch-") as temporary:
        repo = Path(temporary) / "openmw.git"
        env = clean_git_environment()
        run([git, "init", "--bare", str(repo)], env=env)
        run([git, "--git-dir", str(repo), "fetch", "--no-tags", repository,
             f"refs/tags/{pin['tag']}:refs/tags/{pin['tag']}"], env=env)
        actual = run([git, "--git-dir", str(repo), "rev-list", "-n", "1", f"refs/tags/{pin['tag']}"], env=env)
        if actual != pin["commit"]:
            raise FoundationError(f"remote tag returned wrong commit: {actual}")
        provisional = Path(temporary) / "openmw.bundle"
        run([git, "--git-dir", str(repo), "bundle", "create", str(provisional),
             f"refs/tags/{pin['tag']}"], env=env)
        digest = sha256_file(provisional)
        artifact = cache_dir / "objects" / "sha256" / digest[:2] / digest[2:]
        artifact.parent.mkdir(parents=True, exist_ok=True)
        if artifact.exists() and sha256_file(artifact) != digest:
            raise FoundationError(f"existing content-addressed object is corrupt: {artifact}")
        if not artifact.exists():
            provisional.replace(artifact)
    index = {"schema_version": 1, "artifact": artifact.relative_to(cache_dir).as_posix(),
             "sha256": digest, "commit": pin["commit"], "tag": pin["tag"]}
    write_json(cache_index_path(cache_dir, pin["commit"]), index)
    return verify_cache(cache_dir, pin, git)


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    command = [str(Path(__file__).resolve()), *(argv if argv is not None else sys.argv[1:])]
    try:
        pin = read_json(args.pin.resolve())
        git = require_tool("git")
        if args.mode == "prefetch":
            artifact, index = prefetch(pin, args.cache_dir.resolve(), args.repository or pin["repository"], git)
            outputs = {"cache_artifact": str(artifact), "cache_sha256": index["sha256"]}
        else:
            if args.repository:
                raise FoundationError("--repository is not accepted by strict offline bootstrap")
            if args.source_dir is None:
                raise FoundationError("bootstrap requires --source-dir")
            artifact, index = verify_cache(args.cache_dir.resolve(), pin, git)
            destination = args.source_dir.resolve()
            materialize_bundle(artifact, destination, pin, git)
            outputs = {"source_dir": str(destination), "source_commit": pin["commit"],
                       "cache_sha256": index["sha256"]}
        manifest = run_manifest(command, {"pin_file": str(args.pin.resolve()), "pin_commit": pin["commit"]},
                                outputs, {"python": sys.version.split()[0], "git": git_version(git)})
        write_json(args.manifest.resolve(), manifest)
        print(canonical_json(manifest).decode("utf-8"), end="")
        return 0
    except FoundationError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
