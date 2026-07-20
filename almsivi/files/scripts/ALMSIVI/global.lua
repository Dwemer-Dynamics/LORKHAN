local adapter=require('scripts.ALMSIVI.adapters.openmw')
local orchestrator=require('scripts.ALMSIVI.orchestrator')
local bridge=assert(adapter.bridge())
local core=adapter.event()
local function emit(name,payload) if core and core.sendGlobalEvent then core.sendGlobalEvent(name,payload) end end
local state=orchestrator.new(bridge,emit)

return {
    engineHandlers={
        onNewGame=function() orchestrator.lifecycle(state,'new_game') end,
        onLoad=function(data) orchestrator.load(state,data) end,
        onSave=function() return orchestrator.save(state) end,
        onObjectActive=function(object) if object.almsiviIdentity then orchestrator.activate(state,object.almsiviIdentity,object) end end,
        onObjectInactive=function(object) if object.almsiviIdentity then orchestrator.deactivate(state,object.almsiviIdentity,object) end end,
        onUpdate=function() orchestrator.poll(state) end,
    },
    eventHandlers={
        ALMSIVI_SESSION=function(event) orchestrator.configureSession(state,event.session_id) end,
        ALMSIVI_TARGET_REQUEST=function(event) emit('ALMSIVI_PLAYER_RESOLVE_TARGET',{maxDistance=event.maxDistance}) end,
        ALMSIVI_SELECT_TARGET=function(event) orchestrator.selectTarget(state,event.candidate) end,
        ALMSIVI_SUBMIT_TEXT=function(event) orchestrator.submitText(state,event) end,
        ALMSIVI_HALT_REQUEST=function() orchestrator.halt(state) end,
        DialogueResponse=function(event) state.lastVanillaDialogue=event end,
    },
}
