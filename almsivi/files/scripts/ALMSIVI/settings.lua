local input = require('openmw.input')
local storage = require('openmw.storage')
local I = require('openmw.interfaces')

local PAGE_KEY = 'ALMSIVI'
local GROUP_KEY = 'SettingsALMSIVIControls'
local DEFAULTS_SECTION = 'ALMSIVIInputDefaults'
local DEFAULTS_VERSION = 1

local bindings = {
    talk = 'ALMSIVI_Talk_Binding',
    halt = 'ALMSIVI_Halt_Binding',
    pushToTalk = 'ALMSIVI_PushToTalk_Binding',
    openMic = 'ALMSIVI_OpenMic_Binding',
}

input.registerTrigger({key='ALMSIVI_Talk',l10n='ALMSIVI',name='Talk_name',description='Talk_description'})
input.registerTrigger({key='ALMSIVI_Halt',l10n='ALMSIVI',name='Halt_name',description='Halt_description'})
input.registerTrigger({key='ALMSIVI_OpenMic',l10n='ALMSIVI',name='OpenMic_name',description='OpenMic_description'})
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
            argument={type='trigger',key='ALMSIVI_Talk'}},
        {key='HaltBinding',renderer='inputBinding',default=bindings.halt,
            argument={type='trigger',key='ALMSIVI_Halt'}},
        {key='PushToTalkBinding',renderer='inputBinding',default=bindings.pushToTalk,
            argument={type='action',key='ALMSIVI_PushToTalk'}},
        {key='OpenMicBinding',renderer='inputBinding',default=bindings.openMic,
            argument={type='trigger',key='ALMSIVI_OpenMic'}},
    },
})

-- Seed the legacy F10/F12 controls once, then leave cleared or rebound controls untouched.
local bindingSection = storage.playerSection('OMWInputBindings')
local defaultsSection = storage.playerSection(DEFAULTS_SECTION)
if defaultsSection:get('version') == nil then
    if bindingSection:get(bindings.talk) == nil then
        bindingSection:set(bindings.talk,
            {device='keyboard',button=input.KEY.F10,type='trigger',key='ALMSIVI_Talk'})
    end
    if bindingSection:get(bindings.halt) == nil then
        bindingSection:set(bindings.halt,
            {device='keyboard',button=input.KEY.F12,type='trigger',key='ALMSIVI_Halt'})
    end
    defaultsSection:set('version',DEFAULTS_VERSION)
end

return {}
