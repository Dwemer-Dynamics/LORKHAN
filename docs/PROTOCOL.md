# ALMSIVI protocol v1

This document and `ALMSIVIserver/docs/PROTOCOL.md` must remain semantically identical. Canonical
JSON Schemas and fixtures live in both repos and CI compares their SHA-256 manifest.

## Transport

- Base: `http://127.0.0.1:8089/ALMSIVIserver/api/v1` by default.
- Authentication uses `hmac-sha256-v1` request MACs. Fixed native headers carry installation ID, canonical UTC timestamp, unique random nonce, body SHA-256 and signature over algorithm/method/canonical target/content type/body digest/installation/timestamp/nonce. The 256-bit pairing MAC key is never transmitted routinely. Server persistence binds it to one installation, accepts active or bounded-overlap keys, rejects revoked keys, enforces clock skew and database nonce uniqueness, and covers JSON, STT, event, session and media routes. Plaintext loopback still does not provide payload confidentiality against privileged local software; TLS is not claimed without server support.
- Requests and ordinary responses: `application/json; charset=utf-8`.
- STT upload: bounded WAV body only (`codec: wav`) plus metadata headers/schema.
- Response progress: `GET /events?session_id=...&after=<sequence>&wait_ms<=15000`, returning bounded
  ordered JSON events. Long polling avoids exposing streaming parser complexity to Lua.
- Media: authenticated fixed route by opaque media ID; descriptor supplies hash/size/codec. No
  server-supplied absolute URL is followed.
- Mutating message POSTs require `Idempotency-Key` equal to envelope `message_id`; session DELETE uses its UUID key as response `request_id`.

## Common envelope

```json
{
  "schema": "almsivi.turn.v1",
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
| `GET /health` | none | `almsivi.health.v1` |
| `POST /sessions` | `almsivi.session.init.v1` | accepted session/capabilities/config revision |
| `DELETE /sessions/{id}` | no body; UUID `Idempotency-Key` | `almsivi.session.ended.v1` |
| `POST /turns` | `almsivi.turn.v1` | accepted request + first event cursor |
| `POST /controls/query` | `almsivi.controls.query.v1` | safe server-owned model slots, NPC profiles, and installation narrator ID |
| `POST /controls/select` | `almsivi.controls.select.v1` | idempotent session model/profile selection or revision-safe NPC/narrator generation |
| `POST /stt` | metadata + audio | transcript event or typed failure |
| `GET /events` | session/cursor/wait | `almsivi.events.v1` |
| `POST /action-results` | `almsivi.action-result.v1` | persisted acknowledgement |
| `POST /interruptions` | `almsivi.interrupt.v1` | cancellation acknowledgement |
| `GET /media/{opaque_id}` | none | verified allowlisted audio bytes |

## Turn payload

A turn includes input `{kind: text|stt, text, language}`, resolved speaker/target/audience identities,
bounded context snapshot/delta, recent terminal action results, and UI source. It never includes the
pairing token, provider key, host file path, save bytes, proprietary assets, engine pointers, or raw
unbounded logs.

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

In-game controls never accept provider endpoints, API keys, or executable configuration. Model choices
are revisioned server-owned slots: a `configured` slot may override only the model while retaining the
server process endpoint and credential environment; a `mock` slot remains deterministic. Roleplay
NPC profiles bind to one stable actor identity within the active installation/playthrough; player and narrator
profiles are excluded from that binding list. The installation narrator ID permits only the server-validated,
revision-safe narrator-generation operation. The chosen
profile affects that actor's profile and prompt sources, while memory, relationship, knowledge, and
narrative retrieval remain scoped to the session profile/playthrough. Every accepted turn freezes the
assembled prompt and selected provider revision before worker execution.

Server response events have a strictly increasing per-session `sequence`. The current v1 slice contracts exactly `turn.accepted`, `dialogue.complete`, `speech.ready`, `action.intent`, `turn.complete`, `turn.failed`, and `turn.cancelled`. Every envelope includes `message_id`, `request_id`, `turn_id`, `session_id`, `generation`, `sequence`, `created_at`, type and strict payload. The events response is capped at 100 items.

`dialogue.complete` is the final utterance. Duplicate events by `(session_id, sequence, message_id)` are ignored. Cursor gaps force bounded replay, never guessed ordering. Streaming deltas/status, configuration/notice and resync variants remain a future v1 amendment rather than accepted open variants.

## Action intent and result

```json
{
  "schema": "almsivi.action-intent.v1",
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
  "schema": "almsivi.action-result.v1",
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

Default server caps mirror or tighten native caps: 2 MiB JSON, 16 MiB STT, 32 MiB media, 128 KiB
context, 12 audience actors, 4 actions/turn, 1 result-aware continuation/action, 15 s event wait,
60 s turn and 120 s provider hard deadline. Negotiation may lower caps only.

Breaking changes use `v2` schemas/routes. Additive fields still require schema changes and dual-repo
fixture updates because v1 rejects unknown fields. Client/server refuse unsupported versions with a
clear compatibility status; they never silently fall back to legacy tuple or file protocols.
