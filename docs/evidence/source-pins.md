# Source pins and provenance

The canonical, machine-readable OpenMW pin is `config/source-pins/openmw.json`: version 0.51.0, tag `openmw-0.51.0`, commit `f4bec41444214a7903bebd178389ca22ca13f646`, and Lua API revision 129. The tag is descriptive; the full commit is authoritative.

`docs/evidence/source-ledger.json` records imported and deferred sources. Null deferred pins are intentional and must not be replaced by guessed branch heads or “latest” versions. Minimum tool versions are environment constraints, not immutable source artifacts.

The required final predecessor pins are not available. `docs/evidence/start-gate-blocker.md` records the 2026-07-19 gate audit: SYNTH and Synthserver implementations remain on non-main branches, Synthserver's exact-HEAD CI is failing, SYNTH has no exact-HEAD CI run, and required Windows/WSL/PostgreSQL evidence is absent. Their observed branch SHAs are evidence inputs only, not authorized import pins. No predecessor source may be imported until the smallest resume evidence in that blocker record exists.
