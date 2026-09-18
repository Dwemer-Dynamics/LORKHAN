local identity = require('scripts.LORKHAN.identity')
local protocol = require('scripts.LORKHAN.protocol')
local util = require('scripts.LORKHAN.util')
local M = {}

function M.new(bridge, resolve, currentPlayer, types, identityFn, isPaused)
    return {bridge=bridge, resolve=resolve, currentPlayer=currentPlayer, types=types,
        identityFn=identityFn, isPaused=isPaused, queue={}, receipts={}, receiptCount=0}
end

-- Clear only across session/generation boundaries or a loaded save, never a same-session UI halt.
function M.reset(state)
    state.queue={}; state.receipts={}; state.receiptCount=0
    state.sessionId=nil; state.generation=nil; state.observations={}
end

local function scope(state, sessionId, generation)
    if state.sessionId~=sessionId or state.generation~=generation then
        M.reset(state); state.sessionId=sessionId; state.generation=generation
    end
    return protocol.isUuid(sessionId) and type(generation)=='number'
end

local function finite(value)
    return type(value)=='number' and value==value and value~=math.huge and value~=-math.huge
end

local function read(state, actorIdentity, dialogueOpen)
    local ok, result, object, player = pcall(function()
        local actor=state.resolve(actorIdentity)
        local current=state.currentPlayer()
        if not actor or not current or not state.types.NPC.objectIsInstance(actor) then return end
        local playerIdentity=state.identityFn(current)
        if not identity.validate(playerIdentity) or playerIdentity.kind~='player' then return end
        local base=state.types.NPC.getBaseDisposition(actor, current)
        local effective=state.types.NPC.getDisposition(actor, current)
        if not finite(base) or not finite(effective) then return end
        return {actor=util.copy(actorIdentity), player=util.copy(playerIdentity),
            base_disposition=math.floor(base), disposition=math.max(0,math.min(100,math.floor(effective))),
            dialogue_open=dialogueOpen==true}, actor, current
    end)
    if ok then return result, object, player end
end

function M.observe(state, actorIdentity, sessionId, generation, dialogueOpen)
    if not scope(state,sessionId,generation) or not identity.validate(actorIdentity)
        or actorIdentity.kind~='npc' or type(state.bridge.submitDisposition)~='function' then return false end
    local observation=read(state,actorIdentity,dialogueOpen)
    if not observation then return false end
    state.observations=state.observations or {}
    local key=identity.key(actorIdentity)
    local signature=table.concat({observation.base_disposition,observation.disposition,tostring(observation.dialogue_open)},':')
    local previous=state.observations[key]
    if previous and previous.signature==signature then
        if previous.request and type(state.bridge.pumpDispositionResult)=='function' then
            local ok,result=pcall(state.bridge.pumpDispositionResult,previous.request)
            if not ok or not result or result.error then state.observations[key]=nil
            elseif result.ok then previous.request=nil end
        end
        if state.observations[key] then return true end
    end
    -- Observation cache is expendable; applied-adjustment receipts are never evicted.
    if not state.observations[key] and util.count(state.observations)>=128 then state.observations={} end
    local ok, request=pcall(state.bridge.submitDisposition,observation)
    if ok and request then state.observations[key]={signature=signature,request=request};return true end
    return false
end

function M.receive(state, event, sessionId, generation)
    if not scope(state,sessionId,generation) or type(event)~='table'
        or event.type~='relationship.adjust' or event.session_id~=sessionId or event.generation~=generation then return false end
    local p=event.payload
    if type(p)~='table' or not protocol.isUuid(p.adjustment_id)
        or not identity.validate(p.actor) or p.actor.kind~='npc'
        or not identity.validate(p.player) or p.player.kind~='player'
        or not finite(p.delta) or p.delta~=math.floor(p.delta) or p.delta==0 or math.abs(p.delta)>3
        or type(p.expires_at)~='string' then return false end
    local ok, current=pcall(function() return state.identityFn(state.currentPlayer()) end)
    if not ok or not identity.same(current,p.player) then return false end
    local previous=state.receipts[p.adjustment_id]
    if previous then
        -- Replayed IDs must retain their original actor/player/delta, not mutate a new target.
        if not identity.same(previous.actor,p.actor) or not identity.same(previous.player,p.player)
            or previous.delta~=p.delta then return false end
        previous.nextAttempt=0; previous.attempts=0; previous.request=nil; previous.acked=false
        return true
    end
    for _,pending in ipairs(state.queue) do
        if pending.adjustment_id==p.adjustment_id then return identity.same(pending.actor,p.actor)
            and identity.same(pending.player,p.player) and pending.delta==p.delta end
    end
    if #state.queue>=16 or state.receiptCount+#state.queue>=128 then return false end
    state.queue[#state.queue+1]=util.copy(p)
    return true
end

-- Retain the outcome before any transport submission so a lost acknowledgement cannot repeat mutation.
local function retain(state, p, observation, status)
    if observation then observation.adjustment_id=p.adjustment_id; observation.status=status end
    state.receipts[p.adjustment_id]={id=p.adjustment_id,actor=p.actor,player=p.player,delta=p.delta,
        observation=observation,status=status,nextAttempt=0,attempts=0}
    state.receiptCount=state.receiptCount+1
end

function M.pump(state, sessionId, generation, now, dialogueOpen)
    if not scope(state,sessionId,generation) or not finite(now) then return end
    local paused=true
    if type(state.isPaused)=='function' then local ok,value=pcall(state.isPaused);paused=not ok or value~=false end
    for index=#state.queue,1,-1 do
        local p=state.queue[index]
        local checked, expired=pcall(function() return state.bridge.isExpired(p.expires_at) end)
        if not checked or expired then
            retain(state,p,read(state,p.actor,dialogueOpen),'rejected');table.remove(state.queue,index)
        elseif not paused and not dialogueOpen then
            local observation, actor, player=read(state,p.actor,false)
            if observation and identity.same(observation.player,p.player) then
                local delta=math.max(-observation.disposition,math.min(100-observation.disposition,p.delta))
                -- Mark first: even a throwing native mutation must never be retried as a second write.
                retain(state,p,nil,'rejected');table.remove(state.queue,index)
                local applied=delta==0 or pcall(state.types.NPC.modifyBaseDisposition,actor,player,delta)
                local after=read(state,p.actor,false)
                local receipt=state.receipts[p.adjustment_id]
                receipt.status=applied and 'applied' or 'rejected'
                if after then after.adjustment_id=p.adjustment_id;after.status=receipt.status;receipt.observation=after end
            end
        end
    end
    if type(state.bridge.submitDisposition)~='function' then return end
    for _,receipt in pairs(state.receipts) do
        if not receipt.observation then
            local observation=read(state,receipt.actor,dialogueOpen)
            if observation and identity.same(observation.player,receipt.player) then
                observation.adjustment_id=receipt.id; observation.status=receipt.status
                receipt.observation=observation
            end
        end
        if receipt.request and type(state.bridge.pumpDispositionResult)=='function' then
            local ok,result=pcall(state.bridge.pumpDispositionResult,receipt.request)
            if ok and type(result)=='table' and result.ok then
                receipt.acked=true; receipt.request=nil
                -- A receipt confirms the past write; immediately publish the current game reading.
                state.observations=state.observations or {};state.observations[identity.key(receipt.actor)]=nil
                M.observe(state,receipt.actor,sessionId,generation,dialogueOpen)
            elseif not ok or not result or result.error or now>=receipt.nextAttempt+30 then receipt.request=nil end
        end
        if receipt.observation and not receipt.acked and not receipt.request
            and receipt.attempts<5 and now>=receipt.nextAttempt then
            receipt.attempts=receipt.attempts+1;receipt.nextAttempt=now+math.min(30,2^receipt.attempts)
            local fresh=read(state,receipt.actor,dialogueOpen)
            if fresh and identity.same(fresh.player,receipt.player) then
                fresh.adjustment_id=receipt.id;fresh.status=receipt.status
                local ok,request=pcall(state.bridge.submitDisposition,fresh)
                if ok and request and type(state.bridge.pumpDispositionResult)=='function' then receipt.request=request end
            end
        end
    end
end

return M
