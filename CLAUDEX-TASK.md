# Azure Sol assignment: build LORKHAN

## Objective

Implement LORKHAN as a side-by-side OpenMW 0.51.0 distribution plus Lua mod that preserves every
applicable CHIM/Dialectic/SYNTH behavior, communicates with sibling `RANGROO/LorkhanServer`, and
produces deterministic Windows x64 packages with focused supported-platform CI. Do not weaken
OpenMW's Lua sandbox and do not require a proprietary content addon for the first complete product.

Current user override: Windows x64 Release is the supported native CI/product lane. Ubuntu CI runs
portable Python/Lua/contracts/audits only. Linux-native, sanitizer, macOS, and definition-only CI
lanes are removed. Manual gameplay does not block the automated build/deployment goal and remains
explicitly unverified until the user runs the supplied checklist.

## Start gate and baselines

Do not begin source import until `RANGROO/SYNTH` and `RANGROO/Synthserver` have completed their
documented non-game stop conditions. Record their final SHAs in `docs/evidence/source-pins.md`.

- Working repositories: `RANGROO/LORKHAN` and sibling `RANGROO/LorkhanServer`.
- Engine: `OpenMW/openmw` tag `openmw-0.51.0`, commit
  `f4bec41444214a7903bebd178389ca22ca13f646`, Lua API revision 129, GPLv3.
- Server seed: the final tested `RANGROO/Synthserver` main SHA after SYNTH completion.
- Fallout client reference: the final tested `RANGROO/SYNTH` main SHA after SYNTH completion.
- Reference client behavior: `Dwemer-Dynamics/Dialectic@eddbdc77a8347128b5cf5bcd68df0c2404fbf074`.
- Skyrim design behavior: `Dwemer-Dynamics/CHIM@77c73ffb6bb32c226340bbda93b3aac5a7ad49f8`.
- Server lineage references: `Dwemer-Dynamics/DialecticServer@f447a9c6b59bfc689c788fb0139a0d13c6c6dc51`
  and `abeiro/HerikaServer@0dbfa3eb4d3197d8159b5ff2c77bfdb5bf98b4d0`.

Reference repositories are read-only. Import only behavior whose license and provenance are
recorded. Never copy Bethesda data, compiled plugins, voices, saves, credentials, or unknown-origin
assets.

## Required reading and decision lock

Read, in order:

1. `docs/PROGRAM-PLAN.md` and its decision register.
2. `docs/REFERENCE-STACK-DATAFLOW.md`.
3. `docs/ENGINE-INTEGRATION-PLAN.md` and `docs/LUA-MOD-ARCHITECTURE.md`.
4. `docs/ARCHITECTURE.md`, `docs/PROTOCOL.md`, and the sibling protocol document.
5. `docs/FEATURE-PARITY-MATRIX.md`, `docs/OPENMW-TOOLCHAIN.md`,
   `docs/COMPATIBILITY-PLAN.md`, and `docs/PACKAGING-AND-LICENSE.md`.
6. Every sibling `LorkhanServer/docs/*.md` document.

The decisions in those documents are closed. A discovered engine fact may require a documented
change proposal and failing evidence, but it is not permission to silently redesign the boundary.

## Agent topology

Use one Sol parent and at most four non-overlapping children:

1. **Engine/transport owner:** pinned OpenMW worktree, `openmw.lorkhan`, bounded Boost.Beast loopback
   transport, configuration, cancellation, media staging, C++ tests, patch manifest.
2. **Lua/gameplay owner:** `.omwscripts`, global/player/CUSTOM scripts, UI, input, targeting,
   snapshots, actions, save/load, Lua tests.
3. **Server owner:** sibling LorkhanServer migration, protocol, schema, providers, UI, workers, PHP
   tests. It may not edit client protocol fixtures directly.
4. **Verifier/critic:** read-only parity, sandbox, threading, GPL/provenance, package, compatibility,
   and evidence audit until given isolated test/fixture ownership.

The parent owns shared schemas and reconciles cross-repository changes. Writers must have disjoint
files. Do not spend agents repeating the same repository scan.

## Required implementation order

1. **Evidence and source map.** Create `docs/evidence/source-pins.md`, `component-map.md`, and
   `completion-ledger.md`. Pin all sources, licenses, retained behaviors, target owners, and proof.
   Import the final Synthserver into the sibling repo through a reviewable commit preserving its
   history/provenance; do not blindly fork current planning content.
2. **Reproducible OpenMW foundation.** Add an upstream remote/pin script and deterministic patch
   manifest. Establish the supported MSVC 2022 Windows x64 Release lane plus portable Ubuntu
   foundation/contract checks. Produce an unmodified upstream control build before the first patch.
3. **Typed native bridge.** Implement `openmw.lorkhan` only in GLOBAL, PLAYER, and CUSTOM local
   contexts. Add config/status/capabilities, bounded async request/cancel/poll, and verified media
   staging/playback operations. Use Boost.Asio/Beast with `Boost::system`; accept only HTTP to an IP
   loopback literal, reject DNS/redirects, keep the pairing secret native, and expose no generic
   request primitive to Lua.
4. **Health vertical slice.** Implement one lifecycle/init request against the sibling fake server:
   engine event -> immutable DTO -> worker -> strict response -> generation-bound Lua event ->
   visible UI/status. Prove timeout, cancellation, malformed/oversized responses, disconnect, and
   stale-generation suppression before dialogue work.
5. **Lua foundation and dialogue slice.** Add `LORKHAN.omwscripts`, GLOBAL orchestration, PLAYER
   input/UI, dynamically attached CUSTOM actor script, protocol mappers, storage, and one complete
   targeted text dialogue flow. Use a dedicated action/hotkey; never replace vanilla activation.
6. **Input, groups, and media.** Add configurable keyboard/controller actions, text entry, semantic
   push-to-talk, STT upload, group audience, streamed/polled response events, subtitles, TTS cache,
   actor-positioned `Sound.say`, interruption, queueing, and hard halt. Native media staging must
   make generated files available without giving Lua arbitrary paths.
7. **Context and intelligence.** Add bounded snapshots for player, cell/region, game time, weather,
   nearby actors/objects, target, stats, factions/disposition/reputation, inventory/equipment,
   active effects/spells, journal/quests, loaded content/load order, and captured vanilla dialogue.
   Implement server memory, relationships, profiles, narrator, diary, world knowledge, playback-gated
   rechat, and playthrough restore behavior. Exclude boredom, automatic greetings, combat barks,
   ITT, Background Life, and every timer-driven model trigger.
8. **Typed actions.** Prove a read-only action end to end, including correlated terminal result.
   Then add allowlisted follow/escort/travel/wander/pursue/combat package controls, stop, face/look,
   equip/use/consume, give/take exact inventory deltas, and safe UI interactions supported by API
   revision 129. Keep mutation tiers disabled by default. Never add console/Lua/MWScript execution.
9. **Management and operations.** Complete the server quickstart, profiles, provider settings,
   prompt/action editor, request traces, memories, relationships, world knowledge, playthroughs,
   health, backups, worker supervision, credential redaction, import/export, and diagnostics UI.
10. **Hardening and packages.** Run upstream and LORKHAN tests, protocol fixture parity, fuzz and
    negative fixtures, deterministic packaging, SBOM/notices/source archive, secret/proprietary-data
    scans, upgrade/rollback, and all no-game compatibility tests.
11. **Windows acceptance.** On legally supplied Morrowind GOTY data, run minimal vanilla and each
    required compatibility profile in `COMPATIBILITY-PLAN.md`. Record video/screenshots/logs,
    content manifest, save copies, version, package hash, and every in-game matrix result.

## Proof required without Morrowind data

- Clean Windows x64 Release LORKHAN build from the exact OpenMW pin plus portable Ubuntu
  Python/Lua/contract/audit results. Linux-native and macOS builds are deferred.
- An unmodified upstream control build plus patch-manifest audit proving the integration is narrow.
- C++ tests for URL/IP enforcement, authentication, schema/size/hash validation, bounded queues,
  cancellation, generations, timeout, backpressure, media lifecycle, redaction, and shutdown.
- Lua tests for protocol mapping, target/audience state, snapshots, action allowlists/results,
  storage migration, halt, queueing, and UI view models.
- Fake-server E2E for init, dialogue, group dialogue, STT, TTS, media hash failure, action/result,
  save/load invalidation, malformed/oversized data, server loss/restart, and duplicate IDs.
- Byte-identical schemas/fixtures in both repos and a compatibility test that runs both validators.
- Reproducible client/runtime/source archives with SBOM and no game data, credentials, logs, saves,
  caches, raw provider output, or unrelated OpenMW applications.

## Explicitly deferred proof

- In-game behavior until the user supplies a legal Morrowind GOTY installation on Windows.
- Android packaging and touch/mobile lifecycle.
- Multiplayer/shared-world authority; LORKHAN is a single-player multi-character system.
- Original `.omwaddon` records. The first release uses `.omwscripts`; add records only through the
  separately gated process in `CONTENT-ADDON-DEFERRED.md`.
- Automatic support for a future OpenMW tag. Each upgrade is a new pin, API/schema review, control
  build, save-copy migration matrix, compatibility run, and package.

## Boundaries

- Work only in LORKHAN, sibling LorkhanServer, and isolated temporary worktrees.
- Pushes to the two existing draft PR branches and the final local deployment are authorized by the
  active goal. Do not merge, release, publish, change GitHub settings, or modify reference repos.
- Do not put source, secrets, saves, game data, provider payloads, or personal data outside the
  user's approved personal Azure project.
- Preserve all pre-existing user work. Never clean or reset an ambiguous worktree.

## Stop condition

Do not stop because a schedule ended. Stop only when every non-game, non-Android, non-content-addon
row in both completion ledgers is implemented and proven, all automated/build/package/license gates
pass, both repos are clean, and the critic finds no unexplained parity or security gap. If a true
external dependency blocks progress, record the exact command/error, exhausted alternatives, owner,
and smallest evidence needed to resume; continue every other independent row first.
