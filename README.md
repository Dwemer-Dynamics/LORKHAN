# ALMSIVI

ALMSIVI is the OpenMW/Morrowind client for a CHIM- and Dialectic-style AI character system. It
combines a narrowly scoped OpenMW engine integration with an ordinary OpenMW Lua mod, and talks to
the separate `RANGROO/ALMSIVIserver` backend over authenticated loopback HTTP.

## Status

Planning and Azure handoff are complete; implementation has not started. The implementation run is
deliberately queued behind completion of `RANGROO/SYNTH` and `RANGROO/Synthserver`. It must import
the final, tested server architecture rather than a half-built snapshot.

The engine baseline is OpenMW `openmw-0.51.0` at
`f4bec41444214a7903bebd178389ca22ca13f646`, with Lua API revision 129. The first supported package
is Windows x64. Linux x64 and macOS arm64 are build/test lanes; Android is deferred.

## Product shape

- A side-by-side ALMSIVI-branded OpenMW build; it never overwrites stock OpenMW.
- A minimal native `openmw.almsivi` package: typed asynchronous requests, media staging, status,
  cancellation, and no generic HTTP, shell, or filesystem access.
- An OpenMW Lua mod owning targeting, conversations, custom UI, context collection, actor-local
  actions, save/load state, subtitles, and voice playback.
- No Bethesda game data, saves, or third-party mod assets in source or release archives.
- Vanilla dialogue remains available. ALMSIVI starts from its own configurable input and captures
  vanilla dialogue responses only as context.

## Start here

1. `CLAUDEX-TASK.md` — self-contained Azure/Claude Code execution assignment.
2. `RUN-AZURE-CLAUDE-CODE.md` — exact launch, supervision, resume, and completion procedure.
3. `docs/PROGRAM-PLAN.md` — program phases, decisions, gates, and completion rules.
4. `docs/REFERENCE-STACK-DATAFLOW.md` — CHIM/Dialectic/SYNTH/OpenMW ownership and data flow.
5. `docs/ENGINE-INTEGRATION-PLAN.md` — exact native patch boundary.
6. `docs/LUA-MOD-ARCHITECTURE.md` — scripts, events, UI, targeting, actions, and persistence.
7. `docs/PROTOCOL.md` — cross-repository wire contract.
8. `docs/FEATURE-PARITY-MATRIX.md` — retained, adapted, deferred, and excluded capabilities.
9. `docs/OPENMW-TOOLCHAIN.md` — source pin, build, CI, packaging, and in-game proof.
10. `docs/COMPATIBILITY-PLAN.md` — vanilla and popular OpenMW mod-list profiles.
11. `docs/PACKAGING-AND-LICENSE.md` — GPL/source-offer and proprietary-asset release gate.

## First implementation command

After SYNTH is complete, clone both ALMSIVI repositories into the same parent, open this repository
in Claude Code using the approved Azure GPT-5.6 Sol configuration, and give it:

> Read `CLAUDEX-TASK.md` completely and execute it. Continue until its stop condition is met. Work
> only in `ALMSIVI` and sibling `ALMSIVIserver`; do not push, release, or modify reference repos.

The assignment contains the order, agent ownership, validation commands to create, evidence ledger,
and exact stop condition. The worker does not need to invent a schedule or answer design questions.
