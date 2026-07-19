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
- nested server-owned `turn.status`, `turn.failed`, `session.config_changed`, `server.notice`, STT
  metadata/transcript/failure, config payloads, and resync response details;
- endpoint-specific connect/write/first-byte/idle/total defaults and native per-frame poll count/time
  cap (only the documented 15-second server event-wait ceiling is contracted);
- all action intent names and parameter/result payloads except exact `ai.follow`; its documented
  distance example is typed and bounded to a conservative engine-unit range, but behavioral timeout,
  restoration, and policy remain an implementation acceptance contract;
- typed `observed` payloads beyond the known follow package observation, and stable action reason-code
  enumeration beyond its documented lowercase diagnostic form;
- exact context object domains and recent action-result embedding. Until domain schemas are specified,
  `turn.context` is a bounded UTF-8 serialized snapshot string rather than an invented object model;
- cross-repository byte parity against ALMSIVIserver. The local deterministic manifest is ready for
  that check once the final server contract is authorized and available.

Schemas consequently cover known client-owned request shapes and known event payloads only. They do
not certify final server response evidence or in-game behavior.
