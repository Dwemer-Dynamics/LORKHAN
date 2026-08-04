local util = require('scripts.ALMSIVI.util')

local M = {}

function M.new(policy)
    return {visible=false, status='offline', target=nil, audience={}, nearby={}, agents={}, input='', transcript={}, subtitle=nil,
        diagnostics=nil, lastCorrelation=nil, mode='Standard',panel='conversation',actionView='root',actionPage=1,actionSlot=nil,
        historyPage=1,
        pendingTargetAction=nil,
        statusHudVisible=false,policy=util.copy(policy or {})}
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
local function correlation(event)
    if type(event)~='table' then return {} end
    return {messageId=event.message_id,requestId=event.request_id,turnId=event.turn_id,
        sequence=event.sequence,createdAt=event.created_at}
end
local function appendTranscript(state,speaker,text,event,status)
    local ids=correlation(event)
    state.subtitle={speaker=util.copy(speaker), text=text, provisional=false}
    table.insert(state.transcript, {speaker=util.copy(speaker),text=text,status=status,
        messageId=ids.messageId,requestId=ids.requestId,turnId=ids.turnId,
        sequence=ids.sequence,createdAt=ids.createdAt})
    state.historyPage=1
    state.lastCorrelation=ids
    local limit=state.policy.transcriptRows
    while limit and #state.transcript > limit do table.remove(state.transcript, 1) end
end
function M.queued(state,speaker,text,event) appendTranscript(state,speaker,text,event,'queued') end
function M.final(state, speaker, text, event) appendTranscript(state,speaker,text,event,'responding') end
-- Keep every line for a request aligned with its terminal server state and latest correlation IDs.
function M.updateTurnState(state,event,status)
    local ids=correlation(event)
    state.lastCorrelation=ids
    for _,line in ipairs(state.transcript) do
        if (ids.requestId and line.requestId==ids.requestId) or (ids.turnId and line.turnId==ids.turnId) then
            line.status=status
            line.terminalSequence=ids.sequence
            line.terminalCreatedAt=ids.createdAt
        end
    end
end
function M.clearTransient(state) state.input='' state.subtitle=nil end

return M
