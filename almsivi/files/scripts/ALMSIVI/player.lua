local adapter=require('scripts.ALMSIVI.adapters.openmw')
local player=require('scripts.ALMSIVI.player_state')
local core=adapter.event()
local state=player.new()
local function send(name,payload) if core and core.sendGlobalEvent then core.sendGlobalEvent(name,payload) end end

return {
    engineHandlers={
        onInputAction=function(action) return player.onAction(state,action,send) end,
    },
    eventHandlers={
        ALMSIVI_STATUS=function(event) state.ui.status=event.status state.ui.diagnostics=event.reason end,
        ALMSIVI_PLAYER_RESOLVE_TARGET=function(event) send('ALMSIVI_TARGET_UNAVAILABLE',{reason='camera_adapter_deferred',maxDistance=event.maxDistance}) end,
        ALMSIVI_TARGET=function(event) state.ui.target=event.target end,
        ALMSIVI_EVENT=function(event) player.event(state,event) end,
    },
}
