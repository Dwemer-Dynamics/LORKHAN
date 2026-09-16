local identity=require('scripts.LORKHAN.identity')
local protocol=require('scripts.LORKHAN.protocol')
local util=require('scripts.LORKHAN.util')
local M={}

-- Retain only the authenticated plan for the current origin turn, never a later unrelated scene.
function M.receive(event,seed)
    local payload=event and event.payload
    if not seed or not payload or event.turn_id~=seed.turn_id or payload.origin_turn_id~=seed.turn_id
        or not protocol.isUuid(payload.plan_id) or type(payload.expires_at)~='string'
        or type(payload.instructions)~='table' or #payload.instructions<1 or #payload.instructions>12 then return nil end
    local seen={}
    for _,row in ipairs(payload.instructions) do
        local key=identity.key(row.actor)
        if not protocol.isUuid(row.instruction_id) or seen[row.instruction_id] or not key
            or (row.actor.kind~='npc' and row.actor.kind~='creature') or not identity.validate(row.recipient)
            or identity.same(row.actor,row.recipient) or type(row.instruction)~='string'
            or #row.instruction<1 or #row.instruction>2000 then return nil end
        seen[row.instruction_id]=true
    end
    return {planId=payload.plan_id,sessionId=event.session_id,generation=event.generation,
        expiresAt=payload.expires_at,instructions=util.copy(payload.instructions),index=1,seed=util.copy(seed)}
end

-- Each child waits for prior speech/actions to finish, then asks PLAYER for a fresh exact-actor snapshot.
function M.next(plan,bridge,sessionId,generation,ready)
    if not plan then return nil end
    local now=bridge.utcNow and bridge.utcNow()
    if plan.sessionId~=sessionId or plan.generation~=generation or type(now)~='string' or now>=plan.expiresAt then
        plan.cancelled=true return nil
    end
    if plan.cancelled or plan.pending or not ready then return nil end
    local row=plan.instructions[plan.index]
    if not row then plan.complete=true return nil end
    local metadata=bridge.nextTurnMetadata and bridge.nextTurnMetadata()
    if not metadata or not protocol.isUuid(metadata.request_id) or not protocol.isUuid(metadata.turn_id)
        or not protocol.isUuid(metadata.message_id) then plan.cancelled=true return nil end
    local args=util.copy(plan.seed)
    for key,value in pairs(metadata) do args[key]=value end
    args.text=row.instruction;args.speaker=util.copy(row.recipient);args.target=util.copy(row.actor)
    args.execution_mode='standard';args.director_instruction_id=row.instruction_id
    args.ui_source='lorkhan_director_child';args.input_key='director:'..row.instruction_id
    args.mood=nil;args.action_request=nil;args.context=nil;args.dialogueMode='Standard'
    plan.pending=args
    return {request_id=args.request_id,session_id=sessionId,generation=generation,
        instruction_id=row.instruction_id,target=util.copy(row.actor)}
end

function M.context(plan,event)
    local args=plan and plan.pending
    if not args or plan.cancelled or type(event)~='table' or event.session_id~=plan.sessionId
        or event.generation~=plan.generation or event.request_id~=args.request_id
        or event.instruction_id~=args.director_instruction_id or not identity.same(event.target,args.target)
        or type(event.context)~='table' then return nil end
    args.context=util.copy(event.context)
    plan.pending=nil;plan.index=plan.index+1
    return args
end

return M
