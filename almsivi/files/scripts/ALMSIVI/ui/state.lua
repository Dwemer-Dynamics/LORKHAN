local util = require('scripts.ALMSIVI.util')

local M = {}

function M.new(policy)
    return {visible=false, status='offline', target=nil, audience={}, nearby={}, input='', transcript={}, subtitle=nil,
        diagnostics=nil, policy=util.copy(policy or {})}
end

function M.toggle(state) state.visible = not state.visible return state.visible end
function M.setStatus(state, status, diagnostics) state.status=status state.diagnostics=diagnostics end
function M.setTarget(state, target) state.target=util.copy(target) end
function M.setAudience(state, audience)
    state.audience={}
    for index,actor in ipairs(audience or {}) do state.audience[index]=util.copy(actor) end
end
function M.setNearby(state, actors)
    state.nearby={}
    local limit=state.policy.nearbyPickerRows
    for index,item in ipairs(actors or {}) do
        if limit==nil or index<=limit then state.nearby[index]=util.copy(item) end
    end
end
function M.delta(state, speaker, text) state.subtitle={speaker=util.copy(speaker), text=text, provisional=true} end
function M.final(state, speaker, text)
    state.subtitle={speaker=util.copy(speaker), text=text, provisional=false}
    table.insert(state.transcript, {speaker=util.copy(speaker), text=text})
    local limit=state.policy.transcriptRows
    while limit and #state.transcript > limit do table.remove(state.transcript, 1) end
end
function M.clearTransient(state) state.input='' state.subtitle=nil end

return M
