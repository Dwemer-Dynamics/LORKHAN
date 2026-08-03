# ALMSIVI feature parity and completion matrix

The implementation ledger copies these rows and attaches evidence. `Keep` means required; `Adapt`
means the user outcome remains but implementation is OpenMW-native; `Defer` has a defined later gate;
`Exclude` is a closed decision.

## Foundation and flow

| Capability | Decision | ALMSIVI implementation / proof |
| --- | --- | --- |
| Lifecycle/init/health | Keep | OpenMW session/generation + native health round trip; fake E2E and in-game log/UI. |
| Local server discovery | Adapt | Fixed loopback profile config and pairing token; no legacy file probing. |
| Version/capability negotiation | Keep | Engine/API/client/content capabilities in init; mismatch fixtures. |
| Typed events and correlation | Keep | Strict v1 JSON, UUIDs, event cursor, idempotency; dual validators. |
| Cancellation/halt/recovery | Keep | Generation, request cancel, speech/AI/UI clear, server restart; race tests. |
| Streaming response experience | Adapt | Bounded long-poll events and text deltas rather than a Lua socket stream. |
| TTS media download/cache | Keep | Native opaque-ID verified cache; hash/limit/failure tests. |
| Native actor speech/lips | Adapt | Existing OpenMW voice/loudness path used by controlled media service; in-game proof. |
| Installation diagnostics | Keep | Redacted native/server status and exportable manifest; secret scan. |

## Input, dialogue, and presentation

| Capability | Decision | Implementation / proof |
| --- | --- | --- |
| Targeted conversation | Keep | Dedicated semantic action + ray target/nearby picker. |
| Group conversation | Keep | Explicit speaker/addressee/audience registry and one ordered no-overlap speech lane. |
| Typed player input | Keep | Custom TextEdit overlay, size/UTF-8 validation. |
| Push-to-talk/STT | Keep | Semantic input action, native/server bounded audio upload, transcript event. |
| Open microphone | Keep, opt-in | VAD/rate/privacy indicator; default off. |
| Subtitles/transcript | Keep | Custom UI with speaker and status, independent of stock subtitle toggle. |
| Interrupt/skip/hard halt | Keep | Reserved control lane; speech/action/server cancellation. |
| Automatic greeting | Keep, opt-in | Activity/distance/cooldown/rate rules. |
| Rechat/boredom | Keep, opt-in | Server scheduler plus current-game safety checks. |
| Vanilla dialogue context | Adapt | Passive `DialogueResponse` capture; never replace vanilla UI. |
| Skyrim/Fallout HUD widgets | Adapt | OpenMW Lua UI built from scratch; no copied SWF/Papyrus. |

## Game and character context

| Domain | Decision | Notes |
| --- | --- | --- |
| Player stats/identity | Keep | TES3 race/class/birthsign/skills/attributes/dynamic stats. |
| Target and nearby actors | Keep | Active-cell bounded registry, state/distance/combat/death plus actor-local AI activity for managed actors. |
| Cell/region/time/weather | Keep | OpenMW fields where exposed; explicit capability gaps. |
| Factions/disposition/reputation | Keep | Read context; mutation excluded by default. |
| Inventory/equipment/gold | Keep | Bounded summaries with stable record identities. |
| Spells/active effects | Keep | API-129 actor types. |
| Journal/quests/topics | Keep | OpenMW journal/dialogue APIs and recent responses. |
| Nearby items/doors/containers | Keep | Bounded `nearby` reads with names, ownership, lock level, key and trap metadata; no full-world scan. |
| Loaded mods/load order | Keep | `core.contentFiles.list`, fingerprint and truncation. |
| Physical VR state | Exclude | OpenMW Morrowind target is flat; no HMD/hand contract. |
| Fallout/Skyrim-specific systems | Exclude | No Pip-Boy, VATS, Power Armor, shouts, Dragonborn, Papyrus aliases. |

## Intelligence and server product

| Capability | Decision | Proof |
| --- | --- | --- |
| Character profiles/prompts | Keep | TES3-aware searchable profile editor with prompt head, core identity, biography, skills, moods, lock/favorite state, default-on edit locking, independent profile cloning, file-picker imports, bulk unlock/delete/binding switch, private portraits, revision history, prompt trace, revision-safe NPC/narrator generation, player speech-style analysis from up to 200 real inputs, primary LLM routing and per-speaker TTS connector selection with safe fallbacks; TTS Studio blocks local sample deletion while a profile or connector references it; server runtime and saved model slots have non-persistent contract probes. |
| Short/middle/long memory | Keep | Event-derived memory with provenance plus CHIM-style create, edit, deterministic index rebuild and soft-delete management. |
| Relationships | Keep | Actor/player scoped state with manual create/edit and audited soft-delete management. |
| Dynamic profiles | Keep | Server-controlled revisions with source/event history. |
| World knowledge | Keep | Scoped documents/facts with retrieval trace. |
| Narrator and diary | Keep | Opt-in narrator persona, inline routing, player-local speech, and revision-safe PHP/in-game narrator generation are implemented; dedicated narrator/diary/summary CRUD exists, while automatic diary generation remains deferred. |
| Rechat, boredom and greetings | Keep | Runtime-backed Global Settings schedules are editable, default off, bounded to 30-86400 seconds, and require an active session in the exact playthrough scope before enabling. |
| Playthrough export/restore | Keep | Transactional server snapshot plus binding safeguards. |
| LLM/STT/TTS providers | Keep | Full CHIM-lineage TTS/STT catalogs, bounded adapters, health and secret handling, per-profile routing, portable LLM/TTS/STT preset export/import/clone with in-use deletion guards, and a persistent voice studio with traversal-safe bounded ZIP batch import, explicit OmniVoice/Chatterbox/XTTS voice discovery, revisioned default-voice selection, per-voice testing, and sample sync to compatible local services. |
| Prompt/action editor | Keep | Validated schemas, revisions, rollback, portable prompt export/import/clone, explicit per-NPC prompt selection with in-use deletion guards, and labelled per-action policy controls that cannot broaden the server-owned OpenMW catalog. |
| Request/event logs | Keep | Structured/redacted correlation and retention. |
| Workers/backups/health | Keep | Supervised worker, retry/dead-letter queue, health/audit/provider diagnostics, bounded redacted server-log viewer, schema migrations, retention controls, scoped playthrough export/restore, and hash-verified same-installation configuration backup/restore that excludes secrets and runtime data. |

## Actions

| Action family | Decision | Initial enablement |
| --- | --- | --- |
| Inspect/report | Keep | Tier 0 on. |
| Follow/escort/travel/wander/pursue | Keep | Tier 1 opt-in after individual proof. |
| Start/stop combat | Keep | Tier 1 opt-in with hostility/essential/player safeguards. |
| Face/look/animation/speech | Keep | Tier 1; allowlisted and restorable. |
| Equip/use/consume | Keep | Tier 1, owned inventory only. |
| Give/take item or gold | Keep | Tier 2, exact delta and ownership confirmation. |
| Lock/unlock | Adapt | Tier 2 only where API/preconditions are proven. |
| Trade/menu opening | Adapt | Use supported UI/interface only; no simulated raw input. |
| Teleport/spawn/delete/record creation | Exclude initially | Too destructive; original content gate does not auto-enable it. |
| Stat/faction/reputation/quest mutation | Exclude initially | Read-only context; no model authority. |
| Arbitrary console/Lua/MWScript/files/network | Exclude permanently | Violates trust boundary. |

## Packaging and compatibility

| Row | Required completion evidence |
| --- | --- |
| Windows x64 Debug/Release | Clean exact-pin build/tests, package hashes and logs. |
| Linux x64/macOS arm64 | Clean build/tests; secondary package only after platform-specific acceptance. |
| Upstream control | Unmodified OpenMW pin builds/tests with same environment. |
| Patch narrowness | Manifest and diff audit, API surface/security tests. |
| Runtime archive | Deterministic ALMSIVI app, mod/default config, notices/SBOM; no unrelated apps/data. |
| Corresponding source | Exact fork source/patches/build scripts/license/checksums. |
| Minimal GOTY | Full dialogue/context/action/save/menu/cell/soak matrix. |
| I Heart Vanilla | Install/profile manifest and regression matrix. |
| Expanded Vanilla | Dense content/identity/performance/action matrix. |
| Total Overhaul | Maximum-load performance/UI/VFS/media compatibility matrix. |
| Tamriel Rebuilt/Project Tamriel | Added lands/records/factions/journal/content identity matrix. |
| Controller/Steam Deck | Semantic inputs/UI scaling/Linux runtime matrix. |
| Voice mod coexistence | Speech priority/interruption/vanilla voice compatibility matrix. |

## Deliberate deferrals

- Android/mobile lifecycle and packaging.
- Network multiplayer/shared authoritative worlds.
- Original `.omwaddon` records and any redistributable authored content package.
- Automatic future OpenMW version support.
- Provider billing/live credentials in CI.
