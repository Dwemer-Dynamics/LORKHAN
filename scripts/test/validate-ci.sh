#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

find "$ROOT/scripts" -type f \( -name '*.sh' -o -name '*.bash' \) -print | LC_ALL=C sort |
while IFS= read -r script; do
  case "$(head -n 1 "$script")" in
    *bash*) bash -n "$script" ;;
    *) sh -n "$script" ;;
  esac
done

python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
workflow_root = root / ".github/workflows"
action = re.compile(r"^\s*-?\s*uses:\s*([^\s#]+)", re.MULTILINE)
immutable = re.compile(r"^[^@]+@[0-9a-f]{40}$")
forbidden_events = {"release", "registry_package", "deployment", "deployment_status", "page_build"}
required_events = {"push", "pull_request"}


def scalar(value: str) -> str:
    return value.strip().strip("'\"")


def workflow_events(text: str, path: Path) -> set[str]:
    lines = text.splitlines()
    for index, line in enumerate(lines):
        match = re.match(r"^on\s*:\s*(.*?)\s*(?:#.*)?$", line)
        if not match:
            continue
        value = match.group(1)
        if value.startswith("[") and value.endswith("]"):
            return {scalar(item) for item in value[1:-1].split(",") if scalar(item)}
        if value.startswith("{") and value.endswith("}"):
            return {scalar(item.split(":", 1)[0]) for item in value[1:-1].split(",") if ":" in item}
        if value:
            return {scalar(value)}
        events: set[str] = set()
        for nested in lines[index + 1:]:
            if nested and not nested[0].isspace():
                break
            event = re.match(r"^\s{2}([A-Za-z0-9_-]+)\s*:", nested)
            if event:
                events.add(event.group(1))
        return events
    raise SystemExit(f"error: workflow has no top-level on trigger: {path}")


workflows = sorted((*workflow_root.glob("*.yml"), *workflow_root.glob("*.yaml")))
if not workflows:
    raise SystemExit("error: no workflows found")
for workflow in workflows:
    text = workflow.read_text(encoding="utf-8")
    uses = action.findall(text)
    if not uses:
        raise SystemExit(f"error: workflow has no action dependency: {workflow}")
    for reference in uses:
        if not immutable.fullmatch(reference):
            raise SystemExit(f"error: action is not pinned to an immutable 40-character SHA: {workflow}: {reference}")
    events = workflow_events(text, workflow)
    if events & forbidden_events:
        raise SystemExit(f"error: release/publish trigger forbidden: {workflow}: {sorted(events & forbidden_events)}")
    missing = required_events - events
    if missing:
        raise SystemExit(f"error: mandatory CI triggers missing: {workflow}: {sorted(missing)}")
    if re.search(r"(?i)(ALMSIVIserver|Synthserver|RANGROO/SYNTH|\.\./(?:ALMSIVIserver|SYNTH|Synthserver))", text):
        raise SystemExit(f"error: sibling checkout/reference forbidden in workflow: {workflow}")
    if re.search(r"(?m)^\s*repository:\s*", text):
        raise SystemExit(f"error: checkout repository override forbidden: {workflow}")
    if re.search(r"(?i)\b(?:gh\s+release|npm\s+publish|twine\s+upload|docker\s+push)\b", text):
        raise SystemExit(f"error: release/publish command forbidden: {workflow}")
    if "scripts/evidence/validate.py" in text or re.search(r"package_audit\.py[^\n]*\bprovenance\b", text):
        checkout_steps = re.findall(
            r"(?ms)^\s*-\s+name:\s+[^\n]*\n(?:.*?\n)*?^\s*uses:\s*actions/checkout@[0-9a-f]{40}.*?(?=^\s*-\s+(?:name:|uses:)|\Z)",
            text)
        if not checkout_steps or any(re.search(r"(?m)^\s*fetch-depth:\s*0\s*$", step) is None
                                     for step in checkout_steps):
            raise SystemExit(f"error: evidence/provenance workflow requires full checkout history: {workflow}")
print("ok: workflow action pins, mandatory triggers, publish bans, and repository boundaries validated")
PY

powershell_files=$(find "$ROOT/scripts" -type f -name '*.ps1' -print | LC_ALL=C sort)
if command -v pwsh >/dev/null 2>&1; then
  printf '%s\n' "$powershell_files" | while IFS= read -r script; do
    [ -n "$script" ] || continue
    pwsh -NoLogo -NoProfile -NonInteractive -Command \
      '$e=$null; $t=$null; [System.Management.Automation.Language.Parser]::ParseFile($args[0],[ref]$t,[ref]$e)|Out-Null; if($e.Count){$e|ForEach-Object{Write-Error $_};exit 1}' "$script"
  done
else
  printf 'skip: pwsh unavailable; PowerShell parser proof deferred for:\n%s\n' "$powershell_files"
fi
printf 'ok: all shell entrypoints and available PowerShell entrypoints validated\n'
