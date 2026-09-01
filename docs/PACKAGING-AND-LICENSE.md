# Packaging, licensing, and provenance

## License boundary

OpenMW is GPLv3. LORKHAN modifies and distributes the OpenMW program, so every runtime distribution
must preserve GPL notices and provide the exact corresponding source in a GPL-compliant manner. A
private repository does not remove distribution obligations once binaries are shared.

The Lua mod is distributed with the runtime under a GPLv3-compatible license selected in the first
implementation provenance commit. Server licensing is inherited only after auditing the final
Synthserver and every imported DialecticServer/HerikaServer file; original LorkhanServer code uses a
compatible declared license. Unknown provenance blocks release, not implementation of an original
replacement.

This plan records engineering gates, not legal advice. The release owner performs the final license
review before giving binaries to anyone.

## Provenance ledger

For every imported or derived file record:

- target path and target commit;
- source repository URL, exact commit and source path;
- source license and retained copyright/notice;
- whether copied, modified, concept-only, or original rewrite;
- transformation summary and reviewer.

Concept-only references do not justify copying code/assets. Reject files with missing/incompatible
license or replace them with an independently authored implementation based on documented behavior.

## Runtime archive allowlist

The Windows runtime archive may contain only the LORKHAN-branded OpenMW game executable and required
runtime libraries/resources, LORKHAN Lua mod/default config/schema, user documentation, license/
copyright/notices/SBOM, build/version manifest and checksums. Exclude OpenMW-CS/editor/dev tools unless
separately packaged and needed, plus all build caches/logs/dumps/saves/user config/secrets/provider
payloads/media cache and proprietary game/third-party mod files.

Installer behavior:

- installs into a versioned side-by-side directory;
- creates a separate LORKHAN OpenMW configuration profile only with confirmation;
- discovers but never copies/uploads game data outside the user's chosen local path;
- imports pairing configuration without displaying/logging the token;
- backs up any file it edits and records an uninstall manifest;
- uninstall removes only manifest-owned files and never data, saves, stock OpenMW or server state.

## Corresponding source archive

Include the exact OpenMW/LORKHAN source used, full LORKHAN changes/patch manifest, Lua source, CMake and
dependency acquisition/build/package scripts, schemas/fixtures, licenses/notices and instructions
sufficient for a recipient to rebuild the distributed runtime. Pin dependency source/binary versions
and preserve their licenses. A GitHub link alone is not the only source offer for a private/deletable
tag; publish or accompany the exact source artifact when binaries are distributed.

## Automated release audits

- archive allowlist and normalized manifest/hash comparison;
- `git status`, source tag/SHA and patch-manifest verification;
- secret/token/private-key/provider-config patterns and high-entropy scan;
- Bethesda filename/signature plus prohibited extensions (`.esm`, `.bsa`, `.omwsave`) and sampled
  binary signature scan;
- media/cache/log/dump/user-path/username scan;
- SBOM dependency/license completeness and notice presence;
- source archive rebuild rehearsal on a clean runner;
- install/uninstall dry run inside an isolated directory;
- two-build normalized reproducibility comparison.

Any finding fails closed. Suppressions require an exact file/hash/rationale in the release manifest,
not a broad pattern exemption.

## Release checklist

1. Completion and compatibility ledgers have no unexplained required row.
2. Exact source/runtime/server/schema/profile pins and test evidence are recorded.
3. GPL/provenance review signs the manifest; corresponding source is available.
4. Package audits and clean rebuild pass; checksums are generated after final bytes.
5. Minimal-profile in-game acceptance passes with copied saves and clean uninstall.
6. Release notes state supported pin/platform/profiles, upgrade/save warning, known limitations,
   server requirement, source location and no-game-data requirement.
7. Only then, with separate user authorization, publish a release/sign artifacts.
