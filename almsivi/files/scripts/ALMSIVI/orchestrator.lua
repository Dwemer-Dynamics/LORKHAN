local constants=require('scripts.ALMSIVI.constants')
local context=require('scripts.ALMSIVI.context')
local conversation=require('scripts.ALMSIVI.conversation')
local identity=require('scripts.ALMSIVI.identity')
local protocol=require('scripts.ALMSIVI.protocol')
local storage=require('scripts.ALMSIVI.storage')
local targeting=require('scripts.ALMSIVI.targeting')
local util=require('scripts.ALMSIVI.util')

local M={}

function M.new(bridge,emit,sendActor)
    local generation=bridge and bridge.generation and bridge.generation() or 1
    local state={bridge=bridge,emit=emit or function() end,sendActor=sendActor or function() return nil,'actor_sender_unavailable' end,
        generation=generation,sessionId=nil,registry=identity.Registry(),
        conversation=conversation.new(generation),events=nil,attachments={},media={},pendingConfirmations={},
        pendingVoice=nil,pendingStt={},openMic=false,openMicRequested=false,
        pendingAutonomy={},autonomyRequested=false,disabled=false,hardHalted=false}
    return state
end

local function detachAll(state,reason)
    for _,actorIdentity in pairs(state.attachments) do
        state.sendActor(actorIdentity,'ALMSIVI_ACTOR_DETACH',{actor=actorIdentity,reason=reason,generation=state.generation})
    end
    state.attachments={}
end

function M.lifecycle(state,kind)
    if state.bridge and state.bridge.cancelVoiceCapture then state.bridge.cancelVoiceCapture()
    elseif state.bridge and state.bridge.stopVoiceCapture then state.bridge.stopVoiceCapture() end
    detachAll(state,kind)
    state.generation=conversation.invalidate(state.conversation,kind)
    if state.bridge then state.bridge.cancelGeneration(state.generation-1) end
    state.events=state.sessionId and protocol.CursoredEvents(state.sessionId,state.generation) or nil
    state.pendingConfirmations={}
    state.pendingVoice=nil state.pendingStt={} state.openMic=false state.openMicRequested=false
    state.pendingAutonomy={} state.autonomyRequested=false
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
    if removed and key and state.attachments[key] then state.sendActor(actorIdentity,'ALMSIVI_ACTOR_DETACH',{actor=actorIdentity}) state.attachments[key]=nil end
    return removed
end

function M.selectTarget(state,candidate)
    local actor,reason=targeting.validate(candidate,state.registry)
    if not actor then return nil,reason end
    conversation.setTarget(state.conversation,actor)
    local key=identity.key(actor)
    if not state.attachments[key] then state.attachments[key]=actor end
    state.emit('ALMSIVI_TARGET',{target=actor,audience={actor}}) return actor
end

local autonomyPrompt={
    greeting='[Autonomy: greeting] Begin a natural, context-aware greeting to the player as the selected character.',
    rechat='[Autonomy: rechat] Continue the recent conversation naturally as the selected character without repeating prior lines.',
    boredom='[Autonomy: boredom] Start a brief, context-aware conversation about the current place, events, or relationship.',
}

function M.pollAutonomy(state)
    if not state.bridge or not state.bridge.pollAutonomy then return 0 end
    local directives=state.bridge.pollAutonomy(3) or {}
    for _,directive in ipairs(directives) do
        if type(directive)=='table' and protocol.isUuid(directive.schedule_id) and autonomyPrompt[directive.kind]
            and #state.pendingAutonomy<3 then table.insert(state.pendingAutonomy,util.copy(directive)) end
    end
    if state.autonomyRequested or #state.pendingAutonomy==0 then return #directives end
    if state.conversation.turn and not state.conversation.turn.terminal then return #directives end
    if not state.conversation.target then
        local skipped=table.remove(state.pendingAutonomy,1)
        state.emit('ALMSIVI_AUTONOMY_STATUS',{status='skipped',reason='target_required',schedule_id=skipped.schedule_id})
        return #directives
    end
    state.autonomyRequested=true
    state.emit('ALMSIVI_AUTONOMY_CONTEXT_REQUEST',{directive=util.copy(state.pendingAutonomy[1]),
        target=util.copy(state.conversation.target)})
    return #directives
end

function M.runAutonomy(state,args)
    local directive=state.pendingAutonomy[1]
    state.autonomyRequested=false
    if not directive or not args or not args.directive or args.directive.schedule_id~=directive.schedule_id then
        return nil,'autonomy_directive_mismatch'
    end
    table.remove(state.pendingAutonomy,1)
    if not identity.validate(args.speaker) then return nil,'invalid_speaker' end
    local target=state.conversation.target
    if not target or not state.registry:resolve(target) then return nil,'target_inactive' end
    local metadata=state.bridge.nextTurnMetadata and state.bridge.nextTurnMetadata() or {}
    local request={text=autonomyPrompt[directive.kind],input_key='autonomy:'..directive.schedule_id..':'..directive.issued_at,
        language=args.language or 'en-US',speaker=util.copy(args.speaker),context=util.copy(args.context or {}),
        capabilities=util.arrayCopy(args.capabilities or {}),recent_action_results=util.arrayCopy(args.recent_action_results or {}),
        ui_source='almsivi_autonomy'}
    for key,value in pairs(metadata) do request[key]=value end
    local submitted,reason=M.submitText(state,request)
    state.emit('ALMSIVI_AUTONOMY_STATUS',{status=submitted and 'queued' or 'failed',reason=reason,
        schedule_id=directive.schedule_id,request_id=submitted})
    return submitted,reason
end

function M.startVoice(state,args)
    if state.disabled or state.hardHalted then return nil,'almsivi_disabled' end
    if not state.bridge or not state.bridge.startVoiceCapture then return nil,'voice_capture_unavailable' end
    if state.conversation.turn and not state.conversation.turn.terminal then return nil,'turn_in_flight' end
    if not state.conversation.target then return nil,'target_required' end
    if not args or not identity.validate(args.speaker) then return nil,'invalid_speaker' end
    local started,reason=state.bridge.startVoiceCapture(args.automatic==true)
    if not started then return nil,reason or 'voice_capture_failed' end
    state.pendingVoice={speaker=util.copy(args.speaker),target=util.copy(state.conversation.target),
        context=util.copy(args.context or {}),language=args.language or 'en-US',
        capabilities=util.arrayCopy(args.capabilities or {}),recent_action_results=util.arrayCopy(args.recent_action_results or {}),
        ui_source=args.ui_source or 'almsivi_voice',continuous=args.continuous==true}
    state.emit('ALMSIVI_VOICE_STATUS',{status=args.automatic and 'listening' or 'recording',
        continuous=args.continuous==true})
    return true
end

function M.enableOpenMic(state,args)
    state.openMic=true state.openMicRequested=false
    if state.conversation.turn and not state.conversation.turn.terminal then
        state.emit('ALMSIVI_VOICE_STATUS',{status='waiting',continuous=true})
        return true
    end
    args=args or {} args.automatic=true args.continuous=true args.ui_source='almsivi_open_mic'
    local started,reason=M.startVoice(state,args)
    if not started then state.openMic=false state.emit('ALMSIVI_VOICE_STATUS',{status='failed',reason=reason}) end
    return started,reason
end

function M.disableOpenMic(state)
    state.openMic=false state.openMicRequested=false
    if state.pendingVoice and state.pendingVoice.continuous then
        if state.bridge and state.bridge.cancelVoiceCapture then state.bridge.cancelVoiceCapture()
        elseif state.bridge and state.bridge.stopVoiceCapture then state.bridge.stopVoiceCapture() end
        state.pendingVoice=nil
    end
    state.emit('ALMSIVI_VOICE_STATUS',{status='open mic off'})
    return true
end

function M.pollOpenMic(state)
    if not state.openMic or state.openMicRequested or state.pendingVoice or next(state.pendingStt) then return false end
    if state.conversation.turn and not state.conversation.turn.terminal then return false end
    if not state.conversation.target or not state.registry:resolve(state.conversation.target) then
        state.openMic=false state.emit('ALMSIVI_VOICE_STATUS',{status='failed',reason='target_inactive'}) return false
    end
    state.openMicRequested=true
    state.emit('ALMSIVI_OPEN_MIC_CONTEXT_REQUEST',{target=util.copy(state.conversation.target)})
    return true
end

function M.runOpenMicContext(state,args)
    if not state.openMic then return nil,'open_mic_disabled' end
    state.openMicRequested=false
    args=args or {} args.automatic=true args.continuous=true args.ui_source='almsivi_open_mic'
    return M.startVoice(state,args)
end

function M.stopVoice(state)
    if not state.pendingVoice then return nil,'voice_capture_not_recording' end
    if state.bridge and state.bridge.stopVoiceCapture then state.bridge.stopVoiceCapture() end
    state.pendingVoice.stopping=true
    state.emit('ALMSIVI_VOICE_STATUS',{status='processing',continuous=state.pendingVoice.continuous==true})
    return true
end

function M.pollVoice(state)
    if not state.pendingVoice or not state.bridge or not state.bridge.voiceCaptureStatus then return false end
    local status=state.bridge.voiceCaptureStatus()
    if not status or status.state=='recording' or status.state=='idle' then return false end
    if status.state=='ready' then
        local metadata,reason=state.bridge.submitCapturedStt(state.pendingVoice.language)
        if not metadata then
            state.emit('ALMSIVI_VOICE_STATUS',{status='failed',reason=reason or 'stt_submit_failed'})
            state.pendingVoice=nil return false
        end
        state.pendingStt[metadata.request_id]=state.pendingVoice
        state.pendingVoice=nil
        state.emit('ALMSIVI_VOICE_STATUS',{status='transcribing',request_id=metadata.request_id,
            continuous=state.pendingStt[metadata.request_id].continuous==true})
        return true
    end
    local continuous=state.pendingVoice.continuous==true
    if continuous and status.error=='voice_not_detected' and state.openMic then
        state.emit('ALMSIVI_VOICE_STATUS',{status='listening',reason='voice_not_detected',continuous=true})
    else
        state.emit('ALMSIVI_VOICE_STATUS',{status='failed',reason=status.error or status.state,continuous=continuous})
        if continuous then state.openMic=false end
    end
    state.pendingVoice=nil
    return false
end

function M.addAudience(state,candidate)
    local actor,reason=targeting.validate(candidate,state.registry)
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
    local requestId=args.request_id
    local turnId=args.turn_id
    local ok,reason=conversation.begin(state.conversation,requestId,turnId,args.input_key or args.text)
    if not ok then return nil,reason end
    local audience={}
    for _,entry in ipairs(state.conversation.audience) do table.insert(audience,entry.identity) end
    args.context=args.context or {}
    args.context.audience=audience
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

local function preparePendingMedia(state)
    for mediaId,item in pairs(state.conversation.pendingMedia) do
        if item.status=='new' then
            local requestId,reason=state.bridge.prepareMedia(item.descriptor)
            if requestId then item.status='preparing' item.prepareRequestId=requestId
            else item.status='failed' item.reason=reason or 'media_prepare_rejected' end
        elseif item.status=='preparing' then
            local status=state.bridge.mediaStatus(mediaId)
            if status and status.state=='ready' then
                item.status='ready'
                state.sendActor(item.speaker,'ALMSIVI_ACTOR_SPEAK',{actor=item.speaker,media_id=mediaId,subtitle=item.subtitle,
                    request_id=item.requestId,turn_id=item.turnId,session_id=item.sessionId,
                    dialogue_message_id=item.messageId,generation=item.generation,
                    expires_at=item.descriptor.expires_at})
            elseif status and (status.state=='failed' or status.state=='expired' or status.state=='cancelled') then
                item.status=status.state item.reason=status.reason
            end
        end
    end
end

function M.poll(state)
    if state.disabled or state.hardHalted then return 0 end
    local results=state.bridge.pollResults(constants.MAX_INBOUND_RESULTS) or {}
    local accepted=0
    for index=1,math.min(#results,constants.MAX_INBOUND_RESULTS) do
        local event=results[index]
        local ok,reason=state.events:accept(event)
        if ok then
            if event.type=='stt.transcript' or event.type=='stt.failed' then
                local pending=state.pendingStt[event.request_id]
                state.pendingStt[event.request_id]=nil
                if event.type=='stt.transcript' and pending and (not pending.continuous or state.openMic) then
                    local active,selectReason=state.registry:resolve(pending.target)
                    if active and conversation.setTarget(state.conversation,pending.target) then
                        local metadata=state.bridge.nextTurnMetadata and state.bridge.nextTurnMetadata() or {}
                        for key,value in pairs(metadata) do pending[key]=value end
                        pending.text=event.payload.text pending.input_key='voice:'..event.message_id
                        pending.language=event.payload.language
                        local submitted,submitReason=M.submitText(state,pending)
                        if submitted then state.emit('ALMSIVI_VOICE_STATUS',{status='queued',request_id=submitted})
                        else state.emit('ALMSIVI_VOICE_STATUS',{status='failed',reason=submitReason}) end
                    else state.emit('ALMSIVI_VOICE_STATUS',{status='failed',reason=selectReason or 'target_inactive'}) end
                elseif event.type=='stt.transcript' and pending and pending.continuous then
                    state.emit('ALMSIVI_VOICE_STATUS',{status='open mic off'})
                elseif event.type=='stt.failed' then
                    state.emit('ALMSIVI_VOICE_STATUS',{status='failed',reason=event.payload.code})
                else state.emit('ALMSIVI_VOICE_STATUS',{status='failed',reason='stt_context_missing'}) end
                accepted=accepted+1
                state.emit('ALMSIVI_EVENT',event)
            else
            local applied,applyReason=conversation.apply(state.conversation,event)
            if applied then
                accepted=accepted+1
                if event.type=='action.intent' then
                    if event.payload.tier>=2 then
                        state.pendingConfirmations[event.payload.action_id]=util.copy(event.payload)
                        state.emit('ALMSIVI_ACTION_CONFIRMATION',{action_id=event.payload.action_id,name=event.payload.name,
                            actor=util.copy(event.payload.actor),target=util.copy(event.payload.target)})
                    else state.sendActor(event.payload.actor,'ALMSIVI_ACTOR_ACTION',event.payload) end
                end
                state.emit('ALMSIVI_EVENT',event)
            else state.emit('ALMSIVI_DROP',{reason=applyReason}) end
            end
        elseif reason~='duplicate_event' and reason~='stale_generation' and reason~='stale_session' then
            state.emit('ALMSIVI_RESYNC',{reason=reason,cursor=state.events:cursor()})
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

function M.halt(state)
    detachAll(state,'hard_halt')
    state.bridge.halt() conversation.halt(state.conversation)
    state.generation=state.conversation.generation state.hardHalted=true state.pendingConfirmations={}
    state.pendingVoice=nil state.pendingStt={} state.openMic=false state.openMicRequested=false
    state.pendingAutonomy={} state.autonomyRequested=false
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
