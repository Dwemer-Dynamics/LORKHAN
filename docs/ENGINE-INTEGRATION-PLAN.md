# OpenMW engine integration plan

## Why a native patch is required

OpenMW Lua 0.51 runs each script in an OS-isolated sandbox. Its exposed packages include world,
types, UI, input, sound, storage and a read-only VFS, but not HTTP or sockets. Storage is internal
persistent script data, and VFS is read-only; neither is a supported real-time server bridge.

The patch adds one narrow product package. It does not introduce a general networking facility for
mods and does not change existing script permissions.

## Patch surface

Prefer new files under:

```text
apps/openmw/mwlorkhan/
  bridge.hpp/.cpp
  client.hpp/.cpp
  configuration.hpp/.cpp
  dto.hpp/.cpp
  mediastore.hpp/.cpp
  validation.hpp/.cpp
apps/openmw/mwlua/
  lorkhanbindings.hpp/.cpp
components/lorkhan/
  protocol.hpp/.cpp
  queues.hpp
  result.hpp
```

Expected upstream-file edits are limited to root/component/app CMake lists, Lua package declaration
and registration, application lifecycle construction/shutdown, VFS/media registration seam if
required, version branding, and packaging. Every edit is listed with rationale and upstream base
blob SHA in `patch-manifest.json`.

`openmw.lorkhan` is registered for GLOBAL, PLAYER and CUSTOM/local scripts. MENU receives a separate
status-only surface if needed; LOAD receives none. Context tests prove unavailable functions cannot
be required or invoked outside their intended context.

## Lua API surface

The exact v1 shape may use Lua tables but contains only these typed operations:

- `version`, `capabilities()` and `status()` — safe constants/health, never token or host paths.
- `configureProfile(profileId)` — selects a predeclared native profile; no URL argument.
- `submitInit(dto)`, `submitTurn(dto)`, `submitActionResult(dto)`, `submitStt(dto)` — strict typed
  schemas, returning request IDs or explicit synchronous validation errors.
- `pollResults(maxItems)` — validated current queue items up to a hard cap.
- `cancel(requestId)`, `cancelGeneration(generation)`, `halt()`.
- `prepareMedia(mediaDescriptor)` — server-issued opaque media ID/hash/size/codec only.
- `mediaStatus(mediaId)`, `playSpeech(mediaId, actor, subtitle)`, `stopSpeech(actor)` — no path.
- optional test-only diagnostics behind a compile-time flag absent from release packages.

There is deliberately no `request(method, url, body)`, `download(url, path)`, file open/write,
process execution, environment access, callback that runs on the worker, or token getter.

## Transport decision

Use existing Boost 1.70+ infrastructure and add the `system` component. Boost.Asio/Beast provides a
portable asynchronous HTTP/1.1 client without pulling Qt Network into the OpenMW runtime. V1 uses
plain HTTP only because the peer is an IP loopback literal; external/LAN endpoints and TLS are not
supported. This makes the trust and certificate boundary unambiguous.

Rules:

- parse URL once at configuration load; allow only `http`, no userinfo/query/fragment;
- require IP literal in `127.0.0.0/8` or `::1`, never resolve DNS;
- refuse redirects, proxy environment variables, connection reuse across profile changes, and any
  response with unexpected content type;
- bearer pairing token added natively; redact it and provider content from diagnostics;
- 2 MiB JSON request/response hard cap, 16 MiB STT upload, 32 MiB media file, configurable lower
  operational caps; reject unknown-length/overflow/chunk abuse;
- connect, write, first-byte, idle and total deadlines; cancellation closes the operation;
- max 32 outbound, 128 inbound/control items, reserved halt/control capacity;
- no retry for turns/actions; health/media GET may retry with bounded exponential backoff and jitter;
- IDs make accepted retries idempotent server-side.

## Media design

Stock `Sound.say` resolves a VFS filename through the FFmpeg decoder, so a file downloaded after
startup is not safely assumed visible to the existing read-only VFS. The bridge therefore owns a
controlled media service:

1. Server response supplies media ID, relative server route, SHA-256, byte count, codec and expiry.
2. Native code constructs the fixed loopback route; Lua cannot provide it.
3. Bytes stream to a private LORKHAN cache using a temporary name, size cap and restrictive access.
4. Validate HTTP type, byte count, SHA-256 and allowlisted codec (`wav`, `ogg`, `mp3` as supported by
   the pinned FFmpeg build); atomically promote under a hash-derived name.
5. Register/open the verified resource through an LORKHAN-only resource manager/decoder seam and
   invoke the existing voice playback/loudness path so lip animation and spatial voice work.
6. Enforce 512 MiB default quota, LRU eviction of unpinned entries, expiry, no path traversal and no
   deletion outside the resolved cache root.

If the least-invasive implementation can mount one controlled cache directory into VFS before the
game starts, use that. Runtime-generated files still enter through the native verifier and opaque
IDs; Lua never gains general VFS writes. If live VFS indexing cannot safely observe atomic additions,
use a dedicated LORKHAN decoder entry point. This is an implementation branch with an objective
probe and fixed preference order, not an architectural question.

## Lifecycle and threading

- Construct after configuration/logging and before Lua package registration.
- All public Lua functions validate/copy synchronously and enqueue; none waits on I/O.
- Worker uses no `sol`, `MWWorld::Ptr`, VFS object, UI object or OpenMW service.
- Main thread maps validated results back into Lua events/tables and resolves actor identity again.
- Shutdown cancels all I/O, closes sockets, waits for worker, clears token memory and cache pins.
- A debug assertion/thread checker guards engine-facing code; focused queue/cancellation race tests
  exercise pure bridge components without requiring a hosted sanitizer matrix.

## Native validation matrix

Test valid IPv4/IPv6 loopback; non-loopback; DNS names including `localhost`; octal/hex/mapped IPs;
userinfo; redirects; proxy variables; CRLF; duplicate headers; chunk overflow; wrong type; missing or
bad token; duplicate IDs; unknown fields; malformed UTF-8/JSON; numeric overflow; queue pressure;
timeouts at each stage; cancel races; server restart; profile/generation change; shutdown during each
stage; media truncation/hash/codec/path/zip-bomb-like data; cache quota and symlink/reparse attacks.

## CHIM parity controls and reading additions

The typed native surface also exposes `updateSessionSetting(scope,key,value,changeToken,target)`.
It accepts only a field advertised by the current authenticated Settings snapshot. Server-side
allowlists, target/installation scope, revision checks, and generation checks remain authoritative.
`requestSessionControls(target,true)` opts into the bounded Settings editor; old queries retain their
unchanged response shape. No generic URL or document mutation is exposed.

`submitAutomaticDiary` and `submitRpgEvent` submit their closed game-data types. RPG commentary is
considered only after the server explicitly authorizes an accepted event. The internal callback is
session/generation fenced and uses the ordinary nearby-target dialogue path without player TTS.

`requestBookReadAloud(bookId,title,text)` submits one bounded book sentence to the server's Narrator
route. The player must enable Read Books Aloud, which defaults off. Existing verified media and
local speech playback are reused; no provider, actor impersonation, path, or arbitrary URL is accepted.
`pumpMenuDialogueTts` advances only owned speech/media during paused menus and defers other results.
Book closure, Halt, session change, and generation change cancel pending and playing book speech.


### Quest journal delta preparation (2026-09-08)

Replaced the final-line-only signature with a bounded 32-entry comparison owned
by the current session and generation. Initial snapshots and ordering/removal
alone do not emit updates; changed stage/text retains the exact entry payload
for the upcoming Quest Comment request. Existing narrator routing remains in
place. Tests cover baseline, order, stage/text changes, copy isolation, repeated
snapshot and session-generation reset: 71 Lua tests passed.

Deployed only player.lua and player_state.lua with matching hashes and unchanged
Config; local Temp rollback `lorkhan-journal-rollback-o54upfn0`. No engine build
needed and no game launched. This does not yet implement NPC Quest Comments: the
server request, actual changed-text prompt, Core UI and end-to-end checks remain.

### Loaded-save handshake fence

`cancelGeneration(generation, loadedSave)` accepts an optional boolean lifecycle
marker; the default remains false. Only GLOBAL orchestration passes true for an
actual save load. `finishLoadedSave(calendar)` releases that pending fence with
four validated calendar scalars or nil for unknown. It returns false when no load
fence exists. Neither method accepts a URL, path, script or generic request.

Loaded-save snapshot checkpoint: WINDOWS BUILD PROVEN on 2026-09-12. Exact OpenMW
pin f4bec41444214a7903bebd178389ca22ca13f646; Release openmw.exe SHA-256
096691cd213ab048ea632bc684d0994bd01ff78fb97a689d8512818f336c9b7b.
Windows native and Beast tests passed; 73 standalone Lua tests passed, including
GLOBAL handler load/player readiness. No game was launched; in-game proof remains
outstanding. Existing unrelated foundation/provenance failures are not waived by
these focused results. Temp evidence: dragon-windows-build.txt and WSL
/tmp/dragon-global-lua.txt.


## Approved physical diary exception

See PROTOCOL.md, Physical NPC diary books. Only authenticated completed diary snapshots may
create or update their fixed mundane book record. No general record API is added.

## Local audio, combat, and timeout controls

Reference behavior is CHIM unstable `76194ad1d0be2c971ebf02a0ca3c4d6266479acd`
and HerikaServer unstable `1d9a3d8ad1157e3fd429f85e3b992efc234dcfea`.
These references remain read-only; OpenMW playback retains its own engine implementation.

The PLAYER script owns saved sound preferences. GLOBAL passes bounded numeric/boolean playback
settings and a 15–300 second connection timeout to the native bridge; the default timeout is 30
seconds. No settings path accepts endpoints, credentials, files, or executable commands.
Playback settings apply only to verified LORKHAN speech, leaving vanilla audio ownership intact.
Pause-on-game-pause defaults off to preserve speech in paused dialogue/book menus.

Combat dialogue is a local master permission, separate from the existing combat-entry interruption
switch. Combat barks require that permission and support local Use Profile/On/Off scheduling.
The server also enforces the effective NPC/profile bark cooldown across the installation, using
server receipt time rather than the client's game/request clock. Explicit player conversation is
not subject to the automatic bark cooldown. Microphone capture is not a side effect of this gate.

Verification (2026-09-16): Windows Release OpenMW build, native bridge tests, Beast loopback
transport tests, 97 Lua tests, 10 patch-tool tests, protocol validation, and provenance validation
passed. Server unit suite (1,474 checks) and disposable-database integration tests passed; deployed
server health returned HTTP 200. Local engine and six runtime Lua/localization files were copied
with matching SHA-256 hashes. No game was launched; audible behavior remains unverified in-game.
The broad foundation suite retains a pre-existing typed-player-TTS source-string assertion failure.
OpenMW audio modes adapt direction and distance curves; Skyrim-specific occlusion DSP is not ported.

### Conversation interruption

`cancelTurn(turnId)` reuses `lorkhan.interrupt.v1` for the most recently submitted
conversation, cancelling its native submission and active event poll without changing
the session, generation, or microphone capture. Lua stops/reports queued playback and
fences late results by the replaced turn identity. Lifecycle cancellation stays separate.

### Player speech in vanilla dialogue menus

The dialogue window emits `LorkhanDialogueChoice` with the clicked topic or answer text
before executing the vanilla response. Lua reuses the player TTS route; the server's
player connector remains the authority for whether player speech is enabled. NPC
sentences may prepare concurrently but cannot play until that player line finishes
or fails. A new choice or closing dialogue cancels both menu speech lanes. The
frame callback advances playback while dialogue pauses simulation. No save data,
dialogue results, or server settings are changed by the click hook.

### Chat input focus

The patched Lua TextEdit accepts opt-in `autoFocus`. It focuses the editable widget
after attachment on creation or a false-to-true transition, with the caret at the
end. Ordinary redraws preserve existing focus without stealing it from another
control. Only the main Text Chat and Interact input opts in; other editors retain
their existing behavior. Closing and reopening the overlay creates a fresh editor.
