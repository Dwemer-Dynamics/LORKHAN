# Packaging and source compliance

Release packaging scripts, audit policies and their review records are maintained locally.
They are not prerequisites for compiling the client. See
[building.md](../lorkhan/files/docs/LORKHAN/building.md) for the supported source build.

Distributed builds must retain the GPL license, third-party notices, dependency source
and exact corresponding OpenMW source plus LORKHAN patches. Preserve dependency pins
from `config/dependencies` and the engine pin from `config/source-pins/openmw.json`.

Before publication, check archives for credentials, private paths, game data and unsafe
archive entries. Verify checksums, source correspondence and reproducibility. Keep
packaging, native tests and actual in-game acceptance results separate.

Do not include Morrowind data, saves, user profiles, generated voices or pairing keys.
Install and uninstall only package-owned files; preserve users' existing game data.
