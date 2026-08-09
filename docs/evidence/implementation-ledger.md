# ALMSIVI row-level implementation ledger

Recorded: 2026-07-19. `AUTOMATED` is local no-game automation in the current dirty worktree, not clean-commit durable proof. `PLANNED` is incomplete internal work. `EXTERNAL-DEFERRED` needs unavailable OS/game/CI or finalized predecessor evidence. `EXCLUDED` is a closed decision.

| Matrix section | Row | State | Current evidence / deferral |
| --- | --- | --- | --- |
| Foundation and flow | Lifecycle/init/health | AUTOMATED | Independently authored Beast HTTP/1.1 transport serializes health/session requests, validates typed responses, and passes literal-loopback live-wire tests; OpenMW binding remains separate. |
| Foundation and flow | Local server discovery | PLANNED | Literal-loopback URL enforcement and fixed-base transport are automated, but profile discovery/configuration remains unwired. |
| Foundation and flow | Version/capability negotiation | AUTOMATED | Session init serializes pinned runtime/capabilities and strictly parses negotiated capabilities/config revision in no-game live-wire tests. |
| Foundation and flow | Typed events and correlation | AUTOMATED | Local native/Lua/schema/mock and Beast live-wire tests cover typed events plus session/request/turn/generation correlation. |
| Foundation and flow | Cancellation/halt/recovery | AUTOMATED | Bridge cancellation/halt and per-stage deadline tests pass with request-scoped executor-posted socket cancellation; late cancellation for request A is ignored after A and cannot interrupt request B. Restart during an in-flight HTTP request and production recovery policy remain future work. |
| Foundation and flow | Streaming response experience | PLANNED | Required implementation or no-game proof remains incomplete. |
| Foundation and flow | TTS media download/cache | AUTOMATED | Dirty-worktree no-game Beast tests prove bearer-authenticated plaintext fixed opaque GET, status/typed-error/redirect handling, exact Content-Length/MIME/SHA-256/byte checks, symlink rejection, existing-entry hash validation, corrupt-entry atomic replacement, and temporary cleanup; 512 MiB LRU quota/eviction and stronger no-follow/reparse handling remain incomplete, and no in-game playback is claimed. |
| Foundation and flow | Native actor speech/lips | EXTERNAL-DEFERRED | Exact platform/game/predecessor environment evidence is unavailable and not inferred. |
| Foundation and flow | Installation diagnostics | PLANNED | Required implementation or no-game proof remains incomplete. |
| Input, dialogue, and presentation | Targeted conversation | PLANNED | Required implementation or no-game proof remains incomplete. |
| Input, dialogue, and presentation | Group conversation | PLANNED | Required implementation or no-game proof remains incomplete. |
| Input, dialogue, and presentation | Typed player input | PLANNED | Required implementation or no-game proof remains incomplete. |
| Input, dialogue, and presentation | Push-to-talk/STT | AUTOMATED | Strict bounded raw-WAV upload metadata, Beast binary transport, acceptance, transcript/failure events and Lua mappings pass no-game tests; microphone capture and in-game use remain external. |
| Input, dialogue, and presentation | Open microphone | PLANNED | Required implementation or no-game proof remains incomplete. |
| Input, dialogue, and presentation | Subtitles/transcript | PLANNED | Required implementation or no-game proof remains incomplete. |
| Input, dialogue, and presentation | Interrupt/skip/hard halt | PLANNED | Typed interruption serialization/acknowledgement and transport cancellation are automated no-game; OpenMW input/presentation binding and in-game proof remain incomplete. |
| Input, dialogue, and presentation | Automatic greeting, boredom, and combat barks | EXCLUDED | Closed by the feature matrix; disabled presentation landmarks may remain, but no runtime scheduler or automatic model-triggering is shipped. |
| Input, dialogue, and presentation | Playback-gated rechat | AUTOMATED | Bounded continuation is gated by completed playback and retains target/session/generation fencing; no in-game proof is claimed. |
| Input, dialogue, and presentation | Vanilla dialogue context | PLANNED | Required implementation or no-game proof remains incomplete. |
| Input, dialogue, and presentation | Skyrim/Fallout HUD widgets | PLANNED | Required implementation or no-game proof remains incomplete. |
| Game and character context | Player stats/identity | PLANNED | Required implementation or no-game proof remains incomplete. |
| Game and character context | Target and nearby actors | PLANNED | Required implementation or no-game proof remains incomplete. |
| Game and character context | Cell/region/time/weather | PLANNED | Required implementation or no-game proof remains incomplete. |
| Game and character context | Factions/disposition/reputation | PLANNED | Required implementation or no-game proof remains incomplete. |
| Game and character context | Inventory/equipment/gold | PLANNED | Required implementation or no-game proof remains incomplete. |
| Game and character context | Spells/active effects | PLANNED | Required implementation or no-game proof remains incomplete. |
| Game and character context | Journal/quests/topics | PLANNED | Required implementation or no-game proof remains incomplete. |
| Game and character context | Nearby items/doors/containers | PLANNED | Required implementation or no-game proof remains incomplete. |
| Game and character context | Loaded mods/load order | PLANNED | Required implementation or no-game proof remains incomplete. |
| Game and character context | Physical VR state | EXCLUDED | Closed by feature matrix; no implementation planned. |
| Game and character context | Fallout/Skyrim-specific systems | EXCLUDED | Closed by feature matrix; no implementation planned. |
| Intelligence and server product | Character profiles/prompts | PLANNED | Required implementation or no-game proof remains incomplete. |
| Intelligence and server product | Short/middle/long memory | PLANNED | Required implementation or no-game proof remains incomplete. |
| Intelligence and server product | Relationships | PLANNED | Required implementation or no-game proof remains incomplete. |
| Intelligence and server product | Dynamic profiles | PLANNED | Required implementation or no-game proof remains incomplete. |
| Intelligence and server product | World knowledge | PLANNED | Required implementation or no-game proof remains incomplete. |
| Intelligence and server product | Narrator and diary | PLANNED | Required implementation or no-game proof remains incomplete. |
| Intelligence and server product | Playthrough export/restore | PLANNED | Required implementation or no-game proof remains incomplete. |
| Intelligence and server product | LLM/STT/TTS providers | AUTOMATED | Deterministic mock-only LLM/STT/TTS contract boundaries are synchronized and tested locally; no live provider implementation or evidence is claimed. |
| Intelligence and server product | Prompt/action editor | PLANNED | Required implementation or no-game proof remains incomplete. |
| Intelligence and server product | Request/event logs | PLANNED | Required implementation or no-game proof remains incomplete. |
| Intelligence and server product | Workers/backups/health | PLANNED | Required implementation or no-game proof remains incomplete. |
| Actions | Inspect/report | AUTOMATED | Strict Tier-0 intent union, capability gate, empty-parameter validation and read-only Lua report result foundation pass no-game tests; actual engine snapshot execution remains external. |
| Actions | Follow/escort/travel/wander/pursue | PLANNED | Required implementation or no-game proof remains incomplete. |
| Actions | Start/stop combat | PLANNED | Required implementation or no-game proof remains incomplete. |
| Actions | Face/look/animation/speech | PLANNED | Required implementation or no-game proof remains incomplete. |
| Actions | Equip/use/consume | PLANNED | Required implementation or no-game proof remains incomplete. |
| Actions | Give/take item or gold | PLANNED | Required implementation or no-game proof remains incomplete. |
| Actions | Lock/unlock | PLANNED | Required implementation or no-game proof remains incomplete. |
| Actions | Trade/menu opening | PLANNED | Required implementation or no-game proof remains incomplete. |
| Actions | Teleport/spawn/delete/record creation | EXCLUDED | Closed by feature matrix; no implementation planned. |
| Actions | Stat/faction/reputation/quest mutation | EXCLUDED | Closed by feature matrix; no implementation planned. |
| Actions | Arbitrary console/Lua/MWScript/files/network | EXCLUDED | Closed by feature matrix; no implementation planned. |
| Packaging and compatibility | Windows x64 Debug/Release | EXTERNAL-DEFERRED | Exact platform/game/predecessor environment evidence is unavailable and not inferred. |
| Packaging and compatibility | Linux x64/macOS arm64 | EXTERNAL-DEFERRED | Exact platform/game/predecessor environment evidence is unavailable and not inferred. |
| Packaging and compatibility | Upstream control | EXTERNAL-DEFERRED | Exact platform/game/predecessor environment evidence is unavailable and not inferred. |
| Packaging and compatibility | Patch narrowness | AUTOMATED | Deterministic exact-pin patch generation/apply/verify/audit passes for five paths. Static inspection proves registration in GLOBAL, PLAYER, and CUSTOM-gated local only, with no MENU/LOAD registration. Integrated control/product builds remain externally blocked and unclaimed. |
| Packaging and compatibility | Runtime archive | EXTERNAL-DEFERRED | Exact platform/game/predecessor environment evidence is unavailable and not inferred. |
| Packaging and compatibility | Corresponding source | EXTERNAL-DEFERRED | Exact platform/game/predecessor environment evidence is unavailable and not inferred. |
| Packaging and compatibility | Minimal GOTY | EXTERNAL-DEFERRED | Exact platform/game/predecessor environment evidence is unavailable and not inferred. |
| Packaging and compatibility | I Heart Vanilla | EXTERNAL-DEFERRED | Exact platform/game/predecessor environment evidence is unavailable and not inferred. |
| Packaging and compatibility | Expanded Vanilla | EXTERNAL-DEFERRED | Exact platform/game/predecessor environment evidence is unavailable and not inferred. |
| Packaging and compatibility | Total Overhaul | EXTERNAL-DEFERRED | Exact platform/game/predecessor environment evidence is unavailable and not inferred. |
| Packaging and compatibility | Tamriel Rebuilt/Project Tamriel | EXTERNAL-DEFERRED | Exact platform/game/predecessor environment evidence is unavailable and not inferred. |
| Packaging and compatibility | Controller/Steam Deck | EXTERNAL-DEFERRED | Exact platform/game/predecessor environment evidence is unavailable and not inferred. |
| Packaging and compatibility | Voice mod coexistence | EXTERNAL-DEFERRED | Exact platform/game/predecessor environment evidence is unavailable and not inferred. |
