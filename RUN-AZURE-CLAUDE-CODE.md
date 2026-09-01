# Run LORKHAN with Azure GPT-5.6 Sol in Claude Code

This is the operator runbook. The project is evidence-gated, not scheduled: leave the worker running
and resume it until the task stop condition is true. Do not start the implementation while SYNTH is
still incomplete.

## 1. Verify the start gate

In both predecessor repositories, confirm the final implementation run says its non-game stop
condition passed, the main branch is clean/pushed, and CI is green. Record:

```bash
git -C ~/Projects/SYNTH rev-parse HEAD
git -C ~/Projects/Synthserver rev-parse HEAD
git -C ~/Projects/SYNTH status --short
git -C ~/Projects/Synthserver status --short
```

If either status prints files or either project is unfinished, continue SYNTH instead. LORKHAN's
worker is instructed to refuse source import until this gate is proven.

## 2. Prepare the two repositories

The repos should be sibling directories under the intentionally non-Git `~/Projects` folder:

```bash
mkdir -p ~/Projects
cd ~/Projects
gh repo clone RANGROO/LORKHAN
gh repo clone RANGROO/LorkhanServer
git -C LORKHAN remote -v
git -C LorkhanServer remote -v
```

If the existing local clones are current and clean, use them instead of cloning again. Never nest
one repo inside the other.

## 3. Start a durable terminal session

Use the same already-tested Claude Code configuration whose custom model/provider points at the
approved Azure GPT-5.6 Sol deployment. The credential belongs in Claude Code's credential field; do
not paste it into the prompt, environment transcript, repository, task files or logs.

On the Mac, a simple durable setup is:

```bash
cd ~/Projects/LORKHAN
tmux new -s lorkhan
caffeinate -dimsu claude
```

If `tmux` is unavailable, install/use it or keep the terminal window open; `caffeinate` prevents Mac
sleep while Claude Code is running. Detach from tmux with `Ctrl-b d` and later resume with:

```bash
tmux attach -t lorkhan
```

Confirm inside Claude Code that the active custom model is the Azure GPT-5.6 Sol deployment already
configured in the working Claudex setup. Do not switch to Anthropic billing for this run.

## 4. Give one parent assignment

Paste exactly:

> Read `CLAUDEX-TASK.md` completely, then read every client and sibling-server document it requires.
> Execute the assignment end to end using the approved Azure GPT-5.6 Sol deployment. The sibling is
> `../LorkhanServer`. First prove the post-SYNTH start gate and record the final SYNTH/Synthserver
> SHAs. Use the documented parent/child ownership, keep worktrees and files disjoint, commit coherent
> checkpoints locally, and continue until the task's stop condition is true. Do not push, publish,
> release, deploy, expose a service, use live provider billing, modify reference repositories, or
> include game data/secrets. Continue all independent work when game-only proof is unavailable and
> record that proof exactly as deferred.

One parent owns both repos so protocol/schema changes stay synchronized. Do not start a second
independent Claude session editing the same files. The parent may use only the bounded, disjoint agent
topology defined in the assignment.

## 5. Permission policy

Approve ordinary reads, edits, local builds/tests, isolated temporary worktrees, dependency fetches
from the pinned public sources, local disposable databases and loopback fake services. Review before
approving any command that changes system packages/services or existing WSL/database state.

Do not approve pushes, releases, public repo changes, cloud deploys, provider spending, non-loopback
listening, destructive Git cleanup, edits outside the two repos/isolated temp paths, or access to game
data/saves/secrets unless you separately decide to run that exact acceptance step.

## 6. Let it continue and resume correctly

Claude Code may stop for context compaction, a permission, machine restart, Azure interruption or an
external game-only gate. Resume in the same repo/session and say:

> Re-read `CLAUDEX-TASK.md`, the current evidence/completion ledgers, `git status` in both repos, and
> the latest test manifests. Continue from the first incomplete non-blocked row. Do not redo proven
> work and do not stop until the documented stop condition is true.

The evidence ledger is the durable state—not the chat history. Require coherent local commits after
each green gate. Do not tell it to commit secrets, generated media, build trees, dependencies, game
data, saves or local configuration.

## 7. Monitor without interrupting productive work

Periodically check from a second read-only terminal:

```bash
git -C ~/Projects/LORKHAN status --short
git -C ~/Projects/LORKHAN log --oneline -8
git -C ~/Projects/LorkhanServer status --short
git -C ~/Projects/LorkhanServer log --oneline -8
```

Ask the parent for a short status only when needed: current gate, last green command, next incomplete
ledger row, active blockers and whether any approval is waiting. A long compile/test with live CPU/
output is progress; unchanged state with an unanswered prompt is not.

## 8. Completion review

Before accepting “done,” require the parent to show:

- final SHAs and clean status in both repos;
- exact OpenMW/SYNTH/Synthserver/dependency pins and provenance ledger;
- completion-ledger totals with every non-game/non-Android/non-addon row proven;
- last clean Windows/Linux/macOS build/test and cross-repo E2E commands/results;
- deterministic package/source/SBOM/license/secret/game-data audit results;
- explicit remaining rows limited to documented Windows game, compatibility, Android or optional
  content-addon proof, each with exact evidence needed;
- critic audit with no unexplained parity, sandbox, threading, security or licensing gap.

Then review changes locally. Push or release only in a separate, explicit step after that review.
