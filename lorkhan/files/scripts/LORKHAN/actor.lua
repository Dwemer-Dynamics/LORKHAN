local adapter=require('scripts.LORKHAN.adapters.openmw')
local executor=require('scripts.LORKHAN.actor_executor')
local actions=require('scripts.LORKHAN.actions')
local protocol=require('scripts.LORKHAN.protocol')
local identity=require('scripts.LORKHAN.identity')
local core=adapter.event()
local state
local lastCombatSignature
local menuDialogueSpeech
local waitHere
local savedWaitHere
local combatStatusElapsed=0
local COMBAT_STATUS_INTERVAL=0.25
local engine={
    followSelf=function(target) return adapter.follow(target) end,
    approachSelf=function(target) return adapter.approach(target) end,
    waitSelf=function(target,parameters) return adapter.wait(parameters) end,
    travelSelf=function(target,parameters) return adapter.travel(parameters) end,
    escortSelf=function(target,parameters) return adapter.escort(target,parameters) end,
    faceSelf=function(target,parameters) return adapter.beginFace(target,parameters) end,
    updateFace=function(controller,dt) return adapter.updateFace(controller,dt) end,
    stopFace=function(controller) return adapter.stopFace(controller) end,
    inspectReport=function(target) return adapter.inspect(target) end,
    inventoryReport=function() return adapter.inventoryReport() end,
    stopAi=function(owned) return adapter.stopAi(owned) end,
    wanderSelf=function(target,parameters) return adapter.wander(parameters) end,
    startCombat=function(target,parameters) return adapter.startCombat(target,parameters) end,
    stopCombat=function(target,parameters) return adapter.stopCombat(target,parameters) end,
    playAnimation=function(target,parameters) return adapter.playAnimation(parameters) end,
    equipItem=function(target,parameters) return adapter.equipItem(parameters) end,
    unequipItem=function(target,parameters) return adapter.unequipItem(parameters) end,
    useItem=function(target,parameters) return adapter.useItem(parameters) end,
    sheatheWeapon=function() return adapter.sheatheWeapon() end,
    playSpeech=function(mediaId,actorIdentity,subtitle,volumeBoost) return adapter.playSpeech(mediaId,subtitle,volumeBoost) end,
    isSpeechActive=function() return adapter.isSpeechActive() end,
    stopSpeech=function() adapter.stopSpeech() end,
}
local function report(result,command)
    local bridge=adapter.bridge()
    if not result or not bridge or not bridge.utcNow or not core or not core.sendGlobalEvent then return end
    local canonical=actions.canonicalResult(result,{message_id=command.message_id,request_id=command.request_id,
        turn_id=command.turn_id,session_id=command.session_id,generation=command.generation},bridge.utcNow())
    if canonical then core.sendGlobalEvent('LORKHAN_ACTION_RESULT',{result=canonical,action_name=command.name}) end
end
local function reportDelivery(command,status,reason)
    if command and state and core and core.sendGlobalEvent then
        core.sendGlobalEvent('LORKHAN_SPEECH_STATUS',{actor=state.identity,media_id=command.media_id,
            active=false,status=status,reason=reason})
    end
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
local function reportCombatStatus(probeId,force)
    if not state or state.attached==false or not core or not core.sendGlobalEvent then return end
    local status=adapter.combatStatus()
    if not status then return end
    local target=status.target
    local signature=tostring(status.hostile_to_player)..':'..tostring(status.activity)..':'..tostring(status.conversation_state)
        ..':'..tostring(status.conversation_state_proven)
        ..':'..tostring(target and target.content_file)
        ..':'..tostring(target and target.refnum and target.refnum.index)
    if not force and signature==lastCombatSignature then return end
    lastCombatSignature=signature
    core.sendGlobalEvent('LORKHAN_ACTOR_COMBAT_STATUS',{actor=state.identity,
        hostile_to_player=status.hostile_to_player,activity=status.activity,
        conversation_state=status.conversation_state,conversation_state_proven=status.conversation_state_proven==true,
        target=target,probe_id=probeId})
end
local function clearCombatStatus()
    if not state or not core or not core.sendGlobalEvent then return end
    lastCombatSignature='false:inactive:inactive:false:nil:nil'
    core.sendGlobalEvent('LORKHAN_ACTOR_COMBAT_STATUS',{actor=state.identity,hostile_to_player=false,
        activity='inactive',conversation_state='inactive'})
end
local function cancelFace(reason)
    if not state then return end
    local result,command=executor.cancelFace(state,engine,reason)
    report(result,command)
end
local function reportMenuDialogue(command,status,reason,active)
    if command and state and core and core.sendGlobalEvent then
        core.sendGlobalEvent('LORKHAN_MENU_DIALOGUE_SPEECH_STATUS',{actor=state.identity,
            request_id=command.request_id,media_id=command.media_id,active=active==true,status=status,reason=reason})
    end
end
local function stopMenuDialogue(reason)
    local command=menuDialogueSpeech
    if not command then return end
    menuDialogueSpeech=nil
    adapter.stopSpeech()
    local bridge=adapter.bridge()
    if bridge and bridge.releaseMedia then bridge.releaseMedia(command.media_id) end
    reportMenuDialogue(command,'interrupted',reason or 'client_interrupted',false)
end
local function waitStatus(status,reason)
    if state and core and core.sendGlobalEvent then
        core.sendGlobalEvent('LORKHAN_ACTOR_WAIT_HERE_STATUS',{actor=state.identity,generation=state.generation,status=status,reason=reason})
    end
end
local function endWaitHere(reason)
    if not waitHere then return end
    adapter.endWaitHere(waitHere)
    waitHere=nil
    waitStatus('ended',reason)
end
local function restoreSavedWait()
    if savedWaitHere then adapter.restoreWaitHere(savedWaitHere);savedWaitHere=nil end
end
return {
    engineHandlers={onInit=function(data) state=executor.new(data.actor,data.generation,data.capabilities) end,
        onSave=function() return {waitHere=adapter.saveWaitHere(waitHere)} end,
        onLoad=function(data) waitHere=nil;savedWaitHere=type(data)=='table' and data.waitHere or nil end,
        onActive=function()
            restoreSavedWait()
            if state then
                state.attached=true lastCombatSignature=nil combatStatusElapsed=0 reportCombatStatus()
            end
        end,
        onUpdate=function(dt)
            restoreSavedWait()
            if waitHere then
                local reason=adapter.updateWaitHere(waitHere,dt)
                if reason then waitHere=nil;waitStatus('ended',reason) end
            end
            combatStatusElapsed=combatStatusElapsed+(tonumber(dt) or 0)
            if combatStatusElapsed>=COMBAT_STATUS_INTERVAL then
                combatStatusElapsed=0
                reportCombatStatus()
            end
            if state and state.activeFace then
                local result,command=executor.updateFace(state,engine,dt)
                report(result,command)
            end
            if state and state.activeSpeech and not engine.isSpeechActive() then
                reportDelivery(executor.completeSpeech(state),'played','playback_completed')
            end
            if menuDialogueSpeech and not engine.isSpeechActive() then
                local command=menuDialogueSpeech
                menuDialogueSpeech=nil
                local bridge=adapter.bridge()
                if bridge and bridge.releaseMedia then bridge.releaseMedia(command.media_id) end
                reportMenuDialogue(command,'played','playback_completed',false)
            end
        end,
        onInactive=function()
            endWaitHere('actor_became_inactive')
            if state then
                clearCombatStatus()
                cancelFace('actor_became_inactive')
                stopMenuDialogue('actor_became_inactive')
                reportDelivery(executor.stop(state,engine),'interrupted','actor_became_inactive')
                state.attached=false
            end
        end},
    eventHandlers={
        LORKHAN_ACTOR_ATTACH=function(command)
            if state and command and state.generation~=command.generation then endWaitHere('session_changed') end
            if not state and command and command.actor then
                state=executor.new(command.actor,command.generation,command.capabilities)
            else executor.attach(state,command and command.generation,command and command.capabilities) end
            lastCombatSignature=nil reportCombatStatus()
        end,
        LORKHAN_ACTOR_CONVERSATION_STATE_REQUEST=function(command)
            if state and command and command.generation==state.generation and type(command.probe_id)=='string' then
                reportCombatStatus(command.probe_id,true)
            end
        end,
        LORKHAN_ACTOR_ACTION=function(command)
            if not state then return end
            local result=executor.execute(state,command,engine,authority(command)) report(result,command)
        end,
        LORKHAN_ACTOR_REJECT=function(command)
            if state then report(executor.reject(state,command,'user_declined'),command) end
        end,
        LORKHAN_ACTOR_SPEAK=function(command)
            if not state then return end
            stopMenuDialogue('ai_speech_started')
            local ok,reason=executor.speak(state,command,engine,authority(command))
            if ok and core and core.sendGlobalEvent then
                core.sendGlobalEvent('LORKHAN_SPEECH_STATUS',{actor=state.identity,media_id=command.media_id,
                    active=true,status='playing'})
            else reportDelivery(command,'failed',reason or 'playback_failed') end
        end,
        LORKHAN_ACTOR_SUBTITLE=function(command)
            if not state then return end
            local ok,reason=adapter.showSubtitle(command.subtitle)
            reportDelivery(command,ok and 'played' or 'failed',ok and 'subtitle_displayed' or (reason or 'subtitle_unavailable'))
        end,
        LORKHAN_ACTOR_STOP=function()
            endWaitHere('client_interrupted')
            if state then
                cancelFace('client_interrupted')
                reportDelivery(executor.stop(state,engine),'interrupted','client_interrupted')
            end
        end,
        LORKHAN_ACTOR_STOP_SPEECH=function()
            if state then reportDelivery(executor.stopSpeech(state,engine),'interrupted','client_interrupted') end
        end,
        LORKHAN_MENU_DIALOGUE_SPEAK=function(command)
            if not state or type(command)~='table' or command.generation~=state.generation
                or not command.actor or not identity.same(command.actor,state.identity)
                or type(command.request_id)~='string' or type(command.media_id)~='string' then
                return
            end
            stopMenuDialogue('speech_replaced')
            if state.activeSpeech then
                reportDelivery(executor.stopSpeech(state,engine),'interrupted','menu_dialogue_started')
            end
            local ok,reason=adapter.playSpeech(command.media_id,'',command.volume_boost)
            if ok then
                menuDialogueSpeech=command
                reportMenuDialogue(command,'playing',nil,true)
            else
                local bridge=adapter.bridge()
                if bridge and bridge.releaseMedia then bridge.releaseMedia(command.media_id) end
                reportMenuDialogue(command,'failed',reason or 'playback_failed',false)
            end
        end,
        LORKHAN_MENU_DIALOGUE_STOP=function(command)
            if menuDialogueSpeech and command and command.request_id==menuDialogueSpeech.request_id then
                stopMenuDialogue('client_interrupted')
            end
        end,
        LORKHAN_ACTOR_HALT_ACTIONS=function()
            endWaitHere('client_interrupted')
            if state then cancelFace('client_interrupted') executor.haltActions(state,engine) end
        end,
        LORKHAN_ACTOR_DETACH=function()
            endWaitHere('actor_detached')
            if state then
                cancelFace('actor_detached')
                reportDelivery(executor.stop(state,engine),'interrupted','actor_detached')
                clearCombatStatus()
                state.attached=false
            end
        end,
        LORKHAN_ACTOR_WAIT_HERE=function(command)
            if not state or state.attached==false or type(command)~='table' or command.generation~=state.generation
                or not identity.same(command.actor,state.identity) or state.identity.kind~='npc' then return end
            endWaitHere('wait_restarted')
            cancelFace('wait_started')
            local controller,reason=adapter.beginWaitHere()
            waitHere=controller
            waitStatus(controller and 'waiting' or 'rejected',reason)
        end,
    },
}
