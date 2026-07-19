# Deterministic packaging and compliance foundation

This foundation creates and audits fixture packages now; release-named runtime, Lua, symbols, and source packages remain fail-closed until the product runtime, Lua files, pinned OpenMW source, and patch manifest exist. A passing fixture audit is not release or GPL correspondence proof.

## Build and compare fixture packages

Set one integer `SOURCE_DATE_EPOCH` (at least `315532800`). Inputs must be a staging directory containing only allowlisted regular files. Symlinks, special files, absolute/traversal names, and non-allowlisted content fail.

```bash
export SOURCE_DATE_EPOCH=1700000000
./scripts/package/unix.sh build --input /isolated/fixture-runtime --output-dir /isolated/out-a \
  --name fixture-runtime --version 0 --kind runtime --format zip
./scripts/package/unix.sh build --input /isolated/fixture-runtime --output-dir /isolated/out-b \
  --name fixture-runtime --version 0 --kind runtime --format zip
./scripts/audit/package.sh compare /isolated/out-a/fixture-runtime.zip \
  /isolated/out-b/fixture-runtime.zip --require-raw
./scripts/audit/package.sh archive /isolated/out-a/fixture-runtime.zip --kind runtime \
  --sbom /isolated/out-a/fixture-runtime.spdx.json
./scripts/package/unix.sh ownership-dry-run /isolated/out-a/fixture-runtime.zip \
  /isolated/install-root --output /isolated/ownership.json
```

PowerShell uses `scripts/package/windows.ps1` and `scripts/audit/package.ps1` with the same Python arguments. The builder writes a content manifest, release manifest, SPDX 2.3 JSON SBOM, and `SHA256SUMS`. Release manifests bind the set to the exact ALMSIVI Git commit, OpenMW pin, patch-manifest SHA-256, and dependency-lock hashes.

## Fail-closed gates

`config/packaging/policy.json` defines separate runtime/source allowlists, required notices and rebuild inputs, product/source prerequisites, and prohibited generated or proprietary content. `openmw-patches/patch-manifest.json` and `docs/evidence/file-provenance-ledger.json` are the sole authoritative patch/provenance inputs; package linkage hashes both and rejects pin drift or incomplete provenance. Source packages must include those files, the patch specification/series, exact bootstrap/build/patch/package tooling, and an OpenMW source-materialization manifest. Audits cover archive safety, GPL notices and corresponding-source rebuild inputs, provenance, secrets/private keys/provider credentials/high-entropy tokens, Bethesda master names/extensions and TES3/BSA signatures, saves, voices/media/third-party assets, host paths/usernames/cache/log/dump/privacy, SBOM coverage, package-set linkage, and raw plus normalized reproducibility.

Suppressions in `config/packaging/suppressions.json` must identify one audit, exact normalized file path, exact file SHA-256, nonempty reason, configured reviewer, and future expiry. Wildcards, directory-wide exemptions, expired records, and unused records fail. Suppressions do not bypass archive traversal or special-file rejection.

The install dry-run computes targets beneath an isolated root and records only package-owned files. The uninstall dry-run rejects changed roots or escaped/tampered targets and removes only those owned files; it never discovers game, profile, save, stock OpenMW, or server paths.

## Release proof still required

Before any release-named package can pass, supply the staged built branded runtime and Lua product files, an exact pinned OpenMW source archive/materialization manifest, the authoritative patch manifest, complete dependency locks/licenses/notices/provenance, clean source rebuild evidence, Windows x64 package evidence, and legal-data in-game/install/uninstall acceptance. The generated/ignored `engine/openmw` checkout is not itself a committed prerequisite. No release, signing, or publication is performed by these scripts.
