local adapter=require('scripts.ALMSIVI.adapters.openmw')
local orchestrator=require('scripts.ALMSIVI.orchestrator')
local bridge=assert(adapter.bridge())
local core=adapter.event()
local function emit(name,payload) if core and core.sendGlobalEvent then core.sendGlobalEvent(name,payload) end end
local state
local function sendActor(actor,name,payload)
    local object=state and state.registry:resolve(actor)
    if not object or not object.sendEvent then return nil,'actor_inactive' end
    object:sendEvent(name,payload)
    return true
end
state=orchestrator.new(bridge,emit,sendActor)
local configuredSession

local function activate(object)
    local actor=adapter.identity(object)
    if not actor then return end
    orchestrator.activate(state,actor,object)
    local path='scripts/ALMSIVI/actor.lua'
    if actor.kind~='player' and object.hasScript and object.addScript and not object:hasScript(path) then
        object:addScript(path,{actor=actor,generation=state.generation,
            capabilities=bridge.capabilities and bridge.capabilities() or {}})
    end
end

return {
    engineHandlers={
        onNewGame=function() orchestrator.lifecycle(state,'new_game') end,
        onLoad=function(data) orchestrator.load(state,data) end,
        onSave=function() return orchestrator.save(state) end,
        onActorActive=activate,
        onPlayerAdded=activate,
        onUpdate=function()
            local session=bridge.sessionInfo and bridge.sessionInfo()
            if session and session.session_id~=configuredSession then
                configuredSession=session.session_id
                state.generation=session.generation
                state.conversation.generation=session.generation
                orchestrator.configureSession(state,session.session_id)
            end
            if state.events then orchestrator.poll(state) end
            orchestrator.pollVoice(state)
            orchestrator.pollOpenMic(state)
            orchestrator.pollAutonomy(state)
        end,
    },
    eventHandlers={
        ALMSIVI_SESSION=function(event) orchestrator.configureSession(state,event.session_id) end,
        ALMSIVI_TARGET_REQUEST=function(event) emit('ALMSIVI_PLAYER_RESOLVE_TARGET',{maxDistance=event.maxDistance}) end,
        ALMSIVI_AUDIENCE_REQUEST=function(event) emit('ALMSIVI_PLAYER_RESOLVE_AUDIENCE',{maxDistance=event.maxDistance}) end,
        ALMSIVI_SELECT_TARGET=function(event) orchestrator.selectTarget(state,event.candidate) end,
        ALMSIVI_ADD_AUDIENCE=function(event) orchestrator.addAudience(state,event.candidate) end,
        ALMSIVI_CLEAR_AUDIENCE=function() orchestrator.clearAudience(state) end,
        ALMSIVI_SUBMIT_TEXT=function(event)
            local metadata=bridge.nextTurnMetadata and bridge.nextTurnMetadata() or {}
            for key,value in pairs(metadata) do if event[key]==nil then event[key]=value end end
            orchestrator.submitText(state,event)
        end,
        ALMSIVI_VOICE_START=function(event) orchestrator.startVoice(state,event) end,
        ALMSIVI_VOICE_STOP=function() orchestrator.stopVoice(state) end,
        ALMSIVI_OPEN_MIC_START=function(event) orchestrator.enableOpenMic(state,event) end,
        ALMSIVI_OPEN_MIC_STOP=function() orchestrator.disableOpenMic(state) end,
        ALMSIVI_OPEN_MIC_CONTEXT=function(event) orchestrator.runOpenMicContext(state,event) end,
        ALMSIVI_AUTONOMY_CONTEXT=function(event) orchestrator.runAutonomy(state,event) end,
        ALMSIVI_HALT_REQUEST=function() orchestrator.halt(state) end,
        ALMSIVI_CONFIRM_ACTION=function(event) orchestrator.confirmAction(state,event.action_id,event.approved==true) end,
        ALMSIVI_ACTION_RESULT=function(event) if bridge.submitActionResult then bridge.submitActionResult(event) end end,
        DialogueResponse=function(event) state.lastVanillaDialogue=event end,
    },
}
