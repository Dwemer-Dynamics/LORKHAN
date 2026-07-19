#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
for script in "$ROOT/scripts/build/unix.sh" "$ROOT/scripts/test/lua-unix.sh"; do sh -n "$script"; done
for workflow in "$ROOT"/.github/workflows/*.yml; do
  grep -Eq 'uses: [^#[:space:]]+@[0-9a-f]{40}([ #]|$)' "$workflow" || { printf 'error: workflow has no SHA-pinned action: %s\n' "$workflow" >&2; exit 2; }
  if grep -Eq 'uses: [^#[:space:]]+@(v[0-9]|main|master)([ #]|$)' "$workflow"; then printf 'error: mutable action reference: %s\n' "$workflow" >&2; exit 2; fi
done
if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoLogo -NoProfile -NonInteractive -Command '$e=$null; $t=$null; [System.Management.Automation.Language.Parser]::ParseFile($args[0],[ref]$t,[ref]$e)|Out-Null; if($e.Count){$e|ForEach-Object{Write-Error $_};exit 1}' "$ROOT/scripts/build/windows.ps1"
  pwsh -NoLogo -NoProfile -NonInteractive -Command '$e=$null; $t=$null; [System.Management.Automation.Language.Parser]::ParseFile($args[0],[ref]$t,[ref]$e)|Out-Null; if($e.Count){$e|ForEach-Object{Write-Error $_};exit 1}' "$ROOT/scripts/test/lua-windows.ps1"
else
  printf 'skip: pwsh unavailable; PowerShell parser proof deferred\n'
fi
printf 'ok: CI shell static validation completed\n'
