# LORKHAN row-level implementation ledger

Updated: 2026-08-09. `AUTOMATED` means current repeatable no-game checks pass; it does not claim
manual OpenMW behavior. `WINDOWS BUILD PROVEN` requires the pinned x64 Release product build and
artifact hashes. `EXTERNAL-DEFERRED` requires gameplay, compatibility, release, or another environment
that is outside the automated goal. `EXCLUDED` is a closed product or authority decision.

| Matrix section | Row | State | Current evidence / deferral |
| --- | --- | --- | --- |
| Foundation and flow | Lifecycle/init/health | AUTOMATED | Strict session initialization, health, generation replacement, native transport, fake-server live-wire tests, local WSL health, and deployed OpenMW startup artifacts pass. |
| Foundation and flow | Local server discovery | AUTOMATED | Fixed loopback base URL and hash-only pairing configuration replace legacy probing; profile management writes UTF-8 without a BOM and preserves private credentials. |
| Foundation and flow | Version/capability negotiation | AUTOMATED | Pinned OpenMW/API/client/content metadata and negotiated controls/actions are schema-, native-, server-, and fixture-tested. |
| Foundation and flow | Typed events and correlation | AUTOMATED | Byte-identical strict v1 contracts cover message, request, turn, session, generation, runtime generation, cursor, duplicate, hostile, and stale cases. |
| Foundation and flow | Cancellation/halt/recovery | AUTOMATED | Native cancellation, session/target/runtime fencing, recoverable Halt, hard Halt, media cleanup, stale-drop, and queued-action terminal receipts pass native and Lua checks. |
| Foundation and flow | Streaming response experience | AUTOMATED | One bounded FIFO response lane consumes canonical `response.complete`, orders dialogue before actions, attaches media, emits one terminal delivery, and gates rechat on final playback. |
| Foundation and flow | TTS media download/cache | AUTOMATED | Bearer-authenticated opaque media retrieval validates status, MIME, length, WAV framing, SHA-256, ownership, expiry, cache replacement, and cleanup; deployed cache contents were preserved. |
| Foundation and flow | Native actor speech/lips | EXTERNAL-DEFERRED | OpenMW-native actor speech and LORKHAN TTS gain are wired, but voice identity, loudness, interruption, and lips in the final build require the post-goal gameplay checklist. |
| Foundation and flow | Installation diagnostics | AUTOMATED | Redacted bridge status, diagnostics, session history, server health, worker, request, queue, provider, log, backup, and schema views are implemented and HTTP-tested. |
| Input, dialogue, and presentation | Targeted conversation | AUTOMATED | Semantic typed-talk action, aimed actor resolution, committed target identity, target/session replacement, and compact input flow pass structural and Lua runtime tests. |
| Input, dialogue, and presentation | Group conversation | AUTOMATED | Bounded explicit audience selection, speaker/addressee identities, deterministic multi-utterance persistence, one speech lane, and stale group fencing pass Lua and PostgreSQL integration. |
| Input, dialogue, and presentation | Typed player input | AUTOMATED | OpenMW TextEdit input uses bounded UTF-8 validation and routes through the canonical player-text pipeline. |
| Input, dialogue, and presentation | Push-to-talk/STT | AUTOMATED | Configurable hold action, PCM16 WAV capture, authenticated binary upload, durable provider job, transcript/failure events, device selection, and generation fencing pass protocol, native, Lua, PHP, and PostgreSQL tests. |
| Input, dialogue, and presentation | Open microphone | AUTOMATED | Explicit toggle/mute, bounded VAD sensitivity/end/max/no-voice delays, recording-device selection, and zero microphone polling while disabled pass structural and runtime checks. |
| Input, dialogue, and presentation | Subtitles/transcript | AUTOMATED | Normal actor subtitle delivery is the sole automatic dialogue surface; History and Diagnostics remain user-opened tools. Duplicate top-left dialogue output is absent. |
| Input, dialogue, and presentation | Interrupt/skip/hard halt | AUTOMATED | Stop Dialogue, action-only Halt, hard Halt, player supersession, target/session/generation changes, and provider failure cancel owned FIFO work and suppress stale playback. |
| Input, dialogue, and presentation | Automatic greeting, boredom, and combat barks | IMPLEMENTED | One game-owned real-time scheduler emits idle-only typed turns, uses verified actor state, applies bounded cooldowns, and never interrupts active dialogue or emits actions. |
| Input, dialogue, and presentation | Playback-gated rechat | AUTOMATED | Depth-bounded, action-free continuation advances only after the final `played` delivery and retains target/session/generation/runtime-generation fencing. |
| Input, dialogue, and presentation | Vanilla dialogue context | AUTOMATED | Passive Morrowind dialogue response context is bounded and prompt-tested without replacing vanilla dialogue UI. |
| Input, dialogue, and presentation | Skyrim/Fallout HUD widgets | EXCLUDED | OpenMW-native settings, chat, targeting, subtitle, history, and diagnostics surfaces replace SWF, Papyrus, Pip-Boy, and xNVSE widgets. |
| Game and character context | Player stats/identity | AUTOMATED | TES3 player identity, race, class, birthsign, attributes, skills, dynamic stats, equipment, and bounded status serialize through typed context. |
| Game and character context | Target and nearby actors | AUTOMATED | Active-cell bounded identities, distance, combat/death, managed AI activity, explicit target, group audience, and nearby actor summaries are prompt-tested. |
| Game and character context | Cell/region/time/weather | AUTOMATED | Cell, region, interior/exterior state, date/time, and exposed weather fields use explicit bounded Morrowind XML sections. |
| Game and character context | Factions/disposition/reputation | AUTOMATED | Read-only faction, rank, disposition, and relationship context is typed and prompt-traced; mutation remains excluded. |
| Game and character context | Inventory/equipment/gold | AUTOMATED | Stable record identities and bounded player/actor inventory, equipment, held item, count, and gold summaries are typed and prompt-tested. |
| Game and character context | Spells/active effects | AUTOMATED | API-129-exposed actor spell/effect summaries remain read-only and bounded. |
| Game and character context | Journal/quests/topics | AUTOMATED | UTF-8 Journal and recent vanilla dialogue observations feed Morrowind context without provisioning the excluded AI Quest system. |
| Game and character context | Nearby items/doors/containers | AUTOMATED | Bounded nearby items and points of interest include record identity, ownership, lock level, key, and trap metadata without a world scan. |
| Game and character context | Loaded mods/load order | AUTOMATED | Bounded content-file list, fingerprint, truncation, and exact content identity are part of session/game-data contracts. |
| Game and character context | Physical VR state | EXCLUDED | OpenMW Morrowind is a flat-screen target; no HMD or hand contract is shipped. |
| Game and character context | Fallout/Skyrim-specific systems | EXCLUDED | Pip-Boy, VATS, Power Armor, shouts, Dragonborn, Papyrus aliases, Skyrim FormIDs, and xNVSE outcomes are not LORKHAN capabilities. |
| Intelligence and server product | Character profiles/prompts | AUTOMATED | Global -> Core Profile -> NPC inheritance, immutable revisions, typed profile/prompt editors, generation jobs, model slots, per-speaker TTS, voice fallbacks, locking, portraits, import/export, and prompt traces pass server and browser tests. |
| Intelligence and server product | Short/middle/long memory | AUTOMATED | Played-only recent memory plus deterministic four-to-one middle/long consolidation, provenance, retrieval, rebuild, edit, delete, retention, and playthrough isolation pass PostgreSQL tests. |
| Intelligence and server product | Relationships | AUTOMATED | Actor/player relationship state, manual/derived modes, immutable audit, prompt integration, and scoped CRUD pass repository and browser workflows. |
| Intelligence and server product | Dynamic profiles | AUTOMATED | Server-owned revision history, source/event provenance, scoped profile binding, target generation, installation-batch generation, and narrator generation are durable and revision-fenced. |
| Intelligence and server product | World knowledge | AUTOMATED | Bounded authored ingestion, checksums, scoped retrieval, trace reasons, Oghma views, and deletion pass typed repository and HTTP tests. |
| Intelligence and server product | Narrator and diary | AUTOMATED | Opt-in narrator profile/routing plus manual narrator, diary, and summary CRUD are available. Typed timer, sleep, and optional wait candidates feed server-gated Player, Narrator, and nearby NPC diary jobs with per-profile cooldowns; automatic generation remains off by default. |
| Intelligence and server product | Playthrough export/restore | AUTOMATED | Scoped transactional export/restore and hash-verified same-installation configuration backup/restore preserve ownership and exclude secrets/runtime media. |
| Intelligence and server product | LLM/STT/TTS providers | AUTOMATED | Typed provider catalogs, exact STT wire formats, installation-global STT, profile-routed LLM/TTS, fallback voices, API Badge isolation, health/test controls, and durable worker selection pass mock/provider contract tests. Live credentials remain outside CI. |
| Intelligence and server product | Prompt/action editor | AUTOMATED | Revisioned prompt CRUD/import/export/clone and labelled action policy controls are catalog-bounded and cannot broaden negotiated OpenMW authority. |
| Intelligence and server product | Request/event logs | AUTOMATED | Canonical eventlog, speech, responselog, prompt traces, provider attempts, response queue, action receipts, and rechat correlation read from one typed authority. |
| Intelligence and server product | Workers/backups/health | AUTOMATED | Durable leases, retry/dead-letter, restart recovery, cleanup/retention, redacted diagnostics, dump/restore, local WSL worker restart, and health checks pass. |
| Actions | Inspect/report | AUTOMATED | `inspect.report` and `inventory.inspect` are Tier 0, bounded, capability-gated, identity-fenced, and terminal-receipt tested. |
| Actions | Follow/escort/travel/wander/pursue | AUTOMATED | `ai.follow`, `ai.stop`, `ai.approach`, `ai.wait`, `ai.travel`, `ai.escort`, and `ai.wander` use bounded LORKHAN-owned actor-local packages; unsafe persistent/global pursuit alternatives are not substituted. |
| Actions | Start/stop combat | AUTOMATED | Tier-2 confirmed `combat.start` and owned-only `combat.stop` use strict actor/target/session/generation fencing and one terminal receipt. |
| Actions | Face/look/animation/speech | AUTOMATED | Bounded asynchronous `ai.face` plus allowlisted `animation.play` are lifecycle-cancellable; unavailable head/eye and arbitrary animation authority is not inferred. |
| Actions | Equip/use/consume | AUTOMATED | Tier-2 `item.equip`, `item.unequip`, and `item.use` operate only on an existing acting-NPC inventory record and allowlisted equipment slots. |
| Actions | Give/take item or gold | EXCLUDED | API 129 exposes exact transfer mutation only to global objects, not the actor-local authority used by LORKHAN; no unsafe two-owner mutation protocol is shipped. |
| Actions | Lock/unlock | EXCLUDED | No bounded actor-local ownership and observed completion boundary exists for arbitrary locks. |
| Actions | Trade/menu opening | EXCLUDED | API 129 has no bounded typed actor-local service/menu action with a dependable terminal result. |
| Actions | Teleport/spawn/delete/record creation | EXCLUDED | Arbitrary global creation, relocation, deletion, and lethal authority violates the action trust boundary. |
| Actions | Stat/faction/reputation/quest mutation | EXCLUDED | These domains are read-only context and have no owned reversible mutation boundary. |
| Actions | Arbitrary console/Lua/MWScript/files/network | EXCLUDED | Permanently outside the model action boundary. |
| Packaging and compatibility | Windows x64 Release | WINDOWS BUILD PROVEN | Pinned OpenMW 0.51.0/API 129 and standalone native x64 Release builds pass; built/deployed `openmw.exe` and launcher hashes match. |
| Packaging and compatibility | Linux x64/macOS arm64 | EXTERNAL-DEFERRED | Removed from supported product CI by explicit scope. No platform package or compatibility claim is made. |
| Packaging and compatibility | Upstream control | EXTERNAL-DEFERRED | An unmodified control build is outside the finalized parity goal and remains unclaimed. |
| Packaging and compatibility | Patch narrowness | AUTOMATED | Exact-pin five-path patch apply/verify/audit, source scan, manifests, schemas, fixtures, and Windows product compilation pass. |
| Packaging and compatibility | Runtime archive | EXTERNAL-DEFERRED | The local runtime is deployed, but versioned public packaging/release was not authorized. |
| Packaging and compatibility | Corresponding source | AUTOMATED | Frozen source refs, generated patch manifest, build scripts, licenses/notices, checksums, and draft PR heads are recorded and public. |
| Packaging and compatibility | Minimal GOTY | EXTERNAL-DEFERRED | Final manual target/text/voice/group/rechat/action/halt/cell/save-load checklist is supplied but not claimed. |
| Packaging and compatibility | I Heart Vanilla | EXTERNAL-DEFERRED | Requires a later profile-specific gameplay matrix. |
| Packaging and compatibility | Expanded Vanilla | EXTERNAL-DEFERRED | Requires a later dense-content gameplay matrix. |
| Packaging and compatibility | Total Overhaul | EXTERNAL-DEFERRED | Requires a later maximum-load performance and compatibility matrix. |
| Packaging and compatibility | Tamriel Rebuilt/Project Tamriel | EXTERNAL-DEFERRED | Requires a later added-lands identity, faction, Journal, and content matrix. |
| Packaging and compatibility | Controller/Steam Deck | EXTERNAL-DEFERRED | Requires controller/Linux runtime and UI-scaling gameplay evidence. |
| Packaging and compatibility | Voice mod coexistence | EXTERNAL-DEFERRED | Requires live speech priority/interruption/vanilla-voice compatibility evidence. |
