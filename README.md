# LORKHAN

AI character framework for **The Elder Scrolls III: Morrowind**, powered by OpenMW.
Combines a native OpenMW bridge and Lua mod with [LorkhanServer](https://github.com/Dwemer-Dynamics/LorkhanServer).

## Features

- Text and voice conversations with NPCs.
- Streamed speech, subtitles and vanilla dialogue speech playback.
- NPC profiles, memories, relationships and contextual reactions.
- In-game interaction controls and supported NPC actions.
- Playthrough-aware context and server-managed configuration.

## Requirements

- A legally owned Morrowind installation; game data is not included.
- The matching LORKHAN OpenMW build and Lua files.
- [LorkhanServer](https://github.com/Dwemer-Dynamics/LorkhanServer) for AI and speech services.

This is a **0.5.0 prototype**. Publishing source does not constitute a packaged binary release.
OpenMW is pinned to 0.51.0 commit `f4bec41444214a7903bebd178389ca22ca13f646` (Lua API 129).

## Development

- [Build instructions](lorkhan/files/docs/LORKHAN/building.md)
- [Architecture and diagnostics](lorkhan/files/docs/LORKHAN/agent-guide.md)
- [Packaging and source compliance](docs/PACKAGING-COMPLIANCE.md)
- [Contributor instructions](CONTRIBUTING.md)

## Branches and pull requests

**`unstable` → `dev` → `lorkhan`**

| Branch | Purpose |
| --- | --- |
| `unstable` | Development; submit feature and fix PRs here. |
| `dev` | Beta testing after maintainer promotion. |
| `lorkhan` | Stable/default branch after release review. |

Discuss proposed work with maintainers before submitting a PR.
See [CONTRIBUTING.md](CONTRIBUTING.md) and the [PR template](.github/PULL_REQUEST_TEMPLATE.md).
Promotions are reviewed manually. All three branches initially contain identical code.

## License

Project code is licensed under the [GNU GPL v3.0](LICENSE).
Third-party components retain their original licenses and notices.
Bethesda game content is not covered by this license and is not distributed here.
