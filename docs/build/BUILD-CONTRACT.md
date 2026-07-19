# Build and proof contract

## Scope and invariants

The build wrappers are noninteractive orchestration for an already materialized OpenMW source tree. They never read a game installation, user profile, saves, or sibling checkout. Callers must provide separate absolute source, build, install, and output roots. Build and install roots must be outside the source tree.

Both `scripts/build/unix.sh` and `scripts/build/windows.ps1` accept exactly the same semantic inputs: patch state, roots, configuration, compiler, optional build/test targets, expected commit, and reproducibility epoch. Control and patched runs receive the same CMake options. The only declared difference is `control` versus `patched` source state.

The exact source pin is `f4bec41444214a7903bebd178389ca22ca13f646` (`openmw-0.51.0`). Every build rejects a different `HEAD`. A control build rejects any tracked or untracked source change. A patched build requires a change. This proves declared source state, not patch correctness; the patch tooling establishes patch integrity separately.

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

The independent native and Lua entry points are:

```sh
./scripts/test/native.sh
./scripts/test/lua-unix.sh
```

```powershell
./scripts/test/lua-windows.ps1
```

The native command compiles the pure native scaffold directly; it does not configure or compile OpenMW. The Lua commands execute against fake OpenMW modules and do not constitute engine, mod-loader, or in-game proof.

## Reproducibility comparison

Use clean, distinct roots; identical toolchain/dependency inputs; the same state and options; and the same epoch. Compare install trees only after both builds succeed. Normalize or exclude only artifacts documented by the eventual reproducibility implementation. A matching hash is artifact reproducibility evidence for those inputs, not platform portability, functional correctness, provenance, packaging, or signing proof.

CI action dependencies are pinned to immutable 40-character commits. CI does not fetch or commit a generated source cache. The checked-in CI definitions automate declared foundation, native, Lua, packaging, audit, and platform-readiness commands. Their presence is automation, not execution proof: a platform row remains `PLANNED` until an actual qualifying run is recorded, and skipped or unavailable tools remain no-proof outcomes.

## Current host outcome (2026-07-18 checkpoint)

The real network prefetch and strict offline reconstruction passed for exact commit `f4bec41444214a7903bebd178389ca22ca13f646`: the verified content-addressed cache was 96 MiB and the materialized source was 133 MiB.

The warning-clean direct Clang pure-native suite compiled and passed. The recorded no-game checks also passed 43 Python tests, 7 loopback contract-harness cases, and 38 Lua structural/source-manifest checks. Deterministic archive checks passed, and both the package audit and source audit completed with zero findings.

The sanitizer configuration compiled, but its Apple-host runtime hung; this is not sanitizer runtime proof. CMake, Ninja, Lua, and PowerShell (`pwsh`) were unavailable locally. Consequently there is no local CMake/OpenMW control or patched-engine build, no Lua-runtime result, and no PowerShell/Windows result. The checked-in CI definitions are automation definitions only and are not evidence that any CI platform lane executed.

## Deferred build and runtime gates

The pure native suite is not the integrated engine. Exact-pin OpenMW package registration and media VFS-versus-decoder patches, the Beast live-wire serializer/transport, a patched engine compile, and the matching unmodified control build remain deferred. Lua-runtime proof resumes on a host with the interpreter. Windows control/product builds, legal-game/mod behavior, release assembly, signing, and publication require their exact environments and evidence.

## Platform proof semantics

A green foundation job proves only schema/evidence validation, Python unit tests, and wrapper static checks actually shown in its log. A green platform readiness lane proves runner architecture and/or script parsing plus any explicitly invoked target. A skipped discovery is not proof. Control results do not prove patched behavior; one configuration/compiler/OS does not prove another. Packaging, audit, reproducibility, publishing, signing, secret handling, and game-data compatibility each require their own executed evidence. These workflows perform no publishing, signing, release trigger, secret access, game-data access, or sibling checkout. Fake servers, fake OpenMW modules, structural checks, pure-library tests, and workflow definitions must never be promoted to engine, platform, game, mod, or compatibility proof.
