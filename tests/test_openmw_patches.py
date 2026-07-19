from __future__ import annotations

import copy
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/lib"))
from almsivi_foundation import FoundationError, canonical_json
from openmw_patches import (apply_series, audit, build_artifacts, git_blob_oid, safe_upstream_path,
                            validate_manifest, validate_spec, verify_result, write_artifacts)


class OpenMWPatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.temp = Path(self.temporary.name)
        self.git = shutil.which("git")
        if not self.git:
            self.skipTest("git is required")
        self.base = self.temp / "base"
        self.command(self.git, "init", str(self.base))
        self.command(self.git, "-C", str(self.base), "config", "user.name", "Fixture")
        self.command(self.git, "-C", str(self.base), "config", "user.email", "fixture@example.invalid")
        (self.base / "modify.txt").write_text("alpha\nbeta\ngamma\n", encoding="utf-8")
        (self.base / "delete.txt").write_text("delete me\n", encoding="utf-8")
        self.command(self.git, "-C", str(self.base), "add", ".")
        environment = {**os.environ, "GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z"}
        subprocess.run([self.git, "-C", str(self.base), "commit", "-m", "base"], check=True, env=environment,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.commit = self.command(self.git, "-C", str(self.base), "rev-parse", "HEAD").stdout.strip()
        self.pin = {"repository": "https://example.invalid/openmw.git", "tag": "fixture", "commit": self.commit}
        self.provenance = {"original": {"modify.txt", "delete.txt", "new/dir/add.txt"}}
        self.tests = {"patch-machinery"}
        self.root = self.temp / "artifacts"
        (self.root / "patches").mkdir(parents=True)
        (self.root / "overlay").mkdir(parents=True)

    def tearDown(self):
        self.temporary.cleanup()

    def command(self, *args, check=True):
        return subprocess.run(args, check=check, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})

    def clone(self, name="candidate"):
        destination = self.temp / name
        self.command(self.git, "clone", "--quiet", str(self.base), str(destination))
        self.command(self.git, "-C", str(destination), "checkout", "--quiet", "--detach", self.commit)
        return destination

    def change(self, order, path, operation):
        return {"order": order, "path": path, "operation": operation, "rationale": f"exercise {operation}",
                "subsystem": "fixture", "provenance_id": "original", "test_ids": ["patch-machinery"]}

    def fixture(self, operations=("modify", "delete", "add")):
        source = self.clone("edited")
        changes = []
        order = 1
        if "modify" in operations:
            (source / "modify.txt").write_text("alpha\nchanged\ngamma\n", encoding="utf-8")
            changes.append(self.change(order, "modify.txt", "modify")); order += 1
        if "delete" in operations:
            (source / "delete.txt").unlink()
            changes.append(self.change(order, "delete.txt", "delete")); order += 1
        if "add" in operations:
            (source / "new/dir").mkdir(parents=True)
            (source / "new/dir/add.txt").write_text("new file\n", encoding="utf-8")
            changes.append(self.change(order, "new/dir/add.txt", "add")); order += 1
        spec = {"schema_version": 1, "upstream_commit": self.commit, "changes": changes}
        artifacts = build_artifacts(self.base, source, spec, self.pin, self.provenance, self.tests, self.git)
        write_artifacts(self.root, *artifacts)
        return source, spec, artifacts[0]

    def test_zero_patch_state_validates_and_applies(self):
        spec = {"schema_version": 1, "upstream_commit": self.commit, "changes": []}
        artifacts = build_artifacts(self.base, self.clone("empty-edit"), spec, self.pin,
                                    self.provenance, self.tests, self.git)
        write_artifacts(self.root, *artifacts)
        validate_manifest(self.root, artifacts[0], self.pin, self.provenance, self.tests)
        destination = self.clone("empty-apply")
        apply_series(destination, self.root, artifacts[0], self.pin, self.provenance, self.tests, self.git)
        self.assertEqual(self.command(self.git, "-C", str(destination), "status", "--porcelain").stdout, "")

    def test_generate_apply_verify_audit_add_modify_delete(self):
        _, spec, manifest = self.fixture()
        self.assertEqual([item["operation"] for item in manifest["changes"]], ["modify", "delete", "add"])
        self.assertEqual(len(manifest["series"]), 2)
        destination = self.clone("apply")
        apply_series(destination, self.root, manifest, self.pin, self.provenance, self.tests, self.git)
        verify_result(destination, manifest, self.pin, self.git)
        self.assertEqual((destination / "new/dir/add.txt").read_text(), "new file\n")
        self.assertFalse((destination / "delete.txt").exists())
        audit(self.base, self.root, spec, manifest, self.pin, self.provenance, self.tests, self.git)

    def test_rejects_undeclared_and_declared_unchanged_paths(self):
        source = self.clone("mismatch")
        (source / "modify.txt").write_text("unexpected\n", encoding="utf-8")
        spec = {"schema_version": 1, "upstream_commit": self.commit,
                "changes": [self.change(1, "delete.txt", "delete")]}
        with self.assertRaisesRegex(FoundationError, "undeclared.*declared-but-unchanged"):
            build_artifacts(self.base, source, spec, self.pin, self.provenance, self.tests, self.git)

    def test_rejects_duplicate_path_order_and_gaps(self):
        for changes, message in (
            ([self.change(1, "modify.txt", "modify"), self.change(1, "delete.txt", "delete")], "order"),
            ([self.change(1, "modify.txt", "modify"), self.change(2, "modify.txt", "delete")], "path"),
            ([self.change(2, "modify.txt", "modify")], "orders"),
        ):
            with self.subTest(message=message), self.assertRaises(FoundationError):
                validate_spec({"schema_version": 1, "upstream_commit": self.commit, "changes": changes},
                              self.commit, self.provenance, self.tests)

    def test_rejects_path_traversal_absolute_backslash_and_bad_metadata(self):
        for path in ("../outside", "/absolute", "a/../../outside", "a\\b", "a//b"):
            with self.subTest(path=path), self.assertRaises(FoundationError):
                safe_upstream_path(path)
        bad = self.change(1, "modify.txt", "modify")
        for field, value in (("rationale", ""), ("subsystem", ""), ("provenance_id", "missing"), ("test_ids", [])):
            change = dict(bad); change[field] = value
            with self.subTest(field=field), self.assertRaises(FoundationError):
                validate_spec({"schema_version": 1, "upstream_commit": self.commit, "changes": [change]},
                              self.commit, self.provenance, self.tests)

    def test_rejects_wrong_or_dirty_base_and_generated_files(self):
        dirty = self.clone("dirty")
        (dirty / "generated.tmp").write_text("generated", encoding="utf-8")
        spec = {"schema_version": 1, "upstream_commit": self.commit, "changes": []}
        with self.assertRaisesRegex(FoundationError, "clean"):
            build_artifacts(dirty, self.clone("source-clean"), spec, self.pin,
                            self.provenance, self.tests, self.git)
        wrong_pin = dict(self.pin); wrong_pin["commit"] = "0" * 40
        with self.assertRaisesRegex(FoundationError, "not pinned"):
            build_artifacts(self.base, self.clone("wrong-pin"), spec, wrong_pin,
                            self.provenance, self.tests, self.git)

    def test_rejects_stale_base_blob_and_hash_or_manifest_drift(self):
        _, spec, manifest = self.fixture(("modify",))
        stale = copy.deepcopy(manifest)
        stale["changes"][0]["base_blob"] = "0" * 40
        (self.root / "patch-manifest.json").write_bytes(canonical_json(stale))
        with self.assertRaisesRegex(FoundationError, "stale base blob"):
            apply_series(self.clone("stale"), self.root, stale, self.pin, self.provenance, self.tests, self.git)
        artifact = self.root / manifest["changes"][0]["artifact"]
        artifact.write_bytes(artifact.read_bytes() + b"# drift\n")
        with self.assertRaisesRegex(FoundationError, "artifact hash mismatch"):
            validate_manifest(self.root, manifest, self.pin, self.provenance, self.tests)
        source = self.clone("edited-again")
        (source / "modify.txt").write_text("alpha\nchanged\ngamma\n", encoding="utf-8")
        spec = {"schema_version": 1, "upstream_commit": self.commit,
                "changes": [self.change(1, "modify.txt", "modify")]}
        artifacts = build_artifacts(self.base, source, spec, self.pin, self.provenance, self.tests, self.git)
        write_artifacts(self.root, *artifacts)
        manifest = artifacts[0]
        drift = copy.deepcopy(manifest); drift["changes"][0]["rationale"] = "manual drift"
        (self.root / "patch-manifest.json").write_bytes(canonical_json(drift))
        with self.assertRaisesRegex(FoundationError, "manual patch manifest drift"):
            audit(self.base, self.root, spec, drift, self.pin, self.provenance, self.tests, self.git)

    def test_rejects_untracked_or_generated_result(self):
        _, _, manifest = self.fixture(("modify",))
        destination = self.clone("result-extra")
        apply_series(destination, self.root, manifest, self.pin, self.provenance, self.tests, self.git)
        (destination / "generated.log").write_text("generated", encoding="utf-8")
        with self.assertRaisesRegex(FoundationError, "undeclared"):
            verify_result(destination, manifest, self.pin, self.git)
        (destination / "generated.log").unlink()
        (destination / ".git/info/exclude").write_text("generated.log\n", encoding="utf-8")
        (destination / "generated.log").write_text("generated", encoding="utf-8")
        with self.assertRaisesRegex(FoundationError, "undeclared"):
            verify_result(destination, manifest, self.pin, self.git)

    def test_rejects_patch_offset(self):
        _, _, manifest = self.fixture(("modify",))
        destination = self.clone("offset")
        # Preserve the declared base blob in HEAD but alter the worktree so git apply would use an offset.
        (destination / "modify.txt").write_text("preamble\nalpha\nbeta\ngamma\n", encoding="utf-8")
        with self.assertRaisesRegex(FoundationError, "clean|exactly|offset"):
            apply_series(destination, self.root, manifest, self.pin, self.provenance, self.tests, self.git)

    def test_blob_oid_matches_git(self):
        data = b"fixture\n"
        process = subprocess.run([self.git, "hash-object", "--stdin"], input=data, check=True,
                                 stdout=subprocess.PIPE)
        self.assertEqual(git_blob_oid(data), process.stdout.decode().strip())


if __name__ == "__main__":
    unittest.main()
