local constants = require('scripts.ALMSIVI.constants')
local identity = require('scripts.ALMSIVI.identity')
local util = require('scripts.ALMSIVI.util')

local M = {}

function M.new(generation)
    return {generation=generation or 0, target=nil, audience={}, turn=nil, seenInputs={}, transcript={}, hardHalted=false}
end

function M.setTarget(state, actor)
    local key, reason = identity.key(actor)
    if not key then return nil, reason end
    state.target=util.copy(actor)
    state.audience={{identity=util.copy(actor), key=key}}
    return true
end

function M.addAudience(state, actor)
    local key, reason = identity.key(actor)
    if not key then return nil, reason end
    for _, item in ipairs(state.audience) do if item.key == key then return true end end
    if #state.audience >= constants.MAX_AUDIENCE then return nil, 'audience_full' end
    table.insert(state.audience, {identity=util.copy(actor), key=key})
    return true
end

function M.removeAudience(state, actor)
    local key = identity.key(actor)
    for index, item in ipairs(state.audience) do if item.key == key then table.remove(state.audience,index) return true end end
    return false
end

function M.begin(state, requestId, turnId, inputKey)
    if state.hardHalted then return nil, 'hard_halted' end
    if not state.target then return nil, 'target_required' end
    if state.turn and not state.turn.terminal then return nil, 'turn_in_flight' end
    if state.seenInputs[inputKey] then return nil, 'duplicate_input' end
    state.seenInputs[inputKey]=true
    state.turn={requestId=requestId, turnId=turnId, generation=state.generation, status='queued', delta='', terminal=false}
    return true
end

function M.apply(state, event)
    local turn=state.turn
    if not turn or event.generation ~= state.generation then return false, 'stale_generation' end
    if event.request_id ~= turn.requestId or event.turn_id ~= turn.turnId then return false, 'wrong_turn' end
    if event.type == 'turn.accepted' then turn.status='accepted'
    elseif event.type == 'turn.status' then turn.status=event.payload.status or 'streaming'
    elseif event.type == 'dialogue.delta' then turn.status='streaming' turn.delta=turn.delta .. (event.payload.text or '')
    elseif event.type == 'dialogue.complete' then turn.final=event.payload.text or '' turn.delta='' turn.status='responded'
    elseif event.type == 'turn.complete' then
        if turn.terminal then return false, 'duplicate_terminal' end
        turn.terminal=true turn.status='complete'
        if turn.final then table.insert(state.transcript,{speaker=util.copy(event.payload.speaker),text=turn.final}) end
    elseif event.type == 'turn.failed' or event.type == 'turn.cancelled' then
        if turn.terminal then return false, 'duplicate_terminal' end
        turn.terminal=true turn.status=event.type == 'turn.failed' and 'failed' or 'cancelled' turn.reason=event.payload.code
    end
    return true
end

function M.invalidate(state, reason)
    state.generation=state.generation+1
    if state.turn and not state.turn.terminal then state.turn.terminal=true state.turn.status='cancelled' state.turn.reason=reason end
    state.turn=nil
    return state.generation
end

function M.halt(state)
    M.invalidate(state, 'hard_halt')
    state.hardHalted=true state.audience={} state.target=nil
end

return M
