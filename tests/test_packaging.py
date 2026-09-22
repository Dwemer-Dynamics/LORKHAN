from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
import warnings
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/lib"))
from lorkhan_foundation import read_json
from lorkhan_packaging import (PackagingError, apply_suppressions, archive_manifest, audit_archive_content,
                               audit_bytes, audit_notices, audit_source_inputs, audit_tree, collect_source_tree,
                               collect_tree, content_manifest,
                               create_tar, create_zip, generate_spdx, install_plan, load_suppressions,
                               normalized_archive_comparison, package_set_linkage, release_name_guard,
                               sha256sums, source_date_epoch, tracked_implementation_paths, uninstall_plan, validate_package_set,
                               validate_provenance, validate_spdx)

EPOCH = 1700000000


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.temp = Path(self.temporary.name)
        self.policy = read_json(ROOT / "config/packaging/policy.json")

    def tearDown(self):
        self.temporary.cleanup()

    def tree(self) -> Path:
        root = self.temp / "tree"
        (root / "bin").mkdir(parents=True)
        (root / "docs").mkdir()
        executable = root / "bin/lorkhan"
        executable.write_bytes(b"fixture executable\n")
        executable.chmod(0o755)
        (root / "docs/README.txt").write_bytes(b"fixture docs\n")
        return root

    def repository_fixture(self, *, commit: bool = True) -> Path:
        repository = self.temp / "repository"
        repository.mkdir()
        tracked = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "--cached", "--others", "--exclude-standard"],
            check=True, text=True, stdout=subprocess.PIPE).stdout.splitlines()
        for relative in tracked:
            source = ROOT / relative
            target = repository / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        subprocess.run(["git", "init", "-q", str(repository)], check=True)
        subprocess.run(["git", "-C", str(repository), "add", "-f", "--", *tracked], check=True)
        if commit:
            subprocess.run(["git", "-C", str(repository), "-c", "user.name=Fixture", "-c",
                            "user.email=fixture@invalid", "commit", "-qm", "fixture"], check=True)
        return repository

    def test_epoch_is_required_and_bounded(self):
        old = os.environ.pop("SOURCE_DATE_EPOCH", None)
        try:
            with self.assertRaises(PackagingError): source_date_epoch()
            with self.assertRaises(PackagingError): source_date_epoch("1")
            self.assertEqual(source_date_epoch(str(EPOCH)), EPOCH)
        finally:
            if old is not None: os.environ["SOURCE_DATE_EPOCH"] = old

    def test_zip_is_byte_reproducible_and_normalized(self):
        root = self.tree()
        first, second = self.temp / "first.zip", self.temp / "second.zip"
        create_zip(root, first, EPOCH)
        os.utime(root / "docs/README.txt", (EPOCH + 500, EPOCH + 500))
        create_zip(root, second, EPOCH)
        comparison = normalized_archive_comparison(first, second)
        self.assertTrue(comparison["raw_equal"])
        self.assertTrue(comparison["normalized_equal"])
        with zipfile.ZipFile(first) as archive:
            self.assertEqual(archive.namelist(), sorted(archive.namelist()))
            self.assertEqual((archive.getinfo("bin/lorkhan").external_attr >> 16) & 0o777, 0o755)

    def test_tar_is_byte_reproducible_and_normalized(self):
        root = self.tree()
        first, second = self.temp / "first.tar", self.temp / "second.tar"
        create_tar(root, first, EPOCH); create_tar(root, second, EPOCH)
        self.assertTrue(normalized_archive_comparison(first, second)["raw_equal"])
        with tarfile.open(first) as archive:
            item = archive.getmember("docs/README.txt")
            self.assertEqual((item.uid, item.gid, item.uname, item.gname, item.mtime, item.mode),
                             (0, 0, "root", "root", EPOCH, 0o644))

    @unittest.skipUnless(hasattr(os, "symlink"), "symlinks unavailable")
    def test_symlink_rejected(self):
        root = self.tree()
        os.symlink(root / "docs/README.txt", root / "docs/link")
        with self.assertRaisesRegex(PackagingError, "symlink rejected"):
            collect_tree(root)

    def test_archive_traversal_and_special_entries_rejected(self):
        traversal = self.temp / "traversal.zip"
        with zipfile.ZipFile(traversal, "w") as archive: archive.writestr("../escape", b"bad")
        with self.assertRaisesRegex(PackagingError, "unsafe archive path"):
            archive_manifest(traversal)
        symlink = self.temp / "symlink.zip"
        with zipfile.ZipFile(symlink, "w") as archive:
            info = zipfile.ZipInfo("link"); info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(info, "target")
        with self.assertRaisesRegex(PackagingError, "non-regular"):
            archive_manifest(symlink)
        duplicate = self.temp / "duplicate.zip"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(duplicate, "w") as archive:
                archive.writestr("same.txt", b"one")
                archive.writestr("same.txt", b"two")
        with self.assertRaisesRegex(PackagingError, "duplicate"):
            archive_manifest(duplicate)

    def test_manifest_sums_and_spdx_cover_every_file(self):
        root = self.tree()
        manifest = content_manifest(root)
        sbom = generate_spdx("fixture-runtime", "https://lorkhan.invalid/test", "0", manifest["files"],
                             {"lorkhan_commit": "a" * 40})
        validate_spdx(sbom, manifest["files"])
        sbom["files"][0]["checksums"][0]["checksumValue"] = "0" * 64
        with self.assertRaisesRegex(PackagingError, "coverage mismatch"):
            validate_spdx(sbom, manifest["files"])
        one = self.temp / "b"; two = self.temp / "a"
        one.write_bytes(b"b"); two.write_bytes(b"a")
        self.assertEqual(sha256sums([one, two]).decode().splitlines()[0].split("  ")[1], "a")

    def test_release_names_fail_closed_but_fixture_names_are_safe(self):
        stage = self.temp / "stage"; stage.mkdir()
        release_name_guard("fixture-runtime", ROOT, stage, self.policy, "runtime")
        with self.assertRaisesRegex(PackagingError, "clearly named"):
            release_name_guard("candidate-runtime", ROOT, stage, self.policy, "runtime")
        with self.assertRaisesRegex(PackagingError, "release-named package fails closed"):
            release_name_guard("LORKHAN-OpenMW-0.1-windows-x64", ROOT, stage, self.policy, "runtime")
        with self.assertRaisesRegex(PackagingError, "release-named package fails closed"):
            release_name_guard("LORKHAN-source-0.1", ROOT, stage, self.policy, "source")
        with self.assertRaisesRegex(PackagingError, "release-named package fails closed"):
            release_name_guard("LORKHAN-Lua-0.1", ROOT, stage, self.policy, "runtime")

    def test_provenance_scope_includes_untracked_implementation_files(self):
        repository = self.repository_fixture()
        untracked = repository / "components/lorkhan/src/untracked.cpp"
        untracked.parent.mkdir(parents=True, exist_ok=True)
        untracked.write_text("// original fixture\n")
        self.assertIn("components/lorkhan/src/untracked.cpp", tracked_implementation_paths(repository))

    def test_package_linkage_uses_commit_pin_patch_hash_and_locks(self):
        linkage = package_set_linkage(ROOT, self.policy)
        self.assertRegex(linkage["lorkhan_commit"], r"^[0-9a-f]{40}$")
        self.assertEqual(linkage["openmw_commit"], "f4bec41444214a7903bebd178389ca22ca13f646")
        self.assertRegex(linkage["patch_manifest_sha256"], r"^[0-9a-f]{64}$")
        self.assertRegex(linkage["provenance_ledger_sha256"], r"^[0-9a-f]{64}$")
        self.assertTrue(linkage["dependency_locks"])

    def test_missing_tampered_patch_manifest_and_provenance_fail_linkage(self):
        repository = self.repository_fixture()
        policy = read_json(repository / "config/packaging/policy.json")
        patch = repository / policy["patch_manifest"]
        original_patch = patch.read_bytes()
        patch.unlink()
        with self.assertRaisesRegex(PackagingError, "patch manifest missing"):
            package_set_linkage(repository, policy)
        patch.parent.mkdir(parents=True, exist_ok=True); patch.write_bytes(original_patch)
        document = read_json(patch); document["upstream"]["commit"] = "0" * 40
        patch.write_text(json.dumps(document), encoding="utf-8")
        with self.assertRaisesRegex(PackagingError, "drifted"):
            package_set_linkage(repository, policy)
        patch.write_bytes(original_patch)
        provenance = repository / policy["provenance_ledger"]
        original_provenance = provenance.read_bytes()
        provenance.unlink()
        with self.assertRaisesRegex(PackagingError, "provenance ledger missing"):
            package_set_linkage(repository, policy)
        provenance.write_bytes(original_provenance)
        document = read_json(provenance); document["records"][0]["reviewer"] = ""
        provenance.write_text(json.dumps(document), encoding="utf-8")
        with self.assertRaisesRegex(PackagingError, "incomplete provenance"):
            package_set_linkage(repository, policy)

    def test_package_linkage_and_cli_reject_incomplete_tracked_provenance(self):
        repository = self.repository_fixture()
        policy = read_json(repository / "config/packaging/policy.json")
        provenance = repository / policy["provenance_ledger"]
        document = read_json(provenance)
        removed = document["records"][0]["target_paths"].pop()
        provenance.write_text(json.dumps(document), encoding="utf-8")
        with self.assertRaisesRegex(PackagingError, "source provenance missing"):
            package_set_linkage(repository, policy)
        command = subprocess.run(
            [sys.executable, str(repository / "scripts/audit/package_audit.py"),
             "--repository", str(repository), "provenance"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(command.returncode, 2)
        self.assertIn(removed, command.stderr)

    def test_release_guard_rechecks_authoritative_inputs_after_stage_is_complete(self):
        repository = self.repository_fixture(commit=False)
        policy = read_json(repository / "config/packaging/policy.json")
        stage = self.temp / "release-stage"
        for relative in policy["required_product_paths"]["runtime"] + policy["required_corresponding_source_paths"]:
            target = stage / relative; target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("fixture prerequisite\n", encoding="utf-8")
        with self.assertRaisesRegex(PackagingError, "cannot determine exact LORKHAN commit"):
            release_name_guard("LORKHAN-OpenMW-0.1-windows-x64", repository, stage, policy, "runtime")
        (repository / policy["patch_manifest"]).unlink()
        with self.assertRaisesRegex(PackagingError, "authoritative repository input"):
            release_name_guard("LORKHAN-OpenMW-0.1-windows-x64", repository, stage, policy, "runtime")

    def test_install_uninstall_dry_run_owns_only_archive_files(self):
        entries = content_manifest(self.tree())["files"]
        plan = install_plan(entries, self.temp / "install")
        uninstall = uninstall_plan(plan, self.temp / "install")
        self.assertEqual(len(uninstall["remove_owned_files_only"]), len(entries))
        tampered = json.loads(json.dumps(plan)); tampered["owned_files"][0]["target"] = "/outside"
        with self.assertRaises(PackagingError): uninstall_plan(tampered, self.temp / "install")

    def test_every_content_audit_has_a_seeded_canary_and_clean_fixture(self):
        clean = audit_bytes("docs/clean.txt", b"ordinary authored fixture text")
        self.assertEqual(clean, [])
        provider_canary = b"api" + b"_key=" + b"Ab9Kz7Qw2Rt5" + b"Yu8Io1Pa4Sd6Fg0Hj3Kl"
        master_name = "Morrow" + "ind." + "esm"
        tes_signature = b"TE" + b"S3" + b"x" * 16
        bsa_signature = b"BS" + b"A" + bytes((0,)) + b"x" * 16
        host_path = b"/" + b"Users" + b"/alice/private/file"
        entropy_canary = b"Qp7Zx2Vm9Ka4Rt8Y" + b"u3Wd6Hs1Nj5Lc0Bg"
        cases = {
            "secrets": ("config/provider.txt", provider_canary),
            "proprietary-extension": ("data/" + master_name, b"fixture"),
            "tes3-signature": ("data/blob.bin", tes_signature),
            "bsa-signature": ("data/blob.bin", bsa_signature),
            "privacy": ("docs/path.txt", host_path),
            "cache": ("cache/result.bin", b"fixture"),
            "high-entropy": ("config/value.txt", entropy_canary),
        }
        expected = {"secrets": "secrets", "proprietary-extension": "proprietary-data",
                    "tes3-signature": "proprietary-data", "bsa-signature": "proprietary-data",
                    "privacy": "privacy", "cache": "privacy", "high-entropy": "secrets"}
        for name, (path, data) in cases.items():
            audits = {item["audit"] for item in audit_bytes(path, data)}
            self.assertIn(expected[name], audits, name)

    def test_source_tree_audit_excludes_vcs_and_generated_roots_only(self):
        source = self.temp / "source"; source.mkdir()
        (source / "src").mkdir(); (source / "src/clean.py").write_text("value = 1\n", encoding="utf-8")
        (source / ".git").write_text("gitdir: /" + "Users" + "/operator/worktree\n", encoding="utf-8")
        for generated in ("build", "build-debug", ".cache", ".runs", ".work", "dist", "engine"):
            directory = source / generated; directory.mkdir()
            (directory / "generated.txt").write_text("/" + "Users" + "/generated/path\n", encoding="utf-8")
        self.assertEqual(audit_tree(source), [])
        collected = {item[0] for item in collect_source_tree(source)}
        self.assertEqual(collected, {"src/clean.py"})
        (source / "src/path.txt").write_text("/" + "Users" + "/outside/git\n", encoding="utf-8")
        findings = audit_tree(source)
        self.assertEqual({item["audit"] for item in findings}, {"privacy"})
        self.assertEqual(findings[0]["path"], "src/path.txt")

    def test_archive_collection_does_not_exclude_vcs_metadata(self):
        stage = self.temp / "stage"; stage.mkdir()
        (stage / ".git").write_text("gitdir: /" + "Users" + "/operator/worktree\n", encoding="utf-8")
        self.assertIn(".git", {item[0] for item in collect_tree(stage)})
        archive = self.temp / "fixture-vcs.zip"; create_zip(stage, archive, EPOCH)
        _, findings = audit_archive_content(archive, ["*"], [])
        self.assertIn("privacy", {item["audit"] for item in findings})

    def test_archive_allowlist_notices_and_source_input_canaries(self):
        root = self.tree()
        archive = self.temp / "fixture-runtime.zip"; create_zip(root, archive, EPOCH)
        _, findings = audit_archive_content(archive, self.policy["runtime_allowlist"], self.policy["denylist"])
        self.assertEqual(findings, [])
        entries = archive_manifest(archive)["files"]
        self.assertTrue(audit_notices(entries, self.policy["notices_required"], archive.name,
                                      hashlib.sha256(archive.read_bytes()).hexdigest()))
        self.assertTrue(audit_source_inputs(entries, self.policy["source_rebuild_required"], archive.name,
                                            hashlib.sha256(archive.read_bytes()).hexdigest()))
        bad = self.temp / "fixture-bad.zip"
        with zipfile.ZipFile(bad, "w") as z: z.writestr("unknown/file.xyz", b"x")
        self.assertIn("archive-allowlist", {x["audit"] for x in audit_archive_content(
            bad, self.policy["runtime_allowlist"], self.policy["denylist"])[1]})

        # Development-only files belong in source archives, never player packages.
        dev = self.temp / "fixture-development.zip"
        with zipfile.ZipFile(dev, "w") as z:
            z.writestr("lorkhan/files/scripts/LORKHAN/tests/run.lua", b"-- fixture")
            z.writestr("docs/archive/CLAUDEX-TASK.md", b"Historical task")
        runtime_denies = self.policy["denylist"] + self.policy["runtime_denylist"]
        self.assertTrue(audit_archive_content(dev, self.policy["runtime_allowlist"], runtime_denies)[1])
        self.assertEqual(audit_archive_content(dev, self.policy["source_allowlist"], self.policy["denylist"])[1], [])

    def test_reviewed_resource_requires_exact_bytes_and_keeps_signature_checks(self):
        archive = self.temp / "resource.zip"
        path = "bin/resources/menu.png"
        data = b"upstream fixture image"
        assets = {path: hashlib.sha256(data).hexdigest()}
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr(path, data)
        self.assertEqual(audit_archive_content(archive, ["bin/*"], ["*.png"], assets)[1], [])
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr(path, data + b"changed")
        self.assertTrue(audit_archive_content(archive, ["bin/*"], ["*.png"], assets)[1])
        data = b"TE" + b"S3" + b"fixture"
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr(path, data)
        findings = audit_archive_content(archive, ["bin/*"], ["*.png"], {path: hashlib.sha256(data).hexdigest()})[1]
        self.assertTrue(any(item["message"] == "TES3/BSA binary signature" for item in findings))

    def test_provenance_completeness_canary(self):
        ledger = read_json(ROOT / self.policy["provenance_ledger"])
        recorded = [path for item in ledger["records"] for path in item["target_paths"]]
        validate_provenance(ledger, recorded)
        with self.assertRaisesRegex(PackagingError, "provenance missing"):
            validate_provenance(ledger, ["unrecorded/file.py"])
        drifted = json.loads(json.dumps(ledger)); drifted["records"][0]["reviewer"] = ""
        with self.assertRaisesRegex(PackagingError, "incomplete provenance"):
            validate_provenance(drifted, [])

    def test_suppressions_are_exact_hashed_reasoned_reviewed_and_expiring(self):
        digest = "a" * 64
        policy = {"schema_version": 1, "suppressions": [{"audit": "secrets", "path": "config/x.txt",
                  "sha256": digest, "reason": "Known deterministic test value", "reviewer": self.policy["reviewer"],
                  "expires": "2099-01-01"}]}
        path = self.temp / "suppressions.json"; path.write_text(json.dumps(policy))
        loaded = load_suppressions(path, self.policy["reviewer"], datetime(2026, 1, 1, tzinfo=timezone.utc))
        self.assertEqual(apply_suppressions([{"audit":"secrets","path":"config/x.txt","sha256":digest,"message":"x"}], loaded), [])
        policy["suppressions"][0]["path"] = "config/**"
        path.write_text(json.dumps(policy))
        with self.assertRaisesRegex(PackagingError, "broad exemptions"):
            load_suppressions(path, self.policy["reviewer"])
        policy["suppressions"][0]["path"] = "config/x.txt"; policy["suppressions"][0]["expires"] = "2020-01-01"
        path.write_text(json.dumps(policy))
        with self.assertRaisesRegex(PackagingError, "expired"):
            load_suppressions(path, self.policy["reviewer"])

    def test_cli_builds_source_manifest_and_checksums(self):
        stage = self.temp / "source"
        for relative in self.policy["source_rebuild_required"]:
            target = stage / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("fixture source input\n", encoding="utf-8")
        output = self.temp / "out"
        completed = subprocess.run([sys.executable, str(ROOT / "scripts/package/package.py"), "build",
                                    "--input", str(stage), "--output-dir", str(output),
                                    "--name", "fixture-source", "--version", "0", "--kind", "source",
                                    "--format", "tar", "--epoch", str(EPOCH)], cwd=ROOT, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        source_manifest = read_json(output / "fixture-source.source-manifest.json")
        self.assertEqual(source_manifest["rebuild_inputs"], self.policy["source_rebuild_required"])
        sums = (output / "SHA256SUMS").read_text(encoding="utf-8")
        self.assertIn("fixture-source.source-manifest.json", sums)

    def test_package_set_mismatch_fails(self):
        runtime = self.temp / "r.zip"; source = self.temp / "s.tar"
        runtime.write_bytes(b"r"); source.write_bytes(b"s")
        linkage = {"lorkhan_commit":"a"*40,"openmw_commit":"b"*40,"openmw_tag":"tag",
                   "patch_manifest_sha256":"c"*64,"provenance_ledger_sha256":"e"*64,
                   "dependency_locks":[{"path":"x","sha256":"d"*64}]}
        rmanifest = {"linkage": linkage, "archive_sha256": hashlib.sha256(b"r").hexdigest()}
        smanifest = {"linkage": linkage, "archive_sha256": hashlib.sha256(b"s").hexdigest()}
        validate_package_set(rmanifest, smanifest, runtime, source)
        smanifest["linkage"] = {**linkage, "openmw_commit": "e" * 40}
        with self.assertRaisesRegex(PackagingError, "mismatched"):
            validate_package_set(rmanifest, smanifest, runtime, source)


if __name__ == "__main__":
    unittest.main()
