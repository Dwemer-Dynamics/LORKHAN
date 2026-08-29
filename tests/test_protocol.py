from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class ProtocolRepositoryTests(unittest.TestCase):
    def command(self, *args):
        return subprocess.run(args, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_protocol_validation_and_generated_manifest(self):
        result = self.command(sys.executable, "scripts/protocol/validate.py")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("validated", result.stdout)

    def test_manifest_is_sorted_and_covers_only_contract_bytes(self):
        manifest = json.loads((ROOT / "lorkhan/MANIFEST.json").read_text(encoding="utf-8"))
        paths = [record["path"] for record in manifest["files"]]
        self.assertEqual(paths, sorted(paths))
        self.assertTrue(all(path.startswith(("lorkhan/schemas/v1/", "lorkhan/fixtures/v1/")) for path in paths))
        self.assertEqual(manifest["cross_repository_byte_parity"], "locally-proven")

if __name__ == "__main__":
    unittest.main()
