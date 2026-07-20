local actions = require('scripts.ALMSIVI.actions')
local identity = require('scripts.ALMSIVI.identity')

local M = {}

function M.new(selfIdentity, generation, capabilities)
    return {identity=selfIdentity,generation=generation,attached=true,actions=actions.new(capabilities),activeSpeech=nil,ownedFollow=nil,turns={}}
end

function M.execute(state, command, adapter, authority)
    if not state.attached then return nil,'actor_detached' end
    authority.actor=state.identity authority.generation=state.generation
    local accepted, reason=actions.validate(state.actions,command,authority)
    if not accepted then return actions.result(state.actions,command.action_id,'rejected',reason,{}) end
    if accepted.name=='inspect.report' then
        if type(adapter.inspectReport)~='function' then return actions.result(state.actions,accepted.action_id,'failed','inspect_unavailable',{}) end
        local ok, detail, observed=adapter.inspectReport(accepted.target)
        if ok then return actions.result(state.actions,accepted.action_id,'succeeded',detail or 'inspection_completed',observed or {}) end
        return actions.result(state.actions,accepted.action_id,'failed',detail or 'engine_rejected',{})
    end
    local ok, detail=adapter.followSelf(accepted.target,accepted.parameters.distance)
    if ok then state.ownedFollow=accepted.action_id return actions.result(state.actions,accepted.action_id,'succeeded',detail,{}) end
    return actions.result(state.actions,accepted.action_id,'failed',detail or 'engine_rejected',{})
end

function M.speak(state, command, adapter, authority)
    if not state.attached or command.generation~=state.generation or not identity.same(command.actor,state.identity) then return nil,'stale_or_wrong_actor' end
    if type(command.request_id)~='string' or command.request_id=='' or type(command.turn_id)~='string' or command.turn_id=='' then return nil,'speech_correlation_required' end
    if type(authority)~='table' or type(authority.expired)~='function' then return nil,'speech_authority_required' end
    if command.expires_at and authority.expired(command.expires_at) then return nil,'speech_expired' end
    if type(command.media_id)~='string' or command.media_id=='' then return nil,'media_id_required' end
    local correlation=command.request_id..'|'..command.turn_id..'|'..command.media_id
    if state.turns[correlation] then return nil,'duplicate_speech' end
    local ok, reason=adapter.playSpeech(command.media_id,state.identity,command.subtitle)
    if ok then state.turns[correlation]=true state.activeSpeech=command.media_id return true end
    return nil,reason or 'speech_failed'
end

function M.stop(state, adapter)
    if state.activeSpeech then adapter.stopSpeech() state.activeSpeech=nil end
    if state.ownedFollow then adapter.stopOwnedFollow(state.ownedFollow) state.ownedFollow=nil end
end

function M.detach(state, adapter) M.stop(state,adapter) state.attached=false end
return M
