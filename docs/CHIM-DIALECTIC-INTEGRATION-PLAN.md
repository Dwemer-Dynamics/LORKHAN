# ALMSIVI CHIM/Dialectic integration plan

Status: implementation-ready parity plan, audited 2026-08-09.

This is the execution contract for bringing ALMSIVI and ALMSIVIserver to the applicable CHIM/HerikaServer and Dialectic/DialecticServer product shape. It replaces feature-by-feature invention with direct, documented reuse of the established systems.

## 1. Fixed scope

Applicable parity includes:

- targeted and group conversation;
- typed input and installation-global STT;
- streamed and queued responses, TTS, subtitles, interruption, and delivery receipts;
- playback-gated rechat after a player-started conversation;
- CHIM-style prompt composition, events, speech, response logs, memories, relationships, profiles, narration, and world context;
- Global -> Core Profile -> NPC settings inheritance;
- HerikaServer browser structure and controls;
- Morrowind/OpenMW context and negotiated actions.

The following are excluded from functional implementation:

- AI Quest generation or management;
- Background Life;
- timer-driven autonomy, automatic greetings, boredom, and combat barks;
- ITT;
- Skyrim-only systems such as Soulgaze, PipVision, teleport/return tools, and FormID-specific behavior.

Rechat is not autonomy in this plan. It is a bounded continuation of a player-started conversation and may begin only after the final prior utterance has been acknowledged as played.

## 2. Authority and reuse rules

| Concern | Source of truth | ALMSIVI rule |
|---|---|---|
| Browser presentation | HerikaServer | Preserve page structure, navbar, hubs, assets, CSS, controls, density, and responsive behavior. Change only branding, Morrowind terminology, status badges, and typed wiring. |
| User-visible conversation behavior | CHIM | Match targeting, response lifecycle, TTS/subtitles, interruption, history, diagnostics, and playback-gated continuation outcomes. |
| JSON envelope and response-line format | Dialectic/DialecticServer | Use namespaced `almsivi.*.v1` equivalents of Dialectic input, event, response, response-line, media, action, command, and game-data envelopes. Keep ALMSIVI correlation and security fields. |
| Client response queue | Dialectic | Reuse the single FIFO response-router model, dialogue-before-action ordering, unfinished state, generation fencing, lifecycle cancellation, and queue diagnostics. Adapt it to Lua/OpenMW; do not add a parallel queue. |
| Database compatibility | HerikaServer/DialecticServer | Preserve the useful `eventlog`, `speech`, `responselog`, `prompts`, memory, relationship, profile, connector, and audit shapes. Back them with ALMSIVI typed PostgreSQL source records and compatibility projections; do not dual-write independent truths. |
| Runtime identity and authority | ALMSIVI | Keep installation, playthrough, session, generation, request, turn, utterance, content-file/record, and runtime-reference fencing. Keep the narrow typed native bridge and pinned OpenMW API. |

Audited references:

- ALMSIVI checkpoint: `eee848c00bb48536c67de97ab953760e7c67da76`
- ALMSIVIserver checkpoint: `554befb6d167d2d6deb436662de858503853a584`
- CHIM `origin/unstable`: `005df4c1fda5ff195dc14a674fe71b11542be4df`
- HerikaServer `origin/unstable`: `c973f5c8fde2d01cb8211be3d5f96d1783663da4`
- Dialectic `origin/unstable`: `5cd2817a6733acbe25ca21bdfb716ed64617f5f8`
- DialecticServer `origin/unstable`: `4f3d8fed834b283fd53ff0655ddd091d849dea1d`

Refresh reference behavior deliberately. Do not silently change the presentation or protocol baseline mid-workstream.

## 3. Current checkpoint

Already present and retained:

- typed OpenMW session, turn, event, media, action, control, delivery, and STT contracts;
- target selection, typed chat, group audience snapshots, prompt generation, LLM response, actor-specific TTS, subtitles, cancellation, and delivery acknowledgement;
- Push-to-Talk, bounded Open Mic, mute, sensitivity, end delay, Windows recording-device selection, and durable STT provider routing;
- CHIM-style XML prompt sections and Morrowind context foundations;
- playback-gated rechat coordinator;
- PostgreSQL source events, turns, response events, utterances, media, provider attempts, jobs, prompt traces, profiles, memories, relationships, world knowledge, and operational audit;
- public CHIM-style `eventlog`, `speech`, `responselog`, and `prompts` surfaces plus staged `herika_compat` tables/projections;
- Herika-style browser shell, hubs, connector pages, profile hierarchy, Roleplay pages, and Control Panel families;
- a pinned OpenMW build and local Windows/WSL deployment workflow.

These foundations are not the same as full parity. Several paths overlap, some compatibility tables are staged but not authoritative, the queue contract is not yet a direct Dialectic-format implementation, and full browser/in-game acceptance is incomplete.

## 4. Canonical end-to-end flow

Every player text or STT transcript must use this one path:

1. OpenMW resolves the current target, audience, playthrough, session, and generation.
2. The client emits `almsivi.input.v1` semantics through the typed turn or STT route.
3. The server authenticates, validates, rate-limits, and idempotently persists the immutable source input.
4. A durable job resolves effective Global -> Core Profile -> NPC settings.
5. Prompt assembly records ordered CHIM-style XML sections and their typed source trace.
6. The selected LLM provider records attempts, streaming deltas, and a final Dialectic-shaped response-line list.
7. The server persists canonical utterances and projects them into `eventlog`, `speech`, and `responselog`.
8. The client event poll feeds one response router and one FIFO queue.
9. Dialogue is dispatched in order; actions remain behind the dialogue for that response.
10. TTS media is fetched and played, normal Morrowind subtitles are shown, and one terminal delivery result is sent.
11. Only final successful playback may advance the bounded rechat chain.
12. A new request, Halt, Stop Dialogue, session replacement, load, cell change, or invalid actor cancels stale queued work.

No browser action, alternate endpoint, STT worker, rechat worker, or compatibility projection may bypass this path.

## 5. Dialectic-format JSON mapping

The existing ALMSIVI schemas remain strict and namespaced, but their payload format should converge on Dialectic's proven split:

| Dialectic contract | ALMSIVI contract | Required parity |
|---|---|---|
| `dialectic.input.v1` | `almsivi.input.v1`/`almsivi.turn.v1` | player, text, game, target, audience snapshot, mode, and request identity; retain installation/playthrough/session/generation/runtime/content fingerprint. |
| `dialectic.event.v1` | `almsivi.event.v1` inside `almsivi.events.v1` | typed event name, game, payload, audience snapshot, and request identity. |
| `dialectic.response.v1` | `almsivi.response.v1` | `ok`, ordered `lines`, and `close`; do not infer a response from loosely related events. |
| `dialectic.response.line.v1` | `almsivi.response.line.v1` | speaker, display name, action, text, subtitle, TTS cache/media identity, request, utterance, listener, rechat target, command fields, and bounded metadata. |
| `dialectic.action.v1`/`command.v1` | existing ALMSIVI action intent/result contracts | preserve ALMSIVI tier, capability, confirmation, expiry, and terminal-result fencing. |
| `dialectic.media.v1` | existing ALMSIVI STT/media descriptors | preserve authenticated opaque media, hash, MIME, ownership, expiry, and recording metadata. |
| `dialectic.gamedata.v1` | `almsivi.gamedata.v1` | Morrowind actor profile, inventory, nearby actors/items, world, Journal, dialogue delivery, action results, captured vanilla dialogue, and prompt bridge. Omit AI quests and boredom events. |

Implementation rules:

- Add the response and response-line schemas to both sibling repositories in one change.
- Keep schemas, fixtures, and manifests byte-identical between client and server.
- Convert the current required `events.autonomy` field into an always-empty v1 compatibility field; remove it only in a coordinated v2 schema change.
- Reject `greeting`, `boredom`, and combat-bark directives at schema/service boundaries.
- Keep rechat state server-side and emit it as a normal correlated turn/response, never as an autonomy directive.

## 6. Dialectic queue port

Use one queue item model equivalent to Dialectic's `DialogueLine`/action variant:

- speaker and display name;
- actor and listener identity;
- text, subtitle, and TTS media/cache identity;
- request and utterance identity;
- rechat target and depth;
- response generation and runtime generation;
- final-response-line marker;
- dialogue or action payload.

The queue owns:

- one mutex/single-owner FIFO;
- unfinished/complete state;
- active response and runtime generations;
- pending dialogue/action counts;
- queued, dispatched, cancelled, and stale-drop counters;
- the source that left a response unfinished.

Required behavior:

- validate and normalize a complete response before enqueueing it;
- enqueue dialogue lines first and action lines second;
- generation-check at enqueue and again at dispatch;
- deduplicate recent request/utterance/media identities;
- mark only the final dialogue line as response-final;
- permit an action-only final response without fabricating dialogue;
- serialize TTS playback and subtitle delivery;
- send exactly one delivery result per utterance;
- advance rechat only from the final played delivery result;
- clear and invalidate on new request, Halt, Stop Dialogue, load, cell change, session replacement, or target invalidation;
- expose the same queue snapshot to the in-game Diagnostics panel and browser Response Queue page.

Adapt `conversation.lua` and `orchestrator.lua` to this model. Remove overlapping ad hoc pending-media, pending-speech, and response-completion ownership only after the new queue passes cross-boundary tests.

## 7. Database cutover

Use the ALMSIVIserver plan for the full table map. The client-visible rules are:

- typed source tables remain the write authority;
- CHIM/Herika names are projections or transactional adapters over those source rows;
- `eventlog`, `speech`, `responselog`, and `prompts` preserve established useful column names and ordering for UI and diagnostics;
- JSON payload columns contain Dialectic-shaped canonical JSON rather than alternate page-specific formats;
- every row carries or can resolve installation, playthrough, session, generation, request, turn, utterance, actor, and timestamp correlation;
- no prompt, memory, response, or delivery row is keyed only by display name;
- AI Quest, Background Life, and timer-autonomy compatibility tables remain quarantined, have no worker or writable UI, and are not part of the public product schema.

## 8. Prompt, event, memory, and profile parity

### Prompt order

Use a stable CHIM-style XML split:

1. response/output contract;
2. NPC identity, core identity, biography, boundaries, and speech style;
3. player and narrator identity;
4. world, time, weather, cell, Journal, and relevant observed Morrowind data;
5. relationships and factions;
6. selected recent, middle, and long memories with provenance;
7. bounded conversation history and captured vanilla dialogue;
8. nearby actors/audience and speaker/addressee rules;
9. negotiated action catalogue and policy;
10. the current player turn or rechat continuation.

Each section must have a recorded typed source, ordering index, inclusion reason, token/character size, and redacted preview. Profile text must not be duplicated into multiple sections.

### Event/log behavior

- Source events are immutable.
- `eventlog` is the chronological activity projection.
- `speech` contains accepted spoken utterances and delivery/audio state.
- `responselog` contains normalized model lines/actions and provider outcome.
- `prompts` contains revisioned templates/assignments; per-turn prompt traces point to the exact revision.
- UI filters and detail pages read these canonical surfaces, not alternate browser-only records.

### Memory behavior

- Recent history comes directly from delivered speech/events.
- Middle and long memories are derived idempotently from eligible source rows.
- Failed, cancelled, stale, partial, or unplayed output is not a memory source.
- Records retain actor/playthrough scope, provenance, source range, revision, and deletion/rebuild state.
- Retrieval traces record why a memory was selected for a prompt.

### Settings hierarchy

- Installation-global owns STT, API credentials, server/runtime limits, and local service endpoints.
- Global settings own shared dialogue behavior and the default Core Profile.
- Core Profile owns LLM slot routing, TTS connector/voice fallback, prompts, memory, relationship, rechat, narration, and action policy defaults.
- NPC stores only explicit overrides and inherits the rest.
- Local OpenMW settings own hotkeys, panels, recording device, microphone thresholds, local subtitle/HUD choices, and TTS playback boost.
- The effective-settings response includes values, provenance, revisions, and a change token.

## 9. Remaining work in execution order

### P0 - Make the branch releasable

1. Repair current ALMSIVI CI failures: Ubuntu PowerShell path parsing, GCC optimized `-Werror` false positives, macOS floating `from_chars`, and macOS `std::stop_token` compatibility.
2. Add CI for ALMSIVIserver covering PHP lint, protocol parity, migrations, PostgreSQL integration, workers, and management HTTP flows.
3. Refresh stale evidence ledgers so implemented behavior is not still marked `PLANNED` and no row claims unperformed in-game proof.

### P1 - Canonical schema and data model

1. Produce a column-by-column Herika/Dialectic -> ALMSIVI table map.
2. Mark every current table as source, projection, compatibility-only, or excluded.
3. Add Dialectic-format response, response-line, event, and game-data contracts.
4. Backfill correlation fields and canonical JSON payloads.
5. Cut UI/repository reads to the canonical projections and eliminate dual-write paths.
6. Quarantine quest, Background Life, and timer-autonomy schema/workers/routes.

### P2 - Response router and FIFO queue

1. Port the Dialectic response parser and line normalization behavior.
2. Replace overlapping client pending-response ownership with one queue.
3. Enforce dialogue-before-action ordering and double generation fencing.
4. Tie TTS, subtitles, delivery receipts, action release, and rechat to queue completion.
5. Expose queue state in both diagnostics surfaces.

### P3 - Prompt, event, and memory parity

1. Lock the XML section order and source trace contract.
2. Make event/speech/response/prompt projections the only UI and memory inputs.
3. Validate NPC identity, Morrowind context, relationship, faction, Journal, inventory, nearby actor, book, and vanilla-dialogue formatting against representative live prompts.
4. Complete recent/middle/long memory derivation, retrieval, rebuild, edit, delete, and playthrough isolation.
5. Prove playback-gated rechat depth, target, cancellation, and no-action rules.

### P4 - Applicable game behavior

1. Complete voice selection and volume checks across race/sex/creature/narrator cases.
2. Finish only negotiated OpenMW-safe action families and their terminal receipts.
3. Validate group speaker/addressee behavior, interruption, target changes, loads, cell changes, reconnects, and provider failures.
4. Keep normal Morrowind subtitles as the sole dialogue text surface unless the user opens History/Diagnostics.

### P5 - Browser parity and release acceptance

1. Validate every Herika-derived page family at populated, empty, validation-error, disabled, and modal states.
2. Compare at 1920x1080, 1440x900, 1280x720, 390x844, and 375x667.
3. Prove all forms use browser session, CSRF, typed services, revisions, and PostgreSQL persistence.
4. Run fresh-install and upgrade migrations, backup/restore, worker restart, and retained-user-data deployment tests.
5. Run the final in-game matrix on a clean OpenMW profile and an existing playthrough.

## 10. Completion gates

Parity is complete only when all applicable rows have evidence for:

- strict byte-identical sibling contracts and hostile fixtures;
- clean migrations from a new database and the current local database lineage;
- one authoritative write/read path for each data family;
- queue order, cancellation, stale-drop, media, delivery, action, and rechat behavior;
- representative prompt snapshots and memory provenance;
- desktop/mobile browser visual and functional checks;
- clean-profile and existing-profile Windows/OpenMW in-game checks;
- idle frame-rate and request-rate checks showing no polling or retry regression;
- green client and server CI;
- exact deployed source/artifact hashes.

Passing unit or integration tests is not in-game proof. Passing in-game conversation once is not schema, migration, responsive UI, or lifecycle proof.

## 11. Recommended implementation slices

Keep each slice paired across ALMSIVI and ALMSIVIserver:

1. CI and evidence-ledger repair.
2. Schema/table inventory and excluded-feature quarantine.
3. Dialectic response/response-line JSON contracts.
4. Server canonical response projection.
5. Client response router and FIFO queue.
6. TTS/delivery/rechat completion fencing.
7. Prompt/event/memory canonicalization.
8. Profile/settings provenance and connector routing.
9. Applicable OpenMW action completion.
10. Herika browser acceptance and final deployment/in-game matrix.

Do not combine the queue cutover, database cutover, and browser rewire into one unreviewable change. Each slice must preserve a working typed conversation path and include an upgrade/rollback boundary.
