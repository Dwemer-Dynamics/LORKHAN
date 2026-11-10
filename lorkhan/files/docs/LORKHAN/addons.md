# LORKHAN addon API, version 1

`LORKHAN_Addons` is the stable OpenMW Lua interface for third-party addons. It is exposed by
LORKHAN's GLOBAL script (`scripts/LORKHAN/global.lua`) with `version = 1`. The wire contract is
`lorkhan.plugin.*.v1` (see `plugin_contract.lua` and the protocol docs). Lua API revision 129 is
the minimum.

## Install

1. Install the server package first. The server owns the installed manifest, its SHA-256 and the
   enable policy. The client never installs, downloads or runs server-provided code.
2. Put the addon's client data folder after LORKHAN in the OpenMW profile. Its `.omwscripts` file
   must load after `LORKHAN.omwscripts`, so `interfaces.LORKHAN_Addons` exists when the addon's
   GLOBAL script runs.
3. The addon declares one GLOBAL script, plus a CUSTOM script for each SELF handler. LORKHAN
   attaches the CUSTOM script to the actor itself. Do not attach it in the profile.

The server only sends a plugin action when the session negotiated `plugin.contract.v1` and the
addon is active on both sides.

## GLOBAL interface

```lua
local addons = require('openmw.interfaces').LORKHAN_Addons
local handle, reason = addons.register({
    manifest = manifest,              -- the lorkhan.plugin.manifest.v1 table
    manifest_sha256 = '<64 hex>',     -- SHA-256 of the packaged manifest bytes
    handlers = {                      -- exactly one per declared action
        some_action = {scope = 'global', run = function(ctx) ... end, cancel = function(ctx, reason) end},
        other_action = {scope = 'self', script = 'scripts/<addon>/actor.lua'},
    },
    actor_scopes = {some_action = {actorIdentity, ...}},  -- optional, <= 12 exact actors per action
})
```

| Call | Result |
| --- | --- |
| `register(spec)` | Returns an opaque read-only handle, or `nil, reason`. |
| `unregister(handle)` | Cancels the addon's tracked actions (`cancelled/plugin_withdrawn`), withdraws it locally, and sends `operation = "unregister"` if it was registered. |
| `status(handle)` | `{api_version, plugin_id, version, state, reason, contract}`. `state` is `pending`, `active`, `disabled`, `rejected` or `unregistered`. |
| `emit(handle, event, fields)` | Submits one declared `lorkhan.plugin.event.v1`. Returns the request ID, or `nil, reason`. |
| `completeAction(handle, actionId, result)` | Finishes an asynchronous GLOBAL action. `result` is `{status, reason_code, observed}`. |
| `refresh(handle)` | Offers a `disabled` or `rejected` addon to the server again, for example after its package finished installing. Returns how many addons were re-queued (`0` when active, in flight or out of refreshes), or `nil, reason`. |

An addon with no declared actions (event- or prompt-slot-only) may omit `handlers`.

`refresh` is explicit. LORKHAN never polls for package or enable changes. Each addon can refresh at
most 4 times per session generation. The global event `LORKHAN_ADDONS_REFRESH` refreshes every addon
under the same limit. It is the hook for package-sync completion and the enable UI, but nothing sends
it yet. The server's answer is still authoritative.

`register` rejects these specs:

- An invalid manifest, ID, version, dependency list or hash format.
- A plugin ID that is already registered (`plugin_already_registered`).
- More than 16 addons.
- A missing handler (`addon_handler_missing`) or an extra or invalid handler.
- A SELF script outside `scripts/`, a path with `..`, a path under `scripts/LORKHAN/`, or a script
  that is missing from the VFS.

Only the handle that `register` returned can unregister, emit or complete for that plugin.

`emit` rejects events that are undeclared, inactive or invalid. It also enforces the declared
`max_per_minute` locally and allows at most 8 outstanding submissions.

## Runtime rules

- **Registration per generation.** LORKHAN registers each addon again for every new session or
  generation. It registers an addon only when that addon's dependencies are registered locally.
  If the server reports `disabled`, `rejected` or `unregistered`, the addon is withdrawn locally,
  along with any dependants. Receipts are collected only while a submission is outstanding.
- **Validation before handlers.** GLOBAL validates each `plugin.action.intent` before any handler
  runs. It checks the session and generation, that the plugin and version are active, the
  registered action, the tier, confirmation and cancellable policy, the exact actor scope, that
  the actor and target are loaded, the typed parameters, and the expiry. A stale intent is
  dropped. Any other failure gets one `rejected` result.
- **Gating.** Plugin actions are refused when LORKHAN is disabled, hard-halted or AI is off. Halt,
  stop-dialogue, hard-halt, load, new game, a generation change, `unregister` and server withdrawal
  stop tracking every action. Halt-actions and AI-off are soft: they spare running
  `cancellable = false` work, which still owes its completion or deadline.
- **Cancelled versus timed out. Neither status means a rollback.**
  - `cancelled/<reason>` is used before a handler runs (validated or awaiting confirmation), and for
    running `cancellable = true` work. In the running case the addon's `cancel` callback (GLOBAL) or
    `LORKHAN_ADDON_SELF_CANCEL` (SELF) asks it to stop. Effects that were already applied stay.
  - `timed_out/<reason>` means LORKHAN stopped waiting and does not know the outcome. It is used when
    the deadline passes, and when a running `cancellable = false` action stops being tracked, for
    example `timed_out/plugin_withdrawn`.
  - Once a `cancellable = false` handler has started, LORKHAN never calls its cancel callback or sends
    it a cancel event. It may still finish its work, and its late completion returns
    `action_not_pending`.
- **Confirmation.** Actions declared with `confirmation = "required"` (all tier 2 actions) reuse
  the existing confirmation prompt before any handler runs. If the player declines, the result is
  `rejected/user_declined` and nothing runs. Declining never creates a follow-up turn. If another
  confirmation is already open, the result is `rejected/confirmation_busy`.
- **Handlers.** A GLOBAL handler receives
  `ctx = {api_version, action_id, plugin_id, action, actor, target, parameters, expires_at, cancellable}`.
  Return `{status, reason_code, observed}` to finish synchronously, or return nothing and call
  `completeAction` later. Accepted does not mean complete.
- **SELF handlers.** LORKHAN attaches the declared CUSTOM script to the exact actor and sends it a
  per-dispatch nonce. Build that script with
  `require('scripts.LORKHAN.addon_self').script(pluginId, handlers, {cancel = fn})`. Each
  handler receives `(ctx, api)`. It returns a result or calls `api.complete(ctx.action_id, result)`,
  and it may act only on `openmw.self`. If the actor unloads, the result is `failed/actor_unloaded`.
  GLOBAL accepts a SELF result only when the action ID, nonce, generation and exact actor identity
  all match the dispatch. The helper first snapshots its actual `openmw.self` identity and runs no
  handler for a malformed dispatch or one addressed to another actor; GLOBAL's deadline ends that
  action. It remembers the last 128 generation and action ID pairs, so a redelivered dispatch never
  runs the handler twice, even after it finished. Any script attached to
  the same actor can see that actor's events, so give the actor only scripts you trust.
- **One terminal result.** Every tracked intent gets exactly one `lorkhan.action-result.v1`:
  - success or the handler's failure;
  - `failed/addon_handler_error` when a handler throws;
  - `failed/addon_result_invalid` for a malformed result;
  - `timed_out/action_timeout` or `timed_out/confirmation_timeout`, at the earlier of
    `timeout_seconds` and the server expiry;
  - `cancelled/<reason>`;
  - `failed/actor_unloaded`.

  Later completions return `action_not_pending`.
- **Result delivery.** Each terminal result is held once, with its `message_id`, in a bounded
  outbox of 32 results.
  - In the same generation, a queue or transport failure resends that exact result, never re-running
    the handler. There are at most 6 submissions, with 2 to 10 second backoff, within 120 seconds.
  - Native `actionReceiptStatus` tracks delivery. An accepted receipt ends the entry; a pending one
    is never resent.
  - A new generation discards older entries, because native rejects them as stale.
  - An abandoned result is logged and is not retried.
- **Result bounds.** `status` is `succeeded`, `failed` or `rejected`. `reason_code` is a token of
  up to 128 characters. `observed` is a flat record of at most 16 scalar fields, with strings up
  to 256 characters.

## Not supported in version 1 (CHIM ext-plugin features with no LORKHAN equivalent)

- Server-side PHP hooks or code: pre-request, pre-prompt, post-request or context builders.
  Packages are declarative.
- Free-text or function-calling parameters. Only integer, number, boolean, enum and actor
  parameters exist.
- Prompt-slot content. Slots are declared and registered, but v1 has no Lua call to supply text,
  and the server does not render them yet.
- Events that start an NPC turn or a custom request type. Events are recorded only.
- Follow-up or rechat turns driven by plugin action results.
- Tier 3, world, cheat or player-executor actions. Executors are NPCs and creatures only.
- Per-addon settings pages in LORKHAN, and custom LLM, TTS or STT connectors.
- Defining actions at runtime outside the packaged manifest, and addon database tables.
- Console commands, MWScript, record mutation, HTTP, filesystem, shell or dynamic code from
  the server.

A minimal runnable example is in `examples/plugin-parity` in the client source repository.
