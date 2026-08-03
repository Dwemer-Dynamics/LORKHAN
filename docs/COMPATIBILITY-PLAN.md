# OpenMW mod and platform compatibility plan

## Policy

ALMSIVI supports OpenMW-native mods and content order; it does not support MWSE-only behavior. A
profile is proven only against a recorded list/version/manifest and exact ALMSIVI package. Third-party
mods are never bundled. Compatibility fixes stay in ALMSIVI when general; list-specific adapters are
small, declared and tested without silently changing other profiles.

The current Modding-OpenMW lists require OpenMW 0.51. The published Total Overhaul and Expanded
Vanilla lists are intentionally large, useful stress tests rather than dependencies. Record list
version/date at acceptance because these lists change independently of ALMSIVI.

## Common matrix for every profile

- startup/content load, new game, copied save load/save/reload and clean exit;
- ALMSIVI target selection, overlay/controller input, vanilla dialogue coexistence;
- solo/group text conversation, STT/TTS/subtitle/interrupt/halt;
- added NPC/creature identity, cell/region/journal/faction/inventory/content context;
- all enabled action families on vanilla and mod-added actors/items;
- voice priority/lip behavior and missing/alternate mesh/animation behavior;
- media cache/VFS, UI layout/scaling, log errors and server content fingerprint;
- 30-minute feature loop and 2-hour soak with frame-time/memory/network/queue metrics;
- upgrade/rollback using copied saves and clean disable/uninstall.

## Profile A: minimal legal GOTY

Morrowind, Tribunal and Bloodmoon data plus ALMSIVI only, on the pinned Windows x64 runtime. This is
the release-blocking functional baseline and the source of deterministic in-game smoke saves.

## Profile B: I Heart Vanilla

Use the current published I Heart Vanilla automatic-install output for OpenMW 0.51. It tests common
fixes and visual improvements while staying near vanilla gameplay. Record the installer/list version,
every enabled content/data line and any local deviations.

## Profile C: Expanded Vanilla

Use the current Expanded Vanilla list, which keeps the vanilla feel while adding large land/quest/
gameplay content. It is the primary test for hundreds of content entries, added actors/factions/
journals, extended cells and prompt/context size controls.

## Profile D: Total Overhaul

Use the current Total Overhaul list (over 600 entries at research time) as the maximum-density stress
profile. Focus on startup/VFS/media interactions, Lua/UI conflicts, actor scans, frame budgets,
texture/mesh memory pressure, content fingerprint size, long session and diagnostics quality.

## Profile E: Tamriel Rebuilt and Project Tamriel focused

Create a smaller supported profile centered on current Tamriel Rebuilt/Project Tamriel requirements
and patches. Test added landmasses, exterior grids, cells, record/content provenance, factions,
journals/quests/topics, travel targets, mod-added actors/items and server knowledge-pack scoping.
Do not hardcode Vvardenfell-only assumptions.

## Profile F: controller and Steam Deck/Linux

Use semantic OpenMW input actions with Xbox-style controller on Windows, then a current Steam Deck/
Linux OpenMW setup. Test controller-only overlay navigation, text entry handoff, push-to-talk,
subtitle scale/safe area, pause/menu state, suspend/resume, server reconnect and performance. Linux
runtime support is claimed only after this profile, even if CI builds earlier.

## Profile G: voice and Lua-mod coexistence

Install a current OpenMW-compatible voiceover mod such as Voices of Vvardenfell or the selected
equivalent, plus representative popular OpenMW Lua UI/gameplay mods from the chosen lists. Test
vanilla dialogue voices, ALMSIVI generated speech, subtitle ownership, simultaneous/interrupt policy,
lip/loudness behavior, filenames/cache, script interfaces, input bindings and UI layers. ALMSIVI must
not suppress existing voice playback globally.

## Profile H: ALMSIVI development helpers

Keep a separate local profile containing H3lp Yours3lf, Follower Detection Util and Dynamic Camera.
H3 is a compatibility/library probe rather than an ALMSIVI dependency. Follower Detection Util is an
optional provider for bounded follower/leader context through its published interface. Dynamic Camera
is a camera/UI coexistence probe and does not replace ALMSIVI target authority. Record exact archive
versions and hashes, keep every mod in its own `C:\Modlists\ALMSIVI\Mods` directory, and retain the
minimal legal GOTY profile for release-blocking comparisons. The local Compatibility profile sets
`user-data=.` so its saves and logs remain isolated. The ALMSIVI profile manager owns ordered `data=`
and `content=` entries, reports loose-file conflicts with the final winning folder, validates missing
paths/content, backs up the profile before saving, and starts the server/private client environment
before handing off to the OpenMW launcher.

## Conflict rules

1. Use unique `scripts/ALMSIVI` paths, interfaces, storage sections and semantic input actions.
2. Do not override built-in or third-party interfaces when event/listener composition is possible.
3. Never depend on load-order priority to bypass a conflict silently; detect/report required order.
4. Capture ordered content through OpenMW, not by parsing a user's config heuristically in Lua.
5. A missing optional API/mod disables only its adapter and appears in capabilities/status.
6. Profile-specific patches carry upstream/list version predicates and removal criteria.
7. Any save-affecting compatibility change requires copied-save forward/disable/rollback tests.

## Unsupported setups

- Original Morrowind.exe/MWSE without OpenMW.
- OpenMW older/newer than the exact supported pin unless separately qualified.
- Multiplayer forks such as TES3MP/OpenMW-MP.
- Android, consoles, pirated or incomplete game data.
- Lists requiring incompatible development builds or unreviewed engine patches.

Unsupported does not mean intentionally blocked game data; it means no support claim or destructive
auto-fix. The diagnostics page must explain the detected mismatch and preserve the profile.

## Sources

- Modding-OpenMW lists: <https://modding-openmw.com/lists/>
- I Heart Vanilla: <https://modding-openmw.com/lists/i-heart-vanilla/>
- Expanded Vanilla: <https://modding-openmw.com/lists/expanded-vanilla/>
- Total Overhaul: <https://modding-openmw.com/lists/total-overhaul/>
- OpenMW extended modding: <https://openmw.readthedocs.io/en/openmw-0.51.0/reference/modding/extended.html>
