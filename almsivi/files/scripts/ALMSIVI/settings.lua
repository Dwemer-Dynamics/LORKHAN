local input = require('openmw.input')
local storage = require('openmw.storage')
local I = require('openmw.interfaces')

local PAGE_KEY = 'ALMSIVI'
local GROUP_KEY = 'SettingsALMSIVIControls'
local AUTO_GROUP_KEY = 'SettingsALMSIVIAutoActivate'
local BEHAVIOR_GROUP_KEY = 'SettingsALMSIVIBehavior'
local PRESENTATION_GROUP_KEY = 'SettingsALMSIVIPresentation'
local DEFAULTS_SECTION = 'ALMSIVIInputDefaults'
local DEFAULTS_VERSION = 3

local bindings = {
    talk = 'ALMSIVI_Talk_Binding',
    stopDialogue = 'ALMSIVI_StopDialogue_Binding',
    halt = 'ALMSIVI_Halt_Binding',
    pushToTalk = 'ALMSIVI_PushToTalk_Binding',
    openMic = 'ALMSIVI_OpenMic_Binding',
    openMicMute = 'ALMSIVI_OpenMicMute_Binding',
    manualActivate = 'ALMSIVI_ManualActivate_Binding',
    actionsMenu = 'ALMSIVI_ActionsMenu_Binding',
    masterMenu = 'ALMSIVI_MasterMenu_Binding',
    toggleMode = 'ALMSIVI_ToggleMode_Binding',
    statusHud = 'ALMSIVI_StatusHud_Binding',
    history = 'ALMSIVI_History_Binding',
    diagnostics = 'ALMSIVI_Diagnostics_Binding',
}

input.registerTrigger({key='ALMSIVI_Talk',l10n='ALMSIVI',name='Talk_name',description='Talk_description'})
input.registerTrigger({key='ALMSIVI_StopDialogue',l10n='ALMSIVI',name='StopDialogue_name',description='StopDialogue_description'})
input.registerTrigger({key='ALMSIVI_Halt',l10n='ALMSIVI',name='Halt_name',description='Halt_description'})
input.registerTrigger({key='ALMSIVI_OpenMic',l10n='ALMSIVI',name='OpenMic_name',description='OpenMic_description'})
input.registerTrigger({key='ALMSIVI_OpenMicMute',l10n='ALMSIVI',name='OpenMicMute_name',description='OpenMicMute_description'})
input.registerTrigger({key='ALMSIVI_ManualActivate',l10n='ALMSIVI',name='ManualActivate_name',description='ManualActivate_description'})
input.registerTrigger({key='ALMSIVI_ActionsMenu',l10n='ALMSIVI',name='ActionsMenu_name',description='ActionsMenu_description'})
input.registerTrigger({key='ALMSIVI_MasterMenu',l10n='ALMSIVI',name='MasterMenu_name',description='MasterMenu_description'})
input.registerTrigger({key='ALMSIVI_ToggleMode',l10n='ALMSIVI',name='ToggleMode_name',description='ToggleMode_description'})
input.registerTrigger({key='ALMSIVI_StatusHud',l10n='ALMSIVI',name='StatusHud_name',description='StatusHud_description'})
input.registerTrigger({key='ALMSIVI_History',l10n='ALMSIVI',name='History_name',description='History_description'})
input.registerTrigger({key='ALMSIVI_Diagnostics',l10n='ALMSIVI',name='Diagnostics_name',description='Diagnostics_description'})
input.registerAction({key='ALMSIVI_PushToTalk',l10n='ALMSIVI',name='PushToTalk_name',
    description='PushToTalk_description',type=input.ACTION_TYPE.Boolean,defaultValue=false})

I.Settings.registerPage({
    key=PAGE_KEY,
    l10n='ALMSIVI',
    name='SettingsPage_name',
    description='SettingsPage_description',
})

I.Settings.registerGroup({
    key=GROUP_KEY,
    page=PAGE_KEY,
    l10n='ALMSIVI',
    name='ControlsGroup_name',
    description='ControlsGroup_description',
    permanentStorage=true,
    settings={
        {key='TalkBinding',renderer='inputBinding',default=bindings.talk,
            name='Talk_name',description='Talk_description',
            argument={type='trigger',key='ALMSIVI_Talk'}},
        {key='StopDialogueBinding',renderer='inputBinding',default=bindings.stopDialogue,
            name='StopDialogue_name',description='StopDialogue_description',
            argument={type='trigger',key='ALMSIVI_StopDialogue'}},
        {key='HaltBinding',renderer='inputBinding',default=bindings.halt,
            name='Halt_name',description='Halt_description',
            argument={type='trigger',key='ALMSIVI_Halt'}},
        {key='PushToTalkBinding',renderer='inputBinding',default=bindings.pushToTalk,
            name='PushToTalk_name',description='PushToTalk_description',
            argument={type='action',key='ALMSIVI_PushToTalk'}},
        {key='OpenMicBinding',renderer='inputBinding',default=bindings.openMic,
            name='OpenMic_name',description='OpenMic_description',
            argument={type='trigger',key='ALMSIVI_OpenMic'}},
        {key='OpenMicMuteBinding',renderer='inputBinding',default=bindings.openMicMute,
            name='OpenMicMute_name',description='OpenMicMute_description',
            argument={type='trigger',key='ALMSIVI_OpenMicMute'}},
        {key='ManualActivateBinding',renderer='inputBinding',default=bindings.manualActivate,
            name='ManualActivate_name',description='ManualActivate_description',
            argument={type='trigger',key='ALMSIVI_ManualActivate'}},
        {key='ActionsMenuBinding',renderer='inputBinding',default=bindings.actionsMenu,
            name='ActionsMenu_name',description='ActionsMenu_description',
            argument={type='trigger',key='ALMSIVI_ActionsMenu'}},
        {key='MasterMenuBinding',renderer='inputBinding',default=bindings.masterMenu,
            name='MasterMenu_name',description='MasterMenu_description',
            argument={type='trigger',key='ALMSIVI_MasterMenu'}},
        {key='ToggleModeBinding',renderer='inputBinding',default=bindings.toggleMode,
            name='ToggleMode_name',description='ToggleMode_description',
            argument={type='trigger',key='ALMSIVI_ToggleMode'}},
        {key='StatusHudBinding',renderer='inputBinding',default=bindings.statusHud,
            name='StatusHud_name',description='StatusHud_description',
            argument={type='trigger',key='ALMSIVI_StatusHud'}},
        {key='HistoryBinding',renderer='inputBinding',default=bindings.history,
            name='History_name',description='History_description',
            argument={type='trigger',key='ALMSIVI_History'}},
        {key='DiagnosticsBinding',renderer='inputBinding',default=bindings.diagnostics,
            name='Diagnostics_name',description='Diagnostics_description',
            argument={type='trigger',key='ALMSIVI_Diagnostics'}},
    },
})

I.Settings.registerGroup({
    key=AUTO_GROUP_KEY,page=PAGE_KEY,l10n='ALMSIVI',name='AutoActivateGroup_name',
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
    key=BEHAVIOR_GROUP_KEY,page=PAGE_KEY,l10n='ALMSIVI',name='BehaviorGroup_name',
    description='BehaviorGroup_description',permanentStorage=true,order=2,
    settings={
        {key='actionsEnabled',renderer='checkbox',default=true,name='ActionsEnabled_name',description='ActionsEnabled_description'},
        {key='autoGreeting',renderer='checkbox',default=false,name='AutoGreeting_name',description='AutoGreeting_description'},
        {key='rechat',renderer='checkbox',default=false,name='Rechat_name',description='Rechat_description'},
        {key='rechatDelaySeconds',renderer='number',default=45,name='RechatDelay_name',description='RechatDelay_description',argument={integer=true,min=15,max=3600}},
        {key='rechatMaxDepth',renderer='number',default=10,name='RechatMaxDepth_name',description='RechatMaxDepth_description',argument={integer=true,min=1,max=10}},
        {key='boredom',renderer='checkbox',default=false,name='Boredom_name',description='Boredom_description'},
        {key='boredomDelaySeconds',renderer='number',default=180,name='BoredomDelay_name',description='BoredomDelay_description',argument={integer=true,min=30,max=7200}},
        {key='avoidAutonomyInMenus',renderer='checkbox',default=true,name='AvoidAutonomyInMenus_name',description='AvoidAutonomyInMenus_description'},
        {key='avoidAutonomyInCombat',renderer='checkbox',default=true,name='AvoidAutonomyInCombat_name',description='AvoidAutonomyInCombat_description'},
        {key='avoidAutonomyWhenSneaking',renderer='checkbox',default=true,name='AvoidAutonomyWhenSneaking_name',description='AvoidAutonomyWhenSneaking_description'},
        {key='cancelDialogueOnCombat',renderer='checkbox',default=true,name='CancelDialogueOnCombat_name',description='CancelDialogueOnCombat_description'},
        {key='combatBarks',renderer='checkbox',default=true,name='CombatBarks_name',description='CombatBarks_description'},
        {key='combatBarkPeriodSeconds',renderer='number',default=30,name='CombatBarkPeriod_name',description='CombatBarkPeriod_description',argument={integer=true,min=10,max=300}},
        {key='openMicSensitivity',renderer='number',default=1000,name='OpenMicSensitivity_name',description='OpenMicSensitivity_description',argument={integer=true,min=100,max=5000}},
        {key='openMicEndDelayMs',renderer='number',default=1000,name='OpenMicEndDelay_name',description='OpenMicEndDelay_description',argument={integer=true,min=500,max=5000}},
    },
})

I.Settings.registerGroup({
    key=PRESENTATION_GROUP_KEY,page=PAGE_KEY,l10n='ALMSIVI',name='PresentationGroup_name',
    description='PresentationGroup_description',permanentStorage=true,order=3,
    settings={
        {key='showStatusHud',renderer='checkbox',default=true,name='ShowStatusHud_name',description='ShowStatusHud_description'},
        {key='transcriptRows',renderer='number',default=12,name='TranscriptRows_name',description='TranscriptRows_description',argument={integer=true,min=4,max=64}},
        {key='ttsVolumeBoost',renderer='number',default=3,name='TtsVolumeBoost_name',description='TtsVolumeBoost_description',argument={integer=true,min=1,max=4}},
    },
})

-- Seed conflict-free controls once, then leave cleared or rebound controls untouched.
local bindingSection = storage.playerSection('OMWInputBindings')
local defaultsSection = storage.playerSection(DEFAULTS_SECTION)
local defaultsVersion=defaultsSection:get('version') == nil and 0
    or tonumber(defaultsSection:get('version')) or 0
if defaultsVersion<1 then
    if bindingSection:get(bindings.talk) == nil then
        bindingSection:set(bindings.talk,
            {device='keyboard',button=input.KEY.F6,type='trigger',key='ALMSIVI_Talk'})
    end
    if bindingSection:get(bindings.halt) == nil then
        bindingSection:set(bindings.halt,
            {device='keyboard',button=input.KEY.F7,type='trigger',key='ALMSIVI_Halt'})
    end
end
if defaultsVersion<2 then
    if bindingSection:get(bindings.actionsMenu) == nil then
        bindingSection:set(bindings.actionsMenu,
            {device='keyboard',button=input.KEY.F8,type='trigger',key='ALMSIVI_ActionsMenu'})
    end
end
if defaultsVersion<3 then
    if bindingSection:get(bindings.masterMenu) == nil then
        bindingSection:set(bindings.masterMenu,
            {device='keyboard',button=input.KEY.F9,type='trigger',key='ALMSIVI_MasterMenu'})
    end
end
if defaultsVersion<DEFAULTS_VERSION then
    defaultsSection:set('version',DEFAULTS_VERSION)
end

-- OpenMW script entrypoints may return only documented handler/interface sections. Settings are
-- registered through side effects above, so returning product metadata here only creates runtime
-- "Not supported section" errors and can prevent reliable input setup.
return {}
