# Deferred original OpenMW content addon

## Decision

The first ALMSIVI product uses `ALMSIVI.omwscripts` and the native bridge; it requires no `.esp`,
`.esm`, or `.omwaddon`. OpenMW 0.51 supports dynamic Lua scripts and significant world/runtime APIs,
so records are not a prerequisite for dialogue, UI, speech, context, memory or the initial action set.

## Entry criteria

Create an addon only after all are true:

1. a parity row is proven impossible or materially unsafe using pinned engine/Lua APIs;
2. the exact missing record/form capability and user value are documented;
3. the addon contains only original metadata/scripts/assets or clearly redistributable dependencies;
4. core conversation continues when the addon is absent;
5. load-order, save, localization, compatibility and uninstall effects have tests;
6. the user separately authorizes the content deliverable.

Likely justified uses are original configuration objects, optional spells/items/activators for a
diegetic control surface, or authored dialogue/quest records. Do not use it merely to imitate a Skyrim
or Fallout architecture.

## Planned layout

```text
content-addon/
  ALMSIVI.omwaddon
  source/                 # OpenMW-CS source/export inputs
  assets/                 # original or licensed only
  localization/
  manifest.json
  LICENSES/
```

Record IDs use a unique `almsivi_` namespace. Scripts remain in `scripts/ALMSIVI`. The addon has a
schema/version capability announced to the server and a clean feature-disabled path when absent.

## Build and acceptance

- Build/export reproducibly with the pinned OpenMW-CS/tool version and record a normalized record
  manifest.
- Scan for master dependencies, deleted references, wild edits, proprietary/third-party assets,
  scripts and unexpected records.
- Test new game plus copied saves; enable/disable/reorder; all compatibility profiles; localization;
  missing addon; version upgrade/downgrade warning; clean uninstall.
- Package separately from the core runtime and never merge Bethesda masters/data into it.

Until the entry criteria pass, this document is the complete plan and the addon remains `DEFERRED`.
