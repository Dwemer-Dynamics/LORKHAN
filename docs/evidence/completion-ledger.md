# Completion and proof ledger

The authoritative current-checkpoint rows are in `proof-ledger.json` and use the states defined by `docs/PROGRAM-PLAN.md`. `AUTOMATED` means a repeatable no-game check actually passed; it never means a platform build, integrated engine, Lua runtime, mod-loader, compatibility, or game behavior passed. `PLANNED` identifies checked-in automation or a future platform lane that has not supplied qualifying execution evidence. `WINDOWS BUILD PROVEN`, `IN-GAME PROVEN`, and `COMPATIBILITY PROVEN` require evidence from those exact environments. `DEFERRED` rows state their resume condition. Run manifests attest only to the command, inputs, outputs, tools, and result they contain.

The committed run bundle at `docs/evidence/runs/3717eff-local/index.json` remains the durable standalone-foundation baseline bound to clean commit `3717effebb8d42ad7601d6ca02c19ac3533efcf8`. The newer local acceptance record at `docs/evidence/local-acceptance-2026-08-03.md` is bound to clean client commit `b60908ed18044271fa615a233e120b15d288f464` and the recorded server commits. It records 47 Python tests, 47 Lua 5.1 runtime tests, 6/6 CTests, exact-pin patch validation/audit, a Windows x64 Release OpenMW 0.51.0 product build, source/deployment hash parity, local WSL health, and desktop plus true 390px mobile browser acceptance. It does not claim the unavailable standalone-Clang lane, an unmodified OpenMW control build, a formal release package, clean uninstall, in-game behavior, or compatibility.

CI platform rows remain definitions rather than proof until their workflows execute. The exact-pin LORKHAN product now has a successful local Windows x64 Release build and deployment, while the unmodified control build and release packaging remain unproven. Final predecessor import/migration, in-game and compatibility evidence, and release/signing/publication remain deferred. `start-gate-blocker.md` records predecessor gate metadata and test-evidence observations, but no predecessor source was imported or semantically copied. Workflows, local tests, browser checks, and mocks are never promoted to in-game proof.

The current working implementation adds CHIM-compatible scoped event, speech, response, prompt, and
rechat-chain records. Automated server and Lua tests prove ordered persistence, prompt history,
action-free depth-bounded rechat, and the rule that continuation is submitted only after final spoken
playback. These working-tree checks are not promoted to committed, deployed, or in-game proof here.

The current FIFO checkpoint adds a strict typed `response.complete` bridge and one Lua-owned response
lane with dialogue-before-action ordering, response/runtime generation fencing, bounded identity
deduplication, media/action attachment, terminal delivery receipts, queued-action cancellation, and
playback-gated rechat. The 46-test Lua runtime suite, standalone MSVC native CTest, protocol/patch
validators, and the pinned OpenMW 0.51 Release `openmw` plus `openmw-launcher` build pass locally.
This is automated/build evidence only; it does not claim deployment or in-game playback proof.

The live-participant checkpoint adds an immediate, bounded actor-local OpenMW state probe after final
playback. Lua tests prove that busy candidates are excluded, a busy previous speaker cancels, and an
inactive actor leaves the managed registry. The native seam classifies dead, knocked-down/paralyzed,
combat/pursuit, and attacking/casting actors; API 129 does not expose reliable sleep state. Engine
compilation and in-game state-transition proof are required before this checkpoint is promoted.

The action-catalog parity checkpoint maps the frozen CHIM/Dialectic catalogs to 16 strict LORKHAN actions.
It adds bounded read-only inventory inspection, same-cell approach, and bounded wait; exposes the previously
implemented travel, escort, and face actions to provider normalization; and records every unsupported action
with its API-129 authority reason in `openmw-action-parity-audit.md`. The 47-test Lua suite, 77-file protocol
manifest, standalone native test, and server checks are automated evidence only; engine behavior remains unverified.

The final 2026-08-09 automated/deployment acceptance used client implementation commit
`88763b90fcafc4736592e7faf759805f14c462b0`, server implementation commit
`414a8435b297c5aedd16ee1e1d9afa895f2b5dfc`, and pinned OpenMW
`f4bec41444214a7903bebd178389ca22ca13f646`. Both draft PR heads and CI were green at those exact
implementation commits. The full OpenMW x64 Release product and launcher were built and deployed to
`C:\Modlists\LORKHAN`; the built/deployed SHA-256 values match (`openmw.exe`
`1E3CB477477429B9686DFDC2B5FEF4F64F73B9DA648D7A7DFED01B1E1FC17289`, launcher
`3CE0096D9C6E283C2319FA69A2BE8DE72A5BADA50F608B381789EAB34C385431`). All 26 deployed tracked
data files matched source and 57 cached WAV files survived deployment. LorkhanServer upgraded the
preserved local lineage through migration 046 after a validated private backup, passed its 171-relation/
1,565-column schema hash, restarted Apache and the durable worker, returned typed health, and matched the
pushed server tree with zero rsync differences. Browser checks covered the principal Config, Roleplay,
and Control Panel routes at 1920x1080, 1440x900, 1280x720, 390x844, and 375x667 without horizontal
overflow. This is current automated/build/deployment evidence only; the supplied minimal GOTY gameplay
checklist remains deliberately unclaimed.

## 2026-09-13 observed spell and pickup context

- Successful native casts and player item acquisitions feed immutable source events,
  scoped event history, and prompt context. No observation schedules a model turn.
- Spell targets are cast targets, not hit confirmations. Pickups report transferred
  quantity with canonical inventory gold units; cancelled transfers, barter, crafting,
  and console/script additions are excluded.
- Detect Magic Events defaults on. Item Pickup Detection Value defaults to 500 total
  gold. Global/Core/NPC overrides and existing category/blacklist filters affect
  prompt inclusion; original event records are retained.
- Capture-time calendars use existing zero-based Morrowind months. Loaded-save
  rollback suppresses dated future observations and retires unanchored prior-session
  spell/pickup evidence from active context. Original sources remain immutable.
- Automated Lua and protocol checks pass (81 Lua cases; 38 schemas, 77 fixtures,
  115 paired files). Live gameplay and paid-provider checks have not been performed.
- Server migration 109 records automatic NPC/creature profile revision provenance
  from the leased job. Save rollback appends a restoration revision while preserving
  manual/locked/Narrator/player/unknown-history boundaries. Revision numbers never
  move backwards, and an earlier subsequent load can follow restored ancestry.
- The user approved the physical-diary-only record exception on 2026-09-13.
  The implementation and its current proof are recorded in the checkpoint below.


## 2026-09-13 physical NPC diaries

- User-approved diary-only record exception; no arbitrary commands or general record creation.
- Physical Diary is opt-in in Core Profiles and NPC overrides, with inheritance and preset support.
- Typed capability-gated query/result delivery uses one stable book per NPC/playthrough. Saved
  dynamic records update in place; logical receipt retries preserve idempotence.
- Latest five completed generated entries supply bounded text; invalidated source jobs cannot
  return through edited UI provenance. No new provider request is made by materialization.
- Native text handling accounts for TES3 trailing-tag layout and literal game-variable markers.
- 85 Lua tests and 1265 PHP checks pass; 124 protocol files match across both repositories.
- Windows Release engine, native bridge and Beast loopback tests pass. Full integration, SQL
  backup/import/restore, migration replay and durable jobs pass against fresh factory110
  (183 relations, 1698 columns).
  No game launch, paid provider call, or in-game reading/save-load proof has been performed.

- Local deployment verified: schema110, all920 server runtime files and30 client data files
  match source; health succeeds, private paths403, unauthenticated sessions401. Configuration,
  credential and voice contents preserved. Core/NPC Physical Diary controls visually reviewed
  and toggled without saving; settings remain unchanged. Existing Default Diary LLM is Disabled.
- Engine SHA256: 575E1773656718C87038E946DB7438A7A03FA6F17788FF1369A3804EFCC6A1B5.
  Native overlay refreshed to the maintained/built binding;23 clean-pin patches and10patch tests pass.
- Server rollback: /var/backups/lorkhanserver-code.1ILb9c; live database backup:
  /var/backups/lorkhanserver-before-physical-diary-20260913.dump.
  Client rollback: %TEMP%/lorkhan-physical-diary-de5d33ebcb2d4ce0bc20bf834186cee2.
- No game or paid provider was invoked. Physical reading, dropping/trading, and save/load behavior
  still require in-game acceptance. This checkpoint completes physical diary implementation only.

## Dialogue modes and typed event injection (2026-09-16) — AUTOMATED

- One compact mode menu exposes Standard, Whisper, Close, Shout, Narrator, Director, Cheat,
  Auto Chat, Inject Event, and Inject & Chat; typed shortcuts appear beside their mode.
- Injection inputs are scene context, not player speech. Log-only injection queues no inference,
  TTS, or action work; injection chat generates a reply with the ordinary response pipeline.
- 97 Lua tests and 1474 server checks pass. Disposable database integration and migration/jobs
  pass at schema118, including subsequent NPC prompt retrieval for an intended event witness.
- Protocol manifests match across both repositories; 42 schemas and93 fixtures pass the local
  structural validator. PHP/Lua syntax and client provenance/source-tree audits pass.
- No engine code changed or rebuild was required. In-game menu interaction, live provider audio,
  and game rendering remain unverified; no game was launched.
