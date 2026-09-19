# Source and package layout

`apps/` and `components/` hold maintained native integration sources. Do not delete matching
`openmw-patches/overlay/` files: those are patch-generator outputs consumed when materializing
the pinned OpenMW tree. `scripts/lib/openmw_patches.py` builds and checks the overlay/manifest.
After native edits regenerate using the established patch workflow and verify both copies.

`lorkhan/files/` contains deployable Lua and localization. Its nested tests are source-only.
Packaging and archive auditing reject tests, historical task documents, and evidence-run output
from player archives, while retaining source inputs for reproducibility. `docs/archive/` holds
superseded task instructions, not current configuration or release policy.

## Before public distribution

The packaging policy still requires LICENSE, notices/THIRD-PARTY-NOTICES.txt, and a generated
SBOM. The first two are not yet present in the repository. The release owner must confirm the
applicable licenses and attribution before these are authored; do not invent notices.
Server composer metadata also needs reconciliation with its provenance.
No release has been packaged or authorized by this cleanup.
