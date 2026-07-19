local constants = require('scripts.ALMSIVI.constants')
local util = require('scripts.ALMSIVI.util')

local M = {}

function M.new()
    return {visible=false, status='offline', target=nil, audience={}, nearby={}, input='', transcript={}, subtitle=nil, diagnostics=nil}
end

function M.toggle(state) state.visible = not state.visible return state.visible end
function M.setStatus(state, status, diagnostics) state.status=status state.diagnostics=diagnostics end
function M.setTarget(state, target) state.target=util.copy(target) end
function M.setNearby(state, actors) state.nearby=util.arrayCopy(actors or {}, constants.MAX_NEARBY_PICKER) end
function M.delta(state, speaker, text) state.subtitle={speaker=util.copy(speaker), text=text, provisional=true} end
function M.final(state, speaker, text)
    state.subtitle={speaker=util.copy(speaker), text=text, provisional=false}
    table.insert(state.transcript, {speaker=util.copy(speaker), text=text})
    while #state.transcript > constants.MAX_TRANSCRIPT do table.remove(state.transcript, 1) end
end
function M.clearTransient(state) state.input='' state.subtitle=nil end

return M
