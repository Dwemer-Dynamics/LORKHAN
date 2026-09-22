# LORKHAN 0.1.0 beta

Windows x64, OpenMW 0.51.0, Lua API 129. This is an early beta. Keep existing saves and installations backed up.

## Install

1. Install or update DwemerDistro Launcher to 3.3.28 or later. Select LORKHAN and install its server. Complete its web Quickstart and select your own AI services.
2. Extract `LORKHAN-OpenMW-0.1.0-beta.1-win-x64.zip` into a new versioned directory. Do not extract over stock OpenMW or an older ALMSIVI installation.
3. Create a separate profile, pointing at your own Morrowind Data Files directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\config\Setup-Profile.ps1 -GameData 'D:\Games\Morrowind\Data Files' -ProfileRoot 'D:\LorkhanProfiles\Beta-0.1.0'
```

The script reads the local server's pairing key without displaying it. The private client config is restricted to your Windows account. The destination profile must not already exist. No game files are copied, and stock OpenMW settings and saves are not changed. Use `-Distro` if your DwemerDistro WSL instance has a different name; `-ProxyPort` defaults to 7514.

4. Start DwemerDistro, then run `Play-LORKHAN.cmd` inside the new profile. Settings, saves and audio cache stay in that profile.

For this first beta, add other mods through the isolated profile's `openmw.cfg`. Do not use the stock launcher to edit a different profile by accident. The included OpenMW launcher is provided as an engine tool, not a replacement for DwemerDistro's server manager.

## Remove or update

The runtime is portable. Remove only its extracted versioned directory to uninstall the program; retain your profile and game data. A newer beta should be extracted beside it. Back up the profile before changing its launch script to the newer executable. Disabling the server in DwemerDistro preserves its database and configuration; Repair enables it again.

## Corresponding source

The source ZIP includes the exact LORKHAN source, the pinned OpenMW source archive, patch manifest, and dependency build recipes. Dependency source archives and licenses accompany the package; hashes and acquisition URLs are recorded in manifests. No Bethesda game data, saves, API keys or generated voice audio are distributed.

For a rebuild, use Visual Studio 2022 x64 and CMake with the dependency versions in `config/dependencies/windows-x64.lock.json`. From the source ZIP, run `python scripts/package/materialize-source.py --output <new-directory>` with Python 3.12+ and Git installed. This verifies and applies the bundled source and patches without fetching upstream. Configure that directory with `LORKHAN_SOURCE_ROOT` pointing to the matching LORKHAN source checkout. Use the vcpkg toolchain and Qt prefix from the locked dependencies. Set `LuaJit_LIBRARY` to the dependency's `lib/lua51.lib`. Set `OPENMW_USE_SYSTEM_YAML_CPP`, `OPENMW_USE_SYSTEM_SQLITE3` and `OPENMW_USE_SYSTEM_RECASTNAVIGATION` to OFF, and `BUILD_OPENCS`, `BUILD_WIZARD`, `BUILD_NAVMESHTOOL`, `BUILD_BSATOOL`, `BUILD_ESMTOOL`, `BUILD_ESSIMPORTER`, `BUILD_NIFTEST`, `BUILD_BULLETOBJECTTOOL`, `BUILD_MWINIIMPORTER`, `BUILD_OPENMW_TESTS` and `BUILD_COMPONENTS_TESTS` to OFF. Build Release targets `openmw` and `openmw-launcher`. Use MSVC `/experimental:deterministic /pathmap` for developer-specific dependency paths so personal build paths are not embedded in distributed binaries.

The runtime's `lorkhan-openmw.exe` is the built `openmw.exe` renamed for side-by-side identification. Runtime resources come from the same build. The Lua files come from the matching `lorkhan/files` tree, excluding tests. DLLs include their transitive imports and the engine's OSG plugins; Qt deployment uses `windeployqt --release --no-translations --no-compiler-runtime`. Microsoft Visual C++ 2015–2022 x64 Runtime is required separately.
