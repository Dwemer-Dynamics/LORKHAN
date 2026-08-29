# OpenMW Lua API 129 action parity audit

Audited 2026-08-09 against the frozen CHIM `005df4c1fda5ff195dc14a674fe71b11542be4df`,
HerikaServer `c973f5c8fde2d01cb8211be3d5f96d1783663da4`, Dialectic
`5cd2817a6733acbe25ca21bdfb716ed64617f5f8`, and DialecticServer
`4f3d8fed834b283fd53ff0655ddd091d849dea1d` action catalogs. The OpenMW authority baseline is
Lua API revision 129 at `f4bec41444214a7903bebd178389ca22ca13f646`.

## Implemented equivalents

| Frozen action semantics | LORKHAN action | OpenMW behavior |
| --- | --- | --- |
| Inspect, InspectSurroundings | `inspect.report` | Tier 0 bounded identity, enabled-state, and position observation. |
| CheckInventory | `inventory.inspect` | Tier 0 bounded read-only inventory snapshot of the acting NPC. |
| Follow, FollowPlayer | `ai.follow` | Tier 1 owned Follow package with exact distance 192. |
| StopFollowing, StopWalk | `ai.stop` | Tier 1 cancellation limited to the actor's LORKHAN-owned AI package. |
| ComeCloser | `ai.approach` | Tier 1 same-cell Travel package to the addressed actor's observed current position. |
| WaitHere, Relax | `ai.wait` | Tier 1 distance-zero non-repeating Wander package for one to 24 whole game hours. |
| MoveTo, TravelTo | `ai.travel` | Tier 1 Travel to bounded coordinates and a canonical cell captured by the player. |
| LeadTheWayTo | `ai.escort` | Tier 1 Escort to a player-captured same-cell destination. |
| Attack | `combat.start` | Tier 2 confirmed Combat package against a resolved target. |
| Stop combat | `combat.stop` | Tier 1 cancellation limited to LORKHAN-owned combat. |
| Consume, Drink | `item.use` | Tier 2 use of an existing actor inventory record. |
| EquipItem, UnequipItem | `item.equip`, `item.unequip` | Tier 2 actor-local equipment mutation over an allowlisted slot. |
| Generic safe gesture | `animation.play` | Tier 1 allowlisted idle2 through idle9 only. |
| EndConversation | response `close` | Canonical response closure; no engine action is fabricated. |
| ReadQuestJournal, ReadQuests | Journal prompt context | Read-only Journal data is supplied to the prompt rather than emitted as an action. |

Every emitted action remains capability-negotiated, catalog-validated, generation/session/target fenced,
parameter-bounded, lifecycle-cancellable, and terminal-receipt gated.

## Not Applicable

| Frozen actions | Reason |
| --- | --- |
| GiveItemTo, TakeHeldItem, PickupItem, GiveGoldTo, TakeGoldFromPlayer, GiveCapsTo, TakeCapsFromPlayer, SpawnGold, SpawnCaps | Local actor inventory exposes local objects for inspection/equipment. `moveInto`, `remove`, and split/transfer authority are global-object APIs; a local actor script cannot perform an exact owned transfer safely. |
| AddBounty, ArrestPlayer, ForgiveCrime, PayBounty | The OpenMW Crimes interface is global-script authority. LORKHAN actor/player execution is local and cannot safely claim or restore this state. |
| OpenInventory, OpenInventory2, Barter, Training, RentRoom | These require service/menu activation and stateful UI side effects; API 129 has no bounded typed local action with a terminal result equivalent. |
| SpawnItem, SpawnNPC, CreateNewNPC, TeleportNPC, TeleportActor, KillTarget, DirectorCommand | These are arbitrary global creation, relocation, deletion, lethal, or command authority outside the bounded local action trust model. |
| MakeFollower | Persistent party/faction enrollment is not equivalent to a temporary owned Follow package. |
| ReturnBackHome | No stable actor-home provenance exists in the negotiated turn, and arbitrary destination inference is rejected. |
| HireCarriage, HireFerry | Skyrim transport/service semantics have no Morrowind actor-local equivalent. |
| CastSpell | API 129 does not provide the required bounded, target-fenced, reversible actor-local cast semantic used by the frozen action. |
| Brawl, Surrender, SheatheWeapon | Nonlethal combat, surrender, and weapon-sheathing state are not equivalent to the available combat/equipment operations. |
| TakeASeat, GoToSleep, StartRitualCeremony, EndRitualCeremony, Toast | No reliable bounded API-129 package or animation semantic reports completion without risking unrelated actor state. |
| IncreaseWalkSpeed, DecreaseWalkSpeed | These would mutate actor stats/settings without an owned package or dependable restoration boundary. |
| UseSoulGaze | ITT is explicitly excluded from LORKHAN. |

The authority conclusions are grounded in the pinned OpenMW sources: actor-local equipment is exposed in
`apps/openmw/mwlua/types/actor.cpp`; global-only object transfer methods are registered in
`apps/openmw/mwlua/objectbindings.cpp`; Crimes is a global-context interface; and actor-local AI packages are the
bounded execution surface used here. These decisions are implementation evidence, not manual in-game proof.
