# Predecessor start-gate blocker

Recorded: 2026-07-19

## Required gate

`docs/archive/CLAUDEX-TASK.md` requires both `RANGROO/SYNTH` and `RANGROO/Synthserver` to complete their documented non-game stop conditions before source import. The import source must be each final tested `main` SHA. Planning documents and original LORKHAN work may continue, but predecessor source must not be imported while this gate is open.

## Observed repositories

| Repository | Default/main SHA | Clean implementation branch SHA | Relationship |
| --- | --- | --- | --- |
| `RANGROO/SYNTH` | `1ac75b568fa47834b7b05319e22c8643778850a6` | `claudex/full-build@e96e4363663797bea0e4f9fc3cb17066a60450ba` | implementation branch is 36 commits ahead of `main` |
| `RANGROO/Synthserver` | `958faff7f27bf64dc0576e3e0bb30c67d8b7e9a5` | `claudex/full-build@19ae4c09facff01215597749a324ddb65b209c16` | implementation branch is 44 commits ahead of `main` |

Both implementation worktrees were clean and matched their remote implementation branches when checked. Neither final implementation is on `main`, so no final tested `main` SHA exists.

## Exhausted checks and evidence

- The local SYNTH portable C++/Python suites passed on macOS at `e96e4363663797bea0e4f9fc3cb17066a60450ba`, including actions, adapters, audio, configuration, context, diagnostics, fake HTTP, input, JSON, lifecycle, media fetch, native, presentation, protocol-native, targeting, task lanes, transport, build gates, package audit, and protocol verification. This is useful predecessor evidence but does not satisfy its Windows-build or final-main requirements.
- `gh run list --repo RANGROO/SYNTH --branch claudex/full-build` returned no workflow runs. The repository has no tracked GitHub Actions workflow at this SHA.
- Synthserver GitHub Actions run `29686478540` tested `19ae4c09facff01215597749a324ddb65b209c16` and failed. PHP 8.2 and 8.3 lint stopped at `app/Operations/LogService.php:20`; the portable job failed while checking out the private SYNTH peer. Only the assembled release-audit job passed.
- Portable Synthserver Python checks were run locally. They passed their static checks but explicitly skipped PHP runtime, isolated PostgreSQL, durable restart, and route-aware tests because this macOS host lacks PHP/Composer/PostgreSQL.
- No tracked completion ledger in either predecessor binds a complete passing run to the current implementation SHA. Both feature matrices retain non-game rows without required proof.
- Required Windows flat/VR client builds, WSL/Apache/PostgreSQL/pgvector server acceptance, and cross-repository Windows/WSL contract acceptance are absent.

## Blocking dependency and owner

Owner: predecessor repositories (`RANGROO/SYNTH` and `RANGROO/Synthserver`).

Blocking dependency: finish each predecessor's non-game stop condition, fix the failing server CI, execute required Windows and WSL/PostgreSQL lanes, record exact passing evidence, and merge the completed implementation to `main` (or otherwise establish the documented final tested `main` SHA without changing this task's closed decision).

## Smallest evidence needed to resume import

1. Clean `main` in each predecessor containing the completed implementation.
2. Exact `main` SHAs recorded after the merge.
3. Passing evidence tied to those exact SHAs for all predecessor non-game rows, including Windows client builds and WSL/PostgreSQL/cross-repository contract lanes.
4. Audited source licenses/provenance at those exact SHAs.

Until all four exist, LorkhanServer may receive independently authored scaffolding, but importing or semantically copying Synthserver source is prohibited by the start gate.

## Plaintext loopback confidentiality limitation

Routine reusable bearer transmission has been replaced by installation-bound `hmac-sha256-v1` request MACs with body digests, timestamps, unique nonces, database replay rejection, key overlap and revocation. This authenticates requests without transmitting the reusable key. Plain HTTP loopback still does not provide payload confidentiality against sufficiently privileged local software, and TLS is not claimed without coordinated Apache support.

## Independent client build blocker observed 2026-07-19

The deterministic OpenMW package-registration patch was generated and statically applied/verified at the exact pin. A local no-game configure was attempted with all application/tool/test targets disabled. CMake stopped before compilation because it found ICU 76.1 headers but not the required `uc`, `i18n`, and `data` libraries; `collada_dom` was also not found. No install was attempted, no control/product build claim is made, and the smallest resume step is a pinned OpenMW macOS dependency environment followed by identical control and patched configure/build/test commands.
