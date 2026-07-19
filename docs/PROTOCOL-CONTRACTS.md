# Protocol contract implementation

The canonical ALMSIVI v1 contract bytes are under `almsivi/schemas/v1` and
`almsivi/fixtures/v1`. Schemas declare JSON Schema Draft 2020-12 and reject unknown fields at each
contract-owned object boundary. `common.schema.json` pins OpenMW 0.51.0 commit
`f4bec41444214a7903bebd178389ca22ca13f646` and Lua API revision 129. Identity combines record ID,
RefNum, source content file, cell, kind, and a display-name snapshot; display names are not sufficient.
Timestamps use canonical UTC RFC 3339 `Z`, IDs use UUID text, and documented caps are explicit.

Run:

```bash
python3 scripts/protocol/generate_manifest.py --check
python3 scripts/protocol/validate.py
python3 -m unittest discover -s almsivi/tests -v
```

`generate_manifest.py` deterministically records every schema and fixture byte count and SHA-256 in
`almsivi/MANIFEST.json` and `almsivi/SHA256SUMS`. Regenerate them after intentional contract changes.
The validator uses only the Python standard library and checks repository structure, local references,
the schema-keyword subset used here, fixture classifications, and manifest currency. It is explicitly
not a complete JSON Schema implementation. When `jsonschema` is already installed, without fetching,
it also checks the official Draft 2020-12 meta-schema and instances.

The fake server in `almsivi/tests/fake_server.py` is test-only, fixture-driven, binds an ephemeral
`127.0.0.1` port, and refuses non-loopback binds. Diagnostics never retain authorization values or
request/response bodies. The harness covers auth, content types, idempotency, health, session/turn,
ordered polling with duplicate/gap handling, action results, interruptions, media hash/bytes,
malformed/oversized/wrong-type input, deadlines, disconnect/restart, and stale generations.

## Explicitly deferred contracts

The planning documents do not define these shapes precisely enough to encode without inventing a
server contract:

- health response details beyond the schema discriminator;
- session acceptance/config-revision/capability response, turn acceptance response, action-result
  persistence acknowledgement, interruption/cancellation acknowledgement, and session deletion;
- nested server-owned `turn.accepted`, `turn.status`, `dialogue.delta`, `dialogue.complete`,
  `turn.complete`, `turn.failed`, `turn.cancelled`, `session.config_changed`, `server.notice`, STT
  metadata/transcript/failure, config payloads, and resync response details; these event variants are
  omitted rather than assigned guessed payloads;
- endpoint-specific connect/write/first-byte/idle/total defaults and native per-frame poll count/time
  cap (only the documented 15-second server event-wait ceiling is contracted);
- all action intent names and parameter/result payloads except exact `ai.follow`; its parameter is
  exactly `{\"distance\": 192}`. Behavioral timeout, restoration, and policy remain implementation
  acceptance contracts;
- the `observed` action-result object and stable action reason-code enumeration; `observed` is omitted
  rather than assigned a guessed follow-package shape;
- exact context snapshot/delta domains and recent action-result embedding. `turn.context` is omitted
  from the canonical schema rather than assigned an invented representation;
- exact capability names/count, client-version syntax, platform values, UI-source values, interrupt
  reasons, and undocumented string/cell/identifier numeric bounds; known fields retain their base JSON
  types without freezing guessed enumerations or limits;
- aggregate event response count and payload shapes not explicitly listed above; the native inbound
  queue cap is not treated as a server events-array cap;
- cross-repository byte parity against ALMSIVIserver. The local deterministic manifest is ready for
  that check once the final server contract is authorized and available.

Schemas consequently cover known client-owned request shapes and known event payloads only. They do
not certify final server response evidence or in-game behavior.
