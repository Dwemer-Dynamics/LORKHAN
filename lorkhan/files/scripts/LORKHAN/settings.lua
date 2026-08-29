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
        {key='TalkBinding',renderer='inputBinding',default=bindings.talk,
            name='Talk_name',description='Talk_description',argument={type='trigger',key='LORKHAN_Talk'}},
        {key='StopDialogueBinding',renderer='inputBinding',default=bindings.stopDialogue,
            name='StopDialogue_name',description='StopDialogue_description',argument={type='trigger',key='LORKHAN_StopDialogue'}},
        {key='ManualActivateBinding',renderer='inputBinding',default=bindings.manualActivate,
            name='ManualActivate_name',description='ManualActivate_description',argument={type='trigger',key='LORKHAN_ManualActivate'}},
        {key='ModeMenuBinding',renderer='inputBinding',default=bindings.modeMenu,
            name='ModeMenu_name',description='ModeMenu_description',argument={type='trigger',key='LORKHAN_ToggleMode'}},
        {key='ModelMenuBinding',renderer='inputBinding',default=bindings.modelMenu,
            name='ModelMenu_name',description='ModelMenu_description',argument={type='trigger',key='LORKHAN_ModelMenu'}},
        {key='ProfileMenuBinding',renderer='inputBinding',default=bindings.profileMenu,
            name='ProfileMenu_name',description='ProfileMenu_description',argument={type='trigger',key='LORKHAN_ProfileMenu'}},
        {key='HaltBinding',renderer='inputBinding',default=bindings.halt,
            name='Halt_name',description='Halt_description',argument={type='trigger',key='LORKHAN_Halt'}},
        {key='PushToTalkBinding',renderer='inputBinding',default=bindings.pushToTalk,
            name='PushToTalk_name',description='PushToTalk_description',argument={type='action',key='LORKHAN_PushToTalk'}},
        {key='OpenMicBinding',renderer='inputBinding',default=bindings.openMic,
            name='OpenMic_name',description='OpenMic_description',argument={type='trigger',key='LORKHAN_OpenMic'}},
        {key='OpenMicMuteBinding',renderer='inputBinding',default=bindings.openMicMute,
            name='OpenMicMute_name',description='OpenMicMute_description',argument={type='trigger',key='LORKHAN_OpenMicMute'}},
        {key='ActorToolsBinding',renderer='inputBinding',default=bindings.actorTools,
            name='ActorTools_name',description='ActorTools_description',argument={type='trigger',key='LORKHAN_ActionsMenu'}},
        {key='StatusHudBinding',renderer='inputBinding',default=bindings.statusHud,
            name='StatusHud_name',description='StatusHud_description',argument={type='trigger',key='LORKHAN_StatusHud'}},
        {key='HistoryBinding',renderer='inputBinding',default=bindings.history,
            name='History_name',description='History_description',argument={type='trigger',key='LORKHAN_History'}},
        {key='DiagnosticsBinding',renderer='inputBinding',default=bindings.diagnostics,
            name='Diagnostics_name',description='Diagnostics_description',argument={type='trigger',key='LORKHAN_Diagnostics'}},
    },
})

I.Settings.registerGroup({
    key=AUTO_GROUP_KEY,page=PAGE_KEY,l10n='LORKHAN',name='AutoActivateGroup_name',
    description='AutoActivateGroup_description',permanentStorage=true,order=1,
    settings={
        {key='enabled',renderer='checkbox',default=true,name='AutoActivateEnabled_name',description='AutoActivateEnabled_description'},
        {key='interiorDistance',renderer='number',default=1200,name='InteriorDistance_name',description='InteriorDistance_description',argument={integer=true,min=128,max=8192}},
        {key='exteriorDistance',renderer='number',default=2400,name='ExteriorDistance_name',description='ExteriorDistance_description',argument={integer=true,min=128,max=16384}},
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
        {key='cancelDialogueOnCombat',renderer='checkbox',default=true,name='CancelDialogueOnCombat_name',description='CancelDialogueOnCombat_description'},
        {key='openMicSensitivity',renderer='number',default=700,name='OpenMicSensitivity_name',description='OpenMicSensitivity_description',argument={integer=true,min=100,max=5000}},
        {key='openMicEndDelayMs',renderer='number',default=900,name='OpenMicEndDelay_name',description='OpenMicEndDelay_description',argument={integer=true,min=500,max=5000}},
        {key='recordingDevice',renderer='number',default=-1,name='RecordingDevice_name',description='RecordingDevice_description',argument={integer=true,min=-1,max=recordingDeviceMax}},
        {key='recordingDeviceName',renderer='textLine',default=recordingDeviceName,name='CurrentRecordingDevice_name',description='CurrentRecordingDevice_description',argument={disabled=true}},
    },
})

behaviorSection:set('recordingDeviceName',recordingDeviceName)

I.Settings.registerGroup({
    key=SOUND_GROUP_KEY,page=PAGE_KEY,l10n='LORKHAN',name='SoundGroup_name',
    description='SoundGroup_description',permanentStorage=true,order=3,
    settings={
        {key='ttsVolumeBoost',renderer='number',default=3,name='TtsVolumeBoost_name',description='TtsVolumeBoost_description',argument={integer=true,min=1,max=4}},
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
