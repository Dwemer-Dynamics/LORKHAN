local constants=require('scripts.LORKHAN.constants')
local agentRegistry=require('scripts.LORKHAN.agent_registry')
local context=require('scripts.LORKHAN.context')
local conversation=require('scripts.LORKHAN.conversation')
local identity=require('scripts.LORKHAN.identity')
local protocol=require('scripts.LORKHAN.protocol')
local playerInput=require('scripts.LORKHAN.player_input')
local responseQueue=require('scripts.LORKHAN.response_queue')
local storage=require('scripts.LORKHAN.storage')
local targeting=require('scripts.LORKHAN.targeting')
local util=require('scripts.LORKHAN.util')

local M={}

local function newAutonomyState()
    return {idleSeconds=0,combatSeconds=0,pending=nil,pendingSeconds=0,greetingQueue={},
        greeted={},interacted={},rotation=0,profileEvolutionSeconds=0}
end

function M.new(bridge,emit,sendActor,manageActor)
    local generation=bridge and bridge.generation and bridge.generation() or 1
    local state={bridge=bridge,emit=emit or function() end,sendActor=sendActor or function() return nil,'actor_sender_unavailable' end,
        generation=generation,sessionId=nil,registry=identity.Registry(),agents=agentRegistry.new(),
        manageActor=manageActor or function() return nil,'actor_manager_unavailable' end,
        conversation=conversation.new(generation),responseQueue=responseQueue.new(generation,generation),events=nil,
        attachments={},media={},pendingConfirmations={},actionFollowups={seen={},pending={}},
        activeSpeechMediaId=nil,rechat=nil,rechatSeed=nil,pendingVoice=nil,pendingStt={},openMic=false,openMicRequested=false,
        combatThreats={},combatActors={},combatVerified={},actorStates={},rechatEligibility=nil,
        autonomy=newAutonomyState(),
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
    state.emit('LORKHAN_COMBAT_STATUS',{active=count>0,count=count,threats=threats})
end

local function detachAll(state,reason)
    for _,actorIdentity in pairs(state.attachments) do
        state.sendActor(actorIdentity,'LORKHAN_ACTOR_DETACH',{actor=actorIdentity,reason=reason,generation=state.generation})
    end
    state.attachments={}
end

local function signalAllActors(state,eventName,reason)
    for _,actorIdentity in pairs(state.attachments) do
        state.sendActor(actorIdentity,eventName,{actor=actorIdentity,reason=reason,generation=state.generation})
    end
end

local function currentRuntimeGeneration(state)
    local reported=state.bridge and state.bridge.generation and state.bridge.generation()
    return type(reported)=='number' and reported%1==0 and reported>=1 and reported or state.generation
end

local function emitQueue(state)
    state.emit('LORKHAN_QUEUE',responseQueue.snapshot(state.responseQueue))
end

local function reportQueuedDialogue(state,item,status,reason)
    if not state.bridge or not state.bridge.newMessageId or not state.bridge.utcNow
        or not state.bridge.submitDialogueDeliveryResult then return false end
    local result=protocol.dialogueDeliveryResult({message_id=state.bridge.newMessageId(),request_id=item.requestId,
        dialogue_message_id=item.line.line_id,turn_id=item.turnId,session_id=item.sessionId,
        generation=item.generation,speaker=item.line.speaker_identity,status=status,
        reason_code=reason,completed_at=state.bridge.utcNow()})
    if not result then return false end
    return state.bridge.submitDialogueDeliveryResult(result)~=nil
end

local function reportQueuedAction(state,item,status,reason)
    if not item.intent or not state.bridge or not state.bridge.newMessageId or not state.bridge.utcNow
        or not state.bridge.submitActionResult then return false end
    local result={schema='lorkhan.action-result.v1',message_id=state.bridge.newMessageId(),request_id=item.requestId,
        action_id=item.intent.action_id,turn_id=item.turnId,session_id=item.sessionId,generation=item.generation,
        status=status,reason_code=reason,observed={},completed_at=state.bridge.utcNow()}
    return state.bridge.submitActionResult(result)~=nil
end

local function cancelResponseLane(state,reason,stopSpeech)
    if stopSpeech then
        signalAllActors(state,'LORKHAN_ACTOR_STOP_SPEECH',reason)
        state.emit('LORKHAN_NARRATOR_STOP',{reason=reason})
    end
    local released,undelivered=responseQueue.cancel(state.responseQueue,reason)
    for _,item in ipairs(undelivered) do reportQueuedDialogue(state,item,'interrupted',reason) end
    if state.bridge and state.bridge.releaseMedia then
        for _,mediaId in ipairs(released) do state.bridge.releaseMedia(mediaId) end
    end
    state.activeSpeechMediaId=nil
    emitQueue(state)
end

function M.lifecycle(state,kind)
    if state.bridge and state.bridge.cancelVoiceCapture then state.bridge.cancelVoiceCapture() end
    cancelResponseLane(state,kind,true)
    detachAll(state,kind)
    state.generation=conversation.invalidate(state.conversation,kind)
    if state.bridge then state.bridge.cancelGeneration(state.generation-1) end
    state.events=state.sessionId and protocol.CursoredEvents(state.sessionId,state.generation) or nil
    state.pendingConfirmations={}
    state.actionFollowups={seen={},pending={}}
    responseQueue.setFence(state.responseQueue,state.generation,currentRuntimeGeneration(state),kind)
    emitQueue(state)
    state.activeSpeechMediaId=nil
    state.rechat=nil state.rechatSeed=nil
    state.pendingVoice=nil state.pendingStt={} state.openMic=false state.openMicRequested=false
    state.combatThreats={} state.combatActors={} state.combatVerified={} state.actorStates={}
    state.rechatEligibility=nil state.autonomy=newAutonomyState()
    state.recentVanillaDialogue={}
    state.hardHalted=false state.conversation.hardHalted=false
    state.registry:clear()
    state.agentsSignature=nil
    agentRegistry.clear(state.agents)
    emitCombatState(state)
    state.emit('LORKHAN_ACTOR_ACTIVITY',{reset=true})
    state.emit('LORKHAN_STATUS',{status='offline',reason=kind,generation=state.generation})
end

function M.configureSession(state,sessionId)
    state.sessionId=sessionId state.events=protocol.CursoredEvents(sessionId,state.generation)
    state.emit('LORKHAN_STATUS',{status='ready',generation=state.generation})
end

function M.activate(state,actorIdentity,object)
    return state.registry:activate(actorIdentity,object)
end

function M.deactivate(state,actorIdentity,object)
    local key=identity.key(actorIdentity)
    local removed=state.registry:deactivate(actorIdentity,object)
    if removed and key then
        agentRegistry.remove(state.agents,actorIdentity)
        state.combatVerified[key]=nil state.combatThreats[key]=nil state.combatActors[key]=nil state.actorStates[key]=nil
        emitCombatState(state)
        if state.attachments[key] then state.sendActor(actorIdentity,'LORKHAN_ACTOR_DETACH',{actor=actorIdentity}) state.attachments[key]=nil end
        if state.conversation.target and identity.same(state.conversation.target,actorIdentity) then
            cancelResponseLane(state,'target_inactive',true)
            conversation.clearTarget(state.conversation)
            state.emit('LORKHAN_TARGET',{target=nil,audience={}})
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
    state.emit('LORKHAN_AGENTS',{agents=snapshot})
    return true
end

local function detachAgent(state,actor,reason)
    local key=identity.key(actor)
    if key then state.combatVerified[key]=nil state.combatActors[key]=nil state.actorStates[key]=nil end
    local removedThreat=key and state.combatThreats[key]~=nil
    if key then state.combatThreats[key]=nil end
    if key and state.attachments[key] then
        state.sendActor(actor,'LORKHAN_ACTOR_DETACH',{actor=actor,reason=reason,generation=state.generation})
        state.attachments[key]=nil
    end
    if state.conversation.target and identity.same(state.conversation.target,actor) then
        conversation.clearTarget(state.conversation)
        state.emit('LORKHAN_TARGET',{target=nil,audience={}})
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
                    if actor.kind=='npc' then
                        state.emit('LORKHAN_AUTO_ACTIVATED',{actor=util.copy(actor)})
                        local key=identity.key(actor)
                        if key and not state.autonomy.greeted[key] and not state.autonomy.interacted[key]
                            and #state.autonomy.greetingQueue<32 then
                            state.autonomy.greetingQueue[#state.autonomy.greetingQueue+1]=util.copy(actor)
                        end
                    end
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
    local conversationState=({active=true,busy=true,sleeping=true,unconscious=true,inactive=true})[event.conversation_state]
        and event.conversation_state or (event.activity=='inactive' and 'inactive' or 'active')
    local probe=state.rechatEligibility
    if probe and event.probe_id==probe.probeId and probe.expected[key]
        and event.conversation_state_proven==true then
        probe.states[key]=conversationState
    end
    state.combatVerified[key]=true
    state.actorStates[key]={conversationState=conversationState,activity=event.activity,
        hostile=event.hostile_to_player==true}
    if event.activity=='combat' then state.combatActors[key]=util.copy(event.actor)
    else state.combatActors[key]=nil end
    if event.hostile_to_player==true then state.combatThreats[key]=util.copy(event.actor)
    else state.combatThreats[key]=nil end
    emitCombatState(state)
    if next(state.combatThreats)~=nil and state.settings and state.settings.behavior
        and state.settings.behavior.cancelDialogueOnCombat==true and state.rechat then
        state.rechat.cancelled=true
        state.rechatSeed=nil
        state.rechatEligibility=nil
    end
    state.emit('LORKHAN_ACTOR_ACTIVITY',{actor=util.copy(event.actor),activity=event.activity,target=util.copy(event.target)})
    local entry=agentRegistry.get(state.agents,event.actor)
    if not entry then return nil,'agent_not_found' end
    if conversationState=='inactive' then
        state.registry:deactivate(event.actor)
        agentRegistry.remove(state.agents,event.actor)
        detachAgent(state,event.actor,'actor_inactive')
        emitAgents(state)
        return true,'inactive_removed'
    end
    if event.hostile_to_player~=true or entry.source~='auto' then return false,'agent_retained' end
    local settings=state.settings and state.settings.autoActivate or {}
    if settings.addHostile==true then return false,'hostile_allowed' end
    agentRegistry.remove(state.agents,event.actor)
    detachAgent(state,event.actor,'auto_hostile_to_player')
    emitAgents(state)
    return true,'hostile_removed'
end

local function autonomyActorEligible(state,actor,combat)
    local key=identity.key(actor)
    local entry=key and agentRegistry.get(state.agents,actor) or nil
    local status=key and state.actorStates[key] or nil
    if not entry or not status or not state.registry:resolve(actor) then return false end
    if combat then return status.activity=='combat' end
    return status.conversationState=='active' and status.hostile~=true
end

local function setAutonomyTarget(state,actor)
    local ok=conversation.setTarget(state.conversation,actor)
    if not ok then return false end
    state.emit('LORKHAN_TARGET',{target=util.copy(actor),audience={util.copy(actor)}})
    return true
end

local function requestAutonomy(state,kind,actor)
    if not setAutonomyTarget(state,actor) then return false end
    state.rechat=nil state.rechatSeed=nil state.rechatEligibility=nil
    state.autonomy.pending={kind=kind,actor=util.copy(actor)}
    state.autonomy.pendingSeconds=0
    state.autonomy.idleSeconds=0
    if kind=='combat_bark' then state.autonomy.combatSeconds=0 end
    state.emit('LORKHAN_AUTONOMY_CONTEXT_REQUEST',{kind=kind,actor=util.copy(actor),generation=state.generation})
    return true
end

local function nextGreeting(state)
    local queue=state.autonomy.greetingQueue
    for index=#queue,1,-1 do
        local actor=queue[index]
        local key=identity.key(actor)
        if not key or state.autonomy.greeted[key] or state.autonomy.interacted[key]
            or not agentRegistry.get(state.agents,actor) then table.remove(queue,index) end
    end
    for index,actor in ipairs(queue) do
        if autonomyActorEligible(state,actor,false) then
            table.remove(queue,index)
            state.autonomy.greeted[identity.key(actor)]=true
            return actor
        end
    end
    return nil
end

local function nextBoredActor(state)
    local candidates={}
    for _,entry in ipairs(agentRegistry.snapshot(state.agents)) do
        if entry.identity.kind=='npc' and autonomyActorEligible(state,entry.identity,false) then
            candidates[#candidates+1]=entry.identity
        end
    end
    if #candidates==0 then return nil end
    state.autonomy.rotation=(state.autonomy.rotation%#candidates)+1
    return candidates[state.autonomy.rotation]
end

local function nextCombatActor(state)
    local candidates={}
    for _,actor in pairs(state.combatActors) do
        if actor.kind=='npc' and autonomyActorEligible(state,actor,true) then candidates[#candidates+1]=actor end
    end
    table.sort(candidates,function(left,right)return identity.key(left)<identity.key(right) end)
    return candidates[1]
end

-- Run one real-time, idle-only scheduler for greetings, boredom remarks, and combat barks.
function M.runAutonomy(state,elapsed)
    local seconds=math.max(0,math.min(5,tonumber(elapsed) or 0))
    local autonomy=state.autonomy
    if state.sessionId then autonomy.profileEvolutionSeconds=autonomy.profileEvolutionSeconds+seconds end
    if autonomy.pending then
        autonomy.pendingSeconds=autonomy.pendingSeconds+seconds
        if autonomy.pendingSeconds<5 then return false end
        autonomy.pending=nil autonomy.pendingSeconds=0
    end
    local behavior=state.settings and state.settings.behavior or {}
    local turn=state.conversation.turn
    local busy=state.disabled or state.hardHalted or not state.sessionId or not responseQueue.idle(state.responseQueue)
        or (turn and not turn.terminal) or state.pendingVoice~=nil or state.openMic==true
    if busy then autonomy.idleSeconds=0 return false end
    local profilePeriod=20*60
    if autonomy.profileEvolutionSeconds>=profilePeriod then
        local actors={}
        for _,entry in ipairs(agentRegistry.snapshot(state.agents)) do
            if entry.identity.kind=='npc' and state.registry:resolve(entry.identity) then
                actors[#actors+1]=util.copy(entry.identity)
                if #actors>=32 then break end
            end
        end
        autonomy.profileEvolutionSeconds=0
        if #actors>0 then
            state.emit('LORKHAN_PROFILE_EVOLUTION_REQUEST',{actors=actors,generation=state.generation})
            return true
        end
    end
    autonomy.idleSeconds=autonomy.idleSeconds+seconds
    if next(state.combatActors)~=nil then autonomy.combatSeconds=autonomy.combatSeconds+seconds
    else autonomy.combatSeconds=0 end

    local combatPeriod=math.max(5,math.min(300,tonumber(behavior.combatBarkPeriodSeconds) or 20))
    if behavior.combatBarks==true and autonomy.combatSeconds>=combatPeriod then
        local actor=nextCombatActor(state)
        if actor then return requestAutonomy(state,'combat_bark',actor) end
    end
    if behavior.autoGreeting==true then
        local actor=nextGreeting(state)
        if actor then return requestAutonomy(state,'greeting',actor) end
    end
    local boredomDelay=math.max(30,math.min(86400,tonumber(behavior.boredomDelaySeconds) or 180))
    if behavior.boredom==true and autonomy.idleSeconds>=boredomDelay then
        local actor=nextBoredActor(state)
        if actor then return requestAutonomy(state,'boredom',actor) end
    end
    return false
end

function M.selectTarget(state,candidate)
    local actor,reason=M.manageCandidate(state,candidate,'target',true)
    if not actor then return nil,reason end
    conversation.setTarget(state.conversation,actor)
    state.emit('LORKHAN_TARGET',{target=actor,audience={actor}})
    emitAgents(state)
    return actor
end

-- Capture one target/session/generation snapshot so a late transcript cannot be routed to a different NPC.
function M.startVoice(state,args)
    if state.disabled or state.hardHalted then return nil,'lorkhan_disabled' end
    if not state.bridge or not state.bridge.startVoiceCapture then return nil,'voice_capture_unavailable' end
    if state.conversation.turn and not state.conversation.turn.terminal then return nil,'turn_in_flight' end
    if not state.conversation.target then return nil,'target_required' end
    if not args or not identity.validate(args.speaker) then return nil,'invalid_speaker' end
    local sensitivity=math.max(100,math.min(5000,math.floor(tonumber(args.vad_sensitivity) or 700)))
    local endDelay=math.max(500,math.min(5000,math.floor(tonumber(args.end_delay_ms) or 900)))
    local deviceId=math.max(-1,math.min(31,math.floor(tonumber(args.recording_device) or -1)))
    local deviceName='Unavailable'
    if state.bridge.currentVoiceCaptureDeviceName then
        local called,name=pcall(state.bridge.currentVoiceCaptureDeviceName,deviceId)
        if called and type(name)=='string' then deviceName=name end
    end
    print('[LORKHAN] voice capture configuration: device_id='..tostring(deviceId)..' device='..deviceName..
        ' automatic='..tostring(args.automatic==true)..' threshold='..tostring(sensitivity)..' end_delay_ms='..tostring(endDelay))
    local started,reason=state.bridge.startVoiceCapture(args.automatic==true,sensitivity,endDelay,deviceId)
    if not started then return nil,reason or 'voice_capture_failed' end
    state.pendingVoice={speaker=util.copy(args.speaker),target=util.copy(state.conversation.target),
        target_key=identity.key(state.conversation.target),session_id=state.sessionId,generation=state.generation,
        context=util.copy(args.context or {}),language=args.language or 'en-US',
        capabilities=util.arrayCopy(args.capabilities or {}),recent_action_results=util.arrayCopy(args.recent_action_results or {}),
        ui_source=args.ui_source or 'lorkhan_voice',dialogueMode=args.dialogueMode,mood=util.copy(args.mood),continuous=args.continuous==true}
    state.emit('LORKHAN_VOICE_STATUS',{status=args.automatic and 'listening' or 'recording',continuous=args.continuous==true})
    return true
end

function M.stopVoice(state)
    if not state.pendingVoice then return nil,'voice_capture_not_recording' end
    state.bridge.stopVoiceCapture();state.pendingVoice.stopping=true
    state.emit('LORKHAN_VOICE_STATUS',{status='processing',continuous=state.pendingVoice.continuous==true});return true
end

function M.enableOpenMic(state,args)
    state.openMic=true state.openMicRequested=false
    args=args or {} args.automatic=true args.continuous=true args.ui_source='lorkhan_open_mic'
    local started,reason=M.startVoice(state,args)
    if not started then state.openMic=false state.emit('LORKHAN_VOICE_STATUS',{status='failed',reason=reason}) end
    return started,reason
end

function M.disableOpenMic(state)
    state.openMic=false state.openMicRequested=false
    if state.pendingVoice and state.pendingVoice.continuous then state.bridge.cancelVoiceCapture();state.pendingVoice=nil end
    state.emit('LORKHAN_VOICE_STATUS',{status='open mic off'});return true
end

function M.muteOpenMic(state)
    if not state.openMic then return nil,'open_mic_disabled' end
    state.openMicRequested=false
    if state.pendingVoice and state.pendingVoice.continuous then
        state.bridge.cancelVoiceCapture();state.pendingVoice=nil
    end
    state.emit('LORKHAN_VOICE_STATUS',{status='open mic muted',continuous=true});return true
end

function M.pollOpenMic(state)
    if not state.openMic or state.openMicRequested or state.pendingVoice or next(state.pendingStt) then return false end
    if state.conversation.turn and not state.conversation.turn.terminal then return false end
    if not state.conversation.target or not state.registry:resolve(state.conversation.target) then
        state.openMic=false state.emit('LORKHAN_VOICE_STATUS',{status='failed',reason='target_inactive'});return false end
    state.openMicRequested=true;state.emit('LORKHAN_OPEN_MIC_CONTEXT_REQUEST',{target=util.copy(state.conversation.target)});return true
end

function M.runOpenMicContext(state,args)
    if not state.openMic then return nil,'open_mic_disabled' end
    state.openMicRequested=false;args=args or {};args.automatic=true;args.continuous=true;args.ui_source='lorkhan_open_mic'
    return M.startVoice(state,args)
end

function M.pollVoice(state)
    if not state.pendingVoice or not state.bridge or not state.bridge.voiceCaptureStatus then return false end
    local status=state.bridge.voiceCaptureStatus();if not status or status.state=='recording' or status.state=='idle' then return false end
    if status.state=='ready' then
        print('[LORKHAN] captured voice ready: device_id='..tostring(status.device_id)..
            ' device='..tostring(status.device_name)..' wav_bytes='..tostring(status.bytes)..
            ' pcm_bytes='..tostring(status.pcm_bytes)..' duration_ms='..tostring(status.duration_ms)..
            ' peak='..tostring(status.peak_amplitude)..' rms='..tostring(status.rms_amplitude))
        local metadata,reason=state.bridge.submitCapturedStt(state.pendingVoice.language)
        if not metadata then
            print('[LORKHAN] captured voice submission failed: '..tostring(reason or 'stt_submit_failed'))
            state.emit('LORKHAN_VOICE_STATUS',{status='failed',reason=reason or 'stt_submit_failed'});state.pendingVoice=nil;return false
        end
        state.pendingStt[metadata.request_id]=state.pendingVoice;state.pendingVoice=nil
        print('[LORKHAN] captured voice submitted for transcription: '..tostring(metadata.request_id))
        state.emit('LORKHAN_VOICE_STATUS',{status='transcribing',request_id=metadata.request_id,
            continuous=state.pendingStt[metadata.request_id].continuous==true});return true
    end
    local continuous=state.pendingVoice.continuous==true
    if continuous and status.error=='voice_not_detected' and state.openMic then
        state.emit('LORKHAN_VOICE_STATUS',{status='listening',reason='voice_not_detected',continuous=true})
    else
        print('[LORKHAN] voice capture failed: '..tostring(status.error or status.state)..
            ' device_id='..tostring(status.device_id)..' device='..tostring(status.device_name)..
            ' pcm_bytes='..tostring(status.pcm_bytes)..' peak='..tostring(status.peak_amplitude)..
            ' rms='..tostring(status.rms_amplitude))
        state.emit('LORKHAN_VOICE_STATUS',{status='failed',reason=status.error or status.state,continuous=continuous});if continuous then state.openMic=false end
    end
    state.pendingVoice=nil;return false
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
    state.emit('LORKHAN_AUDIENCE',{target=util.copy(state.conversation.target),audience=audience})
    return actor
end

function M.clearAudience(state)
    local target=state.conversation.target
    state.conversation.audience={}
    if target then conversation.addAudience(state.conversation,target) end
    local audience={}
    for index,item in ipairs(state.conversation.audience) do audience[index]=util.copy(item.identity) end
    state.emit('LORKHAN_AUDIENCE',{target=util.copy(target),audience=audience})
end

function M.submitText(state,args)
    if state.disabled or state.hardHalted then return nil,'lorkhan_disabled' end
    for _,key in ipairs({'request_id','turn_id','message_id'}) do
        if not protocol.isUuid(args[key]) then return nil,'invalid_'..key end
    end
    local isRechat=args.ui_source=='lorkhan_rechat'
    local isActionFollowup=args.ui_source=='lorkhan_action_followup'
    local isAutonomy=({lorkhan_auto_greeting=true,lorkhan_auto_boredom=true,
        lorkhan_auto_combat_bark=true})[args.ui_source]==true
    if isAutonomy then
        state.autonomy.pending=nil state.autonomy.pendingSeconds=0 state.autonomy.idleSeconds=0
        if not responseQueue.idle(state.responseQueue)
            or state.conversation.turn and not state.conversation.turn.terminal then return nil,'autonomy_busy' end
    end
    local isContinuation=isRechat or isActionFollowup or isAutonomy
    if not isContinuation then
        state.rechat=nil state.rechatEligibility=nil
        if not responseQueue.idle(state.responseQueue) then cancelResponseLane(state,'superseded_by_player',true) end
        local targetKey=identity.key(state.conversation.target)
        if targetKey then state.autonomy.interacted[targetKey]=true end
    end
    local requestId=args.request_id
    local turnId=args.turn_id
    local ok,reason=conversation.begin(state.conversation,requestId,turnId,args.input_key or args.text)
    if not ok then return nil,reason end
    local parsed,parseReason=playerInput.parse(args.text)
    if not parsed then state.conversation.turn=nil return nil,parseReason end
    args.text=parsed.text
    local requestedMode=args.dialogueMode
    local mode=({Standard=true,Whisper=true,Close=true,Shout=true})[requestedMode] and requestedMode
        or (({Standard=true,Whisper=true,Close=true,Shout=true})[state.dialogueMode] and state.dialogueMode or 'Standard')
    if parsed.mode then mode=parsed.mode end
    local mood,moodReason=playerInput.validateMood(args.mood)
    if moodReason then state.conversation.turn=nil return nil,moodReason end
    local audience={}
    local audienceKeys={}
    local selectedAudience=state.conversation.audience
    if isRechat and type(args.rechatAudience)=='table' then
        selectedAudience={}
        for _,actor in ipairs(args.rechatAudience) do
            local key=identity.key(actor)
            if key then selectedAudience[#selectedAudience+1]={identity=actor,key=key} end
        end
    end
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
    if hearingDistance>0 and not isRechat then
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
    local runtimeGeneration=currentRuntimeGeneration(state)
    local dto,buildReason=protocol.turn({message_id=args.message_id,request_id=requestId,turn_id=turnId,
        installation_id=args.installation_id,profile_id=args.profile_id,playthrough_id=args.playthrough_id,
        session_id=state.sessionId,generation=state.generation,runtime_generation=runtimeGeneration,
        created_at=args.created_at,platform=args.platform,
        content_fingerprint=args.content_fingerprint,text=args.text,language=args.language,input_kind=args.input_kind,mood=mood,
        speaker=args.speaker,target=state.conversation.target,audience=audience,context=context.snapshot(args.context),
        capabilities=args.capabilities,recent_action_results=args.recent_action_results,ui_source=args.ui_source,
        action_request=args.action_request})
    if not dto then state.conversation.turn=nil return nil,buildReason end
    local submitted,nativeReason=state.bridge.submitTurn(dto)
    if not submitted then state.conversation.turn=nil return nil,nativeReason end
    if not isContinuation then
        args.dialogueMode=mode
        args.mood=nil
        state.rechatSeed=util.copy(args)
        state.rechat={chainId=state.bridge.newMessageId and state.bridge.newMessageId() or args.request_id,
            originTurnId=args.turn_id,originLine=args.text,depth=0,lastSpeaker=nil,lastAddressee=nil,
            targetHint=util.copy(state.conversation.target),cancelled=false,requestInFlight=false}
    elseif isRechat and state.rechat then
        state.rechat.requestInFlight=true
    elseif isActionFollowup then
        state.rechat=nil state.rechatEligibility=nil
    elseif isAutonomy then
        state.rechat=nil state.rechatSeed=nil state.rechatEligibility=nil
    end
    state.recentVanillaDialogue={}
    state.emit('LORKHAN_TURN',{status='queued',message_id=args.message_id,request_id=requestId,turn_id=turnId,
        created_at=args.created_at})
    return requestId
end

-- Submit at most one result-aware continuation per completed action after its response lane is idle.
local function submitActionFollowup(state)
    local queue=state.actionFollowups and state.actionFollowups.pending or nil
    local pending=queue and queue[1] or nil
    if not pending or not state.rechatSeed or not state.conversation.turn or not state.conversation.turn.terminal
        or not responseQueue.idle(state.responseQueue) then return false end
    table.remove(queue,1)
    local metadata=state.bridge.nextTurnMetadata and state.bridge.nextTurnMetadata() or {}
    if not protocol.isUuid(metadata.message_id) or not protocol.isUuid(metadata.request_id)
        or not protocol.isUuid(metadata.turn_id) then return false end
    local args=util.copy(state.rechatSeed)
    for key,value in pairs(metadata) do args[key]=value end
    args.input_key='action-followup:'..pending.result.action_id
    args.text='Respond briefly to the completed action result. Acknowledge the observed outcome without proposing or performing another action.'
    args.ui_source='lorkhan_action_followup'
    args.action_request=nil
    args.recent_action_results={{action_id=pending.result.action_id,status=pending.result.status,
        reason_code=pending.result.reason_code,observed=util.copy(pending.result.observed or {}),
        completed_at=pending.result.completed_at}}
    local submitted,reason=M.submitText(state,args)
    if not submitted then print('[LORKHAN] action follow-up rejected: '..tostring(reason)) return false end
    state.emit('LORKHAN_ACTION_FOLLOWUP',{status='queued',action_id=pending.result.action_id,turn_id=metadata.turn_id})
    return true
end

local emitInbound
local function pumpResponseQueue(state)
    for _=1,64 do
        local item=responseQueue.head(state.responseQueue)
        if not item or state.responseQueue.active then return end
        if item.generation~=state.generation or item.runtimeGeneration~=currentRuntimeGeneration(state) then
            responseQueue.failHead(state.responseQueue,'stale_dispatch_generation') emitQueue(state)
        elseif item.kind=='dialogue' then
            if item.status=='waiting_media' then return end
            if item.status=='new' then
                local requestId,reason=state.bridge.prepareMedia(item.media)
                if requestId then responseQueue.beginMediaPreparation(state.responseQueue,item.media.media_id,requestId) emitQueue(state)
                else
                    reportQueuedDialogue(state,item,'failed','media_prepare_failed')
                    if state.bridge.releaseMedia then state.bridge.releaseMedia(item.media.media_id) end
                    responseQueue.failHead(state.responseQueue,reason or 'media_prepare_rejected') emitQueue(state)
                end
            elseif item.status=='preparing' then
                local status=state.bridge.mediaStatus(item.media.media_id)
                if not status or status.state=='preparing' then return end
                if status.state=='ready' then responseQueue.updateMedia(state.responseQueue,item.media.media_id,'ready') emitQueue(state)
                elseif status.state=='failed' or status.state=='expired' or status.state=='cancelled' then
                    responseQueue.updateMedia(state.responseQueue,item.media.media_id,status.state,status.reason)
                    reportQueuedDialogue(state,item,status.state=='expired' and 'expired' or 'failed','media_prepare_failed')
                    if state.bridge.releaseMedia then state.bridge.releaseMedia(item.media.media_id) end
                    responseQueue.failHead(state.responseQueue,status.reason or status.state) emitQueue(state)
                else return end
            elseif item.status=='ready' or item.status=='subtitle_ready' then
                local subtitleOnly=item.status=='subtitle_ready'
                local mediaId=subtitleOnly and item.line.line_id or item.media.media_id
                local ttsVolumeBoost=math.max(1,math.min(4,math.floor(tonumber(
                    state.settings and state.settings.presentation and state.settings.presentation.ttsVolumeBoost) or 3)))
                local command={actor=util.copy(item.line.speaker_identity),media_id=mediaId,subtitle=item.line.subtitle,
                    request_id=item.requestId,turn_id=item.turnId,session_id=item.sessionId,
                    dialogue_message_id=item.line.line_id,generation=item.generation,
                    expires_at=item.media and item.media.expires_at or '',tts_volume_boost=ttsVolumeBoost,
                    subtitle_only=subtitleOnly}
                local sent,reason
                if command.actor.kind=='narrator' and state.settings and state.settings.narrator
                    and state.settings.narrator.enabled~=true then
                    reportQueuedDialogue(state,item,'failed','narrator_disabled')
                    if item.media and state.bridge.releaseMedia then state.bridge.releaseMedia(mediaId) end
                    responseQueue.failHead(state.responseQueue,'narrator_disabled') emitQueue(state)
                else
                    local marked,markReason=responseQueue.markDispatched(state.responseQueue,item)
                    if not marked then print('[LORKHAN] response dispatch rejected: '..tostring(markReason)) return end
                    state.activeSpeechMediaId=mediaId emitQueue(state)
                    if command.actor.kind=='narrator' then
                        state.emit(subtitleOnly and 'LORKHAN_NARRATOR_SUBTITLE' or 'LORKHAN_NARRATOR_SPEAK',command) sent=true
                    else
                        sent,reason=state.sendActor(command.actor,
                            subtitleOnly and 'LORKHAN_ACTOR_SUBTITLE' or 'LORKHAN_ACTOR_SPEAK',command)
                    end
                    if not sent then
                        state.activeSpeechMediaId=nil
                        reportQueuedDialogue(state,item,'failed',subtitleOnly and 'subtitle_unavailable' or 'actor_speech_unavailable')
                        if item.media and state.bridge.releaseMedia then state.bridge.releaseMedia(mediaId) end
                        responseQueue.failHead(state.responseQueue,reason or 'dialogue_dispatch_failed') emitQueue(state)
                    else return end
                end
            else return end
        else
            if item.status~='ready' or not item.intent then return end
            local command=item.intent
            local marked,markReason=responseQueue.markDispatched(state.responseQueue,item)
            if not marked then print('[LORKHAN] action dispatch rejected: '..tostring(markReason)) return end
            emitQueue(state)
            local confirmationRequired=command.confirmation_required
            if confirmationRequired==nil then confirmationRequired=command.tier>=2 end
            if confirmationRequired then
                state.pendingConfirmations[command.action_id]=util.copy(command)
                emitInbound(state,'LORKHAN_ACTION_CONFIRMATION',{action_id=command.action_id,name=command.name,
                    display_name=command.display_name,
                    actor=util.copy(command.actor),target=util.copy(command.target)})
                return
            end
            local sent,reason=state.sendActor(command.actor,'LORKHAN_ACTOR_ACTION',command)
            if not sent then
                reportQueuedAction(state,item,'failed',reason or 'actor_action_unavailable')
                responseQueue.failHead(state.responseQueue,reason or 'actor_action_unavailable') emitQueue(state)
            else return end
        end
    end
end

-- Submit a continuation only from a complete, bounded set of freshly proven actor states.
local function submitPlaybackRechat(state,probe)
    local chain=state.rechat
    local settings=state.settings and state.settings.behavior or {}
    if not chain or chain.cancelled or chain.requestInFlight or settings.rechat~=true
        or (state.rechatSeed and state.rechatSeed.dialogueMode=='Whisper') or not state.rechatSeed
        or not state.conversation.turn or not state.conversation.turn.terminal then return false end
    if not responseQueue.idle(state.responseQueue) then return false end
    if not chain.lastSpeaker or chain.lastSpeaker.kind=='player' then
        chain.cancelled=true return false
    end
    local speakerKey=identity.key(chain.lastSpeaker)
    local speakerState=speakerKey and probe.states[speakerKey] or nil
    if not speakerKey or speakerState~='active' then
        chain.cancelled=true return false
    end
    local participantStates,rechatAudience,eligibleCount={}, {}, 0
    for _,actor in ipairs(probe.participants) do
        local key=identity.key(actor)
        local actorState=key and probe.states[key] or nil
        if key then rechatAudience[#rechatAudience+1]=util.copy(actor) end
        if actorState then
            participantStates[#participantStates+1]={identity=util.copy(actor),state=actorState}
            local directlyAddressed=identity.same(actor,chain.lastAddressee) or identity.same(actor,chain.targetHint)
            if key~=speakerKey and (actorState=='active' or (actorState=='sleeping' and directlyAddressed)) then
                eligibleCount=eligibleCount+1
            end
        end
    end
    if eligibleCount==0 then chain.cancelled=true return false end
    local metadata=state.bridge.nextTurnMetadata and state.bridge.nextTurnMetadata() or {}
    if not protocol.isUuid(metadata.message_id) or not protocol.isUuid(metadata.request_id)
        or not protocol.isUuid(metadata.turn_id) then chain.cancelled=true return false end
    local args=util.copy(state.rechatSeed)
    for key,value in pairs(metadata) do args[key]=value end
    chain.depth=chain.depth+1
    args.input_key='rechat:'..chain.chainId..':'..tostring(chain.depth)
    args.text='Continue the active conversation naturally. Address the previous speaker or listener directly and do not repeat prior dialogue.'
    args.ui_source='lorkhan_rechat'
    args.rechatAudience=rechatAudience
    args.context=args.context or {}
    args.context.rechat={speaker=util.copy(chain.lastSpeaker),listener_hint=util.copy(chain.lastAddressee),
        rechat_target_hint=util.copy(chain.targetHint),origin_line=chain.originLine,rechat_depth=chain.depth,
        chain_id=chain.chainId,origin_turn_id=chain.originTurnId,participant_states=participantStates}
    local submitted,reason=M.submitText(state,args)
    if not submitted then chain.cancelled=true print('[LORKHAN] rechat rejected: '..tostring(reason)) return false end
    state.emit('LORKHAN_RECHAT',{status='queued',chain_id=chain.chainId,depth=chain.depth,turn_id=metadata.turn_id})
    return true
end

-- Ask each bounded participant's actor-local script for an immediate OpenMW state snapshot.
local function startPlaybackRechatProbe(state)
    local chain=state.rechat
    local settings=state.settings and state.settings.behavior or {}
    if not chain or chain.cancelled or chain.requestInFlight or state.rechatEligibility
        or settings.rechat~=true or (state.rechatSeed and state.rechatSeed.dialogueMode=='Whisper')
        or not state.rechatSeed or not state.conversation.turn or not state.conversation.turn.terminal
        or not responseQueue.idle(state.responseQueue) then return false end
    if not chain.lastSpeaker or chain.lastSpeaker.kind=='player' then chain.cancelled=true return false end
    local probeId=state.bridge.newMessageId and state.bridge.newMessageId() or nil
    if not protocol.isUuid(probeId) then chain.cancelled=true return false end
    local participants,expected,seen={},{},{}
    local candidates={chain.lastSpeaker}
    for _,entry in ipairs(state.conversation.audience or {}) do candidates[#candidates+1]=entry.identity end
    candidates[#candidates+1]=chain.lastAddressee
    candidates[#candidates+1]=chain.targetHint
    for _,actor in ipairs(candidates) do
        local key=identity.key(actor)
        if key and not seen[key] and actor.kind~='player' and actor.kind~='narrator'
            and #participants<constants.MAX_AUDIENCE+1 then
            seen[key]=true participants[#participants+1]=util.copy(actor)
        end
    end
    local probe={probeId=probeId,elapsed=0,participants=participants,expected=expected,states={}}
    state.rechatEligibility=probe
    for _,actor in ipairs(participants) do
        local key=identity.key(actor)
        if key and state.registry:resolve(actor) then
            expected[key]=true
            local sent=state.sendActor(actor,'LORKHAN_ACTOR_CONVERSATION_STATE_REQUEST',
                {actor=util.copy(actor),probe_id=probeId,generation=state.generation})
            if not sent then expected[key]=nil end
        end
    end
    local speakerKey=identity.key(chain.lastSpeaker)
    if not speakerKey or not expected[speakerKey] then
        state.rechatEligibility=nil chain.cancelled=true return false
    end
    return true
end

-- Complete the probe after every expected reply or a short fail-closed timeout.
function M.pollRechatEligibility(state,dt)
    local probe=state.rechatEligibility
    if not probe then return false end
    probe.elapsed=probe.elapsed+(tonumber(dt) or 0)
    local complete=true
    for key in pairs(probe.expected) do if probe.states[key]==nil then complete=false break end end
    if not complete and probe.elapsed<0.5 then return false end
    state.rechatEligibility=nil
    return submitPlaybackRechat(state,probe)
end

-- Advance the single ordered speech lane only after the actor reports a terminal playback state.
function M.speechStatus(state,event)
    if type(event)~='table' or type(event.media_id)~='string' then return false end
    if event.active==true then
        state.activeSpeechMediaId=event.media_id
        return state.responseQueue.active~=nil
    end
    local item=state.responseQueue.active
    if not item or item.kind~='dialogue' then return false end
    local releaseId=item.media and item.media.media_id or nil
    local completed,advance=responseQueue.completeDialogue(state.responseQueue,event.media_id,event.status)
    if not completed then return false end
    if state.activeSpeechMediaId==event.media_id then state.activeSpeechMediaId=nil end
    if releaseId and state.bridge and state.bridge.releaseMedia then state.bridge.releaseMedia(releaseId) end
    emitQueue(state)
    pumpResponseQueue(state)
    submitActionFollowup(state)
    if advance then startPlaybackRechatProbe(state) end
    return true
end

-- A malformed player-local UI event must not stop the authoritative response lane from reaching
-- its terminal event or preparing later speech media.
emitInbound=function(state,name,payload)
    local ok,reason=pcall(state.emit,name,payload)
    if not ok then print('[LORKHAN] player event delivery failed: '..tostring(name)..' '..tostring(reason)) end
    return ok
end

-- Convert a correlated HTTP failure into a local terminal turn so the next input is not stranded.
local function applyTransportFailure(state,event)
    local turn=state.conversation.turn
    if not turn or turn.terminal or event.request_id~=turn.requestId then return false end
    turn.terminal=true turn.status='failed' turn.reason=event.reason or 'transport_failure'
    if state.rechat then state.rechat.cancelled=true state.rechat.requestInFlight=false end
    local failed={type='turn.failed',request_id=turn.requestId,turn_id=turn.turnId,
        session_id=state.sessionId,generation=state.generation,
        payload={status='failed',code=turn.reason}}
    emitInbound(state,'LORKHAN_EVENT',failed)
    print('[LORKHAN] response turn terminal: transport.failure '..tostring(turn.turnId))
    return true
end

function M.poll(state)
    if state.disabled or state.hardHalted then return 0 end
    local results=state.bridge.pollResults(constants.MAX_INBOUND_RESULTS) or {}
    local accepted=0
    for index=1,math.min(#results,constants.MAX_INBOUND_RESULTS) do
        local event=results[index]
        if event.type=='transport.failure' then
            if applyTransportFailure(state,event) then accepted=accepted+1
            else print('[LORKHAN] transport failure dropped: '..tostring(event.request_id)) end
        else
            local ok,reason=state.events:accept(event)
            if ok then
            if reason=='cursor_resynced' then
                print('[LORKHAN] response cursor recovered at sequence '..tostring(event.sequence)
                    ..' ('..tostring(event.type)..')')
            end
            if event.type=='stt.transcript' or event.type=='stt.failed' then
                local pending=state.pendingStt[event.request_id];state.pendingStt[event.request_id]=nil
                local fenced=pending and pending.session_id==state.sessionId and pending.generation==state.generation
                    and pending.target_key==identity.key(state.conversation.target) and state.registry:resolve(pending.target)
                if event.type=='stt.transcript' and fenced and (not pending.continuous or state.openMic) then
                    local metadata=state.bridge.nextTurnMetadata and state.bridge.nextTurnMetadata() or {}
                    for key,value in pairs(metadata) do pending[key]=value end
                    pending.text=event.payload.text;pending.input_key='voice:'..event.message_id;pending.language=event.payload.language
                    pending.input_kind='stt'
                    local submitted,submitReason=M.submitText(state,pending)
                    if not submitted and pending.continuous then state.openMic=false end
                    state.emit('LORKHAN_VOICE_STATUS',{status=submitted and 'queued' or 'failed',reason=submitReason,
                        request_id=submitted,continuous=pending.continuous==true})
                elseif event.type=='stt.failed' then
                    if pending and pending.continuous then state.openMic=false end
                    state.emit('LORKHAN_VOICE_STATUS',{status='failed',reason=event.payload.code,
                        continuous=pending and pending.continuous==true})
                else
                    if pending and pending.continuous then state.openMic=false end
                    state.emit('LORKHAN_VOICE_STATUS',{status='failed',reason=pending and 'stale_voice_context' or 'stt_context_missing',
                        continuous=pending and pending.continuous==true})
                end
                accepted=accepted+1;emitInbound(state,'LORKHAN_EVENT',event)
            else
            local applyOk,applied,applyReason=pcall(conversation.apply,state.conversation,event)
            if not applyOk then
                applyReason='lua_exception: '..tostring(applied)
                applied=false
            end
            if applied then
                local laneOk,laneReason=true,nil
                if event.type=='response.complete' then
                    laneOk,laneReason=responseQueue.enqueue(state.responseQueue,event.payload,state.generation,
                        currentRuntimeGeneration(state))
                elseif event.type=='dialogue.complete' then
                    laneOk,laneReason=responseQueue.enqueueDialogueEvent(state.responseQueue,event,currentRuntimeGeneration(state))
                elseif event.type=='speech.ready' then
                    laneOk,laneReason=responseQueue.attachMedia(state.responseQueue,event)
                elseif event.type=='action.intent' then
                    laneOk,laneReason=responseQueue.attachAction(state.responseQueue,event)
                end
                if not laneOk then applied=false applyReason=laneReason
                else
                    if event.type=='response.complete' or event.type=='dialogue.complete'
                        or event.type=='speech.ready' or event.type=='action.intent' then emitQueue(state) end
                    accepted=accepted+1
                    if event.type=='dialogue.complete' and state.rechat then
                        state.rechat.lastSpeaker=util.copy(event.payload.speaker)
                        state.rechat.lastAddressee=util.copy(event.payload.addressee)
                    elseif (event.type=='turn.failed' or event.type=='turn.cancelled') and state.rechat then
                        state.rechat.cancelled=true
                        state.rechatEligibility=nil
                    end
                    emitInbound(state,'LORKHAN_EVENT',event)
                    if event.type=='turn.complete' or event.type=='turn.failed' or event.type=='turn.cancelled' then
                        if state.rechat then state.rechat.requestInFlight=false end
                        print('[LORKHAN] response turn terminal: '..tostring(event.type)..' '..tostring(event.turn_id))
                    end
                end
            end
            if not applied then
                print('[LORKHAN] response event dropped: '..tostring(event.type)..' '..tostring(applyReason))
                emitInbound(state,'LORKHAN_DROP',{reason=applyReason})
            end
            end
            elseif reason~='duplicate_event' and reason~='stale_generation' and reason~='stale_session' then
                print('[LORKHAN] response event rejected: '..tostring(reason)..' at sequence '..tostring(event.sequence))
                emitInbound(state,'LORKHAN_RESYNC',{reason=reason,cursor=state.events:cursor()})
            end
        end
    end
    pumpResponseQueue(state)
    submitActionFollowup(state)
    if responseQueue.consumeRechat(state.responseQueue) then startPlaybackRechatProbe(state) end
    return accepted
end


function M.confirmAction(state,actionId,approved)
    local command=state.pendingConfirmations[actionId]
    if not command then return nil,'confirmation_not_found' end
    state.pendingConfirmations[actionId]=nil
    local eventName=approved and 'LORKHAN_ACTOR_ACTION' or 'LORKHAN_ACTOR_REJECT'
    local sent,reason=state.sendActor(command.actor,eventName,command)
    if not sent then
        local item=responseQueue.head(state.responseQueue)
        if item and item.kind=='action' then reportQueuedAction(state,item,'failed',reason or 'action_confirmation_delivery_failed') end
        responseQueue.failHead(state.responseQueue,reason or 'action_confirmation_delivery_failed') emitQueue(state) pumpResponseQueue(state)
    end
    return sent,reason
end

function M.actionResult(state,event)
    local result=event and event.result
    if type(result)~='table' or type(result.action_id)~='string' then return nil,'invalid_action_result' end
    state.pendingConfirmations[result.action_id]=nil
    local item=responseQueue.head(state.responseQueue)
    local intent=item and item.kind=='action' and item.intent or nil
    local completed,advance=responseQueue.completeAction(state.responseQueue,result.action_id)
    if not completed then return nil,advance end
    if intent and intent.followup_enabled==true and not state.actionFollowups.seen[result.action_id] then
        state.actionFollowups.seen[result.action_id]=true
        state.actionFollowups.pending[#state.actionFollowups.pending+1]={intent=util.copy(intent),result=util.copy(result)}
    end
    emitQueue(state) pumpResponseQueue(state)
    submitActionFollowup(state)
    if advance then submitPlaybackRechat(state) end
    return true
end

function M.interrupt(state,reason)
    reason=reason or 'halt_ai_actions'
    if state.bridge and state.bridge.cancelVoiceCapture then state.bridge.cancelVoiceCapture() end
    cancelResponseLane(state,reason,true)
    signalAllActors(state,'LORKHAN_ACTOR_STOP',reason)
    local previousGeneration=state.generation
    state.generation=conversation.interrupt(state.conversation,reason)
    if state.bridge and state.bridge.cancelGeneration then state.bridge.cancelGeneration(previousGeneration) end
    responseQueue.setFence(state.responseQueue,state.generation,currentRuntimeGeneration(state),reason)
    state.events=nil
    state.activeSpeechMediaId=nil
    state.rechat=nil state.rechatSeed=nil state.rechatEligibility=nil
    state.pendingConfirmations={}
    state.actionFollowups={seen={},pending={}}
    state.pendingVoice=nil state.pendingStt={} state.openMic=false state.openMicRequested=false
    state.hardHalted=false
    emitQueue(state)
    state.emit('LORKHAN_HALT',{generation=state.generation,reason=reason,recoverable=true})
    return true
end

function M.stopDialogue(state,reason)
    reason=reason or 'stop_dialogue'
    if state.bridge and state.bridge.cancelVoiceCapture then state.bridge.cancelVoiceCapture() end
    cancelResponseLane(state,reason,true)
    local previousGeneration=state.generation
    state.generation=conversation.interrupt(state.conversation,reason)
    if state.bridge and state.bridge.cancelGeneration then state.bridge.cancelGeneration(previousGeneration) end
    responseQueue.setFence(state.responseQueue,state.generation,currentRuntimeGeneration(state),reason)
    state.events=nil
    state.activeSpeechMediaId=nil
    state.rechat=nil state.rechatSeed=nil state.rechatEligibility=nil
    state.pendingConfirmations={}
    state.actionFollowups={seen={},pending={}}
    state.pendingVoice=nil state.pendingStt={} state.openMic=false state.openMicRequested=false
    emitQueue(state)
    state.emit('LORKHAN_DIALOGUE_STOPPED',{generation=state.generation,reason=reason})
    return true
end

function M.haltActions(state,reason)
    reason=reason or 'halt_ai_actions'
    signalAllActors(state,'LORKHAN_ACTOR_HALT_ACTIONS',reason)
    local active=state.responseQueue.active
    local cancelActive=active and active.kind=='action' and active.intent
        and state.pendingConfirmations[active.intent.action_id]~=nil
    local cancelled=responseQueue.cancelActions(state.responseQueue,reason,cancelActive)
    for _,item in ipairs(cancelled) do reportQueuedAction(state,item,'cancelled',reason) end
    state.pendingConfirmations={}
    emitQueue(state)
    pumpResponseQueue(state)
    state.emit('LORKHAN_ACTIONS_HALTED',{generation=state.generation,reason=reason})
    return true
end

function M.hardHalt(state)
    cancelResponseLane(state,'hard_halt',true)
    detachAll(state,'hard_halt')
    state.bridge.halt() conversation.halt(state.conversation)
    state.generation=state.conversation.generation state.hardHalted=true state.pendingConfirmations={}
    state.actionFollowups={seen={},pending={}}
    responseQueue.setFence(state.responseQueue,state.generation,currentRuntimeGeneration(state),'hard_halt')
    state.activeSpeechMediaId=nil
    state.rechat=nil state.rechatSeed=nil state.rechatEligibility=nil
    state.pendingVoice=nil state.pendingStt={} state.openMic=false state.openMicRequested=false
    state.emit('LORKHAN_NARRATOR_STOP',{reason='hard_halt'})
    emitQueue(state)
    state.emit('LORKHAN_HALT',{generation=state.generation,reason='hard_halt',recoverable=false})
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
        responseQueue.setFence(state.responseQueue,state.generation,currentRuntimeGeneration(state),'load_generation')
        emitQueue(state)
        state.events=state.sessionId and protocol.CursoredEvents(state.sessionId,state.generation) or nil
    end
    if meta.disable then state.disabled=true state.futureSave=meta.preserve and raw or nil state.emit('LORKHAN_STATUS',{status='disabled',reason=meta.reason}) end
    return loaded,meta
end
function M.save(state)
    if state.futureSave then return state.futureSave end
    return storage.save({profileId=state.profileId,playthroughId=state.playthroughId,generationSeed=state.generation,
        preferences=state.preferences,conversationUi=state.conversationUi,actorStateHints={}})
end
return M
