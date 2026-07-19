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
check("manifest declares GLOBAL PLAYER CUSTOM contexts", manifest.splitlines() == [
    "GLOBAL: scripts/ALMSIVI/global.lua", "PLAYER: scripts/ALMSIVI/player.lua", "CUSTOM: scripts/ALMSIVI/actor.lua"])
required = ["global.lua", "player.lua", "actor.lua", "orchestrator.lua", "player_state.lua", "actor_executor.lua",
            "protocol.lua", "identity.lua", "context.lua", "conversation.lua", "actions.lua", "storage.lua"]
check("all architecture modules exist", all((SCRIPTS / name).is_file() for name in required))
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
check("only ai.follow action wire contract", "intent.name ~= 'ai.follow'" in text(SCRIPTS / "actions.lua"))
check("future schema preserved", "future_schema_preserved" in text(SCRIPTS / "storage.lua"))
check("exactly one terminal action result", "terminal_result_exists" in text(SCRIPTS / "actions.lua"))
check("stale generation discarded", "stale_generation" in text(SCRIPTS / "protocol.lua"))
check("cursor gaps rejected", "cursor_gap" in text(SCRIPTS / "protocol.lua"))
check("actor self identity required", "identity.same(command.actor,state.identity)" in text(SCRIPTS / "actor_executor.lua"))
check("vanilla Activate not consumed", "return false -- built-in Activate" in text(SCRIPTS / "player_state.lua"))
check("pure Lua runner present", (SCRIPTS / "tests" / "run.lua").is_file())
print(f"{len(failures)} failures (structural fallback; Lua interpreter unavailable)")
sys.exit(bool(failures))
