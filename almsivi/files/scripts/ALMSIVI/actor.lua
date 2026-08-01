local adapter=require('scripts.ALMSIVI.adapters.openmw')
local executor=require('scripts.ALMSIVI.actor_executor')
local actions=require('scripts.ALMSIVI.actions')
local protocol=require('scripts.ALMSIVI.protocol')
local core=adapter.event()
local state
local engine={
    followSelf=function(target) return adapter.follow(target) end,
    inspectReport=function(target) return adapter.inspect(target) end,
    stopAi=function(owned) return adapter.stopAi(owned) end,
    wanderSelf=function(target,parameters) return adapter.wander(parameters) end,
    startCombat=function(target,parameters) return adapter.startCombat(target,parameters) end,
    stopCombat=function(target,parameters) return adapter.stopCombat(target,parameters) end,
    playAnimation=function(target,parameters) return adapter.playAnimation(parameters) end,
    useItem=function(target,parameters) return adapter.useItem(parameters) end,
    playSpeech=function(mediaId,actorIdentity,subtitle) return adapter.playSpeech(mediaId,subtitle) end,
    isSpeechActive=function() return adapter.isSpeechActive() end,
    stopSpeech=function() adapter.stopSpeech() end,
}
local function report(result,command)
    local bridge=adapter.bridge()
    if not result or not bridge or not bridge.utcNow or not core or not core.sendGlobalEvent then return end
    local canonical=actions.canonicalResult(result,{message_id=command.message_id,request_id=command.request_id,
        turn_id=command.turn_id,session_id=command.session_id,generation=command.generation},bridge.utcNow())
    if canonical then core.sendGlobalEvent('ALMSIVI_ACTION_RESULT',canonical) end
end
local function reportDelivery(command,status,reason)
    local bridge=adapter.bridge()
    if not command or not state or not bridge or not bridge.newMessageId or not bridge.utcNow
        or not bridge.submitDialogueDeliveryResult then return end
    local canonical=protocol.dialogueDeliveryResult({message_id=bridge.newMessageId(),request_id=command.request_id,
        dialogue_message_id=command.dialogue_message_id,turn_id=command.turn_id,session_id=command.session_id,
        generation=command.generation,speaker=state.identity,status=status,reason_code=reason,
        completed_at=bridge.utcNow()})
    if canonical then bridge.submitDialogueDeliveryResult(canonical) end
end
local function authority(command)
    local bridge=adapter.bridge()
    return {session_id=command.session_id,resolve=function(actor) return adapter.resolve(actor) end,
        expired=function(timestamp) return not bridge or not bridge.isExpired or bridge.isExpired(timestamp) end}
end
return {
    engineHandlers={onInit=function(data) state=executor.new(data.actor,data.generation,data.capabilities) end,
        onUpdate=function()
            if state and state.activeSpeech and not engine.isSpeechActive() then
                reportDelivery(executor.completeSpeech(state),'played','playback_completed')
            end
        end,
        onInactive=function()
            if state then
                reportDelivery(executor.stop(state,engine),'interrupted','actor_became_inactive')
                state.attached=false
            end
        end},
    eventHandlers={
        ALMSIVI_ACTOR_ACTION=function(command) local result=executor.execute(state,command,engine,authority(command)) report(result,command) end,
        ALMSIVI_ACTOR_REJECT=function(command) report(executor.reject(state,command,'user_declined'),command) end,
        ALMSIVI_ACTOR_SPEAK=function(command)
            local ok,reason=executor.speak(state,command,engine,authority(command))
            if not ok then reportDelivery(command,'failed',reason or 'playback_failed') end
        end,
        ALMSIVI_ACTOR_STOP=function() reportDelivery(executor.stop(state,engine),'interrupted','client_interrupted') end,
        ALMSIVI_ACTOR_DETACH=function()
            reportDelivery(executor.stop(state,engine),'interrupted','actor_detached')
            state.attached=false
        end,
    },
}
