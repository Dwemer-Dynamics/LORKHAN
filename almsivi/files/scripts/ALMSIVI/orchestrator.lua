local constants=require('scripts.ALMSIVI.constants')
local agentRegistry=require('scripts.ALMSIVI.agent_registry')
local context=require('scripts.ALMSIVI.context')
local conversation=require('scripts.ALMSIVI.conversation')
local identity=require('scripts.ALMSIVI.identity')
local protocol=require('scripts.ALMSIVI.protocol')
local storage=require('scripts.ALMSIVI.storage')
local targeting=require('scripts.ALMSIVI.targeting')
local util=require('scripts.ALMSIVI.util')

local M={}

function M.new(bridge,emit,sendActor,manageActor)
    local generation=bridge and bridge.generation and bridge.generation() or 1
    local state={bridge=bridge,emit=emit or function() end,sendActor=sendActor or function() return nil,'actor_sender_unavailable' end,
        generation=generation,sessionId=nil,registry=identity.Registry(),agents=agentRegistry.new(),
        manageActor=manageActor or function() return nil,'actor_manager_unavailable' end,
        conversation=conversation.new(generation),events=nil,attachments={},media={},pendingConfirmations={},
        activeSpeechMediaId=nil,rechat=nil,rechatSeed=nil,combatThreats={},combatVerified={},
        dialogueMode='Standard',disabled=false,hardHalted=false,agentsSignature=nil}
    state.recentVanillaDialogue={}
    return state
end

-- Keep the player script informed without depending on OpenMW's internal music-combat events.
local function emitCombatState(state)
    local count=0
    local threats={}
    for _,actor in pairs(state.combatThreats) do
        count=count+1
        if #threats<constants.MAX_AUDIENCE then threats[#threats+1]=util.copy(actor) end
    end
    table.sort(threats,function(left,right)return identity.key(left)<identity.key(right) end)
    state.emit('ALMSIVI_COMBAT_STATUS',{active=count>0,count=count,threats=threats})
end

local function detachAll(state,reason)
    for _,actorIdentity in pairs(state.attachments) do
        state.sendActor(actorIdentity,'ALMSIVI_ACTOR_DETACH',{actor=actorIdentity,reason=reason,generation=state.generation})
    end
    state.attachments={}
end

local function signalAllActors(state,eventName,reason)
    for _,actorIdentity in pairs(state.attachments) do
        state.sendActor(actorIdentity,eventName,{actor=actorIdentity,reason=reason,generation=state.generation})
    end
end

function M.lifecycle(state,kind)
    detachAll(state,kind)
    state.generation=conversation.invalidate(state.conversation,kind)
    if state.bridge then state.bridge.cancelGeneration(state.generation-1) end
    state.events=state.sessionId and protocol.CursoredEvents(state.sessionId,state.generation) or nil
    state.pendingConfirmations={}
    state.activeSpeechMediaId=nil
    state.rechat=nil state.rechatSeed=nil
    state.combatThreats={} state.combatVerified={}
    state.recentVanillaDialogue={}
    state.hardHalted=false state.conversation.hardHalted=false
    state.registry:clear()
    state.agentsSignature=nil
    agentRegistry.clear(state.agents)
    emitCombatState(state)
    state.emit('ALMSIVI_ACTOR_ACTIVITY',{reset=true})
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
    if removed and key then
        agentRegistry.remove(state.agents,actorIdentity)
        state.combatVerified[key]=nil state.combatThreats[key]=nil
        emitCombatState(state)
        if state.attachments[key] then state.sendActor(actorIdentity,'ALMSIVI_ACTOR_DETACH',{actor=actorIdentity}) state.attachments[key]=nil end
        if state.conversation.target and identity.same(state.conversation.target,actorIdentity) then
            conversation.clearTarget(state.conversation)
            state.emit('ALMSIVI_TARGET',{target=nil,audience={}})
        end
    end
    return removed
end

function M.recordVanillaDialogue(state,event)
    if type(event)~='table' or type(event.text)~='string' or event.text=='' then
        return nil,'invalid_vanilla_dialogue'
    end
    state.recentVanillaDialogue=state.recentVanillaDialogue or {}
    state.recentVanillaDialogue[#state.recentVanillaDialogue+1]=util.copy(event)
    while #state.recentVanillaDialogue>constants.MAX_RECENT_VANILLA_DIALOGUE do
        table.remove(state.recentVanillaDialogue,1)
    end
    return true
end

local function emitAgents(state)
    local snapshot=agentRegistry.snapshot(state.agents)
    local signatureParts={}
    for _,agent in ipairs(snapshot) do
        signatureParts[#signatureParts+1]=table.concat({
            identity.key(agent.identity) or '',
            tostring(agent.source or ''),
            tostring(agent.pinned==true),
            tostring(math.floor((tonumber(agent.distance) or 0)/64)),
        },':')
    end
    local signature=table.concat(signatureParts,'|')
    if signature==state.agentsSignature then return false end
    state.agentsSignature=signature
    state.emit('ALMSIVI_AGENTS',{agents=snapshot})
    return true
end

local function detachAgent(state,actor,reason)
    local key=identity.key(actor)
    if key then state.combatVerified[key]=nil end
    local removedThreat=key and state.combatThreats[key]~=nil
    if key then state.combatThreats[key]=nil end
    if key and state.attachments[key] then
        state.sendActor(actor,'ALMSIVI_ACTOR_DETACH',{actor=actor,reason=reason,generation=state.generation})
        state.attachments[key]=nil
    end
    if state.conversation.target and identity.same(state.conversation.target,actor) then
        conversation.clearTarget(state.conversation)
        state.emit('ALMSIVI_TARGET',{target=nil,audience={}})
    end
    if removedThreat then emitCombatState(state) end
end

function M.manageCandidate(state,candidate,source,silent)
    local policy={allowHostile=source~='auto' or state.settings and state.settings.autoActivate
            and state.settings.autoActivate.addHostile==true,
        allowCreatures=source~='auto' or state.settings and state.settings.autoActivate
            and state.settings.autoActivate.addCreatures==true}
    local actor,reason=targeting.validate(candidate,state.registry,policy)
    if not actor then return nil,reason end
    local entry,status=agentRegistry.activate(state.agents,actor,source,candidate.distance)
    if status=='deactivated' then
        detachAgent(state,actor,'manual_deactivate')
        if not silent then emitAgents(state) end
        return actor,status
    end
    if not entry then return nil,status end
    if status=='activated' or status=='upgraded' then
        local managed,manageReason=state.manageActor(actor,state.generation)
        if not managed then
            agentRegistry.remove(state.agents,actor)
            return nil,manageReason
        end
        state.attachments[identity.key(actor)]=actor
    end
    if not silent then emitAgents(state) end
    return actor,status
end

function M.scanAgents(state,candidates)
    local settings=state.settings and state.settings.autoActivate or {}
    local policy={allowHostile=settings.addHostile==true,allowCreatures=settings.addCreatures==true}
    agentRegistry.beginScan(state.agents)
    local added=0
    if settings.enabled~=false then
        for _,candidate in ipairs(candidates or {}) do
            local valid=targeting.validate(candidate,state.registry,policy)
            if valid and agentRegistry.markSeen(state.agents,valid,candidate.distance) then
                -- Existing agents only need their presence refreshed.
            elseif valid and added<6 then
                local actor,status=M.manageCandidate(state,candidate,'auto',true)
                if actor and status=='activated' then
                    added=added+1
                end
            end
        end
    end
    for _,actor in ipairs(agentRegistry.sweep(state.agents,4)) do detachAgent(state,actor,'auto_out_of_range') end
    emitAgents(state)
    return added
end

-- Match CHIM's no-crosshair manual activation without toggling already pinned actors off.
function M.manageNearby(state,candidates)
    local added=0
    local retained=0
    for index,candidate in ipairs(candidates or {}) do
        if index>constants.MAX_AUDIENCE then break end
        local actor=type(candidate)=='table' and candidate.identity or nil
        local entry=actor and agentRegistry.get(state.agents,actor) or nil
        if entry and entry.source=='manual' then retained=retained+1
        else
            local managed,status=M.manageCandidate(state,candidate,'manual',true)
            if managed and (status=='activated' or status=='upgraded') then added=added+1 end
        end
    end
    emitAgents(state)
    return added,retained
end

-- Enforce the auto-activation hostility policy once the actor-local AI package becomes visible.
function M.actorCombatStatus(state,event)
    if type(event)~='table' or not identity.validate(event.actor) then return nil,'invalid_actor' end
    local key=identity.key(event.actor)
    state.combatVerified[key]=true
    if event.hostile_to_player==true then state.combatThreats[key]=util.copy(event.actor)
    else state.combatThreats[key]=nil end
    emitCombatState(state)
    state.emit('ALMSIVI_ACTOR_ACTIVITY',{actor=util.copy(event.actor),activity=event.activity,target=util.copy(event.target)})
    local entry=agentRegistry.get(state.agents,event.actor)
    if not entry then return nil,'agent_not_found' end
    if event.hostile_to_player~=true or entry.source~='auto' then return false,'agent_retained' end
    local settings=state.settings and state.settings.autoActivate or {}
    if settings.addHostile==true then return false,'hostile_allowed' end
    agentRegistry.remove(state.agents,event.actor)
    detachAgent(state,event.actor,'auto_hostile_to_player')
    emitAgents(state)
    return true,'hostile_removed'
end

function M.selectTarget(state,candidate)
    local actor,reason=M.manageCandidate(state,candidate,'target',true)
    if not actor then return nil,reason end
    conversation.setTarget(state.conversation,actor)
    state.emit('ALMSIVI_TARGET',{target=actor,audience={actor}})
    emitAgents(state)
    return actor
end

function M.addAudience(state,candidate)
    local actor,reason=M.manageCandidate(state,candidate,'target',true)
    if not actor then return nil,reason end
    local ok,addReason=conversation.addAudience(state.conversation,actor)
    if not ok then return nil,addReason end
    local key=identity.key(actor)
    if not state.attachments[key] then state.attachments[key]=actor end
    local audience={}
    for index,item in ipairs(state.conversation.audience) do audience[index]=util.copy(item.identity) end
    state.emit('ALMSIVI_AUDIENCE',{target=util.copy(state.conversation.target),audience=audience})
    return actor
end

function M.clearAudience(state)
    local target=state.conversation.target
    state.conversation.audience={}
    if target then conversation.addAudience(state.conversation,target) end
    local audience={}
    for index,item in ipairs(state.conversation.audience) do audience[index]=util.copy(item.identity) end
    state.emit('ALMSIVI_AUDIENCE',{target=util.copy(target),audience=audience})
end

function M.submitText(state,args)
    if state.disabled or state.hardHalted then return nil,'almsivi_disabled' end
    for _,key in ipairs({'request_id','turn_id','message_id'}) do
        if not protocol.isUuid(args[key]) then return nil,'invalid_'..key end
    end
    local isRechat=args.ui_source=='almsivi_rechat'
    if not isRechat then state.rechat=nil end
    local requestId=args.request_id
    local turnId=args.turn_id
    local ok,reason=conversation.begin(state.conversation,requestId,turnId,args.input_key or args.text)
    if not ok then return nil,reason end
    local mode=({Standard=true,Whisper=true,Close=true,Shout=true})[state.dialogueMode]
        and state.dialogueMode or 'Standard'
    local audience={}
    local audienceKeys={}
    local selectedAudience=state.conversation.audience
    if mode=='Whisper' and state.conversation.target then
        selectedAudience={{identity=state.conversation.target,key=identity.key(state.conversation.target)}}
    end
    for _,entry in ipairs(selectedAudience) do
        table.insert(audience,entry.identity)
        audienceKeys[entry.key]=true
    end
    local hearingDistance=tonumber(state.settings and state.settings.autoActivate
        and state.settings.autoActivate.hearingDistance) or 0
    if mode=='Close' or mode=='Whisper' then hearingDistance=0
    elseif mode=='Shout' then hearingDistance=math.min(32768,hearingDistance*2) end
    if hearingDistance>0 then
        for _,entry in ipairs(agentRegistry.snapshot(state.agents)) do
            local key=identity.key(entry.identity)
            if #audience>=constants.MAX_AUDIENCE then break end
            if entry.distance<=hearingDistance and key and not audienceKeys[key] then
                table.insert(audience,entry.identity)
                audienceKeys[key]=true
            end
        end
    end
    args.context=args.context or {}
    args.context.audience=audience
    args.context.dialogueMode=mode
    args.context.recentVanillaDialogue=util.arrayCopy(state.recentVanillaDialogue or {},constants.MAX_RECENT_VANILLA_DIALOGUE)
    local dto,buildReason=protocol.turn({message_id=args.message_id,request_id=requestId,turn_id=turnId,
        installation_id=args.installation_id,profile_id=args.profile_id,playthrough_id=args.playthrough_id,
        session_id=state.sessionId,generation=state.generation,created_at=args.created_at,platform=args.platform,
        content_fingerprint=args.content_fingerprint,text=args.text,language=args.language,
        speaker=args.speaker,target=state.conversation.target,audience=audience,context=context.snapshot(args.context),
        capabilities=args.capabilities,recent_action_results=args.recent_action_results,ui_source=args.ui_source,
        action_request=args.action_request})
    if not dto then state.conversation.turn=nil return nil,buildReason end
    local submitted,nativeReason=state.bridge.submitTurn(dto)
    if not submitted then state.conversation.turn=nil return nil,nativeReason end
    if not isRechat then
        state.rechatSeed=util.copy(args)
        state.rechat={chainId=state.bridge.newMessageId and state.bridge.newMessageId() or args.request_id,
            originTurnId=args.turn_id,depth=0,lastSpeaker=nil,lastAddressee=nil,cancelled=false}
    end
    state.recentVanillaDialogue={}
    state.emit('ALMSIVI_TURN',{status='queued',message_id=args.message_id,request_id=requestId,turn_id=turnId,
        created_at=args.created_at})
    return requestId
end

local function preparePendingMedia(state)
    local finished={}
    local function reportFailure(mediaId,item,reason)
        local messageId=state.bridge.newMessageId and state.bridge.newMessageId()
        local completedAt=state.bridge.utcNow and state.bridge.utcNow()
        if messageId and completedAt and state.bridge.submitDialogueDeliveryResult then
            local result=protocol.dialogueDeliveryResult({message_id=messageId,request_id=item.requestId,
                dialogue_message_id=item.messageId,turn_id=item.turnId,session_id=item.sessionId,
                generation=item.generation,speaker=item.speaker,status='failed',reason_code='media_prepare_failed',
                completed_at=completedAt})
            if result then state.bridge.submitDialogueDeliveryResult(result) end
        end
        if state.bridge.releaseMedia then state.bridge.releaseMedia(mediaId) end
        finished[#finished+1]=mediaId
        print('[ALMSIVI] media preparation failed: '..tostring(reason))
    end
    for mediaId,item in pairs(state.conversation.pendingMedia) do
        if item.status=='new' then
            local requestId,reason=state.bridge.prepareMedia(item.descriptor)
            if requestId then item.status='preparing' item.prepareRequestId=requestId
            else
                item.status='failed' item.reason=reason or 'media_prepare_rejected'
                reportFailure(mediaId,item,item.reason)
            end
        elseif item.status=='preparing' then
            local status=state.bridge.mediaStatus(mediaId)
            if status and status.state=='ready' then
                item.status='ready'
            elseif status and (status.state=='failed' or status.state=='expired' or status.state=='cancelled') then
                item.status=status.state item.reason=status.reason
                reportFailure(mediaId,item,status.reason or status.state)
            end
        end
    end
    for _,mediaId in ipairs(finished) do state.conversation.pendingMedia[mediaId]=nil end
    if state.activeSpeechMediaId then return end
    local nextMediaId,nextItem
    for mediaId,item in pairs(state.conversation.pendingMedia) do
        if not nextItem or (item.ordinal or math.huge)<(nextItem.ordinal or math.huge) then
            nextMediaId,nextItem=mediaId,item
        end
    end
    if not nextItem or nextItem.status~='ready' then return end
    nextItem.status='playing' state.activeSpeechMediaId=nextMediaId
    local ttsVolumeBoost=math.max(1,math.min(4,math.floor(tonumber(
        state.settings and state.settings.presentation and state.settings.presentation.ttsVolumeBoost) or 3)))
    local command={actor=nextItem.speaker,
        media_id=nextMediaId,subtitle=nextItem.subtitle,request_id=nextItem.requestId,turn_id=nextItem.turnId,
        session_id=nextItem.sessionId,dialogue_message_id=nextItem.messageId,generation=nextItem.generation,
        expires_at=nextItem.descriptor.expires_at,tts_volume_boost=ttsVolumeBoost}
    local sent,reason
    if nextItem.speaker.kind=='narrator' and state.settings and state.settings.narrator
        and state.settings.narrator.enabled~=true then
        state.activeSpeechMediaId=nil nextItem.status='failed'
        reportFailure(nextMediaId,nextItem,'narrator_disabled')
        return
    elseif nextItem.speaker.kind=='narrator' then state.emit('ALMSIVI_NARRATOR_SPEAK',command) sent=true
    else sent,reason=state.sendActor(nextItem.speaker,'ALMSIVI_ACTOR_SPEAK',command) end
    if not sent then
        state.activeSpeechMediaId=nil nextItem.status='failed'
        reportFailure(nextMediaId,nextItem,reason or 'actor_speech_unavailable')
        for _,mediaId in ipairs(finished) do state.conversation.pendingMedia[mediaId]=nil end
    end
end

-- Continue only a player-started conversation and only after the complete speech queue has played.
local function submitPlaybackRechat(state)
    local chain=state.rechat
    local settings=state.settings and state.settings.behavior or {}
    local maxDepth=math.max(1,math.min(20,math.floor(tonumber(settings.rechatMaxDepth or settings.rechat_max_depth) or 10)))
    if not chain or chain.cancelled or settings.rechat~=true or chain.depth>=maxDepth
        or state.dialogueMode=='Whisper' or state.dialogueMode=='Close' or not state.rechatSeed
        or not state.conversation.turn or not state.conversation.turn.terminal then return false end
    if state.activeSpeechMediaId or next(state.conversation.pendingMedia)~=nil then return false end
    local target=chain.lastSpeaker
    if not target or target.kind=='player' or not state.registry:resolve(target) then
        chain.cancelled=true return false
    end
    local metadata=state.bridge.nextTurnMetadata and state.bridge.nextTurnMetadata() or {}
    if not protocol.isUuid(metadata.message_id) or not protocol.isUuid(metadata.request_id)
        or not protocol.isUuid(metadata.turn_id) then chain.cancelled=true return false end
    conversation.setTarget(state.conversation,target)
    local args=util.copy(state.rechatSeed)
    for key,value in pairs(metadata) do args[key]=value end
    chain.depth=chain.depth+1
    args.input_key='rechat:'..chain.chainId..':'..tostring(chain.depth)
    args.text='Continue the active conversation naturally. Address the previous speaker or listener directly and do not repeat prior dialogue.'
    args.ui_source='almsivi_rechat'
    args.context=args.context or {}
    args.context.rechat={chain_id=chain.chainId,depth=chain.depth,max_depth=maxDepth,
        origin_turn_id=chain.originTurnId,previous_speaker=util.copy(chain.lastSpeaker),
        previous_listener=util.copy(chain.lastAddressee)}
    local submitted,reason=M.submitText(state,args)
    if not submitted then chain.cancelled=true print('[ALMSIVI] rechat rejected: '..tostring(reason)) return false end
    state.emit('ALMSIVI_RECHAT',{status='queued',chain_id=chain.chainId,depth=chain.depth,turn_id=metadata.turn_id})
    return true
end

-- Advance the single ordered speech lane only after the actor reports a terminal playback state.
function M.speechStatus(state,event)
    if type(event)~='table' or type(event.media_id)~='string' then return false end
    local item=state.conversation.pendingMedia[event.media_id]
    if event.active==true then
        if item then item.status='playing' end
        state.activeSpeechMediaId=event.media_id
        return item~=nil
    end
    if item then state.conversation.pendingMedia[event.media_id]=nil end
    if state.activeSpeechMediaId==event.media_id then state.activeSpeechMediaId=nil end
    if state.bridge and state.bridge.releaseMedia then state.bridge.releaseMedia(event.media_id) end
    if item and event.status=='played' then submitPlaybackRechat(state) end
    return item~=nil
end

-- A malformed player-local UI event must not stop the authoritative response lane from reaching
-- its terminal event or preparing later speech media.
local function emitInbound(state,name,payload)
    local ok,reason=pcall(state.emit,name,payload)
    if not ok then print('[ALMSIVI] player event delivery failed: '..tostring(name)..' '..tostring(reason)) end
    return ok
end

function M.poll(state)
    if state.disabled or state.hardHalted then return 0 end
    local results=state.bridge.pollResults(constants.MAX_INBOUND_RESULTS) or {}
    local accepted=0
    for index=1,math.min(#results,constants.MAX_INBOUND_RESULTS) do
        local event=results[index]
        local ok,reason=state.events:accept(event)
        if ok then
            if reason=='cursor_resynced' then
                print('[ALMSIVI] response cursor recovered at sequence '..tostring(event.sequence)
                    ..' ('..tostring(event.type)..')')
            end
            local applyOk,applied,applyReason=pcall(conversation.apply,state.conversation,event)
            if not applyOk then
                applyReason='lua_exception: '..tostring(applied)
                applied=false
            end
            if applied then
                accepted=accepted+1
                if event.type=='dialogue.complete' and state.rechat then
                    state.rechat.lastSpeaker=util.copy(event.payload.speaker)
                    state.rechat.lastAddressee=util.copy(event.payload.addressee)
                elseif (event.type=='turn.failed' or event.type=='turn.cancelled') and state.rechat then
                    state.rechat.cancelled=true
                end
                if event.type=='action.intent' then
                    if event.payload.tier>=2 then
                        state.pendingConfirmations[event.payload.action_id]=util.copy(event.payload)
                        emitInbound(state,'ALMSIVI_ACTION_CONFIRMATION',{action_id=event.payload.action_id,name=event.payload.name,
                            actor=util.copy(event.payload.actor),target=util.copy(event.payload.target)})
                    else state.sendActor(event.payload.actor,'ALMSIVI_ACTOR_ACTION',event.payload) end
                end
                emitInbound(state,'ALMSIVI_EVENT',event)
                if event.type=='turn.complete' or event.type=='turn.failed' or event.type=='turn.cancelled' then
                    print('[ALMSIVI] response turn terminal: '..tostring(event.type)..' '..tostring(event.turn_id))
                end
            else
                print('[ALMSIVI] response event dropped: '..tostring(event.type)..' '..tostring(applyReason))
                emitInbound(state,'ALMSIVI_DROP',{reason=applyReason})
            end
        elseif reason~='duplicate_event' and reason~='stale_generation' and reason~='stale_session' then
            print('[ALMSIVI] response event rejected: '..tostring(reason)..' at sequence '..tostring(event.sequence))
            emitInbound(state,'ALMSIVI_RESYNC',{reason=reason,cursor=state.events:cursor()})
        end
    end
    preparePendingMedia(state)
    return accepted
end


function M.confirmAction(state,actionId,approved)
    local command=state.pendingConfirmations[actionId]
    if not command then return nil,'confirmation_not_found' end
    state.pendingConfirmations[actionId]=nil
    local eventName=approved and 'ALMSIVI_ACTOR_ACTION' or 'ALMSIVI_ACTOR_REJECT'
    return state.sendActor(command.actor,eventName,command)
end

function M.interrupt(state,reason)
    reason=reason or 'halt_ai_actions'
    signalAllActors(state,'ALMSIVI_ACTOR_STOP',reason)
    state.emit('ALMSIVI_NARRATOR_STOP',{reason=reason})
    local previousGeneration=state.generation
    state.generation=conversation.interrupt(state.conversation,reason)
    if state.bridge and state.bridge.cancelGeneration then state.bridge.cancelGeneration(previousGeneration) end
    state.events=nil
    state.activeSpeechMediaId=nil
    state.rechat=nil state.rechatSeed=nil
    state.pendingConfirmations={}
    state.hardHalted=false
    state.emit('ALMSIVI_HALT',{generation=state.generation,reason=reason,recoverable=true})
    return true
end

function M.stopDialogue(state,reason)
    reason=reason or 'stop_dialogue'
    signalAllActors(state,'ALMSIVI_ACTOR_STOP_SPEECH',reason)
    state.emit('ALMSIVI_NARRATOR_STOP',{reason=reason})
    local previousGeneration=state.generation
    state.generation=conversation.interrupt(state.conversation,reason)
    if state.bridge and state.bridge.cancelGeneration then state.bridge.cancelGeneration(previousGeneration) end
    state.events=nil
    state.activeSpeechMediaId=nil
    state.rechat=nil state.rechatSeed=nil
    state.pendingConfirmations={}
    state.emit('ALMSIVI_DIALOGUE_STOPPED',{generation=state.generation,reason=reason})
    return true
end

function M.haltActions(state,reason)
    reason=reason or 'halt_ai_actions'
    signalAllActors(state,'ALMSIVI_ACTOR_HALT_ACTIONS',reason)
    state.pendingConfirmations={}
    state.emit('ALMSIVI_ACTIONS_HALTED',{generation=state.generation,reason=reason})
    return true
end

function M.hardHalt(state)
    detachAll(state,'hard_halt')
    state.bridge.halt() conversation.halt(state.conversation)
    state.generation=state.conversation.generation state.hardHalted=true state.pendingConfirmations={}
    state.activeSpeechMediaId=nil
    state.rechat=nil state.rechatSeed=nil
    state.emit('ALMSIVI_NARRATOR_STOP',{reason='hard_halt'})
    state.emit('ALMSIVI_HALT',{generation=state.generation,reason='hard_halt',recoverable=false})
end

-- Preserve the original public entry point while making the in-game control recoverable.
function M.halt(state) return M.interrupt(state,'halt_ai_actions') end

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
