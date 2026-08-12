# ALMSIVI Lua mod architecture

## Package layout

```text
files/
  ALMSIVI.omwscripts
  scripts/ALMSIVI/
    global.lua
    player.lua
    actor.lua
    protocol.lua
    identity.lua
    context.lua
    conversation.lua
    actions.lua
    storage.lua
    ui/
    adapters/
    tests/
```

The manifest starts `global.lua` as GLOBAL, `player.lua` as PLAYER, and marks `actor.lua` CUSTOM.
It does not auto-attach a large script to every NPC/creature. GLOBAL attaches actor.lua only when an
active actor joins an ALMSIVI audience or must execute an action, and later stops it when safe.

## Script ownership

### GLOBAL

- owns playthrough/session/generation and native bridge polling;
- maintains active-object identity registry from `onPlayerAdded`, `onObjectActive` and
  `onActorActive`;
- freezes bounded world/target/audience snapshots;
- maps server response/action intents to actor events;
- captures `DialogueResponse` as context without blocking vanilla dialogue;
- owns turn deduplication, server ordering, action policy, terminal results and halt;
- persists versioned orchestration state via `onSave`/`onLoad`.

### PLAYER

- registers configurable OpenMW input actions for overlay, talk, add/remove audience, push-to-talk,
  interrupt and halt;
- resolves crosshair/camera ray target through supported input/camera/nearby APIs and asks GLOBAL to
  validate it;
- renders HUD status, target/audience chips, transcript, text input, subtitles, microphone state,
  action consent and diagnostics link;
- owns no transport and accepts no server path/command.

### CUSTOM actor

- verifies every command's actor identity, generation, request/turn/action ID and expiry;
- owns speech/stop, facing/look/animation, AI package operations and self-only inventory/equipment
  operations exposed by OpenMW APIs/events;
- reports exactly one terminal result to GLOBAL;
- remembers the pre-ALMSIVI AI state needed for bounded restoration but never serializes pointers.

## Conversation flow

1. Player invokes the dedicated ALMSIVI action while aiming at an active NPC/creature, or selects
   from a bounded nearby list. Essential hostile/dead/unavailable policy is explicit.
2. PLAYER sends a local/global event with an engine object; GLOBAL resolves stable identity and adds
   it to the audience. Display name alone is not accepted.
3. UI captures typed text or starts native STT. Empty/oversized/duplicate input is rejected.
4. GLOBAL freezes player, speaker, audience, cell/world and context deltas under fixed budgets.
5. `submitTurn` returns immediately. UI shows queued/streaming state.
6. GLOBAL polls validated events and routes text/speech to the current actor script only.
7. PLAYER renders subtitles/transcript; actor uses opaque media playback. Queue policy permits one
   speaking actor by default and deliberate interruption.
8. Completion/failure is persisted server-side; Lua stores only recent UI/session recovery state.

Group dialogue carries explicit speaker, addressee and audience identities. The server may choose the
next speaker, but Lua confirms the actor is still active/valid before playback. A missing actor turns
into a delivery result, never speech from a substitute.

## Targeting and activation

- Primary: center camera/crosshair ray filtered to actor types and maximum distance.
- Controller: same semantic OpenMW action, not hardcoded device scancodes.
- Secondary: small nearby active-actor picker sorted by distance with identity disambiguation.
- Automatic greetings, boredom, combat barks, Background Life, ITT, and timer-driven model triggers
  are excluded and have no input action or runtime scheduler.
- Vanilla `Activate` and dialogue continue unchanged. ALMSIVI does not suppress or replace them.

## Context budgets

Full snapshot on session start/target change; compact deltas afterward. Default limits: 12 audience/
nearby actors, 48 inventory rows per relevant owner, 32 nearby objects, 32 active effects, 32 journal
entries, 256 loaded content files, 128 KiB uncompressed context, and a 2 ms average/5 ms p99 Lua
collection budget on the compatibility machine. Overflow emits counts/truncation flags.

Domains:

- player identity, race/class/birthsign/level, attributes/skills, dynamic stats, reputation/bounty;
- cell/region/worldspace, position/heading, game day/time/time scale, weather where exposed;
- target/audience records, state, distance, combat/death, AI package summary, disposition/factions;
- equipment/inventory/barter gold, spells/effects, nearby actors/items/doors/containers;
- journal/quest/topic/dialogue response context;
- ordered content files, content fingerprint, OpenMW/API/build/profile capabilities;
- recent conversation/action results and server-issued memory/profile summaries.

Unavailable engine facts are omitted with capability flags. No console scraping or guessed values.

## Action catalog and tiers

### Tier 0: always safe/read-only

Inspect self/target/player, report inventory/equipment/stats/effects/factions, locate nearby named
objects, report active AI package, and answer current-cell/journal/content questions from snapshots.

### Tier 1: user-enabled reversible actor behavior

Follow, escort, travel to bounded position, wander, pursue, start/stop combat when policy permits,
stop/remove only ALMSIVI-owned AI packages, face/look, play allowlisted animation, speak/stop speech,
equip/use/consume an item already owned by that actor.

### Tier 2: user-enabled mutations with confirmation policy

Give/take exact item or gold deltas between resolved inventories, lock/unlock when ownership and
policy permit, and other explicit API-129 mutations after individual acceptance tests. Server and
client settings must both enable the action.

Excluded: arbitrary console/Lua/MWScript, teleport outside bounded/tested travel semantics, record or
quest fabrication, stat/faction/reputation/disposition rewriting, spawn/delete, unrestricted combat,
file/network operations, or any target chosen only by text.

Each action has schema, tier, actor/target types, parameter bounds, preconditions, timeout,
cancellation behavior, ownership/restoration policy and exact terminal result. Result-aware follow-up
is capped at one automatic turn per action and four actions per originating turn.

## Persistence and migration

Lua `onSave` returns `{schemaVersion, profileId, playthroughId, generationSeed, preferences,
conversationUi, actorStateHints}` with serializable primitives only. Loading validates version,
migrates supported old schemas, increments generation, clears in-flight work and re-resolves actors.
Unknown future schemas disable ALMSIVI for that save with a clear message; they are never overwritten.

Server state is authoritative for event history, profiles, relationships and memory. Save/playthrough
binding changes require explicit user confirmation in the management UI to prevent cross-character
memory leakage.

## Lua tests

Use extracted pure modules and an OpenMW API fake for identity, schema mapping, budgets/truncation,
target/audience state, input actions, UI view models, save migration, dedupe/order, generation/halt,
media queue, action validation/ownership/results and unavailable capabilities. In-engine tests prove
actual handler/event/context permissions and actor-script attachment lifecycle.
