# LORKHAN

LORKHAN is the OpenMW/Morrowind client for a CHIM- and Dialectic-style AI character system. It
combines a narrowly scoped OpenMW engine integration with an ordinary OpenMW Lua mod, and talks to
the separate `RANGROO/LorkhanServer` backend over authenticated loopback HTTP.

## Status

The playable development stack is implemented through the no-game gate. The exact-pinned OpenMW
0.51.0 engine builds with the restricted `openmw.lorkhan` package and live authenticated Beast
transport. The OpenMW Lua mod provides targeting, multi-actor conversation controls, typed conversation UI,
bounded TES3 context collection, subtitles, TTS playback, interruption, `inspect.report`, owned
`ai.follow`/stop/wander actions, and start/stop combat. Combat initiation is held for explicit player
confirmation before actor dispatch. Allowlisted idle animations and use of an existing inventory item
are also supported; item use requires the same confirmation gate. All actions and dialogue deliveries produce terminal reports. The sibling server protocol is byte-identical and the full
mock-provider client/server/PostgreSQL vertical slice passes locally.

The local server and private client configuration are deployed. A Windows x64 Release build of the
exact-pinned OpenMW engine and a development OpenMW data package are prepared for installation; see
`docs/LOCAL-TESTING.md`. The native bridge includes bounded WinMM push-to-talk capture and opt-in
open-microphone capture with voice activity detection. This checkpoint does not claim in-game proof
because legal Morrowind game data and a playable OpenMW profile are not configured on this machine
yet. Item transfer, trade-menu actions, and compatibility profiles remain later gates rather than
silently enabled model authority.

The engine baseline is OpenMW `openmw-0.51.0` at
`f4bec41444214a7903bebd178389ca22ca13f646`, with Lua API revision 129. The first supported package
is Windows x64. Linux x64 and macOS arm64 are build/test lanes; Android is deferred.

## Product shape

- A side-by-side LORKHAN-branded OpenMW build; it never overwrites stock OpenMW.
- A minimal native `openmw.lorkhan` package: typed asynchronous requests, media staging, status,
  cancellation, and no generic HTTP, shell, or filesystem access.
- An OpenMW Lua mod owning targeting, conversations, custom UI, context collection, actor-local
  actions, save/load state, subtitles, and voice playback.
- No Bethesda game data, saves, or third-party mod assets in source or release archives.
- Vanilla dialogue remains available. LORKHAN starts from its own configurable input and captures
  vanilla dialogue responses only as context.

## Start here

1. `docs/archive/CLAUDEX-TASK.md` — historical implementation assignment (archived).
2. `docs/archive/RUN-AZURE-CLAUDE-CODE.md` — historical Azure execution procedure (archived).
3. `docs/PROGRAM-PLAN.md` — program phases, decisions, gates, and completion rules.
4. `docs/REFERENCE-STACK-DATAFLOW.md` — CHIM/Dialectic/SYNTH/OpenMW ownership and data flow.
5. `docs/ENGINE-INTEGRATION-PLAN.md` — exact native patch boundary.
6. `docs/LUA-MOD-ARCHITECTURE.md` — scripts, events, UI, targeting, actions, and persistence.
7. `docs/PROTOCOL.md` — cross-repository wire contract.
8. `docs/FEATURE-PARITY-MATRIX.md` — retained, adapted, deferred, and excluded capabilities.
9. `docs/OPENMW-TOOLCHAIN.md` — source pin, build, CI, packaging, and in-game proof.
10. `docs/LOCAL-TESTING.md` — current local server/client install and launch procedure.
11. `docs/COMPATIBILITY-PLAN.md` — vanilla and popular OpenMW mod-list profiles.
12. `docs/PACKAGING-AND-LICENSE.md` — GPL/source-offer and proprietary-asset release gate.

## Reproducible source foundation

Requirements are Python 3.10+ and Git; CMake 3.25+ and Ninja are minimum environment versions for the
foundation preset. They are not immutable dependency pins. OpenMW itself is immutably pinned in
`config/source-pins/openmw.json`.

Prefetch is the only network-capable step. It fetches the full exact commit into a Git bundle, hashes
it into a content-addressed cache, verifies the bundle and tag, and writes a deterministic run
manifest. All locations are configurable:

```bash
LORKHAN_CACHE_DIR=/safe/cache LORKHAN_RUN_MANIFEST=/safe/runs/prefetch.json \
  ./scripts/bootstrap/prefetch-unix.sh
LORKHAN_CACHE_DIR=/safe/cache LORKHAN_SOURCE_DIR=/safe/work/openmw \
  LORKHAN_RUN_MANIFEST=/safe/runs/bootstrap.json ./scripts/bootstrap/unix.sh
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
The patch state contains the restricted package registration, authenticated transport integration,
and media cache/VFS bridge used by the development client. Each changed path declares an ordered add/modify/delete
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
`lorkhan/`. The durable run records seven passing loopback tests. They cover the local
contract and fake server only, not the Beast live wire or cross-repository parity. See
`docs/PROTOCOL-CONTRACTS.md` for commands, scope, and contracts deliberately deferred rather than
invented.

## Packaging and compliance

Deterministic fixture packaging, SPDX 2.3 SBOM generation, ownership dry-runs, compliance audits, and
Unix/PowerShell commands are documented in `docs/PACKAGING-COMPLIANCE.md`. Deterministic archives and
the durable run records 45 passing Python tests, including deterministic packaging/audit fixtures, plus a zero-finding source audit and successful exact provenance validation. Release-named
packages still fail closed until the required built product and corresponding source exist; signing
and publication remain deferred.
