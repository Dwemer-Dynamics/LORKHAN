# Building LORKHAN from source

Run commands from a checkout of https://github.com/Dwemer-Dynamics/LORKHAN at the revision matching
the intended package. Installed Lua files alone cannot rebuild OpenMW. Read root AGENTS.md
and docs/build/BUILD-CONTRACT.md before native work. Historical plans can contain proposed
commands; check the actual script parameters before using them.

The client and server repositories are public under Dwemer-Dynamics. Use the source revision matching the installed build. Submit development changes to unstable; lorkhan is the default release branch.

## Prerequisites and pins

- Git and Python 3.10+; Python jsonschema for authoritative protocol validation.
- CMake 3.25+, Ninja and a C++20 compiler for the foundation checks.
- Windows x64 engine builds: Visual Studio 2022 C++ workload plus OpenMW dependencies.
  Dependency preparation is not performed by the build wrapper. Follow the pinned
  upstream dependency requirements and docs/OPENMW-TOOLCHAIN.md, recording versions.
- Lua interpreter for Lua runtime tests; structural checks alone do not execute Lua.
- OpenMW tag openmw-0.51.0, commit f4bec41444214a7903bebd178389ca22ca13f646, Lua API 129.
  config/source-pins/openmw.json is authoritative. Do not substitute current upstream.

## Focused checks

```powershell
python -m unittest discover -s tests -v
python scripts/protocol/generate_manifest.py --check
python scripts/protocol/validate.py --require-jsonschema
python scripts/patches/openmw.py validate
$env:LORKHAN_REQUIRE_LUA_TESTS = '1'
./scripts/test/lua-windows.ps1
cmake --preset foundation
cmake --build --preset foundation
```

The foundation target checks the standalone bridge; it does not build the engine.
Unix equivalents include scripts/test/native.sh and scripts/test/lua-unix.sh.

## Pinned engine build

Choose empty absolute work locations outside game/profile directories. Configure
LORKHAN_CACHE_DIR and LORKHAN_RUN_MANIFEST, then run scripts/bootstrap/prefetch-windows.ps1
for the explicit online fetch. Set LORKHAN_SOURCE_DIR and a new LORKHAN_RUN_MANIFEST, then
run scripts/bootstrap/windows.ps1 for verified offline reconstruction. Preserve a separate
pristine tree for patch auditing. Apply and verify the patch with:

```powershell
python scripts/patches/openmw.py apply --source $env:LORKHAN_SOURCE_DIR
python scripts/patches/openmw.py verify --source $env:LORKHAN_SOURCE_DIR
```

Set LORKHAN_BUILD_DIR, LORKHAN_INSTALL_DIR and LORKHAN_OUTPUT_DIR to separate absolute
paths, then build with the prepared OpenMW dependency CMake arguments:

```powershell
./scripts/build/windows.ps1 -State patched -Config Release -Compiler msvc
```

Outputs and logs go to those selected roots. The wrapper accepts trailing CMake arguments;
use the same dependency inputs for a pristine control build. Record exact source, toolchain
and dependency versions. No discovered CTest tests means no test proof.

## Packages and source correspondence

The canonical agent guides are lorkhan/files/docs/LORKHAN, with discovery in
lorkhan/files/README-LORKHAN.md. The local installer copies this whole data tree to Data;
release runtime/Lua staging retains lorkhan/files. The release policy requires these files
in runtime, Lua and corresponding-source packages. Do not add a generic AGENTS.md to a
shared Data root. Package-specific guides need to be opened explicitly by some agents.

Use scripts/package/package.py build --help and docs/PACKAGING-COMPLIANCE.md in source.
Its --input is an already assembled staging tree, not an automatic engine installer.
Do not omit licenses, notices, provenance, exact corresponding source or audit gates.
A repository URL alone is not the source artifact. Documentation changes do not authorize
release, deployment or an engine rebuild. Fixture package tests do not prove a releasable
runtime or in-game compatibility.
