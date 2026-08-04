local input = require('openmw.input')
local storage = require('openmw.storage')
local I = require('openmw.interfaces')

local PAGE_KEY = 'ALMSIVI'
local HOTKEY_GROUP_KEY = 'SettingsALMSIVIControls'
local AUTO_GROUP_KEY = 'SettingsALMSIVIAutoActivate'
local BEHAVIOR_GROUP_KEY = 'SettingsALMSIVIBehavior'
local SOUND_GROUP_KEY = 'SettingsALMSIVISound'
local AGENTS_GROUP_KEY = 'SettingsALMSIVIAgents'
local TOOLS_GROUP_KEY = 'SettingsALMSIVIPresentation'
local DEFAULTS_SECTION = 'ALMSIVIInputDefaults'
local LAYOUT_MIGRATION_SECTION = 'ALMSIVISettingsLayout'
local DEFAULTS_VERSION = 4

local bindings = {
    talk = 'ALMSIVI_Talk_Binding',
    stopDialogue = 'ALMSIVI_StopDialogue_Binding',
    halt = 'ALMSIVI_Halt_Binding',
    pushToTalk = 'ALMSIVI_PushToTalk_Binding',
    openMic = 'ALMSIVI_OpenMic_Binding',
    openMicMute = 'ALMSIVI_OpenMicMute_Binding',
    manualActivate = 'ALMSIVI_ManualActivate_Binding',
    actorTools = 'ALMSIVI_ActionsMenu_Binding',
    masterMenu = 'ALMSIVI_MasterMenu_Binding',
    modeMenu = 'ALMSIVI_ToggleMode_Binding',
    modelMenu = 'ALMSIVI_ModelMenu_Binding',
    profileMenu = 'ALMSIVI_ProfileMenu_Binding',
    statusHud = 'ALMSIVI_StatusHud_Binding',
    history = 'ALMSIVI_History_Binding',
    diagnostics = 'ALMSIVI_Diagnostics_Binding',
}

local function trigger(key,name,description)
    input.registerTrigger({key=key,l10n='ALMSIVI',name=name,description=description})
end

trigger('ALMSIVI_Talk','Talk_name','Talk_description')
trigger('ALMSIVI_StopDialogue','StopDialogue_name','StopDialogue_description')
trigger('ALMSIVI_Halt','Halt_name','Halt_description')
trigger('ALMSIVI_OpenMic','OpenMic_name','OpenMic_description')
trigger('ALMSIVI_OpenMicMute','OpenMicMute_name','OpenMicMute_description')
trigger('ALMSIVI_ManualActivate','ManualActivate_name','ManualActivate_description')
trigger('ALMSIVI_ActionsMenu','ActorTools_name','ActorTools_description')
trigger('ALMSIVI_MasterMenu','ActorTools_name','ActorTools_description')
trigger('ALMSIVI_ToggleMode','ModeMenu_name','ModeMenu_description')
trigger('ALMSIVI_ModelMenu','ModelMenu_name','ModelMenu_description')
trigger('ALMSIVI_ProfileMenu','ProfileMenu_name','ProfileMenu_description')
trigger('ALMSIVI_StatusHud','StatusHud_name','StatusHud_description')
trigger('ALMSIVI_History','History_name','History_description')
trigger('ALMSIVI_Diagnostics','Diagnostics_name','Diagnostics_description')
input.registerAction({key='ALMSIVI_PushToTalk',l10n='ALMSIVI',name='PushToTalk_name',
    description='PushToTalk_description',type=input.ACTION_TYPE.Boolean,defaultValue=false})

I.Settings.registerPage({
    key=PAGE_KEY,
    l10n='ALMSIVI',
    name='SettingsPage_name',
    description='SettingsPage_description',
})

I.Settings.registerGroup({
    key=HOTKEY_GROUP_KEY,page=PAGE_KEY,l10n='ALMSIVI',name='HotkeysGroup_name',
    description='HotkeysGroup_description',permanentStorage=true,order=0,
    settings={
        {key='TalkBinding',renderer='inputBinding',default=bindings.talk,
            name='Talk_name',description='Talk_description',argument={type='trigger',key='ALMSIVI_Talk'}},
        {key='StopDialogueBinding',renderer='inputBinding',default=bindings.stopDialogue,
            name='StopDialogue_name',description='StopDialogue_description',argument={type='trigger',key='ALMSIVI_StopDialogue'}},
        {key='ManualActivateBinding',renderer='inputBinding',default=bindings.manualActivate,
            name='ManualActivate_name',description='ManualActivate_description',argument={type='trigger',key='ALMSIVI_ManualActivate'}},
        {key='ModeMenuBinding',renderer='inputBinding',default=bindings.modeMenu,
            name='ModeMenu_name',description='ModeMenu_description',argument={type='trigger',key='ALMSIVI_ToggleMode'}},
        {key='ModelMenuBinding',renderer='inputBinding',default=bindings.modelMenu,
            name='ModelMenu_name',description='ModelMenu_description',argument={type='trigger',key='ALMSIVI_ModelMenu'}},
        {key='ProfileMenuBinding',renderer='inputBinding',default=bindings.profileMenu,
            name='ProfileMenu_name',description='ProfileMenu_description',argument={type='trigger',key='ALMSIVI_ProfileMenu'}},
        {key='HaltBinding',renderer='inputBinding',default=bindings.halt,
            name='Halt_name',description='Halt_description',argument={type='trigger',key='ALMSIVI_Halt'}},
        {key='ActorToolsBinding',renderer='inputBinding',default=bindings.actorTools,
            name='ActorTools_name',description='ActorTools_description',argument={type='trigger',key='ALMSIVI_ActionsMenu'}},
        {key='StatusHudBinding',renderer='inputBinding',default=bindings.statusHud,
            name='StatusHud_name',description='StatusHud_description',argument={type='trigger',key='ALMSIVI_StatusHud'}},
        {key='HistoryBinding',renderer='inputBinding',default=bindings.history,
            name='History_name',description='History_description',argument={type='trigger',key='ALMSIVI_History'}},
        {key='DiagnosticsBinding',renderer='inputBinding',default=bindings.diagnostics,
            name='Diagnostics_name',description='Diagnostics_description',argument={type='trigger',key='ALMSIVI_Diagnostics'}},
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
    },
})

I.Settings.registerGroup({
    key=SOUND_GROUP_KEY,page=PAGE_KEY,l10n='ALMSIVI',name='SoundGroup_name',
    description='SoundGroup_description',permanentStorage=true,order=3,
    settings={
        {key='ttsVolumeBoost',renderer='number',default=3,name='TtsVolumeBoost_name',description='TtsVolumeBoost_description',argument={integer=true,min=1,max=4}},
    },
})

I.Settings.registerGroup({
    key=AGENTS_GROUP_KEY,page=PAGE_KEY,l10n='ALMSIVI',name='AgentsGroup_name',
    description='AgentsGroup_description',permanentStorage=true,order=4,
    settings={
        {key='actionsEnabled',renderer='checkbox',default=true,name='ActionsEnabled_name',description='ActionsEnabled_description'},
    },
})

I.Settings.registerGroup({
    key=TOOLS_GROUP_KEY,page=PAGE_KEY,l10n='ALMSIVI',name='ToolsGroup_name',
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
        bindingSection:set(bindings.talk,{device='keyboard',button=input.KEY.F6,type='trigger',key='ALMSIVI_Talk'})
    end
    if bindingSection:get(bindings.halt) == nil then
        bindingSection:set(bindings.halt,{device='keyboard',button=input.KEY.F7,type='trigger',key='ALMSIVI_Halt'})
    end
end
if defaultsVersion<DEFAULTS_VERSION then defaultsSection:set('version',DEFAULTS_VERSION) end

-- OpenMW settings are registered through side effects; returning product metadata creates
-- unsupported script sections and can prevent reliable input setup.
return {}
