local constants=require('scripts.ALMSIVI.constants')
local context=require('scripts.ALMSIVI.context')
local conversation=require('scripts.ALMSIVI.conversation')
local identity=require('scripts.ALMSIVI.identity')
local protocol=require('scripts.ALMSIVI.protocol')
local storage=require('scripts.ALMSIVI.storage')
local targeting=require('scripts.ALMSIVI.targeting')

local M={}

function M.new(bridge,emit)
    local state={bridge=bridge,emit=emit or function() end,generation=1,sessionId=nil,registry=identity.Registry(),
        conversation=conversation.new(1),events=nil,attachments={},disabled=false,hardHalted=false}
    return state
end

local function detachAll(state,reason)
    for _,actorIdentity in pairs(state.attachments) do
        state.emit('ALMSIVI_ACTOR_DETACH',{actor=actorIdentity,reason=reason,generation=state.generation})
    end
    state.attachments={}
end

function M.lifecycle(state,kind)
    detachAll(state,kind)
    state.generation=conversation.invalidate(state.conversation,kind)
    if state.bridge then state.bridge.cancelGeneration(state.generation-1) end
    state.events=state.sessionId and protocol.CursoredEvents(state.sessionId,state.generation) or nil
    state.registry:clear()
    state.emit('ALMSIVI_STATUS',{status='offline',reason=kind,generation=state.generation})
end

function M.configureSession(state,sessionId)
    state.sessionId=sessionId state.events=protocol.CursoredEvents(sessionId,state.generation)
    state.emit('ALMSIVI_STATUS',{status='ready',generation=state.generation})
end

function M.activate(state,actorIdentity,object)
    return state.registry:activate(actorIdentity,object)
end

function M.deactivate(state,actorIdentity,object)
    local key=identity.key(actorIdentity)
    local removed=state.registry:deactivate(actorIdentity,object)
    if removed and key and state.attachments[key] then state.emit('ALMSIVI_ACTOR_DETACH',{actor=actorIdentity}) state.attachments[key]=nil end
    return removed
end

function M.selectTarget(state,candidate)
    local actor,reason=targeting.validate(candidate,state.registry)
    if not actor then return nil,reason end
    conversation.setTarget(state.conversation,actor)
    local key=identity.key(actor)
    if not state.attachments[key] then state.attachments[key]=actor state.emit('ALMSIVI_ACTOR_ATTACH',{actor=actor,generation=state.generation}) end
    state.emit('ALMSIVI_TARGET',{target=actor}) return actor
end

function M.submitText(state,args)
    if state.disabled or state.hardHalted then return nil,'almsivi_disabled' end
    for _,key in ipairs({'request_id','turn_id','message_id'}) do
        if not protocol.isUuid(args[key]) then return nil,'invalid_'..key end
    end
    local requestId=args.request_id
    local turnId=args.turn_id
    local ok,reason=conversation.begin(state.conversation,requestId,turnId,args.input_key or args.text)
    if not ok then return nil,reason end
    local audience={}
    for _,entry in ipairs(state.conversation.audience) do table.insert(audience,entry.identity) end
    local dto,buildReason=protocol.turn({message_id=args.message_id,request_id=requestId,turn_id=turnId,
        installation_id=args.installation_id,profile_id=args.profile_id,playthrough_id=args.playthrough_id,
        session_id=state.sessionId,generation=state.generation,created_at=args.created_at,platform=args.platform,
        content_fingerprint=args.content_fingerprint,text=args.text,language=args.language,
        speaker=args.speaker,target=state.conversation.target,audience=audience,context=context.snapshot(args.context),
        capabilities=args.capabilities,recent_action_results=args.recent_action_results,ui_source=args.ui_source})
    if not dto then state.conversation.turn=nil return nil,buildReason end
    local submitted,nativeReason=state.bridge.submitTurn(dto)
    if not submitted then state.conversation.turn=nil return nil,nativeReason end
    state.emit('ALMSIVI_TURN',{status='queued',request_id=requestId,turn_id=turnId})
    return requestId
end

function M.poll(state)
    if state.disabled or state.hardHalted then return 0 end
    local results=state.bridge.pollResults(constants.MAX_INBOUND_RESULTS) or {}
    local accepted=0
    for index=1,math.min(#results,constants.MAX_INBOUND_RESULTS) do
        local event=results[index]
        local ok,reason=state.events:accept(event)
        if ok then
            local applied,applyReason=conversation.apply(state.conversation,event)
            if applied then accepted=accepted+1 state.emit('ALMSIVI_EVENT',event) else state.emit('ALMSIVI_DROP',{reason=applyReason}) end
        elseif reason~='duplicate_event' and reason~='stale_generation' and reason~='stale_session' then
            state.emit('ALMSIVI_RESYNC',{reason=reason,cursor=state.events:cursor()})
        end
    end
    return accepted
end

function M.halt(state)
    detachAll(state,'hard_halt')
    state.bridge.halt() conversation.halt(state.conversation)
    state.generation=state.conversation.generation state.hardHalted=true
    state.emit('ALMSIVI_HALT',{generation=state.generation})
end

function M.load(state,raw)
    local loaded,meta=storage.load(raw,state.generation)
    M.lifecycle(state,'load')
    if loaded and not meta.disable then
        state.profileId=loaded.profileId state.playthroughId=loaded.playthroughId
        state.preferences=loaded.preferences state.conversationUi=loaded.conversationUi
        state.generation=math.max(state.generation,loaded.generationSeed or state.generation)
        state.conversation.generation=state.generation
        state.events=state.sessionId and protocol.CursoredEvents(state.sessionId,state.generation) or nil
    end
    if meta.disable then state.disabled=true state.futureSave=meta.preserve and raw or nil state.emit('ALMSIVI_STATUS',{status='disabled',reason=meta.reason}) end
    return loaded,meta
end
function M.save(state)
    if state.futureSave then return state.futureSave end
    return storage.save({profileId=state.profileId,playthroughId=state.playthroughId,generationSeed=state.generation,
        preferences=state.preferences,conversationUi=state.conversationUi,actorStateHints={}})
end
return M
