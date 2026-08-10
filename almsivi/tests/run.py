#!/usr/bin/env python3
"""Dependency-free structural fallback. It does not prove Lua runtime behavior."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
FILES = ROOT / "almsivi" / "files"
SCRIPTS = FILES / "scripts" / "ALMSIVI"
DEPLOY = ROOT / "scripts" / "deploy" / "full-local.ps1"
PROFILE_MANAGER = ROOT / "scripts" / "tools" / "manage-openmw-profile.ps1"
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
            "protocol.lua", "identity.lua", "context.lua", "conversation.lua", "actions.lua", "storage.lua",
            "ui/chatbox.lua", "ui/selector.lua", "ui/actor_tools.lua", "ui/notifications.lua"]
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
adapter_script = text(SCRIPTS / "adapters" / "openmw.lua")
native_binding = text(ROOT / "apps" / "openmw" / "mwlua" / "almsivibindings.cpp")
native_overlay = text(ROOT / "openmw-patches" / "overlay" / "apps" / "openmw" / "mwlua" / "almsivibindings.cpp")
check("verified speech bypasses the startup-only VFS index", all(fragment in native_binding for fragment in [
    'api["playSpeech"]', "sayAlmsiviMedia", "openConstrainedFileStream", "cachePath"])
    and 'api["mediaVfsName"]' not in native_binding
    and "bridge.playSpeech(mediaId,modules.self,subtitle or '',tonumber(volumeBoost) or 3)" in adapter_script
    and "modules.core.sound.say" not in adapter_script)
check("speech-ready correlation reaches Lua from both tracked OpenMW bindings",
      all('payload["dialogue_message_id"] = item.dialogueMessage.value();' in binding
          for binding in [native_binding, native_overlay]))
check("one failed request does not poison an established native session", all(
    'if (!m_session)\n                            m_status = "error";\n                        else if (!mediaFailure)\n                            m_status = "ready";' in binding
    for binding in [native_binding, native_overlay]))
check("ALMSIVI-only TTS boost is bounded and reaches native playback", all(fragment in native_binding for fragment in [
    "invalid_tts_volume_boost", "volumeBoost.value_or(3.f)", "sayAlmsiviMedia("])
    and "tts_volume_boost=ttsVolumeBoost" in text(SCRIPTS / "orchestrator.lua")
    and "command.tts_volume_boost" in text(SCRIPTS / "actor_executor.lua")
    and "command.tts_volume_boost" in text(SCRIPTS / "player.lua"))
check("OpenMW special player identity is stable and resolvable", all(fragment in adapter_script for fragment in [
    "kind=='player' and object.id:match('^@0x[0-9a-fA-F]+$')", "refnumIndex=specialPlayer and 0",
    "(kind=='npc' or kind=='player') and modules.types.NPC.record", "modules.nearby.players and modules.nearby.players[1]"]))
actions = text(SCRIPTS / "actions.lua")
check("safe action allowlist is explicit", all(name in actions for name in (
    "'inspect.report'", "'inventory.inspect'", "'ai.follow'", "'ai.stop'", "'ai.approach'", "'ai.wait'",
    "'ai.travel'", "'ai.escort'", "'ai.face'", "'ai.wander'", "'combat.start'", "'combat.stop'",
    "'animation.play'", "'item.use'", "'item.equip'", "'item.unequip'")))
check("combat start requires player confirmation", "command.tier>=2" in text(SCRIPTS / "orchestrator.lua")
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
check("native-authenticated cursor gaps recover without replaying duplicates",
      "cursor_resynced" in protocol and "event.sequence <= cursor" in protocol)
check("actor self identity required", "identity.same(command.actor,state.identity)" in text(SCRIPTS / "actor_executor.lua"))
check("vanilla Activate not consumed", "return false -- built-in Activate" in text(SCRIPTS / "player_state.lua"))
settings = text(SCRIPTS / "settings.lua")
player_script = text(SCRIPTS / "player.lua")
check("OpenMW Scripts page exposes all applicable focused hotkeys", settings.count("renderer='inputBinding'") == 14
      and all(fragment in settings for fragment in ["I.Settings.registerPage", "key='ALMSIVI_Talk'",
          "key='ALMSIVI_StopDialogue'", "key='ALMSIVI_ManualActivate'", "key='ALMSIVI_ToggleMode'",
          "key='ALMSIVI_ModelMenu'", "key='ALMSIVI_ProfileMenu'", "key='ALMSIVI_Halt'",
          "key='ALMSIVI_ActionsMenu'", "key='ALMSIVI_StatusHud'", "key='ALMSIVI_History'",
          "key='ALMSIVI_Diagnostics'", "key='ALMSIVI_OpenMic'", "key='ALMSIVI_OpenMicMute'"]))
check("legacy master menu remains hidden while typed voice controls are registered",
      "trigger('ALMSIVI_MasterMenu'" in settings
      and "trigger('ALMSIVI_OpenMic'" in settings
      and "registerAction({key='ALMSIVI_PushToTalk'" in settings
      and "argument={type='action',key='ALMSIVI_PushToTalk'}" in settings)
check("push-to-talk uses action transitions with a configured keyboard fallback", all(fragment in player_script for fragment in [
      "input.registerActionHandler('ALMSIVI_PushToTalk'", "isConfiguredPushToTalkKey(event)",
      "onKeyRelease=function(event)", "handlePushToTalk(true,'configured_key')",
      "handlePushToTalk(false,'configured_key')", "not controlsAllowed() and not ownsUiMode"]))
required_native_voice_entries = ['api["voiceCaptureSupported"]','api["startVoiceCapture"]','api["stopVoiceCapture"]',
    'api["cancelVoiceCapture"]','api["voiceCaptureStatus"]','api["currentVoiceCaptureDeviceName"]',
    'api["voiceCaptureDevices"]',
    'api["submitCapturedStt"]','RequestKind::stt']
check("shipped native package exposes typed STT while autonomy stays absent", all(
    all(fragment in binding for fragment in required_native_voice_entries)
    and 'api["selectVoiceCaptureDevice"]' not in binding
    and 'api["pollAutonomy"]' not in binding for binding in [native_binding,native_overlay]))
check("native handshake negotiates speech input", all(
    binding.count('"speech.listen"') >= 2
    and '"dialogue.text", "speech.say", "speech.listen", "controls.session"' in binding
    for binding in [native_binding,native_overlay]))
check("Lua orchestration exposes fenced STT and no general autonomy execution path",
      all(fragment in orchestrator for fragment in ["function M.startVoice","function M.enableOpenMic",
          "pending.session_id==state.sessionId","pending.generation==state.generation","ALMSIVI_OPEN_MIC_CONTEXT_REQUEST"])
      and all(fragment not in orchestrator for fragment in ["function M.requestLocalAutonomy","function M.pollAutonomy",
          "function M.runAutonomy","ui_source='almsivi_autonomy'","ALMSIVI_AUTONOMY_CONTEXT_REQUEST"]))
player_lua = text(SCRIPTS / "player.lua")
openmw_adapter = text(SCRIPTS / "adapters" / "openmw.lua")
context_lua = text(SCRIPTS / "context.lua")
global_lua = text(SCRIPTS / "global.lua")
check("turn-time OpenMW context includes shallow actors, semantic objects, and authoritative calendar timing",
      "local function nearbyActorContext" in openmw_adapter
      and "row.equipment=actor and equipment(actor,modules) or {}" in openmw_adapter
      and "refnum=formId and {index=formId%0x1000000" in openmw_adapter
      and "cell_identity=cellIdentity" in openmw_adapter
      and "enrichWorldCalendar(event)" in global_lua
      and "averageCollectionMs = snapshot.collectionTiming.averageMs" in context_lua)
check("history and diagnostics bindings open their named panels", all(fragment in player_lua for fragment in [
    "ALMSIVI_History',adapter.callback(function() togglePanel('history')",
    "ALMSIVI_Diagnostics',adapter.callback(function() togglePanel('diagnostics')"]))
check("diagnostics use configured server and native bridge state", all(fragment in player_lua for fragment in [
    "nativeValue('serverBaseUrl',nil)", "'/ui/home.php'", "'Server connection: '",
    "'Session ID: '", "'Bridge queue: '", "nativeValue('lastError','none')",
]) and 'http://127.0.0.1:8089/ALMSIVIserver/manage' not in player_lua)
check("status HUD exposes connection request speech and target state", all(fragment in player_lua for fragment in [
    "'  |  Request: '", "'  |  Speech: '", "'  |  Target: '", "nativeValue('status','unavailable')"]))
check("history exposes bounded ordered timestamped request state", all(fragment in player_lua for fragment in [
    "local pageSize=5", "line.createdAt", "line.status", "line.requestId", "state.ui.historyPage"]))
check("diagnostic correlation IDs are selectable", all(fragment in player_lua for fragment in [
    "state.ui.lastCorrelation", "Correlation IDs (click, select, Ctrl+C)", "readOnly=true"]))
check("player-local vanilla dialogue is forwarded as bounded context", all(fragment in player_lua for fragment in [
    "DialogueResponse=function(event)", "adapter.dialogueResponse(event)", "ALMSIVI_VANILLA_DIALOGUE"]))
controls_schema = text(ROOT / "almsivi" / "schemas" / "v1" / "controls.schema.json")
native_parser = text(ROOT / "components" / "almsivi" / "src" / "protocol_response.cpp")
check("target-effective settings are strict and keep local presentation client-owned", all(fragment in controls_schema for fragment in [
    '"effective_settings"', '"almsivi.effective-settings.v1"', '"change_token"', '"source_map"'])
      and all(fragment in native_parser for fragment in ["parseEffectiveSettings", "effective settings source map mismatch"])
      and all(fragment in native_binding for fragment in ['result["effective_settings"]=effective', 'effective["change_token"]'])
      and all(fragment in player_lua for fragment in ["controls.effective_settings", "targetSettings.safety",
          "effective and effective.change_token", "refreshSessionControls(nil,true)"])
      and "serverPresentation" not in player_lua)
check("OpenMW Scripts page exposes bounded ALMSIVI TTS volume boost", all(fragment in settings for fragment in [
    "key='ttsVolumeBoost'", "default=3", "integer=true,min=1,max=4"]))
check("conflict-free F6 and F7 defaults seed only once", all(fragment in settings for fragment in [
    "ALMSIVIInputDefaults", "defaultsSection:get('version') == nil", "input.KEY.F6", "input.KEY.F7"])
      and "input.KEY.F8" not in settings and "input.KEY.F9" not in settings)
check("OpenMW settings rows have required localization metadata", all(fragment in settings for fragment in [
    "name='Talk_name',description='Talk_description'", "name='Halt_name',description='Halt_description'",
    "name='ModeMenu_name',description='ModeMenu_description'",
    "name='ActorTools_name',description='ActorTools_description'"]))
actor_script = text(SCRIPTS / "actor.lua")
check("dialogue playback uses native Morrowind subtitles without a duplicate status-HUD notification",
      "playSpeech=function(mediaId,actorIdentity,subtitle,volumeBoost) return adapter.playSpeech(mediaId,subtitle,volumeBoost) end" in actor_script
      and "dialogueNotification" not in player_script)
check("rapid UI state changes update existing elements instead of recreating them", all(fragment in player_script for fragment in [
    "statusElement.layout=layout statusElement:update()", "element.layout=layout element:update()"]))
check("player has no duplicate hardcoded ALMSIVI keys", all(key not in player_script for key in [
    "input.KEY.F6", "input.KEY.F7", "input.KEY.F8"]))
check("typed chat fallback follows the configured semantic binding", all(fragment in player_script for fragment in [
    "inputBindings:get('ALMSIVI_Talk_Binding')", "binding.button==event.code",
    "input.registerTriggerHandler('ALMSIVI_Talk',adapter.callback(requestTalkToggle))"]))
chatbox_script = text(SCRIPTS / "ui" / "chatbox.lua")
check("typed chat captures a target before UI mode and renders only focused chat controls",
      all(fragment in player_script for fragment in ["chatbox.build", "chooseTarget(2048,true)\n        enterUiMode()\n        render()"])
      and all(fragment in chatbox_script for fragment in ["type=ui.TYPE.TextEdit", "type=ui.TYPE.Image", "Press Enter or select Send"])
      and all(fragment not in chatbox_script for fragment in ["Open mic", "NEARBY TARGETS", "Master Menu"]))
check("typed chat uses one-line Enter submission and waits for target confirmation", all(fragment in player_script for fragment in [
    "player.consumeTextEdit(value)", "pendingTextSubmit=true",
    "event.code==input.KEY.Enter or event.code==input.KEY.NP_Enter",
    "if controlPanel then refreshSessionControls(controlPanel)",
    "if shouldSubmit then submitText() else render() end"])
      and "multiline=false" in chatbox_script)
check("focused selectors and targeted NPC tools replace the master dashboard", all(fragment in player_script for fragment in [
    "state.ui.panel=='actor-tools'", "state.ui.panel=='profile-menu'", "state.ui.panel=='modes'",
    "refreshSessionControls('models')", "Targeted NPC Tools", "Actor actions..."])
      and "state.ui.panel=='master'" not in player_script)
check("dynamic profile selector exposes server-validated narrator generation", all(fragment in player_script for fragment in [
    "label='Narrator'", "controls.narrator_profile_id",
    "native.selectSessionControl('narrator_profile_generate'", "preserves voice routing and enablement."]))
check("nearby agent manager opens the selected actor profile controls", all(fragment in player_script for fragment in [
    "text='Manage profile for '..label", "pendingControlPanel='profiles'",
    "if controlPanel then refreshSessionControls(controlPanel)", "pendingControlPanel=nil"]))
global_script = text(SCRIPTS / "global.lua")
check("global orchestrator output is delivered to the player-local script", all(fragment in global_script for fragment in [
    "local function currentPlayer()", "player:sendEvent(name,payload)", "local function flushPlayerEvents(player)",
    "pendingPlayerEvents[#pendingPlayerEvents+1]", "flushPlayerEvents(object)"])
    and "local function emit(name,payload) if core and core.sendGlobalEvent" not in global_script)
orchestrator_script = text(SCRIPTS / "orchestrator.lua")
check("terminal speech releases bounded client media state",
    all(fragment in global_script for fragment in ["ALMSIVI_SPEECH_STATUS=function(event)",
        "orchestrator.speechStatus(state,event)", "emit('ALMSIVI_SPEECH_STATUS',event)"])
    and all(fragment in orchestrator_script for fragment in ["function M.speechStatus(state,event)",
        "local releaseId=item.media and item.media.media_id or nil", "state.bridge.releaseMedia(releaseId)"])
    and "state.byMedia[item.media.media_id]=nil" in text(SCRIPTS / "response_queue.lua"))
check("vanilla actor activation only supplies a passive target hint", all(fragment in global_script for fragment in [
    "interfaces.Activation.addHandlerForType(types.NPC,observeActivatedActor)",
    "interfaces.Activation.addHandlerForType(types.Creature,observeActivatedActor)",
    "orchestrator.activate(state,candidate.identity,object)", "orchestrator.selectTarget(state,candidate)"])
    and "return false" not in global_script.split("local function observeActivatedActor", 1)[1].split("end", 1)[0])
check("loaded actors are reactivated before target validation", all(fragment in global_script for fragment in [
    "world.activeActors", "orchestrator.load(state,data)\n            activateWorldActors()",
    "local function selectCandidate(candidate,source)",
    "emit('ALMSIVI_TARGET_REJECTED',{reason=reason})"]))
check("global nearest actor fallback handles empty local target searches", all(fragment in global_script for fragment in [
    "local function nearestWorldCandidate(maxDistance)", "world.activeActors", "world.players",
    "ALMSIVI_SELECT_NEAREST_TARGET=function(event)", "selectCandidate(candidate,'nearest_active_actor')"])
    and all(fragment in player_script for fragment in [
    "send('ALMSIVI_SELECT_NEAREST_TARGET',{maxDistance=maxDistance,local_reason=reason})",
    "local target search failed:", "return true"]))
check("text submission failures are observable in game and logs", all(fragment in global_script for fragment in [
    "local submitted,reason=orchestrator.submitText(state,event)",
    "print('[ALMSIVI] text turn rejected: '..tostring(reason))",
    "emit('ALMSIVI_TURN',{status='failed',reason=reason})"]))
check("native session handshake is pumped before cursored event polling", all(fragment in global_script for fragment in [
    "if not session and bridge.pollResults then", "bridge.pollResults(8)",
    "session=bridge.sessionInfo and bridge.sessionInfo()",
    "if state.events then orchestrator.poll(state) end"]))
check("Follower Detection Util remains an optional bounded context provider", all(fragment in adapter_script for fragment in [
    "modules.interfaces.FollowerDetectionUtil", "type(fdu.getFollowerList)~='function'", "if #result>=32 then break end",
    "follower_detection=followerProvider and followerProvider.provider or 'unavailable'"]))
check("OpenMW content files are copied into serializable event data", all(fragment in adapter_script for fragment in [
    "local contentFiles={}", "for index,name in ipairs(loadedFiles) do contentFiles[index]=name end",
    "contentFiles=contentFiles"]) and "contentFiles=modules.core and modules.core.contentFiles" not in adapter_script)
check("live aimed actor preview is physics-only and distinct from committed target", all(fragment in player_script for fragment in [
    "aimCandidate and aimCandidate.distance<=maxDistance", "adapter.resolveActorRay(2048)",
    "local reason=candidate and 'live_aim_preview' or nil"]) and all(fragment in adapter_script for fragment in [
    "function M.resolveActorRay(maxDistance, modules)", "function M.actorDistance(targetIdentity, modules)"]))
check("guessed UI and targeting constants absent", all(name not in constants for name in ["MAX_TEXT_BYTES", "MAX_TRANSCRIPT", "MAX_NEARBY_PICKER", "MAX_TARGET_DISTANCE"]))
check("Lua tests reject 191 193 and noninteger follow", all(fragment in text(SCRIPTS / "tests" / "run.lua") for fragment in ["distance=191", "distance=193", "distance=192.5"]))
check("pure Lua runner present", (SCRIPTS / "tests" / "run.lua").is_file())
deploy_script = text(DEPLOY)
check("compatibility launcher keeps third-party mods out of the clean profile", all(fragment in deploy_script for fragment in [
    "Profiles\\Compatibility", "Play-ALMSIVI-Compatibility.cmd", "Manage-ALMSIVI-Compatibility-Mods.cmd", "& $engine --config $profile",
    "currentprofile=ALMSIVI Compatibility", "firstrun=false", "user-data=.",
    "content=DynamicCamera.omwscripts", "content=FollowerDetectionUtil.omwscripts", "content=H3lp Yours3lf.esp"]))
profile_manager = text(PROFILE_MANAGER)
check("native OpenMW profile manager preserves settings and backs up before save", all(fragment in profile_manager for fragment in [
    "Where-Object { $_ -notmatch '^\\s*(data|content)\\s*=' }", "Copy-Item -LiteralPath $profilePath -Destination $backup",
    "[IO.File]::WriteAllLines($profilePath", "[Text.UTF8Encoding]::new($false)"]))
check("native OpenMW profile manager supports all engine content types and ordered data folders", all(fragment in profile_manager for fragment in [
    "'.esm', '.esp', '.omwgame', '.omwaddon', '.omwscripts'", "Move mod up", "Move content up",
    "Get-AvailableContent", "Open OpenMW Launcher", "[switch]$Validate", "function Rescan-Mods", "Refresh mods",
    "function Show-ModConflicts", "Later enabled folders win", "Show file conflicts"]))
check("mod-manager launcher starts the private ALMSIVI runtime before OpenMW", all(fragment in profile_manager for fragment in [
    "function Start-AlmsiviServices", "$env:ALMSIVI_CLIENT_CONFIG = $clientConfigPath",
    "service almsiviserver-worker start", "almsivi.health.v1"]) and all(fragment in deploy_script for fragment in [
    "Manage-ALMSIVI-Mods.cmd", "service almsiviserver-worker start", "ALMSIVI_CLIENT_CONFIG=%~dp0Config\\almsivi-client.conf"]))
check("client deployment refreshes every tracked OpenMW overlay before compiling", all(fragment in deploy_script for fragment in [
    "function Sync-OpenMwOverlay", "git -C $repoRoot ls-files -- 'openmw-patches/overlay'",
    "Sync-OpenMwOverlay -Destination $EngineSource"]))
check("deploy installs the ALMSIVI profile manager instead of the limited launcher wrapper", all(fragment in deploy_script for fragment in [
    "scripts\\tools\\manage-openmw-profile.ps1", "Manage-ALMSIVI-Profile.ps1", "-ProfileName Compatibility",
    "extracting it into its own Mods\\Mod Name folder"]))
print(f"{len(failures)} failures (structural fallback; Lua interpreter unavailable)")
sys.exit(bool(failures))
