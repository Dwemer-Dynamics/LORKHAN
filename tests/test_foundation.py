from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/lib"))
from almsivi_foundation import (FoundationError, cache_index_path, canonical_json, materialize_bundle,
                               read_json, run_manifest, validate_pin, verify_cache)
from json_schema import SchemaError, validate

sys.path.insert(0, str(ROOT / "scripts/evidence"))
from validate import required_provenance_paths, validate_provenance_coverage

COMMIT = "f4bec41444214a7903bebd178389ca22ca13f646"
PIN_PATH = ROOT / "config/source-pins/openmw.json"
BOOTSTRAP = ROOT / "scripts/bootstrap/bootstrap.py"


class FoundationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.temp = Path(self.temporary.name)
        self.git = shutil.which("git")
        if not self.git:
            self.skipTest("git is required")

    def tearDown(self):
        self.temporary.cleanup()

    def command(self, *args, check=True):
        return subprocess.run(args, check=check, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})

    def fixture_remote(self):
        work = self.temp / "fixture"
        bare = self.temp / "remote.git"
        self.command(self.git, "init", str(work))
        self.command(self.git, "-C", str(work), "config", "user.name", "Fixture")
        self.command(self.git, "-C", str(work), "config", "user.email", "fixture@example.invalid")
        (work / "README").write_text("fixture\n", encoding="utf-8")
        self.command(self.git, "-C", str(work), "add", "README")
        env = {**os.environ, "GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z"}
        subprocess.run([self.git, "-C", str(work), "commit", "-m", "fixture"], check=True, env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.command(self.git, "-C", str(work), "tag", "openmw-0.51.0")
        self.command(self.git, "clone", "--bare", str(work), str(bare))
        return bare, self.command(self.git, "-C", str(work), "rev-parse", "HEAD").stdout.strip()

    def fixture_pin(self, commit):
        pin = read_json(PIN_PATH)
        pin["commit"] = commit
        path = self.temp / "pin.json"
        path.write_text(json.dumps(pin), encoding="utf-8")
        return path

    def prefetch(self):
        remote, commit = self.fixture_remote()
        pin = self.fixture_pin(commit)
        cache = self.temp / "cache"
        manifest = self.temp / "prefetch.json"
        result = self.command(sys.executable, str(BOOTSTRAP), "prefetch", "--pin", str(pin),
                              "--cache-dir", str(cache), "--manifest", str(manifest),
                              "--repository", str(remote), check=False)
        # Test fixtures have a different commit, so use a subprocess copy with the exact validator patched
        return result, pin, cache, manifest

    def test_exact_pin(self):
        pin = read_json(PIN_PATH)
        validate_pin(pin)
        self.assertEqual(pin["commit"], COMMIT)
        self.assertEqual(pin["lua_api_revision"], 129)

    def test_wrong_pin_rejected(self):
        pin = read_json(PIN_PATH)
        pin["commit"] = "0" * 40
        with self.assertRaisesRegex(FoundationError, "wrong OpenMW commit"):
            validate_pin(pin)

    def test_canonical_json_and_manifest_are_deterministic(self):
        one = run_manifest(["x"], {"b": "2", "a": "1"}, {}, {"python": "3"})
        two = run_manifest(["x"], {"a": "1", "b": "2"}, {}, {"python": "3"})
        self.assertEqual(canonical_json(one), canonical_json(two))
        self.assertTrue(canonical_json(one).endswith(b"\n"))

    def test_all_ledgers_validate(self):
        pairs = (("source-ledger", "source-ledger"), ("component-ledger", "component-ledger"),
                 ("proof-ledger", "proof-ledger"),
                 ("file-provenance-ledger", "file-provenance-ledger"))
        for document, schema in pairs:
            validate(read_json(ROOT / f"docs/evidence/{document}.json"),
                     read_json(ROOT / f"schemas/evidence/{schema}.schema.json"))
        validate(read_json(PIN_PATH), read_json(ROOT / "schemas/evidence/source-pin.schema.json"))
        ledger = read_json(ROOT / "docs/evidence/file-provenance-ledger.json")
        validate_provenance_coverage(ledger, required_provenance_paths(ROOT))
        missing = json.loads(json.dumps(ledger))
        removed = missing["records"][0]["target_paths"].pop()
        with self.assertRaisesRegex(FoundationError, "coverage missing"):
            validate_provenance_coverage(missing, {removed})
        overlap = json.loads(json.dumps(ledger))
        duplicate = overlap["records"][0]["target_paths"][0]
        overlap["records"][1]["target_paths"].append(duplicate)
        with self.assertRaisesRegex(FoundationError, "provenance overlap"):
            validate_provenance_coverage(overlap, set())
        extra = json.loads(json.dumps(ledger))
        extra["records"][0]["target_paths"].append("untracked/implementation.cpp")
        with self.assertRaisesRegex(FoundationError, "untracked or out-of-scope"):
            validate_provenance_coverage(extra, required_provenance_paths(ROOT))

    def test_ci_validator_rejects_inline_release_triggers_and_yaml(self):
        root = self.temp / "ci-root"
        shutil.copytree(ROOT / ".github", root / ".github")
        (root / "scripts/test").mkdir(parents=True)
        shutil.copy2(ROOT / "scripts/test/validate-ci.sh", root / "scripts/test/validate-ci.sh")
        workflow = root / ".github/workflows/foundation.yml"
        original = workflow.read_text(encoding="utf-8")
        for replacement in ("on: [push, pull_request, release]", "on: {push: {}, pull_request: {}, release: {types: [published]}}"):
            with self.subTest(trigger=replacement):
                mutated = re.sub(r"(?ms)^on:\n(?:  [^\n]+\n)+", replacement + "\n", original, count=1)
                workflow.write_text(mutated, encoding="utf-8")
                result = self.command(str(root / "scripts/test/validate-ci.sh"), check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("release/publish trigger forbidden", result.stderr)
        workflow.write_text(original, encoding="utf-8")
        yaml = root / ".github/workflows/release-canary.yaml"
        yaml.write_text("""name: canary\non: [push, pull_request, release]\njobs:\n  canary:\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683\n""", encoding="utf-8")
        result = self.command(str(root / "scripts/test/validate-ci.sh"), check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release-canary.yaml", result.stderr)

    def test_schema_rejects_extra_and_bad_state(self):
        schema = read_json(ROOT / "schemas/evidence/proof-ledger.schema.json")
        bad = {"schema_version": 1, "rows": [{"id":"x", "claim":"x", "state":"DONE", "evidence":[], "extra":1}]}
        with self.assertRaises(SchemaError):
            validate(bad, schema)

    def test_offline_cache_miss(self):
        result = self.command(sys.executable, str(BOOTSTRAP), "bootstrap", "--cache-dir", str(self.temp / "none"),
                              "--source-dir", str(self.temp / "source"), "--manifest", str(self.temp / "run.json"), check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("offline cache miss", result.stderr)
        self.assertFalse((self.temp / "run.json").exists())

    def test_tampered_cache_rejected_before_git(self):
        pin = read_json(PIN_PATH)
        cache = self.temp / "cache"
        digest = "a" * 64
        artifact = cache / "objects/sha256" / digest[:2] / digest[2:]
        artifact.parent.mkdir(parents=True)
        artifact.write_bytes(b"tampered")
        index = {"schema_version":1, "artifact":artifact.relative_to(cache).as_posix(), "sha256":digest,
                 "commit":pin["commit"], "tag":pin["tag"]}
        path = cache_index_path(cache, pin["commit"])
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps(index), encoding="utf-8")
        with self.assertRaisesRegex(FoundationError, "tampered"):
            verify_cache(cache, pin, self.git)

    def test_bootstrap_rejects_repository_override(self):
        result = self.command(sys.executable, str(BOOTSTRAP), "bootstrap", "--cache-dir", str(self.temp / "cache"),
                              "--source-dir", str(self.temp / "source"), "--manifest", str(self.temp / "run.json"),
                              "--repository", "https://example.invalid", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("not accepted by strict offline bootstrap", result.stderr)

    def test_materialize_pristine_bundle(self):
        remote, commit = self.fixture_remote()
        bundle = self.temp / "fixture.bundle"
        self.command(self.git, "--git-dir", str(remote), "bundle", "create", str(bundle), "--all")
        destination = self.temp / "materialized"
        pin = {"commit": commit}
        materialize_bundle(bundle, destination, pin, self.git)
        self.assertEqual(self.command(self.git, "-C", str(destination), "rev-parse", "HEAD").stdout.strip(), commit)
        self.assertEqual(self.command(self.git, "-C", str(destination), "status", "--porcelain").stdout, "")
        self.assertEqual(self.command(self.git, "-C", str(destination), "remote").stdout, "")

    def test_materialize_rejects_nonempty_destination(self):
        destination = self.temp / "source"
        destination.mkdir()
        (destination / "keep").write_text("do not touch", encoding="utf-8")
        with self.assertRaisesRegex(FoundationError, "must not exist or must be empty"):
            materialize_bundle(self.temp / "missing.bundle", destination, {"commit": COMMIT}, self.git)
        self.assertEqual((destination / "keep").read_text(encoding="utf-8"), "do not touch")

    def test_generated_roots_are_ignored(self):
        ignored = self.command(self.git, "-C", str(ROOT), "check-ignore", "build/x", ".cache/x", ".work/x", ".runs/x",
                               check=False)
        self.assertEqual(ignored.returncode, 0, ignored.stderr)


if __name__ == "__main__":
    unittest.main()
