# Building LORKHAN from source

The client repository contains the native bridge, Lua mod, OpenMW patches and build inputs.
Release packaging and Python audit tools are maintained locally, not in this repository.

## Requirements

- Git, CMake 3.25+ and a C++20 compiler.
- Windows engine builds: Visual Studio 2022 C++ workload and the OpenMW dependencies.
- Lua 5.4 or LuaJIT for the optional Lua tests.
- OpenMW 0.51.0, commit `f4bec41444214a7903bebd178389ca22ca13f646` (Lua API 129).
- See `config/dependencies/windows-x64.lock.json` for release dependency pins.

Python is not required by LORKHAN's build configuration. Upstream dependency tools may
have their own prerequisites. Never include game data, credentials or saves in source.

## Standalone bridge checks

Run from the LORKHAN checkout:

```powershell
cmake -S . -B build/native -G "Visual Studio 17 2022" -A x64
cmake --build build/native --config Release
ctest --test-dir build/native -C Release --output-on-failure
./scripts/test/lua-windows.ps1
```

This builds the bridge and its tests, not the complete OpenMW game.

## Prepare the engine source

Choose a new source directory outside the LORKHAN checkout. The following PowerShell
commands apply the tracked patches and verify the resulting files without Python:

```powershell
$repo = (Get-Location).Path
$source = 'D:\build\openmw-lorkhan'
$pin = 'f4bec41444214a7903bebd178389ca22ca13f646'
if (Test-Path -LiteralPath $source) { throw 'Choose a new source directory' }
git clone --no-checkout https://gitlab.com/OpenMW/openmw.git $source
if ($LASTEXITCODE -ne 0) { throw 'Clone failed' }
git -C $source -c core.autocrlf=false checkout --detach $pin
if ($LASTEXITCODE -ne 0) { throw 'Pinned checkout failed' }
$manifest = Get-Content "$repo/openmw-patches/patch-manifest.json" -Raw | ConvertFrom-Json
foreach ($change in $manifest.changes) {
    $artifact = Join-Path "$repo/openmw-patches" $change.artifact
    if ((Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash -ne $change.artifact_sha256) {
        throw "Patch checksum mismatch: $($change.artifact)"
    }
    if ($change.operation -eq 'add') {
        $destination = Join-Path $source $change.path
        New-Item -ItemType Directory -Force -Path (Split-Path $destination) | Out-Null
        Copy-Item -LiteralPath $artifact -Destination $destination
    } else {
        git -C $source -c core.autocrlf=false apply --recount --whitespace=error-all $artifact
        if ($LASTEXITCODE -ne 0) { throw "Patch failed: $($change.path)" }
    }
}
foreach ($change in $manifest.changes) {
    $destination = Join-Path $source $change.path
    if ($change.operation -eq 'delete') {
        if (Test-Path -LiteralPath $destination) { throw "Deleted file remains: $($change.path)" }
    } elseif ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $change.result_sha256) {
        throw "Patched source checksum mismatch: $($change.path)"
    }
}
```

## Compile OpenMW

Prepare the dependencies required by the pinned upstream OpenMW source. Configure with
its dependency/toolchain paths and `-DLORKHAN_SOURCE_ROOT` pointing to this checkout:

```powershell
cmake -S $source -B D:/build/lorkhan-engine -G "Visual Studio 17 2022" -A x64 `
    "-DLORKHAN_SOURCE_ROOT=$repo" `
    "-DCMAKE_TOOLCHAIN_FILE=D:/dependencies/vcpkg/scripts/buildsystems/vcpkg.cmake" `
    "-DCMAKE_PREFIX_PATH=D:/dependencies/Qt/6.6.3/msvc2019_64" `
    -DBUILD_OPENCS=OFF
cmake --build D:/build/lorkhan-engine --config Release --target openmw openmw-launcher
```

The dependency paths above are examples; replace them with your prepared dependency
locations. The upstream dependency configuration can require additional CMake options.
The existing `scripts/build/windows.ps1` and `scripts/build/unix.sh` wrappers are also
available for recording build outputs. Install the Lua files from `lorkhan/files`
alongside the matching engine, never into an unrelated game's data directory.

Keep GPL licensing, third-party notices, exact source pins and corresponding source
with distributed builds. A successful compilation does not prove in-game behavior.
