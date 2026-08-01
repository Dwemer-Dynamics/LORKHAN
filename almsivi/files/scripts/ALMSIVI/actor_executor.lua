local actions = require('scripts.ALMSIVI.actions')
local identity = require('scripts.ALMSIVI.identity')
local util = require('scripts.ALMSIVI.util')

local M = {}

function M.new(selfIdentity, generation, capabilities)
    return {identity=selfIdentity,generation=generation,attached=true,actions=actions.new(capabilities),activeSpeech=nil,
        ownedAi=nil,ownedCombat=nil,turns={}}
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
    if accepted.name=='ai.stop' then
        if not state.ownedAi then return actions.result(state.actions,accepted.action_id,'succeeded','no_owned_ai_package',{}) end
        local ok,detail=adapter.stopAi(state.ownedAi)
        if ok then state.ownedAi=nil return actions.result(state.actions,accepted.action_id,'succeeded',detail,{}) end
        return actions.result(state.actions,accepted.action_id,'failed',detail or 'engine_rejected',{})
    end
    if accepted.name=='combat.stop' then
        if not state.ownedCombat then return actions.result(state.actions,accepted.action_id,'succeeded','no_owned_combat_package',{}) end
        local ok,detail=adapter.stopCombat(state.ownedCombat.target,accepted.parameters)
        if ok then state.ownedCombat=nil return actions.result(state.actions,accepted.action_id,'succeeded',detail,{}) end
        return actions.result(state.actions,accepted.action_id,'failed',detail or 'engine_rejected',{})
    end
    local handler={
        ['ai.follow']='followSelf',['ai.wander']='wanderSelf',['combat.start']='startCombat',
        ['animation.play']='playAnimation',['item.equip']='equipItem',['item.unequip']='unequipItem',['item.use']='useItem',
    }
    local method=handler[accepted.name]
    if type(adapter[method])~='function' then return actions.result(state.actions,accepted.action_id,'failed','action_unavailable',{}) end
    local ok,detail=adapter[method](accepted.target,accepted.parameters)
    if ok then
        if accepted.name=='ai.follow' then state.ownedAi={type='Follow',actionId=accepted.action_id,target=accepted.target}
        elseif accepted.name=='ai.wander' then state.ownedAi={type='Wander',actionId=accepted.action_id}
        elseif accepted.name=='combat.start' then state.ownedCombat={actionId=accepted.action_id,target=accepted.target} end
        return actions.result(state.actions,accepted.action_id,'succeeded',detail,{})
    end
    return actions.result(state.actions,accepted.action_id,'failed',detail or 'engine_rejected',{})
end

function M.reject(state, command, reason)
    if not state or not command or type(command.action_id)~='string' then return nil end
    return actions.result(state.actions,command.action_id,'rejected',reason or 'user_declined',{})
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
    if ok then
        state.turns[correlation]=true
        state.activeSpeech={mediaId=command.media_id,command=util.copy(command)}
        return true
    end
    return nil,reason or 'speech_failed'
end

function M.completeSpeech(state)
    if not state.activeSpeech then return nil end
    local command=state.activeSpeech.command
    state.activeSpeech=nil
    return command
end

function M.stop(state, adapter)
    local interrupted=M.completeSpeech(state)
    if interrupted then adapter.stopSpeech() end
    if state.ownedAi and type(adapter.stopAi)=='function' then adapter.stopAi(state.ownedAi) state.ownedAi=nil end
    if state.ownedCombat and type(adapter.stopCombat)=='function' then adapter.stopCombat(state.ownedCombat.target) state.ownedCombat=nil end
    return interrupted
end

function M.detach(state, adapter) M.stop(state,adapter) state.attached=false end
return M
