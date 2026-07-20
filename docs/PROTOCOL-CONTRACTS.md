# Protocol contract implementation

The canonical ALMSIVI v1 bytes are under `almsivi/schemas/v1` and `almsivi/fixtures/v1`. They use JSON Schema Draft 2020-12, strict contract-owned objects, canonical lowercase UUIDs, UTC RFC 3339 timestamps, the OpenMW 0.51.0/API-129 runtime pin, bounded arrays/strings/media, and TES3 identities.

## Independent decision revision

The original planning lock deferred server-owned response details until an authoritative server existed. On 2026-07-19 the sibling ALMSIVIserver independently implemented the no-game PostgreSQL vertical slice. This batch deliberately revises that deferral only for the concrete shapes emitted by that implementation: session acceptance, turn acceptance, events, interruption acceptance, action-result acceptance, and session end. The revision is evidenced by byte-identical dual-repository schemas/fixtures, authoritative Draft 2020-12 fixture validation, captured server-response validation, typed C++ parsing, Lua mapping checks, and the disposable-PostgreSQL cross-repository harness. It does not authorize broader product semantics.

Run locally:

```bash
python3 scripts/protocol/generate_manifest.py --check
python3 scripts/protocol/validate.py --require-jsonschema
python3 -m unittest discover -s almsivi/tests -v
# sibling ALMSIVIserver:
scripts/verify-protocol-parity.sh
scripts/test/cross-repo-integration.sh
```

`MANIFEST.json` and `SHA256SUMS` deterministically cover all schema and fixture bytes and record `cross_repository_byte_parity` as `locally-proven`. The active-worktree parity result is local dirty-tree evidence, not clean-commit durable proof.

## Contracted response surface

- `almsivi.session.accepted.v1`: originating message, session/generation, negotiated capabilities, configuration revision and cursor.
- `almsivi.turn.accepted.v1`: full message/request/turn/session/generation correlation and cursor.
- `almsivi.events.v1`: session/generation/cursor plus at most 100 strict event envelopes.
- `almsivi.interruption.accepted.v1`: full correlation, cursor and duplicate marker.
- `almsivi.action-result.accepted.v1`: full correlation, action/status and duplicate marker.
- `almsivi.session.ended.v1`: delete request/session/generation and whether this call ended it.

Contracted event variants are exactly the current server outputs: `turn.accepted`, `dialogue.complete`, `action.intent`, `turn.complete`, `turn.cancelled`, `turn.failed` for provider timeout/unavailability, and `speech.ready`. Every event carries message, request, turn, session, generation, sequence and creation time. Media must be non-empty and independently hash/size/type/expiry validated.

Mutating message endpoints require `Idempotency-Key` equal to the envelope `message_id`. Session DELETE has no body and uses its UUID idempotency key as the response `request_id`. `request_id` remains operation correlation; an action-result request has its own request/message identity and is bound separately to action, turn, session and generation.

## Intentionally deferred details

- `turn.status`, `dialogue.delta`, configuration/notice/resync events, STT response variants, and any provider/product event not emitted by this slice;
- typed contents inside bounded `context` and `observed` objects, and stable reason-code catalogues;
- action names and parameters beyond exact `ai.follow` with `{"distance":192}`;
- private media serving/storage, streaming, worker and broad provider contracts;
- exact platform/game/clean-commit evidence.

The fake server is test-only, binds an ephemeral loopback literal, emits the same accepted/event/end shapes, and covers auth, content type/size, message idempotency, sessions/turns/events, duplicates/gaps, interruption/action results, session deletion, media bytes/hash, malformed input, deadlines, disconnect/restart and stale generations.
