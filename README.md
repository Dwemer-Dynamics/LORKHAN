# ALMSIVI

ALMSIVI is the OpenMW/Morrowind client for a CHIM- and Dialectic-style AI character system. It
combines a narrowly scoped OpenMW engine integration with an ordinary OpenMW Lua mod, and talks to
the separate `RANGROO/ALMSIVIserver` backend over authenticated loopback HTTP.

## Status

The independent client foundations are implemented at the current checkpoint: exact source pinning
and offline bootstrap, deterministic OpenMW patch machinery, local protocol schemas and fixtures, a
loopback fake server and contract harness, a pure native scaffold and tests, the Lua architecture and
source manifest, deterministic packaging and compliance/source audits, and pinned CI definitions.
This is foundation proof, not an OpenMW engine build, a live Beast transport result, a Lua-runtime
result, a Windows result, or in-game proof.

The remaining gates are explicit:

- obtain the final tested `SYNTH` and `Synthserver` SHAs, then authorize and perform their import,
  migration, and cross-repository protocol/parity work;
- implement and prove the Beast live-wire serializer and transport;
- create the exact-pin OpenMW package-registration and media VFS-versus-decoder patches, then compile
  the integrated engine and its unmodified exact-pin control build;
- run the Lua suite on a runtime host when a Lua interpreter is unavailable locally;
- produce Windows control/product builds and Windows game/mod evidence using legal game data; and
- build the real release set and complete signing and publication.

No deferred source was read or imported at this checkpoint, and workflows, mocks, structural checks,
and pure-library tests are not promoted to platform, engine, mod, or in-game proof.

The engine baseline is OpenMW `openmw-0.51.0` at
`f4bec41444214a7903bebd178389ca22ca13f646`, with Lua API revision 129. The first supported package
is Windows x64. Linux x64 and macOS arm64 are build/test lanes; Android is deferred.

## Product shape

- A side-by-side ALMSIVI-branded OpenMW build; it never overwrites stock OpenMW.
- A minimal native `openmw.almsivi` package: typed asynchronous requests, media staging, status,
  cancellation, and no generic HTTP, shell, or filesystem access.
- An OpenMW Lua mod owning targeting, conversations, custom UI, context collection, actor-local
  actions, save/load state, subtitles, and voice playback.
- No Bethesda game data, saves, or third-party mod assets in source or release archives.
- Vanilla dialogue remains available. ALMSIVI starts from its own configurable input and captures
  vanilla dialogue responses only as context.

## Start here

1. `CLAUDEX-TASK.md` — self-contained Azure/Claude Code execution assignment.
2. `RUN-AZURE-CLAUDE-CODE.md` — exact launch, supervision, resume, and completion procedure.
3. `docs/PROGRAM-PLAN.md` — program phases, decisions, gates, and completion rules.
4. `docs/REFERENCE-STACK-DATAFLOW.md` — CHIM/Dialectic/SYNTH/OpenMW ownership and data flow.
5. `docs/ENGINE-INTEGRATION-PLAN.md` — exact native patch boundary.
6. `docs/LUA-MOD-ARCHITECTURE.md` — scripts, events, UI, targeting, actions, and persistence.
7. `docs/PROTOCOL.md` — cross-repository wire contract.
8. `docs/FEATURE-PARITY-MATRIX.md` — retained, adapted, deferred, and excluded capabilities.
9. `docs/OPENMW-TOOLCHAIN.md` — source pin, build, CI, packaging, and in-game proof.
10. `docs/COMPATIBILITY-PLAN.md` — vanilla and popular OpenMW mod-list profiles.
11. `docs/PACKAGING-AND-LICENSE.md` — GPL/source-offer and proprietary-asset release gate.

## Reproducible source foundation

Requirements are Python 3.10+ and Git; CMake 3.25+ and Ninja are minimum environment versions for the
foundation preset. They are not immutable dependency pins. OpenMW itself is immutably pinned in
`config/source-pins/openmw.json`.

Prefetch is the only network-capable step. It fetches the full exact commit into a Git bundle, hashes
it into a content-addressed cache, verifies the bundle and tag, and writes a deterministic run
manifest. All locations are configurable:

```bash
ALMSIVI_CACHE_DIR=/safe/cache ALMSIVI_RUN_MANIFEST=/safe/runs/prefetch.json \
  ./scripts/bootstrap/prefetch-unix.sh
ALMSIVI_CACHE_DIR=/safe/cache ALMSIVI_SOURCE_DIR=/safe/work/openmw \
  ALMSIVI_RUN_MANIFEST=/safe/runs/bootstrap.json ./scripts/bootstrap/unix.sh
python3 ./scripts/evidence/validate.py
cmake --preset foundation && cmake --build --preset foundation
```

Windows equivalents are `./scripts/bootstrap/prefetch-windows.ps1` and
`./scripts/bootstrap/windows.ps1`, using the same environment variables. Bootstrap is strictly
offline, rejects cache absence/tampering/wrong pins and nonempty destinations, checks out a detached
pristine source tree, and removes its origin. Defaults remain under ignored repository-generated
roots; no script discovers or touches game, profile, configuration, or save directories.

Machine-readable source, component, file-provenance, and proof ledgers live under `docs/evidence/`;
their schemas live under `schemas/evidence/`. `AUTOMATED` proves only the recorded no-game command. It
does not imply a Windows build, cross-repository match, compatibility, or in-game proof; those have
explicit deferred rows and resume conditions.

## Foundation test entry points

The native entry point compiles and runs only the pure native scaffold; it does not compile or prove
OpenMW integration. The Lua entry points require a Lua runtime and fake OpenMW modules; structural
Python checks remain distinct from runtime proof.

```bash
./scripts/test/native.sh
./scripts/test/lua-unix.sh
```

```powershell
./scripts/test/lua-windows.ps1
```

The durable run at `docs/evidence/runs/3717eff-local/index.json`, bound to clean commit `3717effebb8d42ad7601d6ca02c19ac3533efcf8`, records a successful warning-clean native run and 38 Lua structural checks with zero failures. Lua runtime and in-game proof remain deferred.

## OpenMW patch series

Tracked OpenMW changes use `openmw-patches/patch-spec.json` as human-authored intent and a canonical
`patch-manifest.json`, `series`, numbered `patches/`, and new-file `overlay/` as generated artifacts.
The foundation patch state is valid but does not contain or prove the eventual package-registration or
media VFS-versus-decoder engine patches. Each future path declares an ordered add/modify/delete
operation, rationale, subsystem, provenance ID, and proof IDs; generated metadata pins the upstream
base blob and result SHA-256. Commands are dependency-free beyond Python and Git:

```bash
python3 ./scripts/patches/openmw.py validate
python3 ./scripts/patches/openmw.py generate --base /pristine/openmw --source /edited/openmw
python3 ./scripts/patches/openmw.py apply --source /pristine/openmw
python3 ./scripts/patches/openmw.py verify --source /patched/openmw
python3 ./scripts/patches/openmw.py audit --base /pristine/openmw
```

Generation refuses undeclared or unchanged paths. Application and audit refuse dirty/non-pinned bases,
stale blobs, patch fuzz/offset, traversal, artifact drift, extra generated/untracked files, result hash
mismatches, and metadata that omits rationale, provenance, subsystem, or tests. Run `audit` before
committing any real engine patch; relevant OpenMW subsystem tests remain mandatory and must be named by
the manifest.

## Protocol contracts

Strict Draft 2020-12 schemas, canonical positive/negative/hostile fixtures, deterministic local hashes,
a standard-library discipline validator, and the loopback fake-server contract harness live under
`almsivi/`. The durable run records seven passing loopback tests. They cover the local
contract and fake server only, not the Beast live wire or cross-repository parity. See
`docs/PROTOCOL-CONTRACTS.md` for commands, scope, and contracts deliberately deferred rather than
invented.

## Packaging and compliance

Deterministic fixture packaging, SPDX 2.3 SBOM generation, ownership dry-runs, compliance audits, and
Unix/PowerShell commands are documented in `docs/PACKAGING-COMPLIANCE.md`. Deterministic archives and
the durable run records 45 passing Python tests, including deterministic packaging/audit fixtures, plus a zero-finding source audit and successful exact provenance validation. Release-named
packages still fail closed until the required built product and corresponding source exist; signing
and publication remain deferred.
