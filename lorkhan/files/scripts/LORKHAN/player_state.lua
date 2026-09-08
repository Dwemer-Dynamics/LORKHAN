local ui=require('scripts.LORKHAN.ui.state')
local targeting=require('scripts.LORKHAN.targeting')
local util=require('scripts.LORKHAN.util')
local M={}
function M.new() return {ui=ui.new(),action='LORKHAN_Talk',haltAction='LORKHAN_Halt'} end
-- Keep only recent session-owned responder identities; observations without comments never grow this past 32.
function M.rememberRpgComment(state,request,responder,session,now)
    local pending=state.pendingRpgComments or {}
    local count=0
    for key,item in pairs(pending) do
        if item.session_id~=session.session_id or item.generation~=session.generation or now-item.created>30 then
            pending[key]=nil
        else count=count+1 end
    end
    state.pendingRpgComments=pending
    if count>=32 then return false end
    pending[request]={responder=util.copy(responder),
        session_id=session.session_id,generation=session.generation,created=now}
    return true
end

-- Consume once, even when stale, so duplicate acknowledgements cannot start another turn.
function M.takeRpgComment(state,event,session,now)
    if type(event)~='table' then return nil end
    local pending=state.pendingRpgComments or {}
    local item=pending[event.request_id]
    if not item then return nil end
    pending[event.request_id]=nil
    if not session or item.session_id~=session.session_id or item.generation~=session.generation
        or event.session_id~=item.session_id or event.generation~=item.generation
        or now-item.created>30 or now<item.created then return nil end
    return item.responder
end

-- Apply server-owned target behavior without replacing local presentation, action, or targeting preferences.
function M.applyTargetSettings(settings,targetSettings)
    targetSettings=targetSettings or {}
    local remote=targetSettings.behavior or {}
    local behavior=settings.behavior
    behavior.autoGreeting=remote.auto_greeting==true
    behavior.boredom=remote.boredom==true
    behavior.boredomDelaySeconds=remote.boredom_delay_seconds or 180
    behavior.combatBarks=remote.combat_barks==true
    behavior.combatBarkPeriodSeconds=remote.combat_bark_period_seconds or 20
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
