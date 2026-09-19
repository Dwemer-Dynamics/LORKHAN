# Working with LORKHAN

## Identify the installation

LORKHAN is a side-by-side OpenMW build plus a Lua mod. It is not a Skyrim SKSE DLL.
The Lua-only package still requires the matching LORKHAN engine and native bridge.
Use the installed build/source manifest and companion server revision when available;
do not assume the latest main branch matches an older player's package.

The [client repository](https://github.com/RANGROO/LORKHAN) owns the engine bridge and
Lua gameplay. [LorkhanServer](https://github.com/RANGROO/LorkhanServer) owns providers,
prompts, profiles, memories and durable jobs. No provider API key belongs in Lua.

## How a turn works

Player Lua collects input. Global Lua reads active-world context and submits a typed
request through openmw.lorkhan. A bounded native transport worker talks to the paired
loopback server. The server validates and persists events, assembles prompts and calls
LLM/speech providers. Ordered replies return to Lua for dialogue and actor-local actions.
The client reports terminal playback/action results; accepted HTTP does not prove an
actor performed an action. Session/generation changes invalidate stale work.

Source locations, relative to a client checkout:

| Task | Start here |
| --- | --- |
| Input, settings, targeting | lorkhan/files/scripts/LORKHAN/player.lua, player_input.lua, targeting.lua, settings.lua |
| Context and turn coordination | lorkhan/files/scripts/LORKHAN/global.lua, context.lua, orchestrator.lua |
| Actions and actor execution | lorkhan/files/scripts/LORKHAN/actions.lua, actor_executor.lua, actor.lua |
| Speech ordering | lorkhan/files/scripts/LORKHAN/response_queue.lua |
| Native transport and validation | components/lorkhan/ |
| Actual engine patch | openmw-patches/patch-spec.json, patches/, overlay/ |
| Wire contracts | lorkhan/schemas/v1, lorkhan/fixtures/v1 |
| Installation assembly | scripts/deploy/full-local.ps1 |

## Diagnose before changing code

1. Record the failing action, time, client/server revisions and selected OpenMW profile.
2. Inspect the launcher environment: LORKHAN_CLIENT_CONFIG selects the private client
   file. The repository example is config/client.example.conf; generated installs use
   Config/lorkhan-client.conf. Redact pairing_key. Do not replace this file with defaults.
3. Correlate openmw.log from the selected OpenMW user/profile location with server logs
   in /var/log/lorkhanserver and Apache's lorkhanserver-error.log. Find the active path
   from the launch/profile configuration rather than assuming another game's log folder.
4. For connection failures, compare the configured base_url and pairing state. The usual
   Windows launcher route is port 7514; direct WSL Apache uses 8090. Neither is a public
   service endpoint. Keep loopback/authentication boundaries intact.
5. For missing speech or actions, follow request, turn, session and generation IDs through
   server events and terminal client results before assigning cause.

Keep saves, game archives, voice data, credentials and private logs out of patches.
Use [building.md](building.md) for isolated validation; packaging is not game proof.

## Custom mods and plugins

Ordinary OpenMW content mods should have their own data folder and content entry. Preserve
load order and the player's existing profile; do not overwrite LORKHAN.omwscripts to
install an unrelated mod. The installed profile manager can enable separate mod folders.

For custom LORKHAN behavior, begin with the maintained
[Lua architecture](https://github.com/RANGROO/LORKHAN/blob/main/docs/LUA-MOD-ARCHITECTURE.md)
and [Lua source examples](https://github.com/RANGROO/LORKHAN/tree/main/lorkhan/files/scripts/LORKHAN).
These are implementation examples, not a stable third-party extension SDK. Keep player
input/UI in PLAYER scripts, authoritative context in GLOBAL scripts and self-only actor
mutation in CUSTOM scripts. Use the existing typed action registry and terminal results.

Native additions must follow the
[engine boundary](https://github.com/RANGROO/LORKHAN/blob/main/docs/ENGINE-INTEGRATION-PLAN.md)
and [patch tooling](https://github.com/RANGROO/LORKHAN/tree/main/openmw-patches).
A new network action may require matching server policy, schemas, fixtures and both-side
validation; a client-only script cannot grant model authority. For custom providers or
server behavior, follow the companion server's AGENTS.md. Its feature directories do not
imply support for HerikaServer ext plugins. Test against copied profiles/saves after the
native/Lua/contract checks, and retain vanilla dialogue and cancellation behavior.
