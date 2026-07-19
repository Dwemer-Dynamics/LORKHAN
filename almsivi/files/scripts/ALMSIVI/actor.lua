local adapter=require('scripts.ALMSIVI.adapters.openmw')
local executor=require('scripts.ALMSIVI.actor_executor')
local core=adapter.event()
local state
local engine={
    followSelf=function() return nil,'engine_follow_adapter_deferred' end,
    sayOpaque=function() return nil,'engine_speech_adapter_deferred' end,
    stopSpeech=function() end,
    stopOwnedFollow=function() end,
}
local function report(result) if result and core and core.sendGlobalEvent then core.sendGlobalEvent('ALMSIVI_ACTION_RESULT',result) end end
return {
    engineHandlers={onInit=function(data) state=executor.new(data.actor,data.generation,data.capabilities) end,
        onInactive=function() if state then executor.detach(state,engine) end end},
    eventHandlers={
        ALMSIVI_ACTOR_ACTION=function(command) local result=executor.execute(state,command,engine,command.authority) report(result) end,
        ALMSIVI_ACTOR_SPEAK=function(command) executor.speak(state,command,engine,command.authority) end,
        ALMSIVI_ACTOR_STOP=function() executor.stop(state,engine) end,
        ALMSIVI_ACTOR_DETACH=function() executor.detach(state,engine) end,
    },
}
