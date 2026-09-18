local input = require('openmw.input')
local storage = require('openmw.storage')
local I = require('openmw.interfaces')
local nativeOk,native = pcall(require,'openmw.lorkhan')

local PAGE_KEY = 'LORKHAN'
local HOTKEY_GROUP_KEY = 'SettingsLORKHANControls'
local AUTO_GROUP_KEY = 'SettingsLORKHANAutoActivate'
local BEHAVIOR_GROUP_KEY = 'SettingsLORKHANBehavior'
local SOUND_GROUP_KEY = 'SettingsLORKHANSound'
local AGENTS_GROUP_KEY = 'SettingsLORKHANAgents'
local TOOLS_GROUP_KEY = 'SettingsLORKHANPresentation'
local DEFAULTS_SECTION = 'LORKHANInputDefaults'
local LAYOUT_MIGRATION_SECTION = 'LORKHANSettingsLayout'
local DEFAULTS_VERSION = 7

local behaviorSection = storage.playerSection(BEHAVIOR_GROUP_KEY)
local recordingDeviceId = math.floor(tonumber(behaviorSection:get('recordingDevice')) or -1)
local recordingDeviceMax = 31
local recordingDeviceName = 'Windows default'
if nativeOk and native.currentVoiceCaptureDeviceName then
    local called,name=pcall(native.currentVoiceCaptureDeviceName,recordingDeviceId)
    if called and type(name)=='string' and name~='' then recordingDeviceName=name end
end
if nativeOk and native.voiceCaptureDevices then
    local called,devices=pcall(native.voiceCaptureDevices)
    if called and type(devices)=='table' and #devices>1 then recordingDeviceMax=#devices-2 end
end

-- Bindings the Hotkeys list no longer shows still resolve here: their triggers stay registered so
-- already-saved user bindings keep working, and the controls themselves live in the Interact menu.
local bindings = {
    talk = 'LORKHAN_Talk_Binding',
    pushToTalk = 'LORKHAN_PushToTalk_Binding',
    stopDialogue = 'LORKHAN_StopDialogue_Binding',
    halt = 'LORKHAN_Halt_Binding',
    openMic = 'LORKHAN_OpenMic_Binding',
    openMicMute = 'LORKHAN_OpenMicMute_Binding',
    manualActivate = 'LORKHAN_ManualActivate_Binding',
    actorTools = 'LORKHAN_ActionsMenu_Binding',
    masterMenu = 'LORKHAN_MasterMenu_Binding',
    modeMenu = 'LORKHAN_ToggleMode_Binding',
    modelMenu = 'LORKHAN_ModelMenu_Binding',
    profileMenu = 'LORKHAN_ProfileMenu_Binding',
    statusHud = 'LORKHAN_StatusHud_Binding',
    history = 'LORKHAN_History_Binding',
    diagnostics = 'LORKHAN_Diagnostics_Binding',
}

local function trigger(key,name,description)
    input.registerTrigger({key=key,l10n='LORKHAN',name=name,description=description})
end

trigger('LORKHAN_Talk','Talk_name','Talk_description')
trigger('LORKHAN_StopDialogue','StopDialogue_name','StopDialogue_description')
trigger('LORKHAN_Halt','Halt_name','Halt_description')
trigger('LORKHAN_OpenMic','OpenMic_name','OpenMic_description')
trigger('LORKHAN_OpenMicMute','OpenMicMute_name','OpenMicMute_description')
trigger('LORKHAN_ManualActivate','ManualActivate_name','ManualActivate_description')
trigger('LORKHAN_ActionsMenu','ActorTools_name','ActorTools_description')
trigger('LORKHAN_MasterMenu','ActorTools_name','ActorTools_description')
-- Legacy triggers for controls that moved into Interact. Registered, but intentionally absent from
-- the visible Hotkeys list so Interact is the single discoverable entry point.
trigger('LORKHAN_ToggleMode','ModeMenu_name','ModeMenu_description')
trigger('LORKHAN_ModelMenu','ModelMenu_name','ModelMenu_description')
trigger('LORKHAN_ProfileMenu','ProfileMenu_name','ProfileMenu_description')
trigger('LORKHAN_StatusHud','StatusHud_name','StatusHud_description')
trigger('LORKHAN_History','History_name','History_description')
trigger('LORKHAN_Diagnostics','Diagnostics_name','Diagnostics_description')
input.registerAction({key='LORKHAN_PushToTalk',l10n='LORKHAN',name='PushToTalk_name',
    description='PushToTalk_description',type=input.ACTION_TYPE.Boolean,defaultValue=false})

I.Settings.registerPage({
    key=PAGE_KEY,
    l10n='LORKHAN',
    name='SettingsPage_name',
    description='SettingsPage_description',
})

I.Settings.registerGroup({
    key=HOTKEY_GROUP_KEY,page=PAGE_KEY,l10n='LORKHAN',name='HotkeysGroup_name',
    description='HotkeysGroup_description',permanentStorage=true,order=0,
    settings={
        {key='TalkBinding',renderer='lorkhanBinding',default=bindings.talk,
            name='Talk_name',description='Talk_description',argument={type='trigger',key='LORKHAN_Talk'}},
        {key='PushToTalkBinding',renderer='lorkhanBinding',default=bindings.pushToTalk,
            name='PushToTalk_name',description='PushToTalk_description',argument={type='action',key='LORKHAN_PushToTalk'}},
        {key='OpenMicMuteBinding',renderer='lorkhanBinding',default=bindings.openMicMute,
            name='OpenMicMute_name',description='OpenMicMute_description',argument={type='trigger',key='LORKHAN_OpenMicMute'}},
        {key='HaltBinding',renderer='lorkhanBinding',default=bindings.halt,
            name='Halt_name',description='Halt_description',argument={type='trigger',key='LORKHAN_Halt'}},
        {key='ManualActivateBinding',renderer='lorkhanBinding',default=bindings.manualActivate,
            name='ManualActivate_name',description='ManualActivate_description',argument={type='trigger',key='LORKHAN_ManualActivate'}},
        -- Dialogue mode, LLM model, dynamic profiles, context history, status HUD, and diagnostics
        -- are reached from the Interact menu, so they are deliberately not listed here.
    },
})

I.Settings.registerGroup({
    key=AUTO_GROUP_KEY,page=PAGE_KEY,l10n='LORKHAN',name='AutoActivateGroup_name',
    description='AutoActivateGroup_description',permanentStorage=true,order=1,
    settings={
        {key='enabled',renderer='checkbox',default=true,name='AutoActivateEnabled_name',description='AutoActivateEnabled_description'},
        {key='interiorDistance',renderer='number',default=1200,name='InteriorDistance_name',description='InteriorDistance_description',argument={integer=true,min=128,max=8192}},
        {key='exteriorDistance',renderer='number',default=2400,name='ExteriorDistance_name',description='ExteriorDistance_description',argument={integer=true,min=128,max=16384}},
        {key='hearingPreset',renderer='select',default='Nearby',name='HearingPreset_name',description='HearingPreset_description',argument={l10n='LORKHAN',items={'TargetsOnly','Nearby','Wide'}}},
        {key='interiorHearingDistance',renderer='number',default=500,name='InteriorHearingDistance_name',description='InteriorHearingDistance_description',argument={integer=true,min=128,max=8192}},
        {key='exteriorHearingDistance',renderer='number',default=1000,name='ExteriorHearingDistance_name',description='ExteriorHearingDistance_description',argument={integer=true,min=128,max=16384}},
        {key='addHostile',renderer='checkbox',default=false,name='AddHostile_name',description='AddHostile_description'},
        {key='addCreatures',renderer='checkbox',default=false,name='AddCreatures_name',description='AddCreatures_description'},
    },
})

I.Settings.registerGroup({
    key=BEHAVIOR_GROUP_KEY,page=PAGE_KEY,l10n='LORKHAN',name='BehaviorGroup_name',
    description='BehaviorGroup_description',permanentStorage=true,order=2,
    settings={
        {key='allowCombatDialogue',renderer='checkbox',default=true,name='AllowCombatDialogue_name',description='AllowCombatDialogue_description'},
        {key='combatBarksMode',renderer='select',default='UseProfile',name='CombatBarks_name',description='CombatBarks_description',argument={l10n='LORKHAN',items={'UseProfile','Enabled','Disabled'}}},
        {key='combatBarkInterval',renderer='number',default=30,name='CombatBarkPeriod_name',description='CombatBarkPeriod_description',argument={integer=true,min=5,max=120}},
        {key='cancelDialogueOnCombat',renderer='checkbox',default=true,name='CancelDialogueOnCombat_name',description='CancelDialogueOnCombat_description'},
        {key='openMicEnabled',renderer='checkbox',default=false,name='OpenMicEnabled_name',description='OpenMicEnabled_description'},
        {key='openMicSensitivity',renderer='number',default=1000,name='OpenMicSensitivity_name',description='OpenMicSensitivity_description',argument={integer=true,min=100,max=5000}},
        {key='openMicEndDelayMs',renderer='number',default=1000,name='OpenMicEndDelay_name',description='OpenMicEndDelay_description',argument={integer=true,min=500,max=5000}},
        {key='recordingDeviceName',renderer='textLine',default=recordingDeviceName,name='CurrentRecordingDevice_name',description='CurrentRecordingDevice_description',argument={disabled=true}},
        {key='recordingDevice',renderer='number',default=-1,name='RecordingDevice_name',description='RecordingDevice_description',argument={integer=true,min=-1,max=recordingDeviceMax}},
    },
})

behaviorSection:set('recordingDeviceName',recordingDeviceName)

I.Settings.registerGroup({
    key=SOUND_GROUP_KEY,page=PAGE_KEY,l10n='LORKHAN',name='SoundGroup_name',
    description='SoundGroup_description',permanentStorage=true,order=3,
    settings={
        {key='voice_volume_percent',renderer='number',default=100,name='voice_volume_percent_name',description='voice_volume_percent_description',argument={integer=true,min=0,max=500}},
        {key='audio_mode',renderer='select',default='Normal3D',name='audio_mode_name',description='audio_mode_description',argument={l10n='LORKHAN',items={'Flat3D','Normal3D','Realistic3D','Mono','MonoEffects'}}},
        {key='head_voice_volume_percent',renderer='number',default=100,name='head_voice_volume_percent_name',description='head_voice_volume_percent_description',argument={integer=true,min=0,max=200}},
        {key='distance_scale',renderer='number',default=1,name='distance_scale_name',description='distance_scale_description',argument={integer=false,min=0.1,max=20}},
        {key='dropoff_inside_percent',renderer='number',default=70,name='dropoff_inside_percent_name',description='dropoff_inside_percent_description',argument={integer=true,min=25,max=200}},
        {key='dropoff_outside_percent',renderer='number',default=70,name='dropoff_outside_percent_name',description='dropoff_outside_percent_description',argument={integer=true,min=25,max=200}},
        {key='legacy_distance_scale',renderer='number',default=1,name='legacy_distance_scale_name',description='legacy_distance_scale_description',argument={integer=false,min=0,max=4}},
        {key='clip_start_ms',renderer='number',default=0,name='clip_start_ms_name',description='clip_start_ms_description',argument={integer=true,min=0,max=100}},
        {key='clip_end_ms',renderer='number',default=0,name='clip_end_ms_name',description='clip_end_ms_description',argument={integer=true,min=0,max=2000}},
        {key='lip_intensity',renderer='number',default=1,name='lip_intensity_name',description='lip_intensity_description',argument={integer=false,min=0.1,max=2}},
        {key='lip_resolution_ms',renderer='number',default=0,name='lip_resolution_ms_name',description='lip_resolution_ms_description',argument={integer=true,min=0,max=1000}},
        {key='camera_based_audio',renderer='checkbox',default=true,name='camera_based_audio_name',description='camera_based_audio_description'},
        {key='invert_heading',renderer='checkbox',default=false,name='invert_heading_name',description='invert_heading_description'},
        {key='pause_on_game_pause',renderer='checkbox',default=false,name='pause_on_game_pause_name',description='pause_on_game_pause_description'},
        {key='menuDialogueTts',renderer='checkbox',default=true,name='MenuDialogueTts_name',description='MenuDialogueTts_description'},
        {key='bookReadAloud',renderer='checkbox',default=false,name='BookReadAloud_name',description='BookReadAloud_description'},
    },
})

I.Settings.registerGroup({
    key=AGENTS_GROUP_KEY,page=PAGE_KEY,l10n='LORKHAN',name='AgentsGroup_name',
    description='AgentsGroup_description',permanentStorage=true,order=4,
    settings={
        {key='actionsEnabled',renderer='checkbox',default=true,name='ActionsEnabled_name',description='ActionsEnabled_description'},
    },
})

I.Settings.registerGroup({
    key=TOOLS_GROUP_KEY,page=PAGE_KEY,l10n='LORKHAN',name='ToolsGroup_name',
    description='ToolsGroup_description',permanentStorage=true,order=5,
    settings={
        {key='showStatusHud',renderer='checkbox',default=false,name='ShowStatusHud_name',description='ShowStatusHud_description'},
        {key='connectionTimeoutSeconds',renderer='number',default=30,name='ConnectionTimeout_name',description='ConnectionTimeout_description',argument={integer=true,min=15,max=300}},
        {key='transcriptRows',renderer='number',default=12,name='TranscriptRows_name',description='TranscriptRows_description',argument={integer=true,min=4,max=64}},
    },
})

local migration=storage.playerSection(LAYOUT_MIGRATION_SECTION)
if (tonumber(migration:get('version')) or 0)<1 then
    local legacyBehavior=storage.playerSection(BEHAVIOR_GROUP_KEY)
    local legacyPresentation=storage.playerSection(TOOLS_GROUP_KEY)
    local agents=storage.playerSection(AGENTS_GROUP_KEY)
    local sound=storage.playerSection(SOUND_GROUP_KEY)
    local actionsEnabled=legacyBehavior:get('actionsEnabled')
    local ttsVolumeBoost=legacyPresentation:get('ttsVolumeBoost')
    if actionsEnabled~=nil then agents:set('actionsEnabled',actionsEnabled) end
    if ttsVolumeBoost~=nil then sound:set('ttsVolumeBoost',ttsVolumeBoost) end
    migration:set('version',1)
end

-- Seed only the two discoverability-critical controls on new installs. Existing F8/F9
-- assignments and every user rebind remain untouched.
local bindingSection = storage.playerSection('OMWInputBindings')
local defaultsSection = storage.playerSection(DEFAULTS_SECTION)
local defaultsVersion=defaultsSection:get('version') == nil and 0
    or tonumber(defaultsSection:get('version')) or 0
if defaultsVersion<1 then
    if bindingSection:get(bindings.talk) == nil then
        bindingSection:set(bindings.talk,{device='keyboard',button=input.KEY.F6,type='trigger',key='LORKHAN_Talk'})
    end
    if bindingSection:get(bindings.halt) == nil then
        bindingSection:set(bindings.halt,{device='keyboard',button=input.KEY.F7,type='trigger',key='LORKHAN_Halt'})
    end
end
if defaultsVersion<DEFAULTS_VERSION then defaultsSection:set('version',DEFAULTS_VERSION) end

-- OpenMW settings are registered through side effects; returning product metadata creates
-- unsupported script sections and can prevent reliable input setup.
return {}
