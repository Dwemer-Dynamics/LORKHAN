#!/usr/bin/env python3
"""Dependency-free structural fallback. It does not prove Lua runtime behavior."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
FILES = ROOT / "almsivi" / "files"
SCRIPTS = FILES / "scripts" / "ALMSIVI"
failures = []

def check(name, condition):
    print(("ok" if condition else "not ok") + " - " + name)
    if not condition:
        failures.append(name)

def text(path):
    return path.read_text(encoding="utf-8")

manifest = text(FILES / "ALMSIVI.omwscripts")
allowed_manifest_declarations = [
    "GLOBAL: scripts/ALMSIVI/global.lua", "PLAYER: scripts/ALMSIVI/settings.lua",
    "PLAYER: scripts/ALMSIVI/player.lua", "CUSTOM: scripts/ALMSIVI/actor.lua"]
manifest_declarations = [line.strip() for line in manifest.splitlines() if line.strip() and not line.lstrip().startswith("#")]
check("production manifest has exact pinned-source-verified contexts and paths",
      manifest_declarations == allowed_manifest_declarations)
check("production manifest contains only comments or allowed declarations", all(
    not line.strip() or line.lstrip().startswith("#") or line.strip() in allowed_manifest_declarations
    for line in manifest.splitlines()))
required = ["global.lua", "settings.lua", "player.lua", "actor.lua", "orchestrator.lua", "player_state.lua", "actor_executor.lua",
            "protocol.lua", "identity.lua", "context.lua", "conversation.lua", "actions.lua", "storage.lua"]
check("all architecture modules exist", all((SCRIPTS / name).is_file() for name in required))
deferrals = text(ROOT / "almsivi" / "ENGINE-DEFERRALS.txt")
check("manifest verification cites pinned source paths and commit", all(fragment in deferrals for fragment in [
    "PINNED SOURCE VERIFIED", "f4bec41444214a7903bebd178389ca22ca13f646",
    "files/data/builtin.omwscripts", "scripts/data/integration_tests/test_lua_api/test_lua_api.omwscripts"]))
constants = text(SCRIPTS / "constants.lua")
for name, value in [("MAX_AUDIENCE", "12"), ("MAX_INVENTORY_ROWS", "48"), ("MAX_NEARBY_OBJECTS", "32"),
                    ("MAX_ACTIVE_EFFECTS", "32"), ("MAX_JOURNAL_ENTRIES", "32"), ("MAX_CONTENT_FILES", "256"),
                    ("MAX_CONTEXT_BYTES", "128 * 1024"), ("MAX_ACTIONS_PER_TURN", "4"),
                    ("MAX_CONTINUATIONS_PER_ACTION", "1")]:
    check(f"bounded constant {name}", bool(re.search(rf"\b{name}\s*=\s*{re.escape(value)}\b", constants)))
all_lua = "\n".join(text(path) for path in SCRIPTS.rglob("*.lua") if "tests" not in path.parts)
for forbidden in ["io.open", "os.execute", "loadstring", "dofile", "package.loadlib", "require('socket", 'require("socket']:
    check(f"forbidden primitive absent: {forbidden}", forbidden not in all_lua)
check("native seam exposes typed bridge only", "require, 'openmw.almsivi'" in text(SCRIPTS / "adapters" / "openmw.lua"))
actions = text(SCRIPTS / "actions.lua")
check("safe action allowlist is explicit", all(name in actions for name in (
    "'inspect.report'", "'ai.follow'", "'ai.stop'", "'ai.wander'", "'combat.start'", "'combat.stop'",
    "'animation.play'", "'item.use'")))
check("combat start requires player confirmation", "event.payload.tier>=2" in text(SCRIPTS / "orchestrator.lua")
      and "ALMSIVI_ACTION_CONFIRMATION" in text(SCRIPTS / "player.lua"))
check("ai.follow accepts exact integer distance 192", "distance%1~=0 or distance~=192" in actions)
check("invented ai.follow range absent", "distance < 64" not in actions and "distance > 512" not in actions)
check("action terminal is internal before timestamp", "almsivi.internal.action-terminal" in actions and "completed_at=completedAt" in actions)
check("future schema preserved", "future_schema_preserved" in text(SCRIPTS / "storage.lua"))
check("exactly one terminal action result", "terminal_result_exists" in text(SCRIPTS / "actions.lua"))
protocol = text(SCRIPTS / "protocol.lua")
orchestrator = text(SCRIPTS / "orchestrator.lua")
check("stale generation discarded", "stale_generation" in protocol)
check("correlation identifiers require UUID format", "function M.isUuid" in protocol and "invalid_'..key" in orchestrator)
check("orchestrator does not fabricate identifiers", "local-request-" not in orchestrator and "local-turn-" not in orchestrator)
check("polled events are internal DTOs", "validatePolledEvent" in protocol and "almsivi.event.v1" not in protocol)
check("ui source has no invented wire default", "ui_source=args.ui_source" in protocol and "almsivi.overlay" not in protocol)
check("cursor gaps rejected", "cursor_gap" in text(SCRIPTS / "protocol.lua"))
check("actor self identity required", "identity.same(command.actor,state.identity)" in text(SCRIPTS / "actor_executor.lua"))
check("vanilla Activate not consumed", "return false -- built-in Activate" in text(SCRIPTS / "player_state.lua"))
settings = text(SCRIPTS / "settings.lua")
check("OpenMW Scripts page exposes all ALMSIVI input bindings", all(fragment in settings for fragment in [
    "I.Settings.registerPage", "I.Settings.registerGroup", "renderer='inputBinding'",
    "key='ALMSIVI_Talk'", "key='ALMSIVI_Halt'", "key='ALMSIVI_PushToTalk'", "key='ALMSIVI_OpenMic'"]))
check("conflict-free F6 and F7 defaults seed only once", all(fragment in settings for fragment in [
    "ALMSIVIInputDefaults", "defaultsSection:get('version') == nil", "input.KEY.F6", "input.KEY.F7"]))
check("OpenMW settings rows have required localization metadata", all(fragment in settings for fragment in [
    "name='Talk_name',description='Talk_description'", "name='Halt_name',description='Halt_description'",
    "name='PushToTalk_name',description='PushToTalk_description'",
    "name='OpenMic_name',description='OpenMic_description'"]))
check("player has no duplicate hardcoded ALMSIVI keys", "onKeyPress" not in text(SCRIPTS / "player.lua"))
check("guessed UI and targeting constants absent", all(name not in constants for name in ["MAX_TEXT_BYTES", "MAX_TRANSCRIPT", "MAX_NEARBY_PICKER", "MAX_TARGET_DISTANCE"]))
check("Lua tests reject 191 193 and noninteger follow", all(fragment in text(SCRIPTS / "tests" / "run.lua") for fragment in ["distance=191", "distance=193", "distance=192.5"]))
check("pure Lua runner present", (SCRIPTS / "tests" / "run.lua").is_file())
print(f"{len(failures)} failures (structural fallback; Lua interpreter unavailable)")
sys.exit(bool(failures))
