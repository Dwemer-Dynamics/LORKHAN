local ui=require('scripts.ALMSIVI.ui.state')
local targeting=require('scripts.ALMSIVI.targeting')
local M={}
function M.new() return {ui=ui.new(),action='ALMSIVI_Talk',haltAction='ALMSIVI_Halt'} end
function M.onAction(state,name,send)
    if name==state.action then ui.toggle(state.ui) send('ALMSIVI_TARGET_REQUEST',{}) return true end
    if name==state.haltAction then send('ALMSIVI_HALT_REQUEST',{}) return true end
    return false -- built-in Activate and every unrelated action remain untouched
end
function M.nearby(state,candidates,registry) local list=targeting.nearby(candidates,registry) ui.setNearby(state.ui,list) return list end
function M.event(state,event)
    if event.type=='dialogue.delta' then ui.delta(state.ui,event.payload.speaker,event.payload.text)
    elseif event.type=='dialogue.complete' then ui.final(state.ui,event.payload.speaker,event.payload.text)
    elseif event.type=='turn.failed' or event.type=='turn.cancelled' then ui.setStatus(state.ui,'failed')
    elseif event.type=='turn.complete' then ui.setStatus(state.ui,'ready')
    else ui.setStatus(state.ui,event.payload.status or event.type) end
end
return M
