"""Deterministic ordered OpenMW patch and overlay machinery."""
from __future__ import annotations

import difflib
import hashlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any, Mapping

from almsivi_foundation import FoundationError, canonical_json, clean_git_environment, read_json, run, sha256_file

OID_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SAFE_COMPONENT_RE = re.compile(r"^[A-Za-z0-9._+@-]+$")
OPERATIONS = {"add", "modify", "delete"}


def safe_upstream_path(value: Any) -> str:
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        raise FoundationError(f"unsafe upstream path: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or value != path.as_posix() or any(part in ("", ".", "..") for part in path.parts):
        raise FoundationError(f"unsafe upstream path: {value!r}")
    if any(not SAFE_COMPONENT_RE.fullmatch(part) for part in path.parts):
        raise FoundationError(f"unsupported upstream path characters: {value!r}")
    return value


def git_blob_oid(data: bytes) -> str:
    header = f"blob {len(data)}\0".encode("ascii")
    return hashlib.sha1(header + data).hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _git_bytes(arguments: list[str], cwd: Path) -> bytes:
    try:
        completed = subprocess.run(arguments, cwd=cwd, env=clean_git_environment(), check=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", b"")
        if isinstance(detail, bytes):
            detail = detail.decode("utf-8", "replace")
        raise FoundationError(f"command failed: {' '.join(arguments)}\n{str(detail).strip()}") from exc
    return completed.stdout


def _head(repo: Path, git: str) -> str:
    return run([git, "rev-parse", "HEAD"], cwd=repo, env=clean_git_environment())


def require_pinned_head(repo: Path, commit: str, git: str, *, clean: bool) -> None:
    if not OID_RE.fullmatch(commit):
        raise FoundationError("upstream commit must be a full lowercase Git object ID")
    actual = _head(repo, git)
    if actual != commit:
        raise FoundationError(f"OpenMW base is not pinned: expected {commit}, got {actual}")
    if clean:
        status = _git_bytes([git, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"], repo)
        if status:
            raise FoundationError("OpenMW base must be clean and contain no generated, ignored, or untracked files")


def _tree_entry(repo: Path, commit: str, path: str, git: str) -> tuple[str, str] | None:
    raw = _git_bytes([git, "ls-tree", "-z", commit, "--", path], repo)
    if not raw:
        return None
    if raw.count(b"\0") != 1:
        raise FoundationError(f"ambiguous upstream tree path: {path}")
    metadata, listed = raw[:-1].split(b"\t", 1)
    if listed.decode("utf-8") != path:
        raise FoundationError(f"upstream path mismatch: {path}")
    mode, kind, oid = metadata.decode("ascii").split()
    if kind != "blob" or mode not in ("100644", "100755"):
        raise FoundationError(f"upstream path is not a regular file: {path}")
    return mode, oid


def _base_bytes(repo: Path, commit: str, path: str, git: str) -> bytes:
    return _git_bytes([git, "show", f"{commit}:{path}"], repo)


def _changed_paths(repo: Path, commit: str, git: str) -> set[str]:
    require_pinned_head(repo, commit, git, clean=False)
    tracked = _git_bytes([git, "diff", "--name-only", "-z", commit, "--"], repo)
    untracked = _git_bytes([git, "ls-files", "--others", "--exclude-standard", "-z"], repo)
    ignored = _git_bytes([git, "ls-files", "--others", "--ignored", "--exclude-standard", "-z"], repo)
    result: set[str] = set()
    for raw in (tracked, untracked, ignored):
        for item in raw.split(b"\0"):
            if item:
                result.add(safe_upstream_path(item.decode("utf-8")))
    return result


def validate_spec(spec: Mapping[str, Any], commit: str, known_provenance: Mapping[str, set[str]], known_tests: set[str]) -> list[dict[str, Any]]:
    if not isinstance(spec, dict) or set(spec) != {"schema_version", "upstream_commit", "changes"}:
        raise FoundationError("patch spec has unexpected or missing keys")
    if spec.get("schema_version") != 1 or spec.get("upstream_commit") != commit:
        raise FoundationError("patch spec does not name the exact pinned upstream commit")
    changes = spec.get("changes")
    if not isinstance(changes, list):
        raise FoundationError("patch spec changes must be an array")
    required = {"order", "path", "operation", "rationale", "subsystem", "provenance_id", "test_ids"}
    seen_paths: set[str] = set()
    seen_orders: set[int] = set()
    validated: list[dict[str, Any]] = []
    for change in changes:
        if not isinstance(change, dict) or set(change) != required:
            raise FoundationError("patch change has unexpected or missing keys")
        order = change["order"]
        path = safe_upstream_path(change["path"])
        operation = change["operation"]
        if not isinstance(order, int) or isinstance(order, bool) or order < 1 or order in seen_orders:
            raise FoundationError(f"duplicate or invalid patch order: {order!r}")
        if path in seen_paths:
            raise FoundationError(f"duplicate patch path: {path}")
        if operation not in OPERATIONS:
            raise FoundationError(f"invalid operation for {path}: {operation!r}")
        for field in ("rationale", "subsystem", "provenance_id"):
            if not isinstance(change[field], str) or not change[field].strip():
                raise FoundationError(f"missing {field} for upstream path {path}")
        tests = change["test_ids"]
        if not isinstance(tests, list) or not tests or any(not isinstance(item, str) or not item for item in tests):
            raise FoundationError(f"missing test IDs for upstream path {path}")
        if len(set(tests)) != len(tests):
            raise FoundationError(f"duplicate test IDs for upstream path {path}")
        if change["provenance_id"] not in known_provenance:
            raise FoundationError(f"unknown provenance ID for {path}: {change['provenance_id']}")
        if path not in known_provenance[change["provenance_id"]]:
            raise FoundationError(f"provenance ID {change['provenance_id']} does not declare upstream path: {path}")
        unknown_tests = sorted(set(tests) - known_tests)
        if unknown_tests:
            raise FoundationError(f"unknown test IDs for {path}: {', '.join(unknown_tests)}")
        seen_orders.add(order)
        seen_paths.add(path)
        validated.append(dict(change))
    expected = list(range(1, len(validated) + 1))
    actual = [item["order"] for item in validated]
    if actual != expected:
        raise FoundationError(f"patch orders must be unique, ascending, and contiguous: expected {expected}, got {actual}")
    return validated


def _slug(path: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", path.lower()).strip("-")
    return slug[:60] or "change"


def _unified_patch(path: str, before: bytes, after: bytes, mode: str, base_oid: str) -> bytes:
    try:
        old = before.decode("utf-8").splitlines(keepends=True)
        new = after.decode("utf-8").splitlines(keepends=True)
    except UnicodeDecodeError as exc:
        raise FoundationError(f"modified upstream file must be UTF-8 text: {path}") from exc
    if before and not before.endswith(b"\n") or after and not after.endswith(b"\n"):
        raise FoundationError(f"modified upstream text must end with a newline: {path}")
    result_oid = git_blob_oid(after)
    deleted = not after
    lines = [f"diff --git a/{path} b/{path}\n"]
    if deleted:
        lines.append(f"deleted file mode {mode}\n")
        lines.append(f"index {base_oid}..0000000000000000000000000000000000000000\n")
        tofile = "/dev/null"
    else:
        lines.append(f"index {base_oid}..{result_oid} {mode}\n")
        tofile = f"b/{path}"
    lines.extend(difflib.unified_diff(old, new, fromfile=f"a/{path}", tofile=tofile, n=3))
    return "".join(lines).encode("utf-8")


def build_artifacts(base_repo: Path, source_repo: Path, spec: Mapping[str, Any], pin: Mapping[str, Any],
                    known_provenance: Mapping[str, set[str]], known_tests: set[str], git: str) -> tuple[dict[str, Any], bytes, dict[str, bytes], dict[str, bytes]]:
    commit = pin["commit"]
    require_pinned_head(base_repo, commit, git, clean=True)
    changes = validate_spec(spec, commit, known_provenance, known_tests)
    declared = {item["path"] for item in changes}
    actual = _changed_paths(source_repo, commit, git)
    if actual != declared:
        undeclared = sorted(actual - declared)
        unchanged = sorted(declared - actual)
        details = []
        if undeclared:
            details.append(f"undeclared diffs/generated/untracked paths: {', '.join(undeclared)}")
        if unchanged:
            details.append(f"declared-but-unchanged paths: {', '.join(unchanged)}")
        raise FoundationError("; ".join(details))

    manifest_changes: list[dict[str, Any]] = []
    patches: dict[str, bytes] = {}
    overlays: dict[str, bytes] = {}
    series: list[str] = []
    for change in changes:
        path = change["path"]
        operation = change["operation"]
        entry = _tree_entry(base_repo, commit, path, git)
        candidate_path = source_repo / Path(*PurePosixPath(path).parts)
        candidate_exists = candidate_path.is_file() and not candidate_path.is_symlink()
        if candidate_path.exists() and not candidate_exists:
            raise FoundationError(f"candidate path is not a regular file: {path}")
        if operation == "add":
            if entry is not None or not candidate_exists:
                raise FoundationError(f"add operation does not match upstream/source state: {path}")
            result = candidate_path.read_bytes()
            artifact = f"overlay/{path}"
            overlays[artifact] = result
            base_blob = None
            result_sha256: str | None = sha256_bytes(result)
        else:
            if entry is None:
                raise FoundationError(f"{operation} operation has no upstream base file: {path}")
            mode, base_blob = entry
            before = _base_bytes(base_repo, commit, path, git)
            if git_blob_oid(before) != base_blob:
                raise FoundationError(f"stale base blob for upstream path: {path}")
            if operation == "modify" and not candidate_exists:
                raise FoundationError(f"modify operation deleted path: {path}")
            if operation == "delete" and candidate_path.exists():
                raise FoundationError(f"delete operation left path present: {path}")
            after = candidate_path.read_bytes() if candidate_exists else b""
            if operation == "modify" and before == after:
                raise FoundationError(f"declared-but-unchanged path: {path}")
            filename = f"patches/{change['order']:04d}-{_slug(path)}.patch"
            patch = _unified_patch(path, before, after, mode, base_blob)
            patches[filename] = patch
            series.append(filename)
            artifact = filename
            result_sha256 = sha256_bytes(after)
        artifact_bytes = overlays.get(artifact, patches.get(artifact))
        assert artifact_bytes is not None
        manifest_changes.append({
            **change,
            "base_blob": base_blob,
            "result_sha256": result_sha256,
            "artifact": artifact,
            "artifact_sha256": sha256_bytes(artifact_bytes),
        })
    manifest = {
        "schema_version": 1,
        "upstream": {"repository": pin["repository"], "tag": pin["tag"], "commit": commit},
        "series": series,
        "changes": manifest_changes,
    }
    series_data = ("\n".join(series) + ("\n" if series else "")).encode("utf-8")
    return manifest, series_data, patches, overlays


def _managed_files(root: Path) -> set[str]:
    result: set[str] = set()
    for directory in (root / "patches", root / "overlay"):
        if directory.exists():
            for path in directory.rglob("*"):
                if path.is_file() or path.is_symlink():
                    result.add(path.relative_to(root).as_posix())
    return result


def write_artifacts(root: Path, manifest: dict[str, Any], series: bytes,
                    patches: Mapping[str, bytes], overlays: Mapping[str, bytes]) -> None:
    wanted = set(patches) | set(overlays)
    for stale in _managed_files(root) - wanted:
        (root / stale).unlink()
    for relative, data in {**patches, **overlays}.items():
        destination = root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    (root / "series").write_bytes(series)
    (root / "patch-manifest.json").write_bytes(canonical_json(manifest))


def load_manifest(root: Path) -> dict[str, Any]:
    value = read_json(root / "patch-manifest.json")
    if not isinstance(value, dict):
        raise FoundationError("patch manifest must be an object")
    return value


def validate_manifest(root: Path, manifest: Mapping[str, Any], pin: Mapping[str, Any],
                      known_provenance: Mapping[str, set[str]], known_tests: set[str]) -> list[dict[str, Any]]:
    if set(manifest) != {"schema_version", "upstream", "series", "changes"} or manifest.get("schema_version") != 1:
        raise FoundationError("patch manifest has unexpected or missing keys")
    upstream = manifest["upstream"]
    expected_upstream = {"repository": pin["repository"], "tag": pin["tag"], "commit": pin["commit"]}
    if upstream != expected_upstream:
        raise FoundationError("patch manifest does not name the exact pinned upstream source")
    changes = manifest["changes"]
    spec_changes = []
    required_computed = {"base_blob", "result_sha256", "artifact", "artifact_sha256"}
    if not isinstance(changes, list):
        raise FoundationError("patch manifest changes must be an array")
    for item in changes:
        if not isinstance(item, dict) or not required_computed.issubset(item):
            raise FoundationError("patch manifest change is missing computed metadata")
        spec_changes.append({key: value for key, value in item.items() if key not in required_computed})
    validate_spec({"schema_version": 1, "upstream_commit": pin["commit"], "changes": spec_changes},
                  pin["commit"], known_provenance, known_tests)
    expected_series = [item["artifact"] for item in changes if item["operation"] != "add"]
    if manifest["series"] != expected_series or len(set(manifest["series"])) != len(manifest["series"]):
        raise FoundationError("patch series order is duplicated or does not match manifest order")
    disk_series = (root / "series").read_bytes()
    expected_series_data = ("\n".join(expected_series) + ("\n" if expected_series else "")).encode()
    if disk_series != expected_series_data:
        raise FoundationError("series file drifted from patch manifest")
    expected_files = {item["artifact"] for item in changes}
    actual_files = _managed_files(root)
    if actual_files != expected_files:
        raise FoundationError("patch/overlay layout contains missing, extra, generated, or untracked artifacts")
    for item in changes:
        path = safe_upstream_path(item["path"])
        artifact = item["artifact"]
        expected_artifact = f"overlay/{path}" if item["operation"] == "add" else f"patches/{item['order']:04d}-{_slug(path)}.patch"
        if artifact != expected_artifact:
            raise FoundationError(f"artifact path drift for upstream path: {path}")
        artifact_path = root / artifact
        if artifact_path.is_symlink() or not artifact_path.is_file() or sha256_file(artifact_path) != item["artifact_sha256"]:
            raise FoundationError(f"artifact hash mismatch or unsafe artifact: {artifact}")
        base_blob = item["base_blob"]
        result_hash = item["result_sha256"]
        if item["operation"] == "add":
            if base_blob is not None or not isinstance(result_hash, str) or not SHA256_RE.fullmatch(result_hash):
                raise FoundationError(f"invalid add hashes for {path}")
        elif item["operation"] == "modify":
            if not isinstance(base_blob, str) or not OID_RE.fullmatch(base_blob) or not isinstance(result_hash, str) or not SHA256_RE.fullmatch(result_hash):
                raise FoundationError(f"invalid modify hashes for {path}")
        elif (not isinstance(base_blob, str) or not OID_RE.fullmatch(base_blob)
              or result_hash != sha256_bytes(b"")):
            raise FoundationError(f"invalid delete hashes for {path}")
    if canonical_json(manifest) != (root / "patch-manifest.json").read_bytes():
        raise FoundationError("patch manifest is not canonical deterministic JSON")
    return list(changes)


def _apply_checked(repo: Path, patch: Path, git: str) -> None:
    for check_only in (True, False):
        arguments = [git, "apply", "--verbose", "--recount", "--whitespace=error-all"]
        if check_only:
            arguments.append("--check")
        arguments.append(str(patch))
        try:
            completed = subprocess.run(arguments, cwd=repo, env=clean_git_environment(), check=True,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        except subprocess.CalledProcessError as exc:
            raise FoundationError(f"patch does not apply exactly: {patch.name}\n{exc.stderr.strip()}") from exc
        diagnostic = f"{completed.stdout}\n{completed.stderr}".lower()
        if "offset" in diagnostic or "fuzz" in diagnostic:
            raise FoundationError(f"patch fuzz/offset rejected: {patch.name}")


def apply_series(repo: Path, root: Path, manifest: Mapping[str, Any], pin: Mapping[str, Any],
                 known_provenance: Mapping[str, set[str]], known_tests: set[str], git: str) -> None:
    require_pinned_head(repo, pin["commit"], git, clean=True)
    changes = validate_manifest(root, manifest, pin, known_provenance, known_tests)
    for change in changes:
        entry = _tree_entry(repo, pin["commit"], change["path"], git)
        actual_blob = entry[1] if entry else None
        if actual_blob != change["base_blob"]:
            raise FoundationError(f"stale base blob for upstream path: {change['path']}")
        if change["operation"] == "add":
            destination = repo / Path(*PurePosixPath(change["path"]).parts)
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists():
                raise FoundationError(f"overlay destination already exists: {change['path']}")
            shutil.copyfile(root / change["artifact"], destination)
        else:
            _apply_checked(repo, root / change["artifact"], git)
    verify_result(repo, manifest, pin, git)


def verify_result(repo: Path, manifest: Mapping[str, Any], pin: Mapping[str, Any], git: str) -> None:
    require_pinned_head(repo, pin["commit"], git, clean=False)
    changes = manifest["changes"]
    declared = {item["path"] for item in changes}
    actual = _changed_paths(repo, pin["commit"], git)
    if actual != declared:
        raise FoundationError(f"patched tree has undeclared, missing, generated, or untracked paths: actual={sorted(actual)}, declared={sorted(declared)}")
    for item in changes:
        path = repo / Path(*PurePosixPath(item["path"]).parts)
        if item["operation"] == "delete":
            if path.exists():
                raise FoundationError(f"deleted result path still exists: {item['path']}")
        else:
            if path.is_symlink() or not path.is_file():
                raise FoundationError(f"result is missing or not a regular file: {item['path']}")
            actual_hash = sha256_file(path)
            if actual_hash != item["result_sha256"]:
                raise FoundationError(f"result SHA-256 mismatch for {item['path']}: {actual_hash}")


def audit(base_repo: Path, root: Path, spec: Mapping[str, Any], manifest: Mapping[str, Any], pin: Mapping[str, Any],
          known_provenance: Mapping[str, set[str]], known_tests: set[str], git: str) -> None:
    require_pinned_head(base_repo, pin["commit"], git, clean=True)
    validate_manifest(root, manifest, pin, known_provenance, known_tests)
    with tempfile.TemporaryDirectory(prefix="almsivi-patch-audit-") as temporary:
        candidate = Path(temporary) / "openmw"
        run([git, "clone", "--quiet", "--no-hardlinks", str(base_repo), str(candidate)], env=clean_git_environment())
        run([git, "checkout", "--quiet", "--detach", pin["commit"]], cwd=candidate, env=clean_git_environment())
        apply_series(candidate, root, manifest, pin, known_provenance, known_tests, git)
        generated, series, patches, overlays = build_artifacts(base_repo, candidate, spec, pin, known_provenance, known_tests, git)
    if canonical_json(generated) != canonical_json(manifest):
        raise FoundationError("manual patch manifest drift detected")
    if series != (root / "series").read_bytes():
        raise FoundationError("manual patch series drift detected")
    expected = {**patches, **overlays}
    if set(expected) != _managed_files(root):
        raise FoundationError("manual patch/overlay layout drift detected")
    for relative, data in expected.items():
        if (root / relative).read_bytes() != data:
            raise FoundationError(f"manual patch artifact drift detected: {relative}")
