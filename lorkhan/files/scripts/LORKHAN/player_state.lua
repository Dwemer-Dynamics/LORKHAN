local ui=require('scripts.LORKHAN.ui.state')
local targeting=require('scripts.LORKHAN.targeting')
local util=require('scripts.LORKHAN.util')
local identity=require('scripts.LORKHAN.identity')
local M={}
function M.new() return {ui=ui.new(),action='LORKHAN_Talk',haltAction='LORKHAN_Halt'} end
-- Compare the bounded observed journal window without treating session/load snapshots as new quests.
function M.journalChanges(state,entries,session)
    if not session or type(entries)~='table' then state.journalBaseline=nil return {} end
    local previous=state.journalBaseline
    local current={session_id=session.session_id,generation=session.generation,entries={}}
    local changed={}
    local sameSession=previous and previous.session_id==session.session_id and previous.generation==session.generation
    for index=math.max(1,#entries-31),#entries do
        local entry=entries[index]
        if type(entry)=='table' and type(entry.id)=='string' and type(entry.quest_id)=='string'
            and type(entry.text)=='string' and entry.text~='' then
            local key=tostring(#entry.quest_id)..':'..entry.quest_id..entry.id
            local old=sameSession and previous.entries[key] or nil
            local differs=not old
            if old then
                for _,field in ipairs({'stage','text','day','month','day_of_month'}) do
                    if old[field]~=entry[field] then differs=true break end
                end
            end
            current.entries[key]=util.copy(entry)
            if sameSession and differs then changed[#changed+1]=util.copy(entry) end
        end
    end
    state.journalBaseline=current
    return changed
end

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
-- Keep change detection session-owned and bounded; failed reads or submissions never clear known inventory.
function M.observeInventory(state,event,session,reader,submit,now)
    if type(event)~='table' or type(session)~='table' or event.session_id~=session.session_id
        or event.generation~=session.generation or type(submit)~='function'
        or type(now)~='number' or now~=now or now<0 or now==math.huge then return false end
    local ownerKey=identity.key(event.actor)
    if not ownerKey then return false end
    local observations=state.inventoryObservations
    if not observations or observations.session_id~=session.session_id or observations.generation~=session.generation then
        observations={session_id=session.session_id,generation=session.generation,values={},sentAt={},order={}}
        state.inventoryObservations=observations
    end
    local payload,signature=reader(event.actor)
    if not payload or type(signature)~='string' then return false end
    -- Re-send unchanged observations after five minutes so a dropped HTTP request cannot suppress them forever.
    local sentAt=observations.sentAt[ownerKey]
    if observations.values[ownerKey]==signature and sentAt and now>=sentAt and now-sentAt<300 then return false end
    if not submit(payload) then return false end
    if observations.values[ownerKey]==nil then observations.order[#observations.order+1]=ownerKey end
    observations.values[ownerKey]=signature;observations.sentAt[ownerKey]=now
    while #observations.order>32 do
        local expired=table.remove(observations.order,1)
        observations.values[expired]=nil;observations.sentAt[expired]=nil
    end
    return true
end

-- Retry only this live session's bounded immutable observations; no model turn is scheduled.
local function captureObservation(state,queueKey,event,session,reader,submit,now)
    if type(event)~='table' or type(session)~='table' or event.sessionId~=session.session_id
        or event.generation~=session.generation or type(submit)~='function' then return false end
    local queue=state[queueKey]
    if not queue or queue.session_id~=session.session_id or queue.generation~=session.generation then
        queue={session_id=session.session_id,generation=session.generation,items={},nextAttemptAt=now}
        state[queueKey]=queue
    end
    local payload=reader(event)
    if not payload then return false end
    if #queue.items==0 and submit(payload) then return true end
    if #queue.items>=32 then return false end
    queue.items[#queue.items+1]={payload=util.copy(payload),capturedAt=now,attempts=0}
    return true
end

local function flushObservations(state,queueKey,session,submit,now)
    local queue=state[queueKey]
    if not queue then return false end
    if not session or session.session_id~=queue.session_id or session.generation~=queue.generation then
        state[queueKey]=nil;return false
    end
    if #queue.items==0 or now<queue.nextAttemptAt or type(submit)~='function' then return false end
    queue.nextAttemptAt=now+0.1
    local item=queue.items[1]
    if now-item.capturedAt>=5 or now<item.capturedAt then table.remove(queue.items,1);return false end
    item.attempts=item.attempts+1
    if submit(item.payload) then table.remove(queue.items,1);return true end
    if item.attempts>=20 then table.remove(queue.items,1) end
    return false
end

function M.captureSpellCast(state,event,session,reader,submit,now)
    return captureObservation(state,'spellCaptures',event,session,reader,submit,now)
end
function M.captureResurrection(state,event,session,reader,submit,now)
    return captureObservation(state,'resurrections',event,session,reader,submit,now)
end
function M.flushResurrections(state,session,submit,now)
    return flushObservations(state,'resurrections',session,submit,now)
end
function M.flushSpellCasts(state,session,submit,now)
    return flushObservations(state,'spellCaptures',session,submit,now)
end
function M.captureItemPickup(state,event,session,reader,submit,now)
    return captureObservation(state,'itemPickups',event,session,reader,submit,now)
end
function M.flushItemPickups(state,session,submit,now)
    return flushObservations(state,'itemPickups',session,submit,now)
end

return M
