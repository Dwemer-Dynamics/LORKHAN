# Build and proof contract

## Scope and invariants

The build wrappers are noninteractive orchestration for an already materialized OpenMW source tree. They never read a game installation, user profile, saves, or sibling checkout. Callers must provide separate absolute source, build, install, and output roots. Build and install roots must be outside the source tree.

Both `scripts/build/unix.sh` and `scripts/build/windows.ps1` accept exactly the same semantic inputs: patch state, roots, configuration, compiler, optional build/test targets, expected commit, and reproducibility epoch. Control and patched runs receive the same CMake options. The only declared difference is `control` versus `patched` source state.

The exact source pin is `f4bec41444214a7903bebd178389ca22ca13f646` (`openmw-0.51.0`). Every build rejects a different `HEAD`. A control build rejects any tracked or untracked source change. A patched build requires a change. This proves declared source state, not patch correctness; later patch tooling must establish that separately.

Supported configurations are `Debug`, `RelWithDebInfo`, and `Release`. Unix selects GCC or Clang. Windows selects MSVC or clang-cl and x64. The wrappers set `SOURCE_DATE_EPOCH`, `TZ=UTC`, `LANG=C`, `LC_ALL=C`, deterministic/path-map compiler flags, and write a plain-text invocation manifest and log under the output root.

## Bootstrap and offline reconstruction

Online prefetch is a separate, explicit operation:

```sh
ALMSIVI_CACHE_DIR=/absolute/cache ALMSIVI_RUN_MANIFEST=/absolute/runs/prefetch.json scripts/bootstrap/prefetch-unix.sh
```

PowerShell uses the equivalent environment variables with `scripts/bootstrap/prefetch-windows.ps1`. Prefetch verifies the tagged commit and creates a content-addressed bundle plus index. The generated cache is deliberately not committed.

Bootstrap is strictly offline: it accepts no repository override, verifies the cached SHA-256 and exact pin, materializes a source with no remote, and records a manifest.

```sh
ALMSIVI_CACHE_DIR=/absolute/cache ALMSIVI_SOURCE_DIR=/absolute/openmw ALMSIVI_RUN_MANIFEST=/absolute/runs/bootstrap.json scripts/bootstrap/unix.sh
```

An empty destination is required. Cache transfer into an offline environment is an operator responsibility; preserve the entire cache tree and verify it through bootstrap rather than trusting transport metadata.

## Build examples

```sh
scripts/build/unix.sh --state control --source /absolute/openmw --build /absolute/build-control --install /absolute/install-control --output /absolute/results/control --config RelWithDebInfo --compiler clang
scripts/build/unix.sh --state patched --source /absolute/openmw-patched --build /absolute/build-patched --install /absolute/install-patched --output /absolute/results/patched --config RelWithDebInfo --compiler clang
```

```powershell
./scripts/build/windows.ps1 -State control -Source C:\work\openmw -Build C:\work\build-control -Install C:\work\install-control -Output C:\work\results\control -Config Release -Compiler msvc
```

A declared `--test-target`/`-TestTarget` is required and fails when absent. Without one, CTest runs only when it discovers tests; zero tests emits a skip note and is not proof. Lua wrappers similarly run discovered `*_test.lua` files only when an interpreter and test root exist. Set `ALMSIVI_REQUIRE_LUA_TESTS=1` to turn absence into failure.

## Reproducibility comparison

Use clean, distinct roots; identical toolchain/dependency inputs; the same state and options; and the same epoch. Compare install trees only after both builds succeed. Normalize or exclude only artifacts documented by the eventual reproducibility implementation. A matching hash is artifact reproducibility evidence for those inputs, not platform portability, functional correctness, provenance, packaging, or signing proof.

CI action dependencies are pinned to immutable 40-character commits. CI does not fetch or commit a generated source cache. Native, packaging, audit, and reproducibility lanes remain readiness lanes until an implementation target/script is explicitly declared required; missing required declarations fail, while undeclared future slices skip with an explicit no-proof statement.

## Current host outcome (2026-07-18)

Known host tools were Python 3.9.6 and git 2.50.1. CMake, Ninja, and Lua were absent. Exact OpenMW prefetch and offline bootstrap succeeded: cache size 96 MiB, materialized source size 133 MiB, commit `f4bec41444214a7903bebd178389ca22ca13f646`. No native compilation, CTest, Lua, package, audit, or reproducibility proof exists from that run.

## Platform proof semantics

A green foundation job proves only schema/evidence validation, Python unit tests, and wrapper static checks actually shown in its log. A green platform readiness lane proves runner architecture and/or script parsing plus any explicitly invoked target. A skipped discovery is not proof. Control results do not prove patched behavior; one configuration/compiler/OS does not prove another. Packaging, audit, reproducibility, publishing, signing, secret handling, and game-data compatibility each require their own executed evidence. These workflows perform no publishing, signing, release trigger, secret access, game-data access, or sibling checkout.
