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
    if intent.name ~= 'ai.follow' and intent.name ~= 'inspect.report' then return nil,'action_not_allowlisted' end
    local capability=intent.name=='ai.follow' and 'action.ai.follow' or 'action.inspect.report'
    if not state.enabled[capability] then return nil,'capability_disabled' end
    local expectedTier=intent.name=='ai.follow' and 1 or 0
    if intent.tier ~= expectedTier then return nil,'invalid_action_tier' end
    if intent.generation ~= authority.generation or intent.session_id ~= authority.session_id then return nil,'stale_action' end
    if not identity.same(intent.actor, authority.actor) then return nil,'wrong_actor' end
    if not authority.resolve(intent.actor) then return nil,'actor_inactive' end
    if not identity.validate(intent.target) or not authority.resolve(intent.target) then return nil,'target_inactive' end
    if type(authority.expired)~='function' or authority.expired(intent.expires_at) then return nil,'action_expired' end
    local count=state.byTurn[intent.turn_id] or 0
    if count >= constants.MAX_ACTIONS_PER_TURN then return nil,'turn_action_limit' end
    if type(intent.parameters)~='table' then return nil,'invalid_action_parameters' end
    local parameters={}
    if intent.name=='ai.follow' then
        for key in pairs(intent.parameters) do if key~='distance' then return nil,'unknown_follow_parameter' end end
        local distance=intent.parameters.distance
        if type(distance)~='number' or distance%1~=0 or distance~=192 then return nil,'invalid_follow_distance' end
        parameters.distance=distance
    else
        for _ in pairs(intent.parameters) do return nil,'unknown_inspect_parameter' end
    end
    state.byTurn[intent.turn_id]=count+1
    return {action_id=intent.action_id, turn_id=intent.turn_id, request_id=intent.request_id,
        generation=intent.generation, actor=util.copy(intent.actor), target=util.copy(intent.target),
        name=intent.name, parameters=parameters, expires_at=intent.expires_at}
end

function M.result(state, actionId, status, reason, observed)
    if state.results[actionId] then return nil,'terminal_result_exists' end
    if not terminal(status) then return nil,'non_terminal_status' end
    local result={kind='almsivi.internal.action-terminal',action_id=actionId,status=status,
        reason=reason,observed=util.copy(observed or {})}
    state.results[actionId]=result
    return result
end

function M.canonicalResult(internal, correlation, completedAt)
    if type(internal)~='table' or internal.kind~='almsivi.internal.action-terminal' then return nil,'invalid_internal_result' end
    if type(correlation)~='table' then return nil,'correlation_required' end
    local function uuid(value)
        if type(value)~='string' then return false end
        local a,b,c,d,e=value:match('^([0-9a-f]+)%-([0-9a-f]+)%-([0-9a-f]+)%-([0-9a-f]+)%-([0-9a-f]+)$')
        return a and #a==8 and #b==4 and #c==4 and #d==4 and #e==12 or false
    end
    if not uuid(internal.action_id) then return nil,'invalid_action_id' end
    for _,key in ipairs({'message_id','request_id','turn_id','session_id'}) do
        if not uuid(correlation[key]) then return nil,'invalid_'..key end
    end
    if type(correlation.generation)~='number' or correlation.generation%1~=0 or correlation.generation<0 then return nil,'invalid_generation' end
    if type(completedAt)~='string' or not completedAt:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$') then return nil,'completed_at_required' end
    return {schema='almsivi.action-result.v1',message_id=correlation.message_id,request_id=correlation.request_id,
        action_id=internal.action_id,turn_id=correlation.turn_id,session_id=correlation.session_id,
        generation=correlation.generation,status=internal.status,reason_code=internal.reason or 'unspecified',
        observed=util.copy(internal.observed),completed_at=completedAt}
end

function M.claimContinuation(state, actionId)
    local n=state.continuations[actionId] or 0
    if n >= constants.MAX_CONTINUATIONS_PER_ACTION then return nil,'continuation_limit' end
    state.continuations[actionId]=n+1 return true
end

return M
