# Contributing

## Branch policy

Open feature and fix pull requests against **unstable**, not dev or lorkhan.
Discuss proposed changes with RANGROO or tyler.maister in Discord before submission.
Use a focused branch and keep unrelated work out of the PR.

Maintainers promote **unstable → dev → lorkhan** through reviewed pull requests.
The lorkhan branch is the default release branch; dev is for beta testing.
Promotion PRs are the exception to the unstable-only submission rule.

## Before submitting

- Read AGENTS.md and the linked build and architecture guides.
- Explain what changed, why, and how you verified it.
- Link companion client/server changes when required.
- Keep protocol schemas and fixtures synchronized between the two repositories.
- Never commit credentials, logs, saves, player data or Bethesda game files.
- Preserve third-party notices and submit project contributions under GNU GPL v3.0.
- Distinguish source tests, local deployment and in-game verification.
