local actions = require('scripts.ALMSIVI.actions')
local identity = require('scripts.ALMSIVI.identity')
local util = require('scripts.ALMSIVI.util')

local M = {}

function M.new(selfIdentity, generation, capabilities)
    return {identity=selfIdentity,generation=generation,attached=true,actions=actions.new(capabilities),activeSpeech=nil,
        activeFace=nil,ownedAi=nil,ownedCombat=nil,turns={}}
end

function M.execute(state, command, adapter, authority)
    if not state.attached then return nil,'actor_detached' end
    authority.actor=state.identity authority.generation=state.generation
    local accepted, reason=actions.validate(state.actions,command,authority)
    if not accepted then return actions.result(state.actions,command.action_id,'rejected',reason,{}) end
    if accepted.name=='inspect.report' or accepted.name=='inventory.inspect' then
        local method=accepted.name=='inventory.inspect' and 'inventoryReport' or 'inspectReport'
        if type(adapter[method])~='function' then return actions.result(state.actions,accepted.action_id,'failed','inspect_unavailable',{}) end
        local ok, detail, observed=adapter[method](accepted.target)
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
    if accepted.name=='ai.face' then
        if state.activeFace then return actions.result(state.actions,accepted.action_id,'failed','face_action_busy',{}) end
        if state.ownedAi then return actions.result(state.actions,accepted.action_id,'failed','face_blocked_by_owned_movement',{}) end
        if type(adapter.faceSelf)~='function' then return actions.result(state.actions,accepted.action_id,'failed','action_unavailable',{}) end
        local ok,detail,controller=adapter.faceSelf(accepted.target,accepted.parameters)
        if not ok then return actions.result(state.actions,accepted.action_id,'failed',detail or 'engine_rejected',{}) end
        state.activeFace={actionId=accepted.action_id,command=util.copy(command),controller=controller}
        return nil,'action_pending'
    end
    local handler={
        ['ai.follow']='followSelf',['ai.approach']='approachSelf',['ai.wait']='waitSelf',
        ['ai.travel']='travelSelf',['ai.escort']='escortSelf',['ai.wander']='wanderSelf',['combat.start']='startCombat',
        ['animation.play']='playAnimation',['item.equip']='equipItem',['item.unequip']='unequipItem',['item.use']='useItem',
    }
    local method=handler[accepted.name]
    if type(adapter[method])~='function' then return actions.result(state.actions,accepted.action_id,'failed','action_unavailable',{}) end
    local movement=accepted.name=='ai.follow' or accepted.name=='ai.approach' or accepted.name=='ai.wait'
        or accepted.name=='ai.travel' or accepted.name=='ai.escort' or accepted.name=='ai.wander'
    if movement and state.ownedAi then
        local replaced,replaceReason=adapter.stopAi(state.ownedAi)
        if not replaced then
            return actions.result(state.actions,accepted.action_id,'failed',replaceReason or 'owned_ai_replace_failed',{})
        end
        state.ownedAi=nil
    end
    local ok,detail,observed=adapter[method](accepted.target,accepted.parameters)
    if ok then
        if accepted.name=='ai.follow' then state.ownedAi={type='Follow',actionId=accepted.action_id,target=accepted.target}
        elseif accepted.name=='ai.approach' then state.ownedAi={type='Travel',actionId=accepted.action_id,
            destination=util.copy(observed)}
        elseif accepted.name=='ai.wait' then state.ownedAi={type='Wander',actionId=accepted.action_id,
            distance=0,duration=accepted.parameters.duration_seconds/3600}
        elseif accepted.name=='ai.travel' then state.ownedAi={type='Travel',actionId=accepted.action_id,
            destination=util.copy(accepted.parameters)}
        elseif accepted.name=='ai.escort' then state.ownedAi={type='Escort',actionId=accepted.action_id,
            target=accepted.target,destination=util.copy(accepted.parameters)}
        elseif accepted.name=='ai.wander' then state.ownedAi={type='Wander',actionId=accepted.action_id,
            distance=accepted.parameters.distance,duration=accepted.parameters.duration_seconds/3600}
        elseif accepted.name=='combat.start' then state.ownedCombat={actionId=accepted.action_id,target=accepted.target} end
        return actions.result(state.actions,accepted.action_id,'succeeded',detail,observed or {})
    end
    return actions.result(state.actions,accepted.action_id,'failed',detail or 'engine_rejected',{})
end

function M.updateFace(state, adapter, dt)
    if not state or not state.activeFace then return nil end
    if type(adapter.updateFace)~='function' then
        local pending=state.activeFace state.activeFace=nil
        return actions.result(state.actions,pending.actionId,'failed','face_update_unavailable',{}),pending.command
    end
    local completed,reason,observed,terminalStatus=adapter.updateFace(state.activeFace.controller,dt)
    if completed==nil then return nil end
    local pending=state.activeFace state.activeFace=nil
    local status=terminalStatus or (completed and 'succeeded' or 'failed')
    return actions.result(state.actions,pending.actionId,status,reason or (completed and 'face_completed' or 'engine_rejected'),
        observed or {}),pending.command
end

function M.cancelFace(state, adapter, reason)
    if not state or not state.activeFace then return nil end
    local pending=state.activeFace state.activeFace=nil
    if type(adapter.stopFace)=='function' then adapter.stopFace(pending.controller) end
    return actions.result(state.actions,pending.actionId,'cancelled',reason or 'face_cancelled',{}),pending.command
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
    local ok, reason=adapter.playSpeech(command.media_id,state.identity,command.subtitle,command.tts_volume_boost)
    if ok then
        state.turns[correlation]=true
        state.activeSpeech={mediaId=command.media_id,command=util.copy(command)}
        return true
    end
    return nil,reason or 'speech_failed'
end

function M.completeSpeech(state)
    if not state then return nil end
    if not state.activeSpeech then return nil end
    local command=state.activeSpeech.command
    state.activeSpeech=nil
    return command
end

function M.stopSpeech(state, adapter)
    if not state then return nil end
    local interrupted=M.completeSpeech(state)
    if interrupted then adapter.stopSpeech() end
    return interrupted
end

function M.haltActions(state, adapter)
    if not state then return false end
    M.cancelFace(state,adapter,'client_interrupted')
    if state.ownedAi and type(adapter.stopAi)=='function' then adapter.stopAi(state.ownedAi) state.ownedAi=nil end
    if state.ownedCombat and type(adapter.stopCombat)=='function' then adapter.stopCombat(state.ownedCombat.target) state.ownedCombat=nil end
    return true
end

function M.stop(state, adapter)
    if not state then return nil end
    local interrupted=M.stopSpeech(state,adapter)
    M.cancelFace(state,adapter,'client_interrupted')
    M.haltActions(state,adapter)
    return interrupted
end

function M.attach(state, generation, capabilities)
    if not state then return nil,'actor_state_uninitialized' end
    state.generation=generation or state.generation
    state.attached=true
    if capabilities then state.actions=actions.new(capabilities) end
    return true
end

function M.detach(state, adapter)
    if not state then return nil end
    M.stop(state,adapter)
    state.attached=false
    return true
end
return M
