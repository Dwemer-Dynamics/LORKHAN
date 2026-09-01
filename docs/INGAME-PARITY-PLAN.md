# LORKHAN in-game CHIM and Dialectic parity plan

This plan translates user-visible behavior from the locked reference pins into OpenMW-native
outcomes. It does not copy extender, Papyrus, GECK, UI asset, or game-specific implementation code.

Reference behavior:

- `Dwemer-Dynamics/CHIM@77c73ffb6bb32c226340bbda93b3aac5a7ad49f8`
- `Dwemer-Dynamics/Dialectic@eddbdc77a8347128b5cf5bcd68df0c2404fbf074`
- OpenMW `0.51.0@f4bec41444214a7903bebd178389ca22ca13f646`, Lua API 129

Proof states in this file are intentionally narrow. `AUTOMATED` means the current worktree has a
repeatable no-game check. It never means the behavior has been exercised in Morrowind.

## Current in-game control parity

| User outcome | Reference behavior | LORKHAN implementation | Current proof |
| --- | --- | --- | --- |
| Typed conversation | CHIM Text Chat; Dialectic Talk to NPC | Semantic OpenMW trigger, camera target resolution, TextEdit, Enter send, successful-submit close and Escape close | IN-GAME PROVEN for Fargoth on 2026-08-02; enriched-context regression still requires in-game proof |
| Voice conversation | CHIM Voice Chat; Dialectic Toggle Voice | Semantic hold action, bounded native capture/STT, visible recording state | AUTOMATED transport; microphone/in-game proof required |
| Open microphone | Both products expose opt-in VAD, sensitivity/end-delay and separate mute controls | Explicit toggle, target requirement, bounded native sensitivity/end-delay, pause/resume mute, VAD re-arm, visible state | AUTOMATED transport/settings; microphone/in-game proof required |
| Stop controls | Stop dialogue, halt actions, recoverable full stop | Separate semantic triggers and Master Menu commands | AUTOMATED; in-game proof required |
| Master/actions/history/diagnostics | CHIM Prisma master, actions, history and logs views | OpenMW-native panels, safe status data, recent session transcript | AUTOMATED; layout/in-game proof required |
| Mode selection | CHIM mode controls; Dialectic mode selector | Explicit Standard, Whisper, Close and Shout selector plus semantic cycle binding | AUTOMATED audience/prompt routing; in-game proof required |
| Player mood and one-turn delivery | CHIM player mood selector and typed delivery shortcuts | Saved None/built-in/custom mood for typed or spoken turns; typed `|`, `||`, and `!!` apply Whisper, Close, or Shout to one turn without changing the selected mode | AUTOMATED Lua/protocol/prompt routing; layout/in-game proof required |
| Rebindable inputs | MCM/INI hotkeys | OpenMW Options > Scripts > LORKHAN semantic bindings | AUTOMATED; controller proof required |

Conflict-free defaults remain F6 for typed talk, F7 for recoverable stop, and F8 for Actor Actions.
Other semantic actions are deliberately unbound until the player assigns them in OpenMW settings.

### Pinned reference outcome audit

| Reference outcome | LORKHAN decision | State |
| --- | --- | --- |
| Text/voice chat, halt, manual activation, actions and master menu | OpenMW-native semantic bindings and panels | TEXT CHAT AND TARGETING IN-GAME PROVEN; remaining controls require in-game proof |
| Explicit mode selector | Standard, Whisper, Close and Shout now alter both prompt context and bounded audience routing | IMPLEMENTED; in-game proof required |
| Player mood and one-turn delivery | Optional bounded mood cues reach prompt/history while authored text stays unchanged; `|`, `||`, and `!!` are stripped before one-turn Whisper/Close/Shout routing | IMPLEMENTED; layout/in-game proof required |
| Open-mic mute, sensitivity and end delay | Separate mute binding plus bounded 100-5000 RMS and 500-5000 ms native VAD settings | IMPLEMENTED; microphone proof required |
| Status/history/log views | Compact HUD, session history and safe diagnostics; no raw secret/log browser | IMPLEMENTED; layout proof required |
| LLM model slots | Authenticated typed query/select routes expose revisioned server-owned slots; configured slots override only the model and never expose credentials/endpoints; management supports secret-free export/import/clone and blocks deletion while in use | IMPLEMENTED; in-game proof required |
| Per-profile LLM/TTS routing | CHIM-style NPC profile fields choose Standard, Fast, Powerful, Experimental and Fallback LLM slots plus a speech connector; optional deterministic per-turn randomization uses only configured general-purpose slots, an enabled fallback is frozen with the accepted turn and tried once after primary failure, explicit F9 model selection overrides profile LLM routing, and per-speaker TTS uses the profile voice, then the connector's male/female fallback selected from profile gender, then the connector default; TTS/STT connector forms expose driver-specific labelled controls during both creation and editing; TTS Studio imports bounded WAV/ZIP samples, explicitly syncs them to compatible PocketTTS/OmniVoice/Chatterbox/XTTS services, durably caches explicitly discovered provider voices for NPC profile selection, and can test or set a revisioned connector default | IMPLEMENTED; management/integration, real multipart provider-sync and real fallback-worker proof complete; in-game proof required |
| Player speech-style profile | Player Management can analyze up to 200 stored real player turns through the configured profile-generation provider and update only the current profile's speech-style field if its revision is unchanged; typed player messages can use the player profile's TTS connector and voice | IMPLEMENTED; autonomous player chat remains excluded |
| NPC profile management | CHIM-style search, favorites, edit locking, portraits and bulk operations | IMPLEMENTED with private portrait storage, default-on auto-locking, auditable revisions, bulk unlock/delete/binding switch and portable profile export; live management proof complete |
| Roleplay memory and relationship management | CHIM-style roleplay tabs create/edit/rebuild/delete scoped memories and create/edit/audit-delete relationships without exposing raw database access | IMPLEMENTED; browser-like CRUD and live layout proof complete |
| Server behavior settings | Global, Core Profile and NPC settings expose bounded playback-gated rechat inheritance; unsupported autonomy controls remain visible only as disabled status landmarks | RECHAT IMPLEMENTED; greetings, boredom, combat barks and timer autonomy EXCLUDED |
| Profile slot assignment and dynamic profile regeneration | Actor-specific profile binding preserves session memory/playthrough scope; PHP and the OpenMW master menu can queue a bounded, revision-safe LLM generation job for the profile explicitly bound to the current target; Character Management can queue up to 100 unlocked NPC profiles from one installation while excluding locked/player/narrator profiles; Narration management and the OpenMW master menu provide the same revision-safe operation with narrator-specific generation instructions | TARGET, INSTALLATION BATCH AND NARRATOR GENERATION IMPLEMENTED; a nearby-only in-game batch trigger remains pending; in-game proof required |
| Narrator routing | One opt-in installation narrator profile, deterministic leading `*narration*` separation, narrator/NPC/text-only modes, narrator-specific TTS context, ordered player-local playback and normal delivery receipts | IMPLEMENTED; disabled by default; in-game proof required |
| Installation configuration transfer | Server-generated, hash-verified backup/restore for profiles, prompts, model slots, speech presets, action policies, selections and profile preferences | IMPLEMENTED; same-installation restore only; secrets, portraits, voices and runtime roleplay data excluded |
| Nearby actors/activity, items and points of interest | Bounded identities, player/target state, explicit held items, actor-local AI activity, item ownership, door/container locks, keys/traps, cell, weather and journal; activity is reported only for managed actors because API 129 exposes AI packages only to the actor-local script | IMPLEMENTED; in-game prompt proof required |
| Quests and read books | The client sends the bounded Morrowind journal on every turn; vanilla world activation and inventory use observe opened books without replacing their normal behavior, deduplicate them locally, and attach a bounded recent-books list to subsequent turns | IMPLEMENTED; book observation requires in-game proof |
| Combat barks | Timer-driven hostile remarks are outside the bounded player-driven conversation scope | EXCLUDED; any inherited control remains visible and disabled |
| CHIM Browser, Soulgaze, AI Quest Manager and rumor tools | Skyrim/Prisma or server-product features, not core Morrowind conversation-control parity | OUT OF CURRENT IN-GAME CORE |
| Dialectic `OpenMenu` and `QuickCommand` bindings | Pinned declarations have no GameLoop consumer, so LORKHAN does not copy dead controls | INTENTIONALLY OMITTED |

### 2026-08-02 upstream parity refresh

- HerikaServer's new NPC return/teleport workflow remains a no-port. It issues Skyrim
  FormID/location commands, while LORKHAN intentionally excludes teleport/spawn/delete from the
  initial OpenMW action authority as destructive operations.
- HerikaServer's other new NPC-manager changes belong to Background Life, which remains excluded.
- CHIM's matching popup change only presents the same Skyrim return/teleport workflow and therefore
  has no independent OpenMW user outcome to port.
- DialecticServer's new "copy profile setting to all" control targets free profile metadata. LORKHAN
  preserves Global -> Core Profile -> NPC inheritance for bounded playback-gated rechat only. Greeting,
  boredom, combat-bark and timer-driven autonomy controls remain disabled and are not copied into
  runtime scheduling state.

## Activation, targeting, and groups

| Requirement | Current implementation | Current proof |
| --- | --- | --- |
| Preserve vanilla Activate/dialogue | LORKHAN uses separate semantic actions; vanilla NPC/creature activation only supplies a passive target hint and is never consumed | AUTOMATED |
| Aim and confirm a target | Live physics-only aimed-actor preview, input-time rendering-ray fallback, stable identity validation, visible committed target name and distance | IN-GAME PROVEN for Fargoth on 2026-08-02 |
| Nearby target fallback | Agent Manager lists the closest bounded active actors for target/group selection | AUTOMATED; layout/in-game proof required |
| Manual AI activation | Aim toggles one pinned actor; no aimed actor pins up to 12 nearby actors without unpinning existing agents | AUTOMATED |
| Automatic activation | 250 ms bounded active-cell scans; six new attachments per scan; 32-agent maximum; stale auto agents swept | AUTOMATED |
| Interior/exterior distances | 1200/2400 activation defaults and 500/1000 hearing defaults | AUTOMATED |
| Hostile/creature policy | Both opt-in; actor-local combat state removes disallowed hostile auto agents | AUTOMATED; in-game package proof required |
| Spatial group hearing | Managed actors inside the current cell-type hearing distance join the bounded audience | AUTOMATED |
| Explicit group conversation | Aim or nearby picker adds actors; reset returns to primary target; duplicates and oversize fail closed | AUTOMATED |
| Optional follower awareness | Follower Detection Util 2.x relationships enter bounded prompt context when its interface exists; absence disables only the adapter | AUTOMATED adapter; compatibility/in-game proof required |

## Rechat boundary

| Requirement | Current implementation | Current proof |
| --- | --- | --- |
| Playback-gated rechat | An enabled profile can continue only after the preceding response finishes, while retaining the current target/session/generation fence and bounded continuation depth | AUTOMATED logic; full runtime chain proof required |
| Live participant eligibility | After final playback, the global script requests an immediate actor-local API-129 state probe for the previous speaker and at most 12 candidates. Missing/late proof fails closed; busy, unconscious, inactive, or dead actors cannot respond. OpenMW sleep detection remains unavailable, so the server-only direct-address sleep rule is forward-compatible rather than claimed native proof. | AUTOMATED Lua/native source and server integration; in-game state transitions required |
| Cancellation safety | Halt, target/session/generation changes and newer accepted turns cancel or fence stale continuation work | AUTOMATED source checks; in-game state proof required |
| Automatic greeting | No scheduler or automatic model-triggering | EXCLUDED |
| Bored conversation | No quiet timer, actor rotation or automatic model-triggering | EXCLUDED |
| Combat barks | No entry timer, periodic timer or automatic model-triggering | EXCLUDED |

## Action parity

Currently implemented end to end:

- inspect/report;
- follow, same-cell aimed travel/escort, wait, bounded wander and stop LORKHAN-owned movement;
- asynchronous face-player/face-aimed-actor control with observed heading completion;
- start/stop combat with explicit secondary-target confirmation;
- allowlisted idle animation;
- equip, unequip and use an item already present in the actor inventory;
- one terminal action result, capability/policy/tier validation on both client and server, and halt.

Travel and escort destinations are captured from the player's center-camera rendering ray only when
the configured Targeted NPC Tools control confirms the second stage. They are bounded to 2048 units and the actor's current cell, carried as typed
coordinates through the server catalog, and rechecked actor-locally before API-129 starts the package.
Replacement and stop operations match the owned package's target/destination/distance instead of
removing unrelated packages of the same type.

The frozen action-catalog audit is complete. Sixteen strict action names are negotiated across the
client/server boundary. Exact inventory/currency transfer, lock mutation, trade/menu activation,
persistent pursuit/follower state, teleport, spawn/delete, quest/faction/stat mutation, and arbitrary
console/Lua/MWScript remain Not Applicable or excluded for the authority reasons recorded in
`docs/evidence/openmw-action-parity-audit.md`; they are not future implementation promises.

Remaining control/runtime work is manual proof only: exercise the current popup, model/profile binding,
enriched context, voice runtime, queue interruption, and enabled actions in the deployed pinned build.
Disabled greetings, boredom, combat-bark, ITT, Background Life, and timer-autonomy landmarks must remain
inert throughout that checklist.

### Pinned API-129 design gates

- **Face is asynchronous and actor-local.** CUSTOM actor scripts write `self.controls.yawChange` and
  read `self.rotation:getYaw()`. The enabled action uses shortest-angle math, a three-second timeout,
  target/cell/combat cancellation, explicit control release, and emits its terminal result only after
  the final heading is observed. Pitch/look-at is still gated because head/eye control is not exposed.
- **Exact give/take cannot remain actor-local.** API 129 exposes `split`, `moveInto`, and `remove` only
  on global `GameObject`s. The actor-local inventory view is suitable for validation and observation,
  not mutation. This needs an explicit two-owner protocol: CUSTOM actor validates its own stack and
  requests a narrowly typed global transfer; global resolves the exact object, rechecks both
  inventories and count, mutates once, and returns observed before/after counts. Record IDs alone are
  insufficient authority for a particular stack.
- **Pursue targets only the player.** OpenMW's native Pursue package rejects non-player targets. It is
  held until its user outcome is specified distinctly from persistent Follow and point-in-time Travel.

## Acceptance sequence

1. Keep Lua, native, protocol, PHP, PostgreSQL integration and client/server parity checks green.
2. Deploy the exact worktree into `C:\Modlists\LORKHAN` and `/var/www/html/LORKHANserver`; verify
   representative hashes, Apache, worker and health.
3. Run the post-goal minimal GOTY checklist: target Fargoth and one additional race/sex voice; send
   UTF-8 typed input; use push-to-talk and bounded open mic; add a two-NPC group; verify normal Morrowind
   subtitles and ordered TTS; exercise playback-gated rechat; execute inspect, inventory inspect,
   follow, stop, approach, wait, travel, escort, face, wander, combat start/stop, allowlisted animation,
   equip, unequip, and use; interrupt active speech/action; replace target/session; cross a cell; save/load;
   and observe idle frame rate/request rate. Confirm greetings, boredom, combat barks, ITT, Background
   Life, and timer autonomy never create a request.
4. Capture screenshots/logs and promote only individually observed rows to `IN-GAME PROVEN`.
5. Repeat the compatibility profiles in `COMPATIBILITY-PLAN.md`; do not infer them from minimal GOTY.
