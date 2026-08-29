# OpenMW 0.51 toolchain and evidence plan

## Pinned source

- Upstream: `https://gitlab.com/OpenMW/openmw.git`
- Tag: `openmw-0.51.0`
- Commit: `f4bec41444214a7903bebd178389ca22ca13f646`
- Commit date: 2026-05-30
- Lua API revision: 129
- License: GNU GPL version 3

Never build release evidence from `master`, `stable`, a branch name, or an unrecorded dependency
cache. The bootstrap script fetches the exact commit, verifies it and refuses a dirty base.

## Repository strategy

LORKHAN remains the product repository. During implementation it gains the OpenMW source as one of:

1. preferred: a full fork history with `upstream` remote and LORKHAN commits on a named branch;
2. acceptable: reproducible upstream-fetch script plus numbered patches and new-file overlay.

Choose the full fork if GitHub size and CI are practical because GPL source correspondence and blame
are simpler. The decision procedure is fixed: prototype fetch/build and measure repository/CI cost;
use full fork unless it exceeds GitHub/runner limits, otherwise use patch series. Record the result,
not a debate, in the source ledger. In both modes, `patch-manifest.json` describes the same diff.

## Build targets

### Windows x64 release lane

- Windows Server 2022 runner or equivalent clean Windows x64 host.
- Visual Studio 2022 C++ workload, current supported CMake and Ninja.
- Use the pinned OpenMW 0.51 CI dependency preparation/vcpkg manifest approach, not ad-hoc DLLs.
- Add Boost `system` to the exact dependency lock.
- Build upstream control and LORKHAN with identical compiler/dependency settings.
- Configuration: Windows x64 Release for CI and the final package. Debug/RelWithDebInfo remain optional local diagnostics.

### Linux x64

Linux product/native CI is deferred. Ubuntu remains available only for portable Python/Lua,
schema/fixture, packaging-input, evidence, and patch-manifest checks that do not claim a Linux product build.

### macOS arm64

macOS build, test, signing, notarization, packaging, and CI are deferred. No macOS runner or matrix
lane is required for the Windows/OpenMW LORKHAN release goal.

Android is excluded from these targets because background networking, cache permissions, touch UI,
packaging and proprietary data acquisition require a separate product/acceptance plan.

## Target source layout

```text
engine/                     # full upstream tree or fetch/patch workspace
lorkhan/files/              # .omwscripts and Lua modules
lorkhan/schemas/            # canonical JSON Schemas
lorkhan/fixtures/           # valid/invalid protocol fixtures
lorkhan/tests/              # product integration harnesses
cmake/                      # LORKHAN build glue only
scripts/bootstrap/          # exact source/dependency acquisition
scripts/test/               # one-command focused suites
scripts/package/            # deterministic artifacts/audits
docs/evidence/              # pins, completion ledger, run manifests
patch-manifest.json
```

## Commands the implementation must provide

Names are fixed so the Azure worker and later Codex runs have a stable contract:

```powershell
pwsh ./scripts/bootstrap/windows.ps1
pwsh ./scripts/build/windows.ps1 -Configuration Debug -Control
pwsh ./scripts/build/windows.ps1 -Configuration Debug
pwsh ./scripts/test/windows.ps1 -Configuration Debug
pwsh ./scripts/package/windows.ps1 -Configuration Release
pwsh ./scripts/audit/package.ps1 ./dist/<artifact>.zip
```

```bash
./scripts/bootstrap/unix.sh
./scripts/build/unix.sh --control
./scripts/build/unix.sh
./scripts/test/unix.sh
./scripts/audit/protocol-parity.sh ../LORKHANserver
```

Scripts must be non-interactive, stop on failure, print tool/source pins, accept an isolated build
directory, avoid user game/profile directories by default, and write a machine-readable run manifest.

## Automated test layers

1. Existing relevant OpenMW unit/integration tests for every touched subsystem.
2. Pure C++ bridge tests with fake clocks/socket server and hostile fixtures.
3. Lua pure-module tests using a strict OpenMW API fake.
4. In-engine Lua test content using freely authored fixtures only.
5. Cross-repository fake LORKHANserver E2E.
6. Package/provenance/license/secret/proprietary-signature/reproducibility audits.
7. Windows in-game acceptance using user-supplied data outside the repo/CI.

Required negative cases are listed in the engine, Lua and protocol documents. Add fuzz targets for
URL/header/JSON/event/media descriptor parsers and action parameter validation where the build
platform supports them.

## Package set

- `LORKHAN-OpenMW-<version>-windows-x64.zip`: branded runtime, required libraries, Lua mod,
  safe defaults, setup/upgrade/uninstall docs, notices/SBOM.
- `LORKHAN-Lua-<version>.zip`: Lua files for the matching LORKHAN runtime only; must refuse stock
  runtime without bridge capability.
- `LORKHAN-symbols-<version>-windows-x64.zip`: debug symbols and symbol manifest.
- `LORKHAN-source-<version>.tar.zst`: exact corresponding source, upstream history/patches,
  dependency/build scripts, schemas, notices and reproducibility instructions.
- `SHA256SUMS` and signed provenance when release credentials are later authorized.

Reproducibility means two clean runs from the same pins yield identical tracked file contents and
manifest; archive container timestamps/order are normalized. If platform binaries are not bitwise
identical, document the exact nondeterministic fields and compare normalized artifacts.

## Windows install and acceptance

Install into a new directory such as `C:\Games\LORKHAN-OpenMW-0.1.0`; never into stock OpenMW. Create
a separate OpenMW configuration profile and copied test saves. Point `data=` at the user's legal game
data and LORKHAN mod path; add `content=LORKHAN.omwscripts` last unless a compatibility profile says
otherwise. Import the server-generated pairing snippet into the user config directory.

Capture for every run: LORKHAN/OpenMW/source SHA, package SHA-256, OS/GPU/driver, Morrowind data
language/version, ordered content list/fingerprint, server SHA/schema revision, provider mode,
settings, copied save hash, start/end logs, result matrix and screenshots/video where visual.

Acceptance covers clean/new/load/save/menu/cell transitions; vanilla and LORKHAN dialogue; text/STT/
TTS; groups; interruption/halt; each context domain/action; provider/server/media failure; 2-hour
soak; clean uninstall; and saved-game copy reopening in stock OpenMW when format compatibility allows.

OpenMW 0.51 saves cannot be promised to load in 0.50 or earlier. Always preserve an untouched
pre-upgrade save and never overwrite the only copy.
