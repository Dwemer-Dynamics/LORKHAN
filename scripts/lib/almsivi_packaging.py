"""Deterministic, fail-closed ALMSIVI packaging and compliance helpers."""
from __future__ import annotations

import fnmatch
import hashlib
import json
import math
import os
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Mapping, Sequence

from almsivi_foundation import canonical_json, read_json, sha256_file, write_json


class PackagingError(RuntimeError):
    pass


EPOCH_MIN = 315532800  # ZIP's 1980-01-01 lower bound.
FILE_MODE = 0o644
EXEC_MODE = 0o755
DIR_MODE = 0o755
HEX64 = re.compile(r"^[0-9a-f]{64}$")
RELEASE_NAME = re.compile(r"^ALMSIVI-(?:OpenMW|Lua|source|symbols)-", re.IGNORECASE)
SAFE_FIXTURE_NAME = re.compile(r"^(?:fixture|test)-", re.IGNORECASE)
SOURCE_EXTENSIONS = {
    ".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx", ".lua", ".py",
    ".ps1", ".sh", ".cmake", ".json", ".toml", ".txt", ".md", ".in", ".yml", ".yaml",
}
DEFAULT_TEXT_SCAN_LIMIT = 8 * 1024 * 1024
DEFAULT_BINARY_SCAN_LIMIT = 64 * 1024 * 1024


def source_date_epoch(value: str | int | None = None) -> int:
    raw = os.environ.get("SOURCE_DATE_EPOCH") if value is None else str(value)
    if raw is None or not raw.isdigit():
        raise PackagingError("SOURCE_DATE_EPOCH must be a non-negative integer")
    epoch = int(raw)
    if epoch < EPOCH_MIN:
        raise PackagingError(f"SOURCE_DATE_EPOCH must be at least {EPOCH_MIN} for normalized ZIP timestamps")
    return epoch


def normalize_path(value: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise PackagingError("archive path must be a nonempty text value")
    value = value.replace("\\", "/")
    if value.startswith("/") or re.match(r"^[A-Za-z]:", value):
        raise PackagingError(f"absolute archive path rejected: {value}")
    path = PurePosixPath(value)
    if any(part in ("", ".", "..") for part in path.parts):
        raise PackagingError(f"unsafe archive path rejected: {value}")
    return path.as_posix()


def _mode(path: Path) -> int:
    return EXEC_MODE if path.stat().st_mode & 0o111 else FILE_MODE


def collect_tree(root: Path) -> list[tuple[str, Path, int]]:
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise PackagingError(f"input root is not a directory: {root}")
    entries: list[tuple[str, Path, int]] = []
    for parent, directories, files in os.walk(root, topdown=True, followlinks=False):
        directories.sort()
        files.sort()
        parent_path = Path(parent)
        for name in list(directories):
            path = parent_path / name
            if path.is_symlink():
                raise PackagingError(f"symlink rejected: {path}")
            if not stat.S_ISDIR(path.lstat().st_mode):
                raise PackagingError(f"special file rejected: {path}")
        for name in files:
            path = parent_path / name
            file_stat = path.lstat()
            if path.is_symlink():
                raise PackagingError(f"symlink rejected: {path}")
            if not stat.S_ISREG(file_stat.st_mode):
                raise PackagingError(f"special file rejected: {path}")
            relative = normalize_path(path.relative_to(root).as_posix())
            entries.append((relative, path, _mode(path)))
    return sorted(entries, key=lambda item: item[0].encode("utf-8"))


def content_manifest(root: Path) -> dict[str, Any]:
    files = []
    for relative, path, mode in collect_tree(root):
        files.append({"path": relative, "sha256": sha256_file(path), "size": path.stat().st_size,
                      "mode": f"{mode:04o}"})
    return {"schema_version": 1, "files": files}


def write_content_manifest(root: Path, output: Path) -> None:
    write_json(output, content_manifest(root))


def create_zip(root: Path, output: Path, epoch: int) -> None:
    timestamp = datetime.fromtimestamp(epoch, timezone.utc).timetuple()[:6]
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".tmp")
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9,
                             strict_timestamps=True) as archive:
            for relative, path, mode in collect_tree(root):
                info = zipfile.ZipInfo(relative, timestamp)
                info.create_system = 3
                info.external_attr = mode << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                info.flag_bits = 0x800
                info.extra = b""
                archive.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED,
                                 compresslevel=9)
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)


def create_tar(root: Path, output: Path, epoch: int) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".tmp")
    try:
        with tarfile.open(temporary, "w", format=tarfile.PAX_FORMAT) as archive:
            for relative, path, mode in collect_tree(root):
                info = tarfile.TarInfo(relative)
                info.size = path.stat().st_size
                info.mode = mode
                info.mtime = epoch
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                info.pax_headers = {}
                with path.open("rb") as stream:
                    archive.addfile(info, stream)
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)


def inspect_archive(path: Path) -> list[dict[str, Any]]:
    findings: list[str] = []
    entries: list[dict[str, Any]] = []
    seen: set[str] = set()
    total_size = 0
    try:
        if zipfile.is_zipfile(path):
            with zipfile.ZipFile(path) as archive:
                for info in archive.infolist():
                    raw = info.filename
                    try:
                        name = normalize_path(raw.rstrip("/"))
                    except PackagingError as exc:
                        findings.append(str(exc)); continue
                    mode = (info.external_attr >> 16) & 0xFFFF
                    kind = stat.S_IFMT(mode)
                    if info.is_dir():
                        continue
                    if kind not in (0, stat.S_IFREG):
                        findings.append(f"non-regular archive entry rejected: {raw}")
                    if name in seen:
                        findings.append(f"duplicate archive entry rejected: {name}")
                    seen.add(name)
                    if info.file_size > DEFAULT_BINARY_SCAN_LIMIT:
                        findings.append(f"archive entry exceeds size limit: {name}")
                        continue
                    total_size += info.file_size
                    if total_size > 1024 * 1024 * 1024:
                        findings.append("archive expanded size exceeds 1 GiB audit limit")
                        continue
                    data = archive.read(info)
                    entries.append({"path": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                                    "mode": f"{(mode & 0o777 or FILE_MODE):04o}"})
        elif tarfile.is_tarfile(path):
            with tarfile.open(path, "r:*") as archive:
                for info in archive.getmembers():
                    raw = info.name
                    try:
                        name = normalize_path(raw.rstrip("/"))
                    except PackagingError as exc:
                        findings.append(str(exc)); continue
                    if info.isdir():
                        continue
                    if not info.isreg():
                        findings.append(f"non-regular archive entry rejected: {raw}")
                        continue
                    if name in seen:
                        findings.append(f"duplicate archive entry rejected: {name}")
                    seen.add(name)
                    if info.size > DEFAULT_BINARY_SCAN_LIMIT:
                        findings.append(f"archive entry exceeds size limit: {name}")
                        continue
                    total_size += info.size
                    if total_size > 1024 * 1024 * 1024:
                        findings.append("archive expanded size exceeds 1 GiB audit limit")
                        continue
                    stream = archive.extractfile(info)
                    if stream is None:
                        findings.append(f"unreadable archive entry: {name}"); continue
                    data = stream.read()
                    entries.append({"path": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                                    "mode": f"{info.mode & 0o777:04o}"})
        else:
            raise PackagingError(f"unsupported archive format: {path}")
    except (OSError, zipfile.BadZipFile, tarfile.TarError) as exc:
        raise PackagingError(f"cannot inspect archive {path}: {exc}") from exc
    if findings:
        raise PackagingError("; ".join(findings))
    return sorted(entries, key=lambda item: item["path"].encode("utf-8"))


def archive_manifest(path: Path) -> dict[str, Any]:
    return {"schema_version": 1, "archive": path.name, "sha256": sha256_file(path),
            "files": inspect_archive(path)}


def sha256sums(paths: Iterable[Path]) -> bytes:
    ordered = sorted(paths, key=lambda item: item.name.encode("utf-8"))
    return "".join(f"{sha256_file(path)}  {path.name}\n" for path in ordered).encode("utf-8")


def git_commit(root: Path) -> str:
    completed = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"], check=False, text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if completed.returncode != 0 or not re.fullmatch(r"[0-9a-f]{40}", completed.stdout.strip()):
        raise PackagingError("cannot determine exact ALMSIVI commit")
    return completed.stdout.strip()


def dependency_locks(root: Path, patterns: Sequence[str]) -> list[dict[str, str]]:
    paths: set[Path] = set()
    for pattern in patterns:
        paths.update(path for path in root.glob(pattern) if path.is_file())
    if not paths:
        raise PackagingError("package set has no dependency lock files")
    return [{"path": path.relative_to(root).as_posix(), "sha256": sha256_file(path)}
            for path in sorted(paths, key=lambda item: item.relative_to(root).as_posix())]


def package_set_linkage(root: Path, policy: Mapping[str, Any]) -> dict[str, Any]:
    openmw = read_json(root / policy["openmw_pin"])
    patch = root / policy["patch_manifest"]
    if not patch.is_file():
        raise PackagingError(f"required patch manifest missing: {patch}")
    return {"almsivi_commit": git_commit(root), "openmw_commit": openmw["commit"],
            "openmw_tag": openmw["tag"], "patch_manifest_sha256": sha256_file(patch),
            "dependency_locks": dependency_locks(root, policy["dependency_lock_globs"])}


def _spdx_id(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9.-]", "-", value)
    return "SPDXRef-" + cleaned.strip("-")


def generate_spdx(name: str, namespace: str, package_version: str, files: Sequence[Mapping[str, Any]],
                  linkage: Mapping[str, Any]) -> dict[str, Any]:
    spdx_files = []
    relationships = []
    package_id = _spdx_id(name)
    for item in sorted(files, key=lambda entry: entry["path"]):
        file_id = _spdx_id("File-" + item["path"])
        spdx_files.append({"SPDXID": file_id, "fileName": "./" + item["path"],
                           "checksums": [{"algorithm": "SHA256", "checksumValue": item["sha256"]}],
                           "licenseConcluded": "NOASSERTION", "copyrightText": "NOASSERTION"})
        relationships.append({"spdxElementId": package_id, "relationshipType": "CONTAINS",
                              "relatedSpdxElement": file_id})
    return {"spdxVersion": "SPDX-2.3", "dataLicense": "CC0-1.0", "SPDXID": "SPDXRef-DOCUMENT",
            "name": name, "documentNamespace": namespace,
            "creationInfo": {"created": "1980-01-01T00:00:00Z",
                             "creators": ["Tool: ALMSIVI-stdlib-packager"]},
            "packages": [{"name": name, "SPDXID": package_id, "versionInfo": package_version,
                          "downloadLocation": "NOASSERTION", "filesAnalyzed": True,
                          "licenseConcluded": "NOASSERTION", "licenseDeclared": "NOASSERTION",
                          "copyrightText": "NOASSERTION", "comment": canonical_json(linkage).decode().strip(),
                          "externalRefs": [{"referenceCategory": "OTHER", "referenceType": "almsivi-linkage",
                                            "referenceLocator": f"almsivi-commit:{linkage.get('almsivi_commit', 'unknown')}"}]}],
            "files": spdx_files, "relationships": relationships}


def validate_spdx(document: Mapping[str, Any], expected_files: Sequence[Mapping[str, Any]] | None = None) -> None:
    required = {"spdxVersion", "dataLicense", "SPDXID", "name", "documentNamespace", "creationInfo",
                "packages", "files", "relationships"}
    missing = required - set(document)
    if missing or document.get("spdxVersion") != "SPDX-2.3" or document.get("dataLicense") != "CC0-1.0":
        raise PackagingError(f"invalid SPDX 2.3 document; missing/invalid: {sorted(missing)}")
    ids: set[str] = {"SPDXRef-DOCUMENT"}
    for package in document.get("packages", []):
        if not isinstance(package, dict) or not package.get("SPDXID") or not package.get("name"):
            raise PackagingError("invalid SPDX package")
        ids.add(package["SPDXID"])
    actual: dict[str, str] = {}
    for item in document.get("files", []):
        if not isinstance(item, dict) or not item.get("SPDXID") or not str(item.get("fileName", "")).startswith("./"):
            raise PackagingError("invalid SPDX file")
        checksums = {entry.get("algorithm"): entry.get("checksumValue") for entry in item.get("checksums", [])}
        if not HEX64.fullmatch(str(checksums.get("SHA256", ""))):
            raise PackagingError(f"missing SPDX SHA256 for {item.get('fileName')}")
        ids.add(item["SPDXID"])
        actual[item["fileName"][2:]] = checksums["SHA256"]
    for relationship in document.get("relationships", []):
        if relationship.get("spdxElementId") not in ids or relationship.get("relatedSpdxElement") not in ids:
            raise PackagingError("SPDX relationship references an unknown element")
    if expected_files is not None:
        # An SPDX document cannot include its own final checksum without a hash cycle.
        expected = {entry["path"]: entry["sha256"] for entry in expected_files
                    if entry["path"] != "sbom/almsivi.spdx.json"}
        if actual != expected:
            missing_files = sorted(set(expected) - set(actual))
            extra_files = sorted(set(actual) - set(expected))
            changed = sorted(key for key in set(actual) & set(expected) if actual[key] != expected[key])
            raise PackagingError(f"SBOM coverage mismatch: missing={missing_files}, extra={extra_files}, changed={changed}")


def match_any(path: str, patterns: Sequence[str]) -> bool:
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns)


def enforce_allowlist(entries: Sequence[Mapping[str, Any]], allow: Sequence[str], deny: Sequence[str]) -> None:
    findings = []
    for entry in entries:
        path = entry["path"]
        if match_any(path, deny):
            findings.append(f"denylisted path: {path}")
        elif not match_any(path, allow):
            findings.append(f"path not allowlisted: {path}")
    if findings:
        raise PackagingError("; ".join(findings))


def release_name_guard(name: str, root: Path, policy: Mapping[str, Any], kind: str) -> None:
    if not RELEASE_NAME.match(name):
        if not SAFE_FIXTURE_NAME.match(name):
            raise PackagingError("non-release packages must be clearly named fixture-* or test-*")
        return
    required_key = "required_source_paths" if kind == "source" else "required_product_paths"
    missing = [value for value in policy[required_key] if not (root / value).exists()]
    if kind != "source":
        missing.extend(f"corresponding source {value}" for value in policy["required_source_paths"]
                       if not (root / value).exists())
    if missing:
        raise PackagingError(f"release-named package fails closed; missing: {', '.join(missing)}")


def install_plan(entries: Sequence[Mapping[str, Any]], install_root: Path) -> dict[str, Any]:
    root = install_root.resolve()
    files = []
    for entry in entries:
        relative = normalize_path(entry["path"])
        target = root.joinpath(*PurePosixPath(relative).parts)
        if target == root or root not in target.parents:
            raise PackagingError(f"install target escapes root: {relative}")
        files.append({"path": relative, "sha256": entry["sha256"], "size": entry["size"],
                      "target": str(target)})
    return {"schema_version": 1, "install_root": str(root), "dry_run": True, "owned_files": files}


def uninstall_plan(ownership: Mapping[str, Any], install_root: Path) -> dict[str, Any]:
    root = install_root.resolve()
    if ownership.get("install_root") != str(root) or not ownership.get("dry_run"):
        raise PackagingError("ownership manifest does not match dry-run install root")
    remove = []
    for item in ownership.get("owned_files", []):
        relative = normalize_path(item.get("path", ""))
        target = root.joinpath(*PurePosixPath(relative).parts)
        if str(target) != item.get("target") or root not in target.parents:
            raise PackagingError(f"ownership target escapes install root: {relative}")
        remove.append(str(target))
    return {"schema_version": 1, "install_root": str(root), "dry_run": True,
            "remove_owned_files_only": remove}


def normalized_archive_comparison(first: Path, second: Path) -> dict[str, Any]:
    first_entries = inspect_archive(first)
    second_entries = inspect_archive(second)
    return {"raw_equal": first.read_bytes() == second.read_bytes(),
            "normalized_equal": first_entries == second_entries,
            "first_sha256": sha256_file(first), "second_sha256": sha256_file(second),
            "first_files": first_entries, "second_files": second_entries}


def shannon_entropy(value: str) -> float:
    if not value:
        return 0.0
    counts = {character: value.count(character) for character in set(value)}
    return -sum((count / len(value)) * math.log2(count / len(value)) for count in counts.values())


def load_suppressions(path: Path, reviewer: str, now: datetime | None = None) -> dict[tuple[str, str, str], Mapping[str, Any]]:
    document = read_json(path)
    if set(document) != {"schema_version", "suppressions"} or document["schema_version"] != 1:
        raise PackagingError("invalid suppression policy")
    now = now or datetime.now(timezone.utc)
    result = {}
    for item in document["suppressions"]:
        required = {"audit", "path", "sha256", "reason", "reviewer", "expires"}
        if set(item) != required or not item["reason"].strip() or item["reviewer"] != reviewer:
            raise PackagingError("suppression must be exact, reasoned, and assigned to the configured reviewer")
        normalize_path(item["path"])
        if any(character in item["path"] for character in "*?[") or not HEX64.fullmatch(item["sha256"]):
            raise PackagingError("suppression path/hash must be exact; broad exemptions are forbidden")
        try:
            expiry = datetime.strptime(item["expires"], "%Y-%m-%d").replace(tzinfo=timezone.utc)
        except ValueError as exc:
            raise PackagingError("suppression expiry must be YYYY-MM-DD") from exc
        if expiry <= now:
            raise PackagingError(f"expired suppression: {item['audit']}:{item['path']}")
        key = (item["audit"], item["path"], item["sha256"])
        if key in result:
            raise PackagingError("duplicate suppression")
        result[key] = item
    return result


def apply_suppressions(findings: Sequence[Mapping[str, str]], suppressions: Mapping[tuple[str, str, str], Any]) -> list[Mapping[str, str]]:
    used: set[tuple[str, str, str]] = set()
    remaining = []
    for finding in findings:
        key = (finding["audit"], finding["path"], finding["sha256"])
        if key in suppressions:
            used.add(key)
        else:
            remaining.append(finding)
    unused = set(suppressions) - used
    if unused:
        raise PackagingError(f"stale or unmatched suppressions: {sorted(unused)}")
    return remaining


def extract_archive(path: Path, destination: Path) -> None:
    entries = inspect_archive(path)  # validates all names and entry types before any write.
    expected = {entry["path"]: entry for entry in entries}
    destination.mkdir(parents=True, exist_ok=False)
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                if info.is_dir(): continue
                name = normalize_path(info.filename)
                target = destination.joinpath(*PurePosixPath(name).parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(info))
                target.chmod(int(expected[name]["mode"], 8))
    else:
        with tarfile.open(path, "r:*") as archive:
            for info in archive.getmembers():
                if not info.isreg(): continue
                name = normalize_path(info.name)
                target = destination.joinpath(*PurePosixPath(name).parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                stream = archive.extractfile(info)
                if stream is None: raise PackagingError(f"unreadable entry: {name}")
                target.write_bytes(stream.read())
                target.chmod(int(expected[name]["mode"], 8))


def write_release_manifest(path: Path, name: str, kind: str, epoch: int, archive: Path,
                           linkage: Mapping[str, Any], content: Sequence[Mapping[str, Any]]) -> None:
    write_json(path, {"schema_version": 1, "name": name, "kind": kind,
                      "source_date_epoch": epoch, "archive_sha256": sha256_file(archive),
                      "linkage": linkage, "files": list(content)})


SECRET_PATTERNS = (
    ("private-key", re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    ("provider-key", re.compile(rb"(?i)(?:api[_-]?key|access[_-]?token|client[_-]?secret|pairing[_-]?token)\s*[:=]\s*['\"]?[A-Za-z0-9_./+=-]{12,}")),
    ("aws-key", re.compile(rb"AKIA[0-9A-Z]{16}")),
    ("github-token", re.compile(rb"gh[opusr]_[A-Za-z0-9]{30,}")),
)
PROPRIETARY_NAMES = re.compile(r"(?i)(?:^|/)(?:morrowind|tribunal|bloodmoon)\.(?:esm|bsa)$")
PROHIBITED_EXTENSIONS = {".esm", ".esp", ".bsa", ".ba2", ".omwsave", ".ess", ".sav", ".nif",
                         ".dds", ".tga", ".bmp", ".wav", ".mp3", ".ogg", ".flac", ".webm",
                         ".mp4", ".avi", ".mov", ".jpg", ".jpeg", ".png"}
PRIVACY_PATTERNS = (
    re.compile(rb"(?i)(?:/Users/|/home/|[A-Z]:\\Users\\)[A-Za-z0-9_.-]+"),
    re.compile(rb"(?i)(?:username|user_name|home_dir)\s*[:=]\s*['\"]?[A-Za-z0-9_.-]+"),
)


def _finding(audit: str, path: str, digest: str, message: str) -> dict[str, str]:
    return {"audit": audit, "path": path, "sha256": digest, "message": message}


def audit_bytes(path: str, data: bytes, digest: str | None = None) -> list[dict[str, str]]:
    digest = digest or hashlib.sha256(data).hexdigest()
    lower = path.lower()
    suffix = PurePosixPath(lower).suffix
    findings: list[dict[str, str]] = []
    if len(data) > DEFAULT_BINARY_SCAN_LIMIT:
        findings.append(_finding("archive-limits", path, digest, "file exceeds binary audit size limit"))
        return findings
    for label, pattern in SECRET_PATTERNS:
        if pattern.search(data):
            findings.append(_finding("secrets", path, digest, label))
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        text = ""
    if text and len(data) <= DEFAULT_TEXT_SCAN_LIMIT:
        for token in re.findall(r"[A-Za-z0-9+/=_-]{32,}", text):
            classes = sum(bool(re.search(pattern, token)) for pattern in (r"[a-z]", r"[A-Z]", r"[0-9]"))
            if classes >= 3 and shannon_entropy(token) >= 4.25 and not HEX64.fullmatch(token.lower()):
                findings.append(_finding("secrets", path, digest, "high-entropy token"))
                break
    if PROPRIETARY_NAMES.search(lower) or suffix in PROHIBITED_EXTENSIONS:
        findings.append(_finding("proprietary-data", path, digest, f"prohibited game/media/asset extension or master name: {suffix}"))
    if data[:4] in (b"TES3", b"BSA\x00", b"BSA\x01") or data[:8] == b"TES3\x00\x00\x00\x00":
        findings.append(_finding("proprietary-data", path, digest, "TES3/BSA binary signature"))
    if any(pattern.search(data) for pattern in PRIVACY_PATTERNS):
        findings.append(_finding("privacy", path, digest, "host path or username"))
    path_parts = set(PurePosixPath(lower).parts)
    if path_parts & {"cache", ".cache", "logs", "log", "dumps", "saves", "profiles", "userdata"} or suffix in {".log", ".dmp", ".core"}:
        findings.append(_finding("privacy", path, digest, "cache/log/dump/save/profile path"))
    return findings


def audit_tree(root: Path) -> list[dict[str, str]]:
    findings: list[dict[str, str]] = []
    for relative, path, _ in collect_tree(root):
        data = path.read_bytes()
        findings.extend(audit_bytes(relative, data))
    return findings


def audit_archive_content(path: Path, allow: Sequence[str], deny: Sequence[str]) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    entries = inspect_archive(path)
    findings: list[dict[str, str]] = []
    try:
        enforce_allowlist(entries, allow, deny)
    except PackagingError as exc:
        findings.append(_finding("archive-allowlist", path.name, sha256_file(path), str(exc)))
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                if not info.is_dir():
                    name = normalize_path(info.filename)
                    findings.extend(audit_bytes(name, archive.read(info)))
    else:
        with tarfile.open(path, "r:*") as archive:
            for info in archive.getmembers():
                if info.isreg():
                    stream = archive.extractfile(info)
                    if stream is not None:
                        findings.extend(audit_bytes(normalize_path(info.name), stream.read()))
    return entries, findings


def audit_notices(entries: Sequence[Mapping[str, Any]], required: Sequence[str], archive_name: str,
                  archive_digest: str) -> list[dict[str, str]]:
    paths = {entry["path"] for entry in entries}
    missing = [path for path in required if path not in paths]
    return [] if not missing else [_finding("gpl-notices", archive_name, archive_digest,
                                           f"missing notices/SBOM: {', '.join(missing)}")]


def audit_source_inputs(entries: Sequence[Mapping[str, Any]], required: Sequence[str], archive_name: str,
                        archive_digest: str) -> list[dict[str, str]]:
    paths = {entry["path"] for entry in entries}
    missing = [path for path in required if path not in paths]
    return [] if not missing else [_finding("corresponding-source", archive_name, archive_digest,
                                           f"missing rebuild inputs: {', '.join(missing)}")]


def validate_provenance(document: Mapping[str, Any], source_paths: Iterable[str]) -> None:
    if set(document) != {"schema_version", "files"} or document["schema_version"] != 1:
        raise PackagingError("invalid provenance ledger")
    records: dict[str, Mapping[str, Any]] = {}
    required = {"path", "origin", "source_repository", "source_commit", "source_path", "license",
                "copyright_notice", "transformation", "reviewer"}
    for record in document["files"]:
        if set(record) != required or record["path"] in records:
            raise PackagingError("provenance records must be unique and complete")
        normalize_path(record["path"])
        if record["origin"] not in {"original", "copied", "modified", "concept-only"}:
            raise PackagingError(f"invalid provenance origin: {record['path']}")
        if not all(str(record[key] or "").strip() for key in ("license", "copyright_notice", "transformation", "reviewer")):
            raise PackagingError(f"incomplete provenance: {record['path']}")
        if record["origin"] in {"copied", "modified"} and not all(record[key] for key in ("source_repository", "source_commit", "source_path")):
            raise PackagingError(f"import provenance missing exact source: {record['path']}")
        records[record["path"]] = record
    missing = sorted(set(source_paths) - set(records))
    if missing:
        raise PackagingError(f"source provenance missing: {missing}")


def validate_package_set(runtime_manifest: Mapping[str, Any], source_manifest: Mapping[str, Any],
                         runtime_archive: Path, source_archive: Path) -> None:
    required = {"almsivi_commit", "openmw_commit", "openmw_tag", "patch_manifest_sha256", "dependency_locks"}
    runtime_link = runtime_manifest.get("linkage", {})
    source_link = source_manifest.get("linkage", {})
    if set(runtime_link) != required or runtime_link != source_link:
        raise PackagingError("runtime/source package linkage is incomplete or mismatched")
    if runtime_manifest.get("archive_sha256") != sha256_file(runtime_archive):
        raise PackagingError("runtime archive does not match release manifest")
    if source_manifest.get("archive_sha256") != sha256_file(source_archive):
        raise PackagingError("source archive does not match release manifest")
    if not runtime_link["dependency_locks"] or not all(HEX64.fullmatch(item.get("sha256", "")) for item in runtime_link["dependency_locks"]):
        raise PackagingError("dependency locks are absent or incomplete")
