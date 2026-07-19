"""Standard-library helpers for deterministic ALMSIVI foundation tooling."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Mapping, Sequence


class FoundationError(RuntimeError):
    pass


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise FoundationError(f"cannot read JSON {path}: {exc}") from exc


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = canonical_json(value)
    if path.exists() and path.read_bytes() == data:
        return
    path.write_bytes(data)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def run(arguments: Sequence[str], *, cwd: Path | None = None, env: Mapping[str, str] | None = None) -> str:
    try:
        completed = subprocess.run(arguments, cwd=cwd, env=env, check=True, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", "") or str(exc)
        raise FoundationError(f"command failed: {' '.join(arguments)}\n{detail.strip()}") from exc
    return completed.stdout.strip()


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        raise FoundationError(f"required tool not found: {name}")
    return path


def git_version(git: str) -> str:
    return run([git, "--version"])


def clean_git_environment() -> dict[str, str]:
    env = dict(os.environ)
    env.update({
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_OPTIONAL_LOCKS": "0",
    })
    for key in list(env):
        if key.startswith("GIT_CONFIG_KEY_") or key.startswith("GIT_CONFIG_VALUE_") or key == "GIT_CONFIG_COUNT":
            del env[key]
    return env


def validate_pin(pin: Mapping[str, Any]) -> None:
    exact = {
        "version": "0.51.0", "tag": "openmw-0.51.0",
        "commit": "f4bec41444214a7903bebd178389ca22ca13f646", "lua_api_revision": 129,
    }
    for key, wanted in exact.items():
        if pin.get(key) != wanted:
            raise FoundationError(f"wrong OpenMW {key}: expected {wanted!r}, got {pin.get(key)!r}")
    commit = pin["commit"]
    if not isinstance(commit, str) or len(commit) != 40 or any(c not in "0123456789abcdef" for c in commit):
        raise FoundationError("OpenMW commit must be a full lowercase SHA-1 object ID")


def cache_index_path(cache_dir: Path, commit: str) -> Path:
    return cache_dir / "indexes" / f"openmw-{commit}.json"


def verify_cache(cache_dir: Path, pin: Mapping[str, Any], git: str) -> tuple[Path, dict[str, Any]]:
    validate_pin(pin)
    index_path = cache_index_path(cache_dir, pin["commit"])
    if not index_path.is_file():
        raise FoundationError(f"offline cache miss: {index_path}")
    index = read_json(index_path)
    required = {"schema_version", "artifact", "sha256", "commit", "tag"}
    if not isinstance(index, dict) or set(index) != required or index.get("schema_version") != 1:
        raise FoundationError(f"invalid cache index: {index_path}")
    if index["commit"] != pin["commit"] or index["tag"] != pin["tag"]:
        raise FoundationError("cache index has the wrong source pin")
    digest = index["sha256"]
    if (not isinstance(digest, str) or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)):
        raise FoundationError("cache index has an invalid SHA-256")
    artifact = cache_dir / "objects" / "sha256" / digest[:2] / digest[2:]
    if index["artifact"] != artifact.relative_to(cache_dir).as_posix() or not artifact.is_file():
        raise FoundationError(f"offline cache miss: {artifact}")
    actual = sha256_file(artifact)
    if actual != digest:
        raise FoundationError(f"cache artifact tampered: expected {digest}, got {actual}")
    run([git, "bundle", "verify", str(artifact)], env=clean_git_environment())
    heads = run([git, "bundle", "list-heads", str(artifact)], env=clean_git_environment()).splitlines()
    refs = {parts[1]: parts[0] for line in heads if len(parts := line.split()) == 2}
    if f"refs/tags/{pin['tag']}" not in refs:
        raise FoundationError("cache bundle does not contain the pinned tag")
    with tempfile.TemporaryDirectory(prefix="almsivi-verify-") as temporary:
        repo = Path(temporary) / "verify.git"
        run([git, "init", "--bare", str(repo)], env=clean_git_environment())
        run([git, "--git-dir", str(repo), "fetch", str(artifact),
             f"refs/tags/{pin['tag']}:refs/tags/{pin['tag']}"], env=clean_git_environment())
        resolved = run([git, "--git-dir", str(repo), "rev-list", "-n", "1",
                        f"refs/tags/{pin['tag']}"], env=clean_git_environment())
    if resolved != pin["commit"]:
        raise FoundationError("cache bundle tag does not resolve to the exact pinned commit")
    return artifact, index


def ensure_empty_destination(destination: Path) -> None:
    if destination.exists():
        if not destination.is_dir() or any(destination.iterdir()):
            raise FoundationError(f"destination must not exist or must be empty: {destination}")
    else:
        destination.mkdir(parents=True)


def materialize_bundle(artifact: Path, destination: Path, pin: Mapping[str, Any], git: str) -> None:
    ensure_empty_destination(destination)
    env = clean_git_environment()
    try:
        run([git, "clone", "--no-checkout", str(artifact), str(destination)], env=env)
        run([git, "checkout", "--detach", pin["commit"]], cwd=destination, env=env)
        actual = run([git, "rev-parse", "HEAD"], cwd=destination, env=env)
        status = run([git, "status", "--porcelain=v1", "--untracked-files=all"], cwd=destination, env=env)
        if actual != pin["commit"] or status:
            raise FoundationError("materialized OpenMW source is not the pristine pinned commit")
        run([git, "remote", "remove", "origin"], cwd=destination, env=env)
    except Exception:
        shutil.rmtree(destination, ignore_errors=True)
        raise


def run_manifest(command: Sequence[str], inputs: Mapping[str, str], outputs: Mapping[str, str],
                 tools: Mapping[str, str], result: str = "success") -> dict[str, Any]:
    return {"schema_version": 1, "command": list(command), "inputs": dict(inputs),
            "outputs": dict(outputs), "result": result, "tools": dict(tools)}
