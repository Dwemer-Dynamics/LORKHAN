# ALMSIVI CHIM/Dialectic parity cleanup plan

Status: active implementation record based on a live client, server, browser, protocol, and test audit on 2026-08-03.

This document is the master cleanup and parity plan for ALMSIVI and ALMSIVIserver. It supersedes the fragmented parity checklists as the execution order, but it does not replace the protocol, architecture, packaging, or local-testing references.

Scope override for this implementation goal: timer-driven autonomy is excluded. Do not implement or expose functional automatic greetings, boredom events, combat barks, autonomous scheduling, cooldowns, or other timer-triggered model behavior. ITT and Background Life remain excluded. STT is active through manual Push-to-Talk and bounded Open Mic controls.

## 1. Target outcome

ALMSIVI should deliver the same understandable product shape as CHIM and Dialectic while remaining native to Morrowind and OpenMW:

- The browser UI uses the pinned HerikaServer presentation baseline 1:1 for its shell, navigation, page structure, controls, assets, CSS behavior, density, and responsive layout.
- Browser controls use ALMSIVI's typed PHP services, PostgreSQL repositories, browser session, and CSRF workflows.
- In-game interaction reaches outcome parity with the applicable CHIM/Dialectic controls: discoverable hotkeys, targeting, text conversation, response management, TTS, HUD/history/diagnostics, profile/model selection, agent controls, context, and actions.
- Settings resolve predictably through Global settings, a Core Profile, and explicit NPC overrides.
- Morrowind-specific context and actions are surfaced using OpenMW-native APIs and terminology.
- Unsupported Herika controls remain visible in the browser baseline but are disabled and labelled centrally as `Planned`, `Excluded`, `Not Applicable`, or `Replaced`.
- Timer-driven autonomy, ITT, and Background Life remain functionally excluded. STT is installation-global and intentionally sits outside the Global/Core Profile/NPC settings hierarchy.

Parity means equivalent user outcomes, not blind runtime code copying. HerikaServer supplies the browser presentation contract. CHIM and Dialectic supply applicable behavior and control expectations. ALMSIVI keeps its own typed backend, protocol, database, OpenMW implementation, branding, terminology, and game-specific constraints.

## 2. Audited baselines

The implementation must record both baselines in its validation evidence:

| Concern | Locked presentation/behavior reference | Current refresh reference |
|---|---|---|
| CHIM client behavior | Existing ALMSIVI task pin `77c73ffb6bb32c226340bbda93b3aac5a7ad49f8` | `origin/unstable` at `6752f97` on 2026-08-03 |
| HerikaServer presentation and controls | Existing ALMSIVI task pin `0dbfa3eb4d3197d8159b5ff2c77bfdb5bf98b4d0` | `origin/unstable` at `b3c28e2f` on 2026-08-03 |
| Dialectic client behavior | Existing ALMSIVI task pin `eddbdc77a8347128b5cf5bcd68df0c2404fbf074` | `origin/unstable` at `7b9c1f9` on 2026-08-03 |
| DialecticServer presentation and controls | Existing ALMSIVI task pin `f447a9c6b59bfc689c788fb0139a0d13c6c6dc51` | `origin/unstable` at `debe32b` on 2026-08-03 |

Do not silently replace a locked baseline with the newest upstream state. New upstream behavior is a separate parity refresh decision.

## 3. Current state summary

The foundations are substantially present, but the product is not yet at full parity.

| Area | Current assessment | Main gap |
|---|---|---|
| Typed server and PostgreSQL persistence | Strong foundation | Browser workflows and status metadata are not all proven against it |
| Browser shell and main hubs | Pinned Herika shell, assets, navbar geometry, hubs, and dashboard layout are deployed | Mobile screenshot proof remains outstanding because the available browser viewport stayed fixed at 1280x720 |
| Configuration pages | Herika page structures and controls are wired across all declared page families | Live external-provider actions and every responsive viewport still need final acceptance evidence |
| Roleplay pages | Events, responses, records, memories, books, and canonical Journal are present | Final populated/empty/error-state visual matrix remains |
| Control Panel | Diagnostic, monitoring, and data/tool families use canonical routes | Final destructive-confirmation and empty/error-state visual matrix remains |
| Text conversation | Targeting, target confirmation, chat submission, cancellation, generation, delivery, History, Diagnostics, and HUD paths exist | Requires complete in-game acceptance testing |
| TTS | Actor/narrator playback, ordered delivery, cancellation, and ALMSIVI boost exist | Full per-NPC voice and volume acceptance matrix remains unproven |
| In-game controls | All applicable controls are exposed; History and Diagnostics open their named panels; Diagnostics uses the configured server URL and native bridge/session state | Requires keyboard/controller and scene-safety acceptance in OpenMW |
| Morrowind context | Bounded player, actor, world, inventory, Journal, book, environment, and recent vanilla-dialogue context is present | Requires prompt inspection against live representative actors and scenes |
| Autonomy | Shipped UI/event wiring is removed and current capabilities do not advertise autonomy | Compatibility internals remain quarantined and negative runtime acceptance remains |
| Settings hierarchy | Global -> Core Profile -> NPC effective settings, provenance, and change token reach the client | Representative target-switch acceptance remains |
| STT | Push-to-Talk, bounded Open Mic, mute, sensitivity, end delay, recording-device selection, native WAV capture, authenticated upload, and transcript fencing are active | Live provider credentials and in-game acceptance remain |
| Exclusions | ITT, Background Life, and timer-driven autonomy remain disabled; no scheduler or background model trigger is exposed | Negative in-game acceptance remains |
| Validation | Client structural checks, 46 Lua runtime tests, native CTest, server integration, migrations/jobs, management HTTP, deployment health, and 1280x720 browser comparisons pass | In-game and mobile visual acceptance remain unverified |

## 4. Immediate parity blockers

These are correctness or scope contradictions and should be fixed before broad UI polishing.

### P0.1 Incorrect in-game panel routing — resolved

`ALMSIVI_History` and `ALMSIVI_Diagnostics` currently open the Actor Tools panel. Each binding must open its named panel. Add direct keyboard/controller acceptance checks so the structural test cannot preserve the wrong mapping.

Resolution: both triggers now open their named panels, with structural coverage. Keyboard/controller runtime acceptance remains part of the final in-game gate.

### P0.2 Incomplete applicable hotkey exposure — resolved

The client registers more applicable actions than the Settings page exposes. Add visible configurable rows for:

- Stop Dialogue
- Status HUD
- Conversation History
- Diagnostics

Keep Talk, Manual Activate, Mode, Model, Profile, Halt, Actor Tools, Push-to-Talk, Open Mic, and Open Mic Mute. Remove the legacy duplicate Master Menu from the public settings model.

Resolution: every applicable row is visible in OpenMW Settings, the duplicate Master Menu is compatibility-only and not public, and excluded voice controls are not registered.

### P0.3 Vanilla dialogue is captured but discarded — resolved

The global script receives `DialogueResponse` and stores `lastVanillaDialogue`, but the turn-context builder does not consume it. Add a bounded, provenance-labelled recent-dialogue context field and clear or age it predictably. It must never grow without bounds or repeat stale dialogue indefinitely.

Resolution: recent vanilla dialogue is bounded, provenance-labelled, forwarded to the next accepted turn, then consumed.

### P0.4 Layered settings stop at the server — resolved

The server resolves effective settings for prompt and routing work, but session initialization only sends installation-wide settings, and controls query does not return target-effective settings or provenance. Define and implement a typed effective-settings response that includes:

- resolved values for the current target/profile;
- source metadata for Global, Core Profile, or NPC override;
- a schema/version marker;
- a change token so the client does not repeatedly reapply unchanged data.

Only target-scoped gameplay behavior may come from Core/NPC settings. Local player preferences such as key bindings, panel placement, HUD visibility, and local audio presentation must remain local and must not change when the target changes.

Resolution: the controls snapshot carries effective values, provenance, revisions, and a change token; the player applies target-scoped safety while keeping local presentation and audio settings client-owned.

### P0.5 STT activation — superseded by the STT parity implementation

The retained speech-listening, capture, protocol, and durable worker foundations are reactivated for Push-to-Talk and bounded Open Mic. Every transcript is fenced to its captured target, session, and generation before it enters the normal player-text pipeline.

Resolution: shipped settings, player events, bounded idle polling, native bindings, advertised capabilities, binary ingress, PostgreSQL state, workers, and connector UI expose STT without enabling any timer-driven autonomy.

### P0.6 Stale browser feature metadata — resolved

The centralized registry still labels Active Quests as planned and Relationships as live. Make Journal the canonical live Roleplay destination, remove Relationships from the visible Roleplay navigation, and keep Relationship Logs only as a diagnostic/administrative surface. Legacy `?tab=quests` and `?tab=relationships` URLs may redirect to the canonical destination, but they must not create duplicate navigation concepts.

Resolution: Journal is canonical, the Roleplay submenu is removed, and legacy quest/relationship tab URLs redirect without recreating visible destinations.

### P0.7 Player speech-style generation fails its HTTP workflow — resolved

The current management browser suite receives HTTP 422 from `player-speech-style-generate` when it expects a successful redirect. Determine whether the created player profile and recent input belong to different installation scope, whether the form is offered too broadly, or whether the repository lookup is wrong. The page must show the control only when the same installation has usable inputs, and the test fixture must prove that exact invariant.

Resolution: the workflow is installation-scoped and the browser-like management suite proves the successful CSRF form path.

### P0.8 Canonical route drift and orphan pages — resolved

Reconcile management aliases and visible hubs so every supported capability has one canonical page. Current risks include legacy Character Manager versus NPC Master, Diagnostics aliases that land on Server Logs, orphan backup-health/diagnostics pages, and a directly routable Narrative Autonomy page that is not represented consistently in the hub. Legacy links should redirect; they should not fork behavior or styling.

Resolution: visible hubs use canonical pages, legacy aliases redirect, and the excluded autonomy route is not exposed as a live destination.

### P0.9 No reproducible 1:1 visual proof — partially resolved

The live shell is responsive, but page-specific copied CSS is not a durable presentation contract. Pin the exact Herika assets and structural markup used by the rebuild, isolate ALMSIVI branding into the smallest token layer, and add screenshot comparison evidence for each page family. Visual parity should be judged at the same viewport, content fixture, scroll position, and UI state.

Current evidence: the pinned Herika shell/assets, shared navbar geometry, Home, Configuration, Roleplay, Control Panel, NPCs, Profiles, Player, LLM, Global Settings, and NPC modal states were compared live at 1280x720. The remaining gate is the full fixed-viewport responsive screenshot matrix.

## 5. Browser UI coverage plan

### 5.1 Shared shell

The following must remain structurally identical to the pinned Herika baseline except for ALMSIVI branding and game terminology:

- header, logo, background, and product menu;
- Home, Roleplay, Configuration, Control Panel, and DwemerDistro navigation;
- grouped hub cards, tab geometry, active states, spacing, content width, and page background;
- buttons, form controls, badges, notices, modals, cards, pagination, search/filter controls, and empty states;
- desktop and mobile breakpoints;
- keyboard focus, disabled state, and accessible labelling.

Create one presentation manifest containing the pinned source path/ref and the allowed ALMSIVI substitutions. Avoid per-page reinterpretations of the baseline.

### 5.2 Configuration hub

| Page | Required disposition | Completion work |
|---|---|---|
| ALMSIVI NPCs | Live | Keep Herika NPC grid, pagination, search, filters, profile actions, lock/favorite/revision controls, and modal structure. Rewire to stable Morrowind identity: content file + record ID + runtime ref data. |
| Profiles | Live | Preserve list/edit/import/export/clone/default/rules/test presentation. Wire the Global -> Core -> NPC model explicitly; unsupported automation controls remain visible and disabled. |
| Player | Live | Wire player profile revisions, observed inputs, speech style generation, and status feedback. Fix the current 422 workflow. |
| Narration | Live | Preserve narrator identity, enablement, prompt, voice, generation, revision, and routing controls. |
| NPC Biographies | Live | Use the same search/edit/revision shell and stable Morrowind identity. |
| LLM | Live | Preserve provider list, editor, selection, test, import/export/clone, and safe optional-key handling. Clearly distinguish conversation, profile generation, and relationship worker routing where applicable. |
| TTS | Live | Preserve connector list, editor, selection, test, clone/import/export, and default voice behavior. PocketTTS remains the preferred recommendation without breaking OmniVoice or other supported providers. |
| TTS Studio | Live | Preserve voice browsing, samples, upload/delete lifecycle, provider filtering, and actor assignment workflows. Prove exact Morrowind voice selection. |
| STT | Live | Preserve the single-global Herika connector page, provider groups, API Badge status, settings, Save/Test controls, and responsive layout; wire it to typed PostgreSQL configuration. |
| ITT | Excluded | Keep the baseline control visible and disabled. Do not expose working forms or runtime capability. |
| API Keys | Live | Preserve provider-scoped secure entry and never render secrets back to the browser. |
| Global Settings | Live | Make every setting's ownership and inheritance behavior explicit. Show effective value and source when meaningful. |
| Oghma Infinium | Live/Replaced by Morrowind data | Preserve the page shape but use the Morrowind actor/item/location knowledge pipeline. Label Skyrim-only functions Not Applicable. |
| Descriptions | Live | Support stable content-file/record identity and revision-safe edits. |
| Action Editor | Live | Show negotiated OpenMW actions and policy controls. Unsupported Herika actions remain visible only if they help parity mapping and are clearly disabled. |
| Prompts Manager | Live | Preserve prompt list/editor/assignment/import/export/revision presentation and typed persistence. |
| Server Plugins | Replaced | Keep the baseline landmark disabled and link/explain the ALMSIVI-native extension approach when it exists. |

### 5.3 Roleplay hub

| Group | Page | Required disposition |
|---|---|---|
| Activity & Logs | Events | Live, backed by accepted event records with filters and detail views |
| Activity & Logs | AI Responses | Live, including request/result/failure state without exposing secrets |
| Activity & Logs | Adventure Log | Live if it represents narrative summaries distinct from Journal; otherwise merge/rename cleanly |
| Memories & Records | Memories | Live, with tiers, provenance, revisions, rebuild controls, and safe deletion |
| Memories & Records | ALMSIVI Diaries | Live if separately generated records exist; otherwise visible Planned |
| Memories & Records | Books | Live Morrowind book observations and bounded text provenance |
| Memories & Records | Soulgaze | Not Applicable |
| World & Quests | Journal | Live and canonical; replaces the visible Active Quests entry |
| World & Quests | AI Quest Manager | Not Applicable unless a Morrowind-native design is separately approved |
| World & Quests | Background Life | Excluded |

Relationships must not be a Roleplay submenu item. Relationship data can still inform prompts and profiles. Relationship Logs stay in Control Panel for diagnostics and auditing.

### 5.4 Control Panel hub

| Group | Page | Required disposition |
|---|---|---|
| Diagnostics | Server Logs | Live, bounded, filterable, and safe for absent logs |
| Diagnostics | Request Logs | Live, correlated by request/session/turn without leaking payload secrets |
| Diagnostics | Oghma Audit | Live for Morrowind knowledge provenance |
| Diagnostics | Relationship Logs | Live administrative audit; no duplicate Roleplay tab |
| Monitoring | Cost Breakdown | Live where providers return usage; degrade cleanly when they do not |
| Monitoring | Response Queue | Live generation/TTS/delivery lifecycle and cancellation state |
| Monitoring | Provider Attempts | Live routing attempts, latency, and sanitized failures |
| Monitoring | Workers & Jobs | Live durable jobs, leases, retries, dead-letter state, and health |
| Data & Tools | Audio & Image Cache | Live for applicable media; label image-only CHIM behavior Not Applicable or Replaced |
| Data & Tools | Playthrough Manager | Live save/playthrough identity, import/restore semantics, and non-destructive history |
| Data & Tools | Database Manager | Live backup/restore/migration health with explicit destructive-action confirmation |

### 5.5 Browser control-status contract

Replace ad hoc badges with one authoritative feature/control manifest. Each entry should include:

- stable feature ID;
- hub group and canonical route;
- baseline label and ALMSIVI label;
- disposition: Live, Planned, Excluded, Not Applicable, or Replaced;
- whether the control is visible, enabled, and routable;
- backend service/repository owner;
- required permission and CSRF behavior;
- validation evidence and last verified ref.

A badge alone is not proof of implementation. A feature becomes Live only after its page, action, persistence, error handling, and applicable runtime effect pass the acceptance gate.

## 6. In-game OpenMW coverage plan

### 6.1 Installation and discovery

- The mod must have one clear OpenMW launcher/mod-manager installation path and a deterministic content/load order.
- On first usable load, show a short non-blocking status message explaining the Talk key and where controls live.
- Settings must identify the server URL, connection state, installation/playthrough identity, and version/protocol compatibility without requiring the browser UI.
- Failures should point to Diagnostics and the browser home page using the configured server base URL, never a stale hard-coded `/manage` link.

### 6.2 Controls and panels

| User outcome | Required in-game surface |
|---|---|
| Select whom to talk to | Crosshair/current dialogue target plus Nearby Profiles fallback; show stable name and selection confirmation |
| Type to an NPC | Chatbox with focus ownership, Enter to send, Escape to cancel, and retained draft on transient failure |
| Stop current speech | Stop Dialogue, affecting only current audio/subtitle playback |
| Cancel the whole turn | Halt, cancelling generation, queued delivery, current audio, and stale callbacks |
| See current state | Optional compact Status HUD with target, connection, request, and speaking state |
| Review conversation | History panel with speaker, timestamp/order, request state, and bounded retention |
| Diagnose failure | Diagnostics panel with connection, session, target, last error, queue state, and copyable IDs |
| Change interaction mode | Mode selector using server-authoritative available modes |
| Change LLM slot | Model selector with current selection and clean unavailable-state feedback |
| Change profile | Profile selector, effective profile indicator, and target binding confirmation |
| Manage AI actors | Targeted NPC Tools: add target, add nearby, remove target, remove all, list active, refresh nearby |

Each applicable action must be visible in OpenMW Settings and reachable without opening a Lua console. Default bindings should be conservative, but an unbound action still needs a discoverable Settings row.

### 6.3 Settings ownership

Use three explicit ownership classes:

| Class | Examples | Source and lifetime |
|---|---|---|
| Local player preference | key bindings, HUD visibility, panel placement, local TTS boost, subtitles, audio spatial presentation | OpenMW client settings; never overridden per NPC |
| Installation/global behavior | response timeout, memory/context bounds, narrator configuration, connector routing, and default action safety | Server Global Settings with safe client fallback |
| Target-effective behavior | Core Profile defaults and explicit NPC overrides for memory/context, narrator, action safety, and voice/profile routing | Server effective-settings response, recalculated on target/profile change |

The resolution order is `NPC explicit override > assigned Core Profile > Global default`. Missing fields inherit; they must not be copied into every NPC record. The browser should show both the effective value and its source. The client should cache the effective snapshot by target/profile/change token and discard it safely when the target becomes invalid.

### 6.4 Conversation and response lifecycle

- One accepted user turn receives a stable request/generation identity.
- New turns, Halt, cell transitions, load transitions, session invalidation, and actor invalidation cancel stale generations and queued TTS.
- Text may stream or arrive complete, but subtitles and audio must preserve sentence/order semantics.
- Delivery receipts distinguish generated, queued, played, skipped, cancelled, and failed.
- Retry behavior is bounded and visible; it cannot generate duplicate NPC replies.
- Empty, filtered, provider-failed, and timeout responses produce concise actionable feedback in HUD/history/diagnostics.
- Group conversation keeps explicit speaker identity and never plays an old speaker after the active scene has changed.

### 6.5 TTS and sound parity

Required outcomes:

- actor voice resolves by exact provider actor/record identity before race/gender fallback;
- narrator uses narrator routing and never inherits the active NPC voice;
- ALMSIVI-specific TTS boost is locally configurable and clamps safely;
- server and client volume factors combine predictably without clipping;
- Stop Dialogue and Halt have distinct semantics;
- queued clips remain ordered and are cancelled on invalid lifecycle transitions;
- subtitles remain usable when TTS is unavailable;
- missing voices/providers fail to text-only mode without blocking conversation.

Assess OpenMW feasibility before promising Dialectic's 3D playback, camera-relative panning, heading inversion, distance drop-off, pre/post clip timing, or lip animation controls. Implement native equivalents where the engine supports them; otherwise keep browser/in-game controls disabled with `Not Applicable` or `Planned`, backed by a recorded feasibility result.

### 6.6 Morrowind context coverage

The context contract should have bounded, typed, provenance-labelled sections for:

- player identity, state, stats, attributes, skills, reputation, factions, and disposition;
- current target identity, race, class, faction, disposition, combat/death state, equipment, and effects;
- inventory, equipment, gold, spells, active effects, and relevant item identity;
- current cell, position, game time, weather, nearby actors, nearby objects, doors, containers, locks, keys, and traps;
- followers and combat participants;
- Journal state and recent changes;
- observed books with bounded/deduplicated content;
- recent vanilla dialogue with speaker and age/provenance;
- loaded content files and stable record identity;
- playthrough/save identity and generation token.

Every section needs size limits, update cadence, omission behavior, and prompt formatting tests. Optional or unavailable OpenMW data must disappear cleanly rather than emit null-heavy payloads or Lua errors.

### 6.7 Autonomy

Autonomy is excluded from this implementation goal. Automatic greetings, rechat, boredom events, combat barks, schedules, cooldowns, and every other automatic model trigger must remain unadvertised and unreachable. Herika presentation controls remain visible only as disabled `Excluded` placeholders. Background Life cannot be used as a hidden scheduler.

### 6.8 Actions

Current applicable actions should be normalized into one negotiated catalogue with policy and receipt handling:

- inspect/report;
- follow, stop following, wander, travel, escort, and face target;
- start/stop combat within safety policy;
- play supported animation;
- use, equip, and unequip item.

Plan separately, with feasibility and safety gates, for exact give/take item deltas, lock/unlock, trade/menu actions, and any distinct pursue behavior. An unsupported action must never be advertised as available. Action confirmation cancellation must hard-cancel without fabricating an AI follow-up.

### 6.9 Controller, accessibility, and scene safety

- All essential panels need keyboard and controller reachability where OpenMW input APIs permit it.
- Chat focus must capture only the keys it owns and release them reliably on close.
- Panels must not open over blocking game menus or persist across load transitions.
- Text, active state, focus state, disabled state, and errors must remain distinguishable without relying only on color.
- HUD and notifications must remain legible at common UI scales and aspect ratios.

## 7. Protocol and server cleanup needed for parity

### 7.1 Canonical control snapshot

Extend the typed controls query/response to return, in one versioned snapshot:

- negotiated capabilities and actions;
- active target and bound NPC/Core Profile;
- selected mode, model slot, profile, and narrator profile;
- target-effective settings and source map;
- client-safe connection/health state;
- snapshot/change token.

This should replace scattered assumptions in the client. It must not expose secrets or arbitrary server configuration.

### 7.2 Capability truthfulness

Capabilities are promises. Remove excluded or unavailable entries from negotiation. Validate that advertised actions, panels, and TTS operations have both a client handler and server path. Reject unknown or version-incompatible capabilities cleanly.

### 7.3 Identity and lifecycle

Use installation, playthrough, session, target, turn, generation, action, TTS segment, and delivery IDs consistently. Every log and diagnostic page should correlate them without depending on display names.

### 7.4 Browser and game parity through shared services

Browser forms and game protocol handlers must call the same typed service/repository rules for profiles, settings, connectors, actions, and revisions. Do not create a browser-only data model to mimic Herika pages.

## 8. Implementation phases

### Phase 0 - Freeze baselines and create evidence fixtures

1. Record full refs for all four baselines.
2. Capture the pinned Herika pages at agreed desktop and mobile viewports using stable fixture data.
3. Create the feature/control manifest and canonical route map.
4. Record the current ALMSIVI browser and in-game coverage matrix with proof state.

Exit gate: every visible baseline control has one disposition and one canonical ALMSIVI owner; every page family has a reproducible comparison fixture.

### Phase 1 - Correct P0 behavior and enforce exclusions

1. Fix History and Diagnostics bindings.
2. Expose every applicable binding, including Push-to-Talk, Open Mic, and Mute, and remove only legacy duplicate bindings.
3. Add recent vanilla dialogue to bounded turn context.
4. Make Journal canonical and remove stale Relationships/Active Quests navigation metadata.
5. Fix the player speech-style HTTP 422 workflow.
6. Activate STT with target/session/generation fencing and retain negative tests for timer-driven autonomy.
7. Reconcile canonical routes and redirects.

Exit gate: focused client structural/runtime checks and management HTTP tests pass; no excluded capability can be activated; STT is player-triggered and bounded; live navigation contains no stale duplicate destination.

### Phase 2 - Lock the Herika presentation shell

1. Port the exact pinned shell, hub markup, shared assets, CSS, controls, and responsive rules.
2. Restrict ALMSIVI differences to brand tokens, labels, game data, feature badges, and typed form wiring.
3. Replace local page-specific approximations with shared baseline components where doing so preserves exact layout.
4. Validate desktop and mobile screenshots for Home and the three hubs before proceeding.

Exit gate: approved screenshot comparisons show no unexplained structural/layout difference in shared shell and hubs; no horizontal overflow at required widths.

### Phase 3 - Rewire browser page families

Implement and validate in bounded families:

1. NPCs, Core Profiles, Player, Narration, and NPC Biographies.
2. LLM, TTS, TTS Studio, and API Keys.
3. Global Settings, Oghma, Descriptions, Action Editor, and Prompts Manager.
4. Roleplay pages.
5. Control Panel pages.
6. Disabled Excluded/Not Applicable/Replaced controls.

Exit gate per family: visual comparison, PHP lint, HTTP GET/POST/CSRF checks, repository persistence, revision/rollback behavior, empty/error states, and responsive inspection all pass before the next family begins.

### Phase 4 - Complete settings hierarchy and in-game controls

1. Add the target-effective settings contract and provenance.
2. Separate local, global, and target-effective ownership.
3. Complete hotkeys, panels, target confirmation, chat focus, status HUD, history, diagnostics, and selectors.
4. Add Targeted NPC Tools outcomes for agent management.
5. Replace stale hard-coded management URLs with configured canonical URLs.

Exit gate: switching targets visibly and correctly changes only target-scoped effective behavior; local preferences remain stable; every applicable control is discoverable and works without the Lua console.

### Phase 5 - Conversation, TTS, context, and action hardening

1. Run cancellation/order tests across new turns, Halt, Stop Dialogue, cell changes, loads, and invalid actors.
2. Complete voice identity and volume validation across representative Morrowind actor classes.
3. Finish bounded context coverage, including recent vanilla dialogue.
4. Prove excluded autonomy paths cannot trigger requests.
5. Finish the applicable action catalogue and policy receipts.

Exit gate: the in-game acceptance matrix passes without duplicate replies, stale audio, unbounded context, unexpected model calls, or advertised unsupported actions.

### Phase 6 - Operations, deployment, and release readiness

1. Run migrations from both fresh and representative upgrade databases.
2. Validate logs, queues, workers, provider attempts, backup/restore, and playthrough history.
3. Deploy with the maintained ALMSIVI full-deploy workflow while preserving local configuration and data.
4. Run clean-profile and existing-profile OpenMW smoke tests.
5. Record exact source refs, artifacts, destinations, and remaining engine limitations.

Exit gate: locally deployed browser and client pass the full acceptance matrix; no in-game verification is claimed until Morrowind is actually exercised.

## 9. Validation matrix

### Automated and static

- PHP lint for every changed PHP file.
- Server integration, migrations, durable jobs, management HTTP, CSRF, and upgrade-path tests.
- Protocol schema/version and capability/action parity checks.
- Existing client structural tests updated to assert the desired controls, not the current incomplete seven-row layout.
- Lua syntax/runtime checks when a Lua interpreter is available; otherwise treat structural Python checks as limited evidence.
- Native bridge build/tests for any changed audio/input/UI bridge code.
- CSS/JavaScript syntax checks and link/route manifest checks.

### Browser visual and functional

Inspect every page family at stable fixture state at minimum:

- 1920x1080 desktop;
- 1440x900 desktop;
- 1280x720 compact desktop;
- 390x844 mobile;
- 375x667 small mobile.

For each: compare shell, tabs, controls, cards, modal, empty state, populated state, validation error, disabled control, focus state, and horizontal overflow. A successful GET alone is not visual validation.

### In-game acceptance

Use a clean OpenMW profile and an existing playthrough. Cover at least:

- exterior and interior cells;
- friendly, hostile, creature, follower, dead/invalid, and unnamed targets;
- single and group conversation;
- text-only fallback, exact actor TTS, narrator TTS, missing voice, and provider failure;
- Talk, Enter, Escape, Stop Dialogue, Halt, History, Diagnostics, HUD, Mode, Model, Profile, and Actor Tools;
- negative checks proving greetings, rechat, boredom, and combat barks cannot trigger requests;
- save/load, cell change, fast travel, menu transition, death, and session reconnect;
- action allow, deny, confirm, cancel, success, failure, timeout, and stale receipt;
- Journal, book, vanilla dialogue, inventory, faction/disposition, and nearby-world context.

Correlate OpenMW, ALMSIVI client, server, Apache/PHP, provider, TTS, and worker logs by current timestamps and IDs.

## 10. Recommended work packages

Keep implementation reviewable and avoid another all-at-once rewrite:

1. Feature manifest, Journal/Relationships cleanup, and canonical routes.
2. In-game binding/panel correctness and bounded STT activation.
3. Player speech-style workflow repair.
4. Shared Herika shell and visual fixture lock.
5. Character page family.
6. AI and voice page family.
7. World and behavior page family.
8. Roleplay page family.
9. Control Panel page family.
10. Effective settings protocol and client application.
11. In-game panel/control polish and agent tools.
12. Context, action, TTS, lifecycle hardening, and negative autonomy checks.
13. Full deployment and acceptance evidence.

Each package should contain the smallest complete behavior, update the master matrix, and include its own validation evidence. Do not defer basic page correctness until the end of the site rebuild.

## 11. Definition of complete

ALMSIVI reaches this parity milestone only when all of the following are true:

- The browser shell and all shared page structures match the pinned Herika baseline at the required viewports, with every difference documented as an ALMSIVI substitution.
- Every baseline control is present and either functional or visibly disabled with an authoritative status.
- All browser forms use typed ALMSIVI services/repositories, scoped browser sessions, CSRF protection, and revision-safe PostgreSQL persistence.
- Journal is the canonical Morrowind quest surface; Relationships is absent from Roleplay navigation but remains available as administrative logs and prompt data where needed.
- Global -> Core Profile -> NPC inheritance is real end to end and its source is visible.
- Every applicable in-game action is discoverable in OpenMW Settings and opens or performs the correct behavior.
- Text conversation, cancellation, response queuing, subtitles, and TTS pass the lifecycle matrix.
- Exact actor voice routing and ALMSIVI volume boost pass representative in-game tests.
- Morrowind context, including Journal, books, and recent vanilla dialogue, is bounded and reaches prompts correctly.
- Timer-driven autonomy, ITT, and Background Life cannot be activated by the shipped product.
- Fresh-install and upgrade migrations, server integration, management HTTP, client checks, browser comparisons, and in-game smoke tests pass.
- Deployment records the exact client/server refs and destinations and preserves user configuration, profiles, voices, and database state.

## 12. Explicit non-goals and guardrails

- Do not copy Herika runtime/database code into ALMSIVI merely to make a page render.
- Do not remove ALMSIVI's typed services, repositories, session, CSRF, revision, job, or protocol boundaries.
- Do not add functional ITT, Background Life, Soulgaze, PipVision, or Skyrim-only quest systems in this milestone.
- Do not allow per-NPC settings to override local hotkeys or local UI/audio preferences.
- Do not advertise capabilities or actions that the current client and server cannot complete.
- Do not use broad generic management forms as the finished implementation for a copied Herika control.
- Do not deploy, migrate, or reset user data until the relevant phase passes its pre-deployment gate.
- Do not claim pixel parity from code inspection or claim in-game parity from structural tests alone.
