# ALMSIVI engineering instructions

## Scope and baseline

- Read `CLAUDEX-TASK.md` and every document it marks required before editing implementation files.
- Pin OpenMW `openmw-0.51.0` commit `f4bec41444214a7903bebd178389ca22ca13f646`.
- Keep the OpenMW fork/patch rebaseable: isolate ALMSIVI integration files and minimize changes to
  upstream files. Record every upstream-file modification in the patch manifest.
- Treat Lua API revision 129 and the `almsivi.*.v1` wire schemas as versioned compatibility
  boundaries, not suggestions.

## Hard boundaries

- Never commit or distribute Morrowind/Tribunal/Bloodmoon data, BSAs, saves, voices, models,
  textures, credentials, generated user data, or third-party assets.
- Do not add generic HTTP, socket, shell, process, unrestricted filesystem, or dynamic-code APIs to
  OpenMW Lua. `openmw.almsivi` exposes only the typed operations in `ENGINE-INTEGRATION-PLAN.md`.
- The bridge accepts loopback endpoints only, rejects redirects, caps every payload and media file,
  validates media hashes/types, and never exposes its pairing token to Lua.
- No model-supplied console commands, Lua, MWScript, record mutation, paths, or arbitrary URLs.
- Keep vanilla dialogue and saves functional. ALMSIVI is opt-in per profile and installed beside
  stock OpenMW.
- Do not push, publish, release, deploy, or modify reference repositories without separate user
  authorization.

## Runtime ownership

- OpenMW main thread owns engine objects. Copy immutable DTOs before handing work to the transport
  thread. Network callbacks enqueue typed results; they never touch engine or Lua state directly.
- One bounded transport worker owns HTTP. All operations are cancellable and keyed by session,
  generation, request, and turn IDs.
- Global Lua owns orchestration and authoritative active-world reads. Player Lua owns input and UI.
  CUSTOM actor scripts own self-only AI, animation, and speech commands.
- A new game, loaded save, return to menu, profile switch, server disconnect, or explicit halt
  increments generation and invalidates older work.

## Quality and proof

- Add focused C++ and Lua tests alongside each subsystem, plus a fake ALMSIVIserver contract test.
- Run existing relevant OpenMW tests after every upstream-file change.
- Keep protocol fixtures byte-for-byte identical in both repositories.
- Track each completion row as `PLANNED`, `AUTOMATED`, `WINDOWS BUILD PROVEN`, `IN-GAME PROVEN`,
  or `DEFERRED` and link its evidence. Do not mark game behavior proven from mocks.
- Release archives must be reproducible and pass the GPL/source, secret, proprietary-data, path,
  and content manifest audits in `PACKAGING-AND-LICENSE.md`.
