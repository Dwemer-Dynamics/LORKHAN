local constants = require('scripts.ALMSIVI.constants')
local identity = require('scripts.ALMSIVI.identity')
local util = require('scripts.ALMSIVI.util')

local M = {}

local function terminal(status)
    return status=='succeeded' or status=='failed' or status=='rejected' or status=='timed_out' or status=='cancelled'
end

function M.new(capabilities)
    local enabled={}
    for _, name in ipairs(capabilities or {}) do enabled[name]=true end
    return {enabled=enabled, byTurn={}, results={}, continuations={}}
end

function M.validate(state, intent, authority)
    if type(intent) ~= 'table' or intent.schema ~= 'almsivi.action-intent.v1' then return nil,'invalid_action_schema' end
    if intent.name ~= 'ai.follow' then return nil,'action_not_allowlisted' end
    if not state.enabled['action.ai.follow'] then return nil,'capability_disabled' end
    if intent.tier ~= 1 then return nil,'invalid_action_tier' end
    if intent.generation ~= authority.generation or intent.session_id ~= authority.session_id then return nil,'stale_action' end
    if not identity.same(intent.actor, authority.actor) then return nil,'wrong_actor' end
    if not authority.resolve(intent.actor) then return nil,'actor_inactive' end
    if not identity.validate(intent.target) or not authority.resolve(intent.target) then return nil,'target_inactive' end
    if type(authority.expired)~='function' or authority.expired(intent.expires_at) then return nil,'action_expired' end
    local count=state.byTurn[intent.turn_id] or 0
    if count >= constants.MAX_ACTIONS_PER_TURN then return nil,'turn_action_limit' end
    if type(intent.parameters)~='table' then return nil,'invalid_follow_parameters' end
    for key in pairs(intent.parameters) do
        if key~='distance' then return nil,'unknown_follow_parameter' end
    end
    local distance=intent.parameters.distance
    if type(distance)~='number' or distance%1~=0 or distance~=192 then return nil,'invalid_follow_distance' end
    state.byTurn[intent.turn_id]=count+1
    return {action_id=intent.action_id, turn_id=intent.turn_id, request_id=intent.request_id,
        generation=intent.generation, actor=util.copy(intent.actor), target=util.copy(intent.target),
        name='ai.follow', parameters={distance=distance}, expires_at=intent.expires_at}
end

function M.result(state, actionId, status, reason, observed)
    if state.results[actionId] then return nil,'terminal_result_exists' end
    if not terminal(status) then return nil,'non_terminal_status' end
    local result={kind='almsivi.internal.action-terminal',action_id=actionId,status=status,
        reason=reason,observed=util.copy(observed or {})}
    state.results[actionId]=result
    return result
end

function M.canonicalResult(internal, completedAt)
    if type(internal)~='table' or internal.kind~='almsivi.internal.action-terminal' then return nil,'invalid_internal_result' end
    if type(completedAt)~='string' or completedAt=='' then return nil,'completed_at_required' end
    return {schema='almsivi.action-result.v1',action_id=internal.action_id,status=internal.status,
        reason_code=internal.reason,observed=util.copy(internal.observed),completed_at=completedAt}
end

function M.claimContinuation(state, actionId)
    local n=state.continuations[actionId] or 0
    if n >= constants.MAX_CONTINUATIONS_PER_ACTION then return nil,'continuation_limit' end
    state.continuations[actionId]=n+1 return true
end

return M
