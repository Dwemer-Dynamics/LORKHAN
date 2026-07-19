# Source pins and provenance

The canonical, machine-readable OpenMW pin is `config/source-pins/openmw.json`: version 0.51.0, tag `openmw-0.51.0`, commit `f4bec41444214a7903bebd178389ca22ca13f646`, and Lua API revision 129. The tag is descriptive; the full commit is authoritative.

`docs/evidence/source-ledger.json` records imported and deferred sources. Null deferred pins are intentional and must not be replaced by guessed branch heads or “latest” versions. Minimum tool versions are environment constraints, not immutable source artifacts.
