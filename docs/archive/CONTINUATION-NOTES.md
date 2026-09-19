# Continuation notes

Checkpoint date: 2026-07-20.

The complete client work through implementation head `1c1eaf188f39dae7c292fc2af41f7675e58ac056`
is preserved on `main`. Continue against the private `RANGROO/LorkhanServer` repository's `main`
branch. The older foundation-only wording in `README.md` is not the complete current state; use
`docs/evidence/completion-ledger.md` and the code on `main` when assessing what exists.

## Known immediate blockers

GitHub Actions was intentionally not repaired before the full-build branch was merged. The failures
observed at the checkpoint were:

- `scripts/test/validate-ci.sh` does not pass the PowerShell file path correctly to the parser on
  the Ubuntu runner;
- the packaging workflow runs `scripts/protocol/validate.py` without installing its `referencing`
  dependency;
- optimized GCC lanes promote a `std::variant` `maybe-uninitialized` diagnostic to an error; and
- the `macos-14`/Xcode 15.4 lane lacks the C++20 floating-point `from_chars` and stop-token support
  used by the native core. Move that lane to an appropriate Xcode 16 runner or add a deliberate
  portability layer.

Do not hide these failures with a blanket warning or test disable. Keep warning-clean and protocol
validation behavior meaningful.

## Resume on another machine

Clone `LORKHAN` and `LorkhanServer` beside each other, use `main` in both, and start with:

```bash
python3 scripts/evidence/validate.py
python3 scripts/protocol/validate.py
python3 lorkhan/tests/run.py
./scripts/test/native.sh
./scripts/test/lua-unix.sh
```

Then repair CI and rerun the server's cross-repository protocol and Beast HTTP suites against the
root `LORKHAN` checkout. The old nested `.claude/worktrees/independent-client-foundations` path is
no longer required because its commits are in `main`.

Windows OpenMW control/product builds, a legal Morrowind installation, Lua inside OpenMW, and
in-game behavior remain separate evidence gates. Never commit game data, saves, voices, generated
media, credentials, or local profile state.
