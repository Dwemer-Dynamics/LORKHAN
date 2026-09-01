local ui=require('scripts.LORKHAN.ui.state')
local targeting=require('scripts.LORKHAN.targeting')
local M={}
function M.new() return {ui=ui.new(),action='LORKHAN_Talk',haltAction='LORKHAN_Halt'} end
-- Apply server-owned target behavior without replacing local presentation, action, or targeting preferences.
function M.applyTargetSettings(settings,targetSettings)
    targetSettings=targetSettings or {}
    local remote=targetSettings.behavior or {}
    local behavior=settings.behavior
    behavior.rechat=remote.rechat==true
    behavior.rechatMaxDepth=remote.rechat_max_depth or 2
    behavior.rechatProbabilityPercent=remote.rechat_probability_percent or 50
    behavior.rechatMode=remote.rechat_mode or 'random'
    behavior.rechatStrictTargeting=remote.rechat_strict_targeting==true
    behavior.openRechat=remote.open_rechat~=false
    behavior.endConversationCooldownSeconds=remote.end_conversation_cooldown_seconds or 60
    settings.narrator=targetSettings.narrator or {}
    settings.memory=targetSettings.memory or {}
end
-- Convert the editable widget value into a single-line message and surface Enter as submit.
function M.consumeTextEdit(value)
    if type(value)~='string' then return '',false end
    local submit=value:find('[\r\n]')~=nil
    local cleaned=value:gsub('[\r\n]+',' ')
    return cleaned,submit
end
function M.onAction(state,name,send)
    if name==state.action then ui.toggle(state.ui) send('LORKHAN_TARGET_REQUEST',{}) return true end
    if name==state.haltAction then send('LORKHAN_HALT_REQUEST',{}) return true end
    return false -- built-in Activate and every unrelated action remain untouched
end
function M.nearby(state,candidates,registry) local list=targeting.nearby(candidates,registry) ui.setNearby(state.ui,list) return list end
function M.event(state,event)
    if event.type=='dialogue.delta' then ui.delta(state.ui,event.payload.speaker or state.ui.target,event.payload.text)
    elseif event.type=='dialogue.complete' then ui.final(state.ui,event.payload.speaker,event.payload.text,event)
    elseif event.type=='turn.failed' then ui.updateTurnState(state.ui,event,'failed') ui.setStatus(state.ui,'failed')
    elseif event.type=='turn.cancelled' then ui.updateTurnState(state.ui,event,'cancelled') ui.setStatus(state.ui,'failed')
    elseif event.type=='turn.complete' then ui.updateTurnState(state.ui,event,'complete') ui.setStatus(state.ui,'ready')
    else ui.setStatus(state.ui,event.payload.status or event.type) end
end
function M.queued(state,speaker,text,event) ui.queued(state.ui,speaker,text,event) end
return M
