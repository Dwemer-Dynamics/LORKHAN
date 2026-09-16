# LORKHAN protocol v1

This document and `LorkhanServer/docs/PROTOCOL.md` must remain semantically identical. Canonical
JSON Schemas and fixtures live in both repos and CI compares their SHA-256 manifest.

## Transport

- Base: `http://127.0.0.1:7514/LorkhanServer/api/v1` through the DwemerDistro Launcher proxy by default; Apache listens on WSL port `8090`.
- Authentication uses `hmac-sha256-v1` request MACs. Fixed native headers carry installation ID, canonical UTC timestamp, unique random nonce, body SHA-256 and signature over algorithm/method/canonical target/content type/body digest/installation/timestamp/nonce. The 256-bit pairing MAC key is never transmitted routinely. Server persistence binds it to one installation, accepts active or bounded-overlap keys, rejects revoked keys, enforces clock skew and database nonce uniqueness, and covers JSON, event, session and media routes. Plaintext loopback still does not provide payload confidentiality against privileged local software; TLS is not claimed without server support.
- Requests and ordinary responses: `application/json; charset=utf-8`.
- STT uses bounded native WAV capture, authenticated binary upload, durable transcription, and fenced transcript events.
- Response progress: `GET /events?session_id=...&after=<sequence>&wait_ms<=15000`, returning bounded
  ordered JSON events. Long polling avoids exposing streaming parser complexity to Lua.
- Media: authenticated fixed route by opaque media ID; descriptor supplies hash/size/codec. No
  server-supplied absolute URL is followed.
- Mutating message POSTs require `Idempotency-Key` equal to envelope `message_id`; session DELETE uses its UUID key as response `request_id`.

## Common envelope

```json
{
  "schema": "lorkhan.turn.v1",
  "message_id": "019...",
  "request_id": "019...",
  "turn_id": "019...",
  "installation_id": "019...",
  "profile_id": "019...",
  "playthrough_id": "019...",
  "session_id": "019...",
  "generation": 7,
  "created_at": "2026-07-18T20:00:00Z",
  "runtime": {
    "game": "tes3",
    "variant": "openmw",
    "openmw_version": "0.51.0",
    "openmw_commit": "f4bec41444214a7903bebd178389ca22ca13f646",
    "lua_api_revision": 129,
    "client_version": "0.1.0",
    "platform": "windows-x86_64",
    "capabilities": ["dialogue.text", "speech.say", "action.ai.follow"]
  },
  "content_fingerprint": "sha256:...",
  "payload": {}
}
```

Unknown top-level fields and unknown enum values are rejected in v1. IDs are UUIDs, timestamps are
UTC RFC 3339, integers have schema bounds, strings are valid UTF-8 and payloads have endpoint caps.
The server accepts only current sessions/generations for turns and results.

## Canonical input, event, response, and game-data split

`lorkhan.input.v1` is the normalized player-text/STT input envelope. `lorkhan.event.v1` is the
typed source-event envelope. `lorkhan.response.v1` contains only `ok`, an ordered bounded `lines`
array, `close`, an error string, and the required installation/profile/playthrough/session/turn/request
plus response/runtime generation correlation. Every `lorkhan.response.line.v1` is either `say` or
`rolecommand`, carries stable speaker/listener/rechat identities and request/utterance IDs, and has
bounded text, TTS/media/cache, command, and metadata fields. The server normalizes provider output
once into this format; persistence, events, TTS, actions, delivery, diagnostics, and rechat consume it.

`lorkhan.gamedata.v1` accepts only typed TES3 actor, inventory, nearby-actor, world, Journal,
captured-dialogue, and prompt-bridge payloads. Automatic dialogue is submitted as an ordinary bounded
turn by the game-owned scheduler; the server does not accept a separate AI quest, boredom, greeting,
combat-bark, ITT, or Background Life variants. The required `lorkhan.events.v1.autonomy` field is
retained for v1 wire compatibility but must always be an empty array. Rechat is a normal correlated
turn and never an autonomy directive. All canonical envelopes require both response generation and
runtime generation values greater than zero.

## TES3/OpenMW identity

```json
{
  "kind": "npc",
  "record_id": "fargoth",
  "refnum": {"index": 112, "content_file": 0},
  "content_file": "Morrowind.esm",
  "cell": {"kind": "exterior", "grid_x": -2, "grid_y": -9},
  "display_name": "Fargoth"
}
```

For generated/runtime identities, include the OpenMW FormId/RefNum representation supported by the
pinned API. Record ID, content source/order, cell and runtime reference are jointly authoritative.
Names and server profile IDs are metadata. A content fingerprint is the SHA-256 of normalized engine
version/API plus the ordered content list and file identity metadata, never proprietary file bytes.

## Endpoints and schemas

| Method/path | Request schema | Response |
| --- | --- | --- |
| `GET /health` | none | `lorkhan.health.v1` |
| `POST /sessions` | `lorkhan.session.init.v1` | accepted session/capabilities/config revision |
| `DELETE /sessions/{id}` | no body; UUID `Idempotency-Key` | `lorkhan.session.ended.v1` |
| `POST /turns` | `lorkhan.turn.v1` | accepted request + first event cursor |
| `POST /controls/query` | `lorkhan.controls.query.v1` | four semantic profile model slots, NPC profiles, narrator ID, and target-effective settings snapshot |
| `POST /controls/select` | `lorkhan.controls.select.v1` | idempotent installation model preference, session profile selection, or revision-safe NPC/narrator generation |
| `POST /stt` | `lorkhan.stt.request.v1` metadata headers plus a binary WAV body | `lorkhan.stt.accepted.v1`; durable work later emits `stt.transcript` or `stt.failed`. |
| `POST /menu-dialogue-tts` | `lorkhan.menu-dialogue-tts.v1` | `lorkhan.menu-dialogue-tts.ready.v1` with one actor-owned, short-lived media descriptor |
| `GET /events` | session/cursor/wait | `lorkhan.events.v1` |
| `POST /action-results` | `lorkhan.action-result.v1` | persisted acknowledgement |
| `POST /interruptions` | `lorkhan.interrupt.v1` | cancellation acknowledgement |
| `GET /media/{opaque_id}` | none | verified allowlisted audio bytes |

Regular Morrowind dialogue TTS uses the active session and the actor's normal TTS connector and voice
resolution. It does not create an AI turn, response event, delivery receipt, memory, or rechat input.
The client owns one cancellable menu request at a time and fetches its returned media through the same
authenticated media route.

## Turn payload

A shipped turn includes typed text input, resolved speaker/target/audience identities,
bounded context snapshot/delta, recent terminal action results, and UI source. It never includes the
pairing token, provider key, host file path, save bytes, proprietary assets, engine pointers, or raw
unbounded logs.

Explicit typed player turns may select `execution_mode` `injection_log` or `injection_chat`.
Both require `ui_source=lorkhan_text`, text input, and no action request or Director child ID.
The input is recorded as a scene event, not spoken player dialogue. `injection_log` persists the
event and emits `turn.accepted` followed by `turn.complete` without provider, speech, or action jobs.
`injection_chat` additionally generates a reply to that event through the normal NPC/Narrator lane;
it never speaks the injected input as the player or enables provider actions.

A playback-driven rechat turn sets `ui_source` to `lorkhan_rechat` and carries the Herika-compatible
typed hint vocabulary: `speaker`, `listener_hint`, `rechat_target_hint`, `origin_line`,
`rechat_depth`, and `chain_id` (plus the originating turn correlation). The server owns mode,
probability pre-roll, round budget, and responder selection, then resolves that NPC's profile, LLM,
TTS, and voice. The client owns ordered playback and cancellation. It submits only after the complete
speech lane is terminal and its final delivery result is `played`, with at most one rechat request in
flight. Immediately before submission it requests one bounded actor-local OpenMW state probe for the
previous speaker and at most 12 candidate responders. The optional `participant_states` list carries
only stable identities and `active`, `busy`, `sleeping`, `unconscious`, or `inactive`; API 129 currently
proves all except sleeping. Missing or late proof fails closed, busy/unconscious/inactive actors are
excluded, and sleeping remains a forward-compatible server rule for a directly addressed actor only.
Rechat provider actions are always discarded, and a chain closes at its server-owned budget or cancels
on new player input, failure, combat, lifecycle changes, stop, or stale state.
Close mode may continue only within its explicit recorded group, and every reply retains that group for
the next round. Whisper remains single-turn and never starts playback-driven rechat.

An in-game action menu may add `action_request` with a catalog action name, exact tier, bounded
parameters, and an optional explicit target. The server derives the actor from the resolved turn target.
It normally derives the action target from the player speaker; only `ai.face`, `combat.start`, and
`combat.stop` may override that target, and only with a different identity present in the bounded nearby-actor context.
The server then applies the negotiated capability and profile action policy without invoking the
language-model provider. Accepted requests still emit the ordinary `turn.accepted`, `action.intent`,
and `turn.complete` sequence.

`ai.travel` and `ai.escort` carry only a player-ray-captured `destination_x`, `destination_y`,
`destination_z`, and canonical `destination_cell`. Both client and server bound those fields, and the
actor rechecks the current cell before starting an OpenMW package.

The API-129 action set additionally provides bounded read-only `inventory.inspect`, same-cell
`ai.approach`, and duration-bounded `ai.wait`. Their names, tiers, parameters, negotiated capabilities,
native parser variants, Lua handlers, server catalog rows, and protocol fixtures are synchronized. The exhaustive
frozen-catalog disposition is recorded in `docs/evidence/openmw-action-parity-audit.md`.

In-game controls never accept provider endpoints, API keys, or executable configuration. Model choices
are the fixed semantic keys Standard, Fast, Powerful, and Experimental. The selected installation
preference resolves through the active target profile, while Random LLM takes precedence and an empty
selected slot falls back to the first configured profile slot. Returned connector details are display-only;
a `configured` connector retains its server-owned endpoint and credential environment, while a `mock`
connector remains deterministic. Roleplay
NPC profiles bind to one stable actor identity within the active installation/playthrough; player and narrator
profiles are excluded from that binding list. The installation narrator ID permits only the server-validated,
revision-safe narrator-generation operation. The chosen
profile owns that actor's relationship and manual-memory context within the installation/playthrough.
Source-derived memories additionally require witnessed-source eligibility. Unbound targets do not
inherit another actor's relationships or manual memories from the session profile. Every accepted turn
freezes the assembled prompt and selected provider revision before worker execution.

Every controls response includes `lorkhan.effective-settings.v1` for the active target. It carries the
resolved automatic-dialogue, rechat, memory, narrator, safety, and client-visible routing values; Global/Core Profile/NPC source metadata; bound profile
revisions; and a deterministic change token. Local hotkeys, HUD visibility, panel layout, and TTS volume boost
remain OpenMW preferences and are never replaced when the target changes. The effective settings
snapshot includes the automatic-dialogue controls and all seven playback-gated rechat controls. The
strict v1 wire shape retains compiled presentation and remaining legacy behavior defaults for older
parsers; local presentation remains authoritative. Local and server safety permissions must both allow an operation.
Greeting, boredom, and combat-bark timing stays game-owned and enters the existing turn lane only while
idle. ITT, Background Life, and unrelated timer-driven model work remain excluded.
Server-only Oghma tags and Oghma/profile-generation routes stay on the server. The source map omits
excluded/internal paths and compatibility-only defaults; model-slot drivers remain `mock` or
`configured`. STT uses one installation-global connector and does not enter the Global/Core Profile/NPC resolver.

Server response events have a strictly increasing per-session `sequence`. The current v1 slice contracts `turn.accepted`, `dialogue.delta`, `dialogue.complete`, `speech.ready`, `stt.transcript`, `stt.failed`, `action.intent`, `turn.complete`, `turn.failed`, and `turn.cancelled`. Bounded `dialogue.delta` text is display-only progress; the validated `dialogue.complete` remains the durable utterance and memory source. TTS runs as a separate durable job after the dialogue is committed, and every `speech.ready` descriptor carries its `dialogue_message_id` so delayed group speech remains correctly ordered. Every envelope includes `message_id`, `request_id`, `turn_id`, `session_id`, `generation`, `sequence`, `created_at`, type and strict payload. The events response is capped at 100 items and its required `autonomy` array is always empty.

`dialogue.complete` is the final utterance. The client reports one terminal delivery result for each
utterance, and the server mirrors it into durable speech state (`spoken`, failure, cancellation, or
expiry). Duplicate events by `(session_id, sequence, message_id)` are ignored. Cursor gaps force
bounded replay, never guessed ordering. Configuration/notice and resync variants remain future
amendments rather than accepted open variants.

## Action intent and result

```json
{
  "schema": "lorkhan.action-intent.v1",
  "action_id": "019...",
  "turn_id": "019...",
  "name": "ai.follow",
  "tier": 1,
  "actor": {},
  "target": {},
  "parameters": {"distance": 192},
  "expires_at": "2026-07-18T20:00:10Z"
}
```

```json
{
  "schema": "lorkhan.action-result.v1",
  "message_id": "019...",
  "request_id": "019...",
  "action_id": "019...",
  "turn_id": "019...",
  "session_id": "019...",
  "generation": 7,
  "status": "succeeded",
  "reason_code": "package_started",
  "observed": {"package": "Follow"},
  "completed_at": "2026-07-18T20:00:02Z"
}
```

Terminal statuses are `succeeded`, `failed`, `rejected`, `timed_out`, or `cancelled`. One action ID
has exactly one terminal result. Human-readable text is diagnostic only; server reasoning uses
status/reason/observed typed fields.

## Error model

HTTP status communicates transport/auth class; JSON communicates a stable code:

- `invalid_schema`, `payload_too_large`, `unauthorized`, `forbidden`, `rate_limited`;
- `unknown_session`, `stale_generation`, `duplicate_conflict`, `cursor_expired`;
- `provider_unavailable`, `provider_timeout`, `media_unavailable`;
- `action_disabled`, `internal_error`.

Client-facing messages are generic. Detailed provider/database errors enter structured redacted
server logs with correlation IDs. Retriability and `retry_after_ms` are explicit.

## Limits and compatibility

Default server caps mirror or tighten native caps: 2 MiB JSON, 32 MiB media, 128 KiB
context, 12 audience actors, 4 actions/turn, 1 result-aware continuation/action, 15 s event wait,
60 s turn and 120 s provider hard deadline. Negotiation may lower caps only.

Breaking changes use `v2` schemas/routes. Additive fields still require schema changes and dual-repo
fixture updates because v1 rejects unknown fields. Client/server refuse unsupported versions with a
clear compatibility status; they never silently fall back to legacy tuple or file protocols.

## In-game Settings, RPG events, and book read-aloud

- `/controls/query` accepts optional `include_settings_editor`. When true, the response may include
  three bounded sections (`global`, `core_profile`, `npc`), at most 64 fields each. Values are strings
  capped at 512 bytes in the native editor; long existing profile prose is not truncated into an edit.
- `/controls/select` accepts `kind=setting` with `setting={scope,key,value,change_token}` and null
  selection IDs/keys. The server owns the field allowlist and rejects stale snapshot tokens.
- `/gamedata` accepts `type=rpg_event`, carrying `kind`, player identity, game time, and observed text.
  Level changes, nearby combat ending, and completed sleep/wait periods are observed without engine
  mutation. `lockpick` is reserved but is not emitted from generic Unlock events, which also include
  spells and do not establish who used a lockpick. RPG acceptance alone may include `comment_requested`.
- `/book/read-aloud` uses `lorkhan.book.read-aloud.v1` with standard message/request/session/generation
  correlation plus `book_id`, `title`, and one text chunk. It returns the existing authenticated
  `lorkhan.menu-dialogue-tts.ready.v1` media shape with the server-resolved Narrator identity.
  The client queues short sentences and cancels on book-menu closure; this is not an NPC dialogue turn.

These controls do not expose provider secrets or model-accessible console authority. Diary read-aloud
and a provenance-correct lockpick observer remain separate follow-up work; generated diaries and
sleep/wait diary triggers retain their existing behavior.

### RPG responder policy correlation

RPG payloads optionally carry `responder`, a strict NPC/creature identity. The
server resolves that actor's Core Profile before the single idempotent event/chance
decision. Legacy player-only payloads retain global policy. Supported event kinds
are levelup, combat_end, sleep and wait; lockpick is not accepted until the client
can prove the actor and actual lockpick use rather than a generic Unlock event.

The client freezes an eligible nearby responder when observing the event. A bounded
32-entry, 30-second request map correlates acceptance to the same identity and
session/generation. Changed targets, expired/duplicate acknowledgements and busy
speech/combat/input lanes cannot substitute another NPC. The global handoff checks
that identity again. A successful RPG turn starts a 60-second game-owned real-time
scheduler cooldown; lifecycle invalidation clears it. Existing native serialization
and acknowledgement fields are unchanged; no native engine modification is needed.

### Loaded-save calendar and pre-replacement snapshots

`lorkhan.session.init.v1` optionally includes `loaded_save`. Normal startup,
reconnect and new-game initialization omit it. Only an actual loaded save includes
an object with integer `year` (1..9999), zero-based `month` (0..11), valid fixed-calendar
`day`, and numeric `hour` (0 inclusive, 24 exclusive). Null records an unavailable
calendar without inventing a date. Unknown fields and invalid dates are rejected.

GLOBAL Lua fences the native session restart at `onLoad`, then calls the typed
`finishLoadedSave(calendar)` when the loaded player is present. Native code freezes
the four scalar fields in the init DTO; it performs no network work on the main
thread. A known-calendar loaded-save init has a 20-second first-byte budget within
the existing 30-second total request budget. Normal requests keep their deadlines.

After authentication, schema and generation checks, but before replacing the old
session, the server compares the calendar with the latest recorded turn in that
installation/playthrough/profile. A rollback of at least three game days attempts
an immutable full database snapshot. The archive retains committed pre-replacement
state; duplicate calendar transitions reuse the stored record. Capture failures
are logged and audited without intentionally rejecting a valid session. This does
not restore the database or prune immutable future history automatically.


### Independent inventory observations

The typed gamedata inventory observation keeps exact owner identity and a bounded
item list. Native and server admission accept only physical NPC, creature or player
owners; Narrator is rejected. Item `condition` is optional: report a normalized 0-1 value only when
OpenMW provides a degrading condition and its maximum. Items without durability
omit it. Item `content_file` is also optional when the engine cannot establish the
record origin; no content file is guessed from the owner. Present values retain
the existing type, length and range checks. This does not relax action identities:
item actions still require their canonical record/content-file pair.

Inventory observations have no recorded game calendar. Consumers use only the
current exact session/generation/playthrough and never carry them across a loaded
save. Current-turn observed inventory, including an empty list, wins over fallback.
Deploy the paired server schema before a client that emits the optional fields.

### Successful spell and pickup observations

`gamedata` types `spell_cast` and `item_pickup` record bounded successful engine
observations without scheduling a model turn. Native capture and Lua delivery retain
the originating session and generation; stale observations are discarded. At most
twelve nearby witnesses are attached. Witnesses describe proximity, not line of sight.

Spell observations contain the caster, spell ID/name, game time, and optional cast
target. A target is not proof of a hit. Failed or scripted casts are not captured.
Pickup observations contain the player, item ID/name, transferred count, unit gold
value, game time, and source kind (`world`, `container`, or `actor`). Optional source
ID/name is descriptive text only, never an actor routing identity. Successful normal
world pickups, container/actor transfers, and harvesting are supported; barter,
crafting, console/script additions, and cancelled transfers are not pickup observations.
Gold is normalized once to its acquired inventory quantity and canonical unit value.

The server retains original observations and projects `spellcast`, `npcspellcast`,
and `itemfound` event history. Scoped conversation context respects the existing
Infoaction category, location/item/magic blacklists, Detect Magic Events (default on),
and Item Pickup Detection Value (default 500 total gold, count times unit value).
Global, Core, and NPC overrides affect prompt inclusion; they do not erase event logs.

New observations also carry the capture-time calendar using the existing loaded-save
shape (zero-based month). Loading an earlier save retires observations at or beyond
its cutoff while preserving earlier dated observations. Legacy undated spell/pickup
records are retained as evidence but cannot cross session boundaries into context;
the DaysPassed clock is never guessed to be an absolute calendar timestamp.


## Physical NPC diary books (2026-09-13)

The user approved a narrow exception to the record-creation boundary for physical NPC diaries.
This does not authorize model-selected record properties, scripts, console commands, paths, assets,
or arbitrary record creation. No content addon or bundled game asset is introduced.

The opt-in Core Profile/NPC setting `diary.materialize_enabled` is labelled **Physical Diary**.
The server selects completed generated diary entries for the exact NPC/creature and playthrough,
combines the latest five into a bounded plain-text book, and excludes invalidated future sources.
Player and Narrator profiles are excluded. Editing a generated entry updates its book contents.

Clients advertise `diary.books.v1`. Authenticated `POST /diary-books/query` returns a nullable
`lorkhan.diary-book.v1` delivery, correlated by request/session/generation. A stable book UUID
identifies one NPC/playthrough diary; a delivery UUID identifies the current content snapshot.
Titles are bounded to 128 UTF-8 bytes; content to 2048 characters and 8192 UTF-8 bytes, with a
SHA-256 content hash. `POST /diary-book-results` records only correlated terminal execution results.
An accepted HTTP request is not evidence that a book was created.

The native client retains the authenticated snapshot and exposes only typed diary materialization.
The exact NPC reference is checked again on the main thread. A deterministic saved dynamic book
record is created once and updated in place, including when its inventory item has moved or been
dropped. Book properties are fixed by native code; visuals reuse an installed mundane book. Text is
neutralized for the TES3 book parser, including literal game-variable markers.
Loading an older save allows the eligible current snapshot to be reconciled without a global
server receipt incorrectly claiming that the book still exists in that save.

This exception is separate from the deferred original content-addon deliverable. In-game reading,
movement, dropping, and save/reload acceptance require user testing; builds do not prove gameplay.

## Approved advanced Cheat/Narrator actions

The user approved this bounded authority extension after the schema117 parity build. It permits
instances of existing loaded item/NPC/creature records, gold creation, verified player/actor
teleportation, living actor vitals restoration, selected dead actor resurrection and selected actor
killing. It does not permit new record definitions, arbitrary scripts/console commands, deletion,
model-provided coordinates, paths or URLs. No Rapport dependency or expanded follower framework.

Actions: item.create (count1..100), gold.create (amount1..100000), actor.spawn (count1..4),
actor.teleport_to_player, player.teleport, actor.restore, actor.resurrect, actor.kill.
Each action has tier2 and mandatory one-intent player confirmation. Follow-up actions are disabled.
Only explicit player text or push-to-talk in Cheat/Narrator mode can expose them; open microphone,
Rechat, automatic dialogue and Director children cannot inherit this authority. The world executor
is the exact current player identity, never an NPC policy or the body of the Narrator.

Native submitTurn overwrites context.advanced_actions from the loaded game catalog using the
explicit request text. Up to16 item,16 actor and16 destination candidates are frozen per turn.
The model chooses only those IDs; destination IDs resolve to frozen native positions, not model
coordinates. No full catalog is transmitted, no background scan or new provider call is added.

Approval displays the exact target and parameters plus frozen record/destination labels. Kill and
resurrection warn about quest consequences. Completed mutations are not promised reversible.
Native code validates live exact references/state again, executes once on the main thread, and
retains a terminal receipt so retries never duplicate spawning. Save/session changes cancel pending
work, while committed results cannot be rewritten into cancellation. Player death is not permitted.

Automated protocol, Lua and server integration checks cover all eight actions, strict approval, frozen candidates, rejected requests and duplicate replay. Server schema 118 is locally deployed. Windows Release build, native bridge and Beast loopback tests passed. The engine and all 32 client data files were deployed locally with matching SHA256 hashes; no in-game execution is claimed.

Record names accept simple plural forms (rat/rats, robe/robes), without fuzzy matching. Ambiguous record names require an exact loaded record ID. Actor spawning creates instances only; dynamically generated actors are not yet addressable for AI profiles or later LORKHAN actions under the existing v1 identity contract. Vanilla game interaction is unaffected.

Client deployment engine SHA256: 923123E3FC9E937B901606E928128911AF5605CF1A46D54FB6A28A13162B70D9. Server tests: 1421 checks plus integration, migrations/jobs and factory restore checks. Lua: 90 tests. Protocol: 42 schemas and 93 fixtures. OpenMW: all 29 declared source hashes and 10 patch fixtures passed.
