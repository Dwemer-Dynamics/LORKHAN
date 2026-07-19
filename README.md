# ALMSIVI

ALMSIVI is the OpenMW/Morrowind client for a CHIM- and Dialectic-style AI character system. It
combines a narrowly scoped OpenMW engine integration with an ordinary OpenMW Lua mod, and talks to
the separate `RANGROO/ALMSIVIserver` backend over authenticated loopback HTTP.

## Status

Planning and Azure handoff are complete; implementation has not started. The implementation run is
deliberately queued behind completion of `RANGROO/SYNTH` and `RANGROO/Synthserver`. It must import
the final, tested server architecture rather than a half-built snapshot.

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

Machine-readable source, component, and proof ledgers live under `docs/evidence/`; their schemas live
under `schemas/evidence/`. `AUTOMATED` proves only the recorded no-game command. It does not imply a
Windows build, cross-repository match, compatibility, or in-game proof; those have explicit deferred
rows and resume conditions.
