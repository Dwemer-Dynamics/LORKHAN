-- Compact binding control adapted from OpenMW 0.51's scripts/omw/input/settings.lua (GPL-3.0).
local input = require('openmw.input')
local storage = require('openmw.storage')
local async = require('openmw.async')
local I = require('openmw.interfaces')
local bindings = storage.playerSection('OMWInputBindings')
local recording
local mouseNames = {[1]='Left', [2]='Middle', [3]='Right', [4]='4', [5]='5'}
local controllerNames = {}
for name, code in pairs(input.CONTROLLER_BUTTON) do controllerNames[code] = name end

-- Keep the existing binding store and input events; only omit the duplicated row copy.
I.Settings.registerRenderer('lorkhanBinding', function(id, set, argument)
    local binding = bindings:get(id)
    local label = 'None'
    if recording and recording.id == id then
        label = 'Press a button...'
    elseif binding and binding.device and binding.button then
        if binding.device == 'keyboard' then label = input.getKeyName(binding.button)
        elseif binding.device == 'mouse' then label = 'Mouse ' .. (mouseNames[binding.button] or tostring(binding.button))
        elseif binding.device == 'controller' then label = controllerNames[binding.button] or tostring(binding.button) end
    end
    return {
        template = I.MWUI.templates.textNormal,
        props = {text=label},
        events = {mouseClick=async:callback(function()
            if recording then return end
            bindings:set(id, nil)
            recording = {id=id, argument=argument, refresh=function() set(id) end}
            recording.refresh()
        end)},
    }
end)

-- Escape leaves the binding cleared, matching the stock OpenMW binding recorder.
local function bindButton(device, button)
    if not recording then return end
    bindings:set(recording.id, {device=device, button=button,
        type=recording.argument.type, key=recording.argument.key})
    local refresh = recording.refresh
    recording = nil
    refresh()
end

return {engineHandlers={
    onKeyPress=function(key) bindButton(key.code ~= input.KEY.Escape and 'keyboard' or nil, key.code) end,
    onMouseButtonPress=function(button) bindButton('mouse', button) end,
    onControllerButtonPress=function(button) bindButton('controller', button) end,
}}
