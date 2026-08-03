local adapter=require('scripts.ALMSIVI.adapters.openmw')
local identity=require('scripts.ALMSIVI.identity')
local player=require('scripts.ALMSIVI.player_state')
local protocol=require('scripts.ALMSIVI.protocol')
local core=adapter.event()
local inputOk,input=pcall(require,'openmw.input')
local uiOk,openmwUi=pcall(require,'openmw.ui')
local utilOk,util=pcall(require,'openmw.util')
local self=require('openmw.self')
local interfacesOk,interfaces=pcall(require,'openmw.interfaces')
local storageOk,openmwStorage=pcall(require,'openmw.storage')
local nativeOk,native=pcall(require,'openmw.almsivi')
local state=player.new()
local element
local statusElement
local voiceRecording=false
local pttHeld=false
local openMicEnabled=false
local openMicMuted=false
local settingsSignature
local autoScanElapsed=0
local quietElapsed=0
local combatBarkElapsed=0
local combatBarkIndex=0
local hadConversation=false
local autonomyPending=false
local turnActive=false
local nearbyCombat=false
local combatThreats={}
local actorActivities={}
local speechActors={}
local narratorSpeech
local rechatDepth=0
local activeAutonomyKind
local activeAutonomySpoke=false
local ownsUiMode=false
local controlsSignature
local MODES={'Standard','Whisper','Close','Shout'}
local EQUIPMENT_SLOTS={'helmet','cuirass','greaves','left_pauldron','right_pauldron','left_gauntlet',
    'right_gauntlet','boots','shirt','pants','skirt','robe','left_ring','right_ring','amulet','belt',
    'carried_right','carried_left','ammunition'}
local autoSettings=storageOk and openmwStorage.playerSection('SettingsALMSIVIAutoActivate') or nil
local behaviorSettings=storageOk and openmwStorage.playerSection('SettingsALMSIVIBehavior') or nil
local presentationSettings=storageOk and openmwStorage.playerSection('SettingsALMSIVIPresentation') or nil
local inputBindings=storageOk and openmwStorage.playerSection('OMWInputBindings') or nil
local unpackValues=table.unpack or unpack
local whiteTexture=uiOk and openmwUi.texture and openmwUi.texture({path='white'}) or nil
local lastTalkToggleAt=-1
local pendingTextSubmit=false
local awaitingTextQueue=false
local pendingControlPanel
local aimCandidate
local aimScanElapsed=0
local aimSignature=''
local function send(name,payload) if core and core.sendGlobalEvent then core.sendGlobalEvent(name,payload) end end
local CAPABILITIES={'dialogue.text','speech.say','speech.listen','action.ai.follow','action.ai.stop',
    'action.ai.travel','action.ai.escort','action.ai.face','action.ai.wander','action.combat.start','action.combat.stop','action.inspect.report',
    'action.animation.play','action.item.equip','action.item.unequip','action.item.use'}

local function conversationContext(target)
    local snapshot=adapter.playerContext(target)
    local activities={}
    for _,status in pairs(actorActivities) do activities[#activities+1]=status end
    table.sort(activities,function(left,right) return identity.key(left.actor)<identity.key(right.actor) end)
    while #activities>12 do table.remove(activities) end
    snapshot.actorActivities=activities
    return snapshot
end

local function voicePayload(uiSource)
    local context=conversationContext(state.ui.target)
    context.dialogueMode=state.ui.mode
    return {speaker=adapter.identity(self),target=state.ui.target,context=context,
        language='en-US',capabilities=CAPABILITIES,recent_action_results={},ui_source=uiSource,
        vad_sensitivity=tonumber(behaviorSettings and behaviorSettings:get('openMicSensitivity')) or 1000,
        end_delay_ms=tonumber(behaviorSettings and behaviorSettings:get('openMicEndDelayMs')) or 1000}
end

local function displayName(actor) return actor and actor.display_name or 'No target' end
local function actorLabel(actor)
    if not actor then return 'No target' end
    local distance=adapter.actorDistance(actor)
    return distance and (displayName(actor)..'  ('..tostring(math.floor(distance+0.5))..')') or displayName(actor)
end
local function activityLabel(actor)
    local key=actor and identity.key(actor)
    local status=key and actorActivities[key] or nil
    return status and type(status.activity)=='string' and status.activity or 'unmanaged'
end
local function audienceNames()
    local names={}
    for _,actor in ipairs(state.ui.audience or {}) do names[#names+1]=displayName(actor) end
    return #names>0 and table.concat(names,', ') or 'None'
end
local function speechActive() return next(speechActors)~=nil end
local function reportNarrator(status,reason)
    local command=narratorSpeech
    if not command then return end
    narratorSpeech=nil
    send('ALMSIVI_SPEECH_STATUS',{actor=command.actor,media_id=command.media_id,active=false,status=status,reason=reason})
    local bridge=adapter.bridge()
    if not bridge or not bridge.newMessageId or not bridge.utcNow or not bridge.submitDialogueDeliveryResult then return end
    local result=protocol.dialogueDeliveryResult({message_id=bridge.newMessageId(),request_id=command.request_id,
        dialogue_message_id=command.dialogue_message_id,turn_id=command.turn_id,session_id=command.session_id,
        generation=command.generation,speaker=command.actor,status=status,reason_code=reason,completed_at=bridge.utcNow()})
    if result then bridge.submitDialogueDeliveryResult(result) end
end

local function stopNarrator(reason)
    if not narratorSpeech then return end
    adapter.stopSpeech();reportNarrator('interrupted',reason or 'client_interrupted')
end
local function controlsAllowed()
    if not interfacesOk or not interfaces or not interfaces.UI or not interfaces.UI.getMode then return true end
    return interfaces.UI.getMode()==nil
end
local function enterUiMode()
    if not interfacesOk or not interfaces or not interfaces.UI or not interfaces.UI.setMode then return end
    if interfaces.UI.getMode()==nil then
        interfaces.UI.setMode(interfaces.UI.MODE.Interface,{windows={}})
        ownsUiMode=true
    end
end
local function leaveUiMode()
    if not ownsUiMode then return end
    if interfacesOk and interfaces and interfaces.UI and interfaces.UI.getMode
        and interfaces.UI.getMode()==interfaces.UI.MODE.Interface then interfaces.UI.setMode() end
    ownsUiMode=false
end

local render
local applySettings
local chooseTarget

local function submitText()
    if pendingTextSubmit or awaitingTextQueue then return false end
    local text=state.ui.input
    if not text or text:match('^%s*$') then
        state.ui.status='message required'
        print('[ALMSIVI] text submit rejected: empty message')
        render()
        return false
    end
    if not state.ui.target then
        pendingTextSubmit=true
        state.ui.status='finding actor target'
        print('[ALMSIVI] text submit waiting for actor target')
        if not chooseTarget(2048) then pendingTextSubmit=false end
        render()
        return false
    end
    local speaker=adapter.identity(self)
    rechatDepth=0 hadConversation=false activeAutonomyKind=nil activeAutonomySpoke=false
    local context=conversationContext(state.ui.target)
    context.dialogueMode=state.ui.mode
    send('ALMSIVI_SUBMIT_TEXT',{text=text,language='en-US',speaker=speaker,
        context=context,capabilities=CAPABILITIES,
        recent_action_results={},ui_source='almsivi_text'})
    awaitingTextQueue=true
    state.ui.status='submitting'
    pendingTextSubmit=false
    print('[ALMSIVI] text message submitted for '..displayName(state.ui.target))
    render()
    return true
end

local function sessionControls()
    if not nativeOk or not native or not native.sessionControls then return nil end
    local ok,value=pcall(native.sessionControls)
    return ok and value or nil
end

local function refreshSessionControls(panel)
    if not state.ui.target then state.ui.status='actor target required' render() return end
    if not nativeOk or not native or not native.requestSessionControls then
        state.ui.status='session controls unavailable' render() return
    end
    local request,error=native.requestSessionControls(state.ui.target)
    if not request then state.ui.status=tostring(error or 'session controls unavailable') else state.ui.status='loading controls' end
    state.ui.panel=panel
    render()
end

local function selectSessionControl(kind,selection)
    if not state.ui.target or not nativeOk or not native or not native.selectSessionControl then
        state.ui.status='session controls unavailable' render() return
    end
    local request,error=native.selectSessionControl(kind,selection,state.ui.target)
    state.ui.status=request and 'control update queued' or tostring(error or 'control update failed')
    render()
end

local function generateSelectedProfile()
    local controls=sessionControls()
    if not controls or not state.ui.target or not identity.same(controls.target,state.ui.target) then
        state.ui.status='profile choices are not loaded' render() return
    end
    if not controls.selected_profile_id then
        state.ui.status='select a target profile first' render() return
    end
    if not nativeOk or not native or not native.selectSessionControl then
        state.ui.status='profile generation unavailable' render() return
    end
    local request,error=native.selectSessionControl('profile_generate',controls.selected_profile_id,state.ui.target)
    state.ui.status=request and 'profile generation queued' or tostring(error or 'profile generation failed')
    render()
end

local function generateNarratorProfile()
    local controls=sessionControls()
    if not controls or not state.ui.target or not identity.same(controls.target,state.ui.target) then
        state.ui.status='narrator profile is not loaded' render() return
    end
    if not controls.narrator_profile_id then
        state.ui.status='configure a narrator profile on the server first' render() return
    end
    if not nativeOk or not native or not native.selectSessionControl then
        state.ui.status='narrator generation unavailable' render() return
    end
    local request,error=native.selectSessionControl('narrator_profile_generate',controls.narrator_profile_id,state.ui.target)
    state.ui.status=request and 'narrator generation queued' or tostring(error or 'narrator generation failed')
    render()
end

local function setMode(mode)
    for _,candidate in ipairs(MODES) do
        if candidate==mode then
            state.ui.mode=mode
            state.ui.status='mode: '..mode
            send('ALMSIVI_MODE_CHANGED',{mode=mode})
            render()
            return true
        end
    end
    return false
end

local function actionContext(actionTarget)
    local snapshot=conversationContext(state.ui.target)
    snapshot.dialogueMode=state.ui.mode
    if actionTarget then
        local nearby={actionTarget}
        for _,actor in ipairs(snapshot.nearbyActors or {}) do
            if not identity.same(actor,actionTarget) then nearby[#nearby+1]=actor end
        end
        snapshot.nearbyActors=nearby
    end
    return snapshot
end

local function submitActionRequest(label,name,tier,parameters,actionTarget)
    if behaviorSettings and behaviorSettings:get('actionsEnabled')==false then
        state.ui.status='actions disabled in settings' render() return
    end
    if not state.ui.target then state.ui.status='actor target required' render() return end
    local request={name=name,tier=tier,parameters=parameters}
    if actionTarget then request.target=actionTarget end
    rechatDepth=0 hadConversation=false activeAutonomyKind=nil activeAutonomySpoke=false
    send('ALMSIVI_SUBMIT_TEXT',{text=label,language='en-US',speaker=adapter.identity(self),
        context=actionContext(actionTarget),capabilities=CAPABILITIES,
        recent_action_results={},ui_source='almsivi_action_menu',action_request=request})
    state.ui.pendingTargetAction=nil
    turnActive=true
    state.ui.status='action queued'
    state.ui.actionView='root'
    state.ui.actionPage=1
    render()
end

local function beginSecondaryTarget(label,name,tier,parameters)
    state.ui.pendingTargetAction={kind='actor',label=label,name=name,tier=tier,parameters=parameters,
        actor=state.ui.target}
    state.ui.visible=false
    state.ui.status='aim action target; F8 confirm'
    leaveUiMode()
    render()
end

local function beginDestinationTarget(label,name,tier)
    state.ui.pendingTargetAction={kind='destination',label=label,name=name,tier=tier,actor=state.ui.target}
    state.ui.visible=false
    state.ui.status='aim at a nearby destination; F8 confirm'
    leaveUiMode()
    render()
end

local function renderStatusHud()
    if statusElement then statusElement:destroy() statusElement=nil end
    if state.ui.visible or not state.ui.statusHudVisible or not uiOk or not utilOk then return end
    statusElement=openmwUi.create({layer='HUD',type=openmwUi.TYPE.Container,
        props={position=util.vector2(26,24),size=util.vector2(430,54)},content=openmwUi.content({
            {type=openmwUi.TYPE.Text,props={text='ALMSIVI  |  '..state.ui.status..'  |  '..state.ui.mode..
                '  |  Target: '..actorLabel(state.ui.target)..'  |  Aim: '..displayName(aimCandidate and aimCandidate.identity)..
                '  |  Agents: '..tostring(#state.ui.agents),
                textSize=15,textColor=util.color.rgb(1.0,0.58,0.18)}}
        })})
end
render=function()
    if element then element:destroy() element=nil end
    renderStatusHud()
    if not state.ui.visible or not uiOk or not utilOk then return end
    local transcript={}
    if state.ui.panel=='conversation' then
    local inputContent={}
    if whiteTexture then
        inputContent[#inputContent+1]={type=openmwUi.TYPE.Image,props={resource=whiteTexture,
            size=util.vector2(620,46),color=util.color.rgb(0.08,0.06,0.04),alpha=0.96,
            propagateEvents=false}}
    end
    inputContent[#inputContent+1]={type=openmwUi.TYPE.TextEdit,props={position=util.vector2(8,5),
        text=state.ui.input,size=util.vector2(604,36),multiline=false,wordWrap=false,readOnly=false,autoSize=false,
        textSize=18,textColor=util.color.rgb(1.0,0.92,0.72),propagateEvents=false},events={
            textChanged=adapter.callback(function(value)
                local text=player.consumeTextEdit(value)
                state.ui.input=text
            end),
            keyPress=adapter.callback(function(event)
                if inputOk and event and event.code==input.KEY.Escape then
                    pendingTextSubmit=false state.ui.visible=false leaveUiMode() render()
                end
            end)}}
    transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='TYPE YOUR MESSAGE',textSize=14,
        textColor=util.color.rgb(1.0,0.58,0.18)}}
    transcript[#transcript+1]={type=openmwUi.TYPE.Container,props={size=util.vector2(620,46)},
        content=openmwUi.content(inputContent)}
    transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Click the dark box, type, then press Enter or click Send',textSize=14,
        textColor=util.color.rgb(0.72,0.68,0.62)}}
    transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Send',textSize=18,textColor=util.color.rgb(1.0,0.58,0.18)},
        events={mouseClick=adapter.callback(submitText)}}
    transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Close',textSize=16,textColor=util.color.rgb(0.82,0.78,0.72)},
        events={mouseClick=adapter.callback(function() pendingTextSubmit=false state.ui.visible=false leaveUiMode() render() end)}}
    transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Use aimed NPC as target',textSize=16,
        textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=adapter.callback(function()
            send('ALMSIVI_TARGET_REQUEST',{maxDistance=2048})
        end)}}
    transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Master Menu',textSize=16,
        textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function()
            state.ui.panel='master' render()
        end)}}
    transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Add aimed NPC to group',textSize=16,textColor=util.color.rgb(1.0,0.58,0.18)},
        events={mouseClick=adapter.callback(function() send('ALMSIVI_AUDIENCE_REQUEST',{maxDistance=2048}) end)}}
    transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Reset group to target',textSize=16,textColor=util.color.rgb(1.0,0.58,0.18)},
        events={mouseClick=adapter.callback(function() send('ALMSIVI_CLEAR_AUDIENCE',{}) end)}}
    local nearbyTargets=adapter.nearbyActors(2048)
    if #nearbyTargets>0 then
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='NEARBY TARGETS',textSize=14,
            textColor=util.color.rgb(0.72,0.68,0.62)}}
        for index=1,math.min(#nearbyTargets,3) do
            local candidate=nearbyTargets[index]
            local label=displayName(candidate.identity)..'  ('..tostring(math.floor(candidate.distance))..', '..activityLabel(candidate.identity)..')'
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Talk to '..label,textSize=16,
                textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=adapter.callback(function()
                    state.ui.status='selecting '..displayName(candidate.identity)
                    send('ALMSIVI_SELECT_TARGET',{candidate=candidate}) render()
                end)}}
        end
    end
    for _,line in ipairs(state.ui.transcript) do
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=displayName(line.speaker)..': '..line.text,
            textColor=util.color.rgb(0.92,0.82,0.68),textSize=16}}
    end
    if state.ui.subtitle then
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=displayName(state.ui.subtitle.speaker)..': '..state.ui.subtitle.text,
            textColor=util.color.rgb(1.0,0.58,0.18),textSize=16}}
    end
    transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=voiceRecording and 'Stop voice recording' or 'Start voice recording',textSize=16,
        textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=adapter.callback(function()
            if openMicEnabled then openMicEnabled=false openMicMuted=false send('ALMSIVI_OPEN_MIC_STOP',{}) end
            voiceRecording=not voiceRecording
            if voiceRecording then
                if not state.ui.target then voiceRecording=false state.ui.status='target required'
                else
                    rechatDepth=0 hadConversation=false activeAutonomyKind=nil activeAutonomySpoke=false
                    send('ALMSIVI_VOICE_START',voicePayload('almsivi_voice'))
                end
            else send('ALMSIVI_VOICE_STOP',{}) end
            render()
        end)}}
    local openMicLabel=openMicEnabled and (openMicMuted and 'Open mic: ON (muted)' or 'Open mic: ON (voice activated)')
        or 'Open mic: Off'
    transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=openMicLabel,textSize=16,
        textColor=openMicEnabled and util.color.rgb(0.45,0.9,0.45) or util.color.rgb(1.0,0.58,0.18)},
        events={mouseClick=adapter.callback(function()
            if not openMicEnabled and not state.ui.target then state.ui.status='target required' render() return end
            openMicEnabled=not openMicEnabled openMicMuted=false voiceRecording=openMicEnabled
            if openMicEnabled then
                rechatDepth=0 hadConversation=false activeAutonomyKind=nil activeAutonomySpoke=false
                send('ALMSIVI_OPEN_MIC_START',voicePayload('almsivi_open_mic'))
            else send('ALMSIVI_OPEN_MIC_STOP',{}) end
            render()
        end)}}
    if openMicEnabled then
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=openMicMuted and 'Resume open microphone' or 'Mute open microphone',textSize=15,
            textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function()
                openMicMuted=not openMicMuted voiceRecording=not openMicMuted
                if openMicMuted then send('ALMSIVI_OPEN_MIC_STOP',{})
                else send('ALMSIVI_OPEN_MIC_START',voicePayload('almsivi_open_mic')) end
                state.ui.status=openMicMuted and 'open mic muted' or 'open mic listening'
                render()
            end)}}
    end
    elseif state.ui.panel=='agents' then
        local exterior=self.cell and self.cell.isExterior==true
        local distance=autoSettings and autoSettings:get(exterior and 'exteriorDistance' or 'interiorDistance')
            or (exterior and 2400 or 1200)
        local nearby=adapter.nearbyActors(tonumber(distance) or (exterior and 2400 or 1200))
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Agent Manager',textSize=20,
            textColor=util.color.rgb(0.95,0.9,0.82)}}
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Managed: '..tostring(#state.ui.agents)..
            '  |  Nearby: '..tostring(#nearby),textSize=16,textColor=util.color.rgb(0.92,0.82,0.68)}}
        if #nearby==0 then
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='No eligible nearby actors.',textSize=16,
                textColor=util.color.rgb(0.72,0.68,0.62)}}
        end
        for index=1,math.min(#nearby,5) do
            local candidate=nearby[index]
            local label=displayName(candidate.identity)..'  ('..tostring(math.floor(candidate.distance))..')'
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Talk to '..label,textSize=16,
                textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=adapter.callback(function()
                    send('ALMSIVI_SELECT_TARGET',{candidate=candidate}) state.ui.panel='conversation' render()
                end)}}
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Add '..label..' to group',textSize=14,
                textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function()
                    send('ALMSIVI_ADD_AUDIENCE',{candidate=candidate})
                end)}}
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Manage profile for '..label,textSize=14,
                textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function()
                    pendingControlPanel='profiles'
                    state.ui.status='loading profile for '..displayName(candidate.identity)
                    send('ALMSIVI_SELECT_TARGET',{candidate=candidate}) render()
                end)}}
        end
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Pin bounded nearby group',textSize=16,
            textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=adapter.callback(function()
                while #nearby>12 do table.remove(nearby) end
                send('ALMSIVI_MANUAL_ACTIVATE_NEARBY_REQUEST',{candidates=nearby})
            end)}}
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Master Menu',textSize=16,
            textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function()
                state.ui.panel='master' render()
            end)}}
    elseif state.ui.panel=='history' then
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Conversation History',textSize=20,
            textColor=util.color.rgb(0.95,0.9,0.82)}}
        if #state.ui.transcript==0 then
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='No ALMSIVI dialogue in this session yet.',
                textSize=16,textColor=util.color.rgb(0.72,0.68,0.62)}}
        end
        for _,line in ipairs(state.ui.transcript) do
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=displayName(line.speaker)..': '..line.text,
                textSize=16,textColor=util.color.rgb(0.92,0.82,0.68)}}
        end
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Master Menu',textSize=16,
            textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=adapter.callback(function()
                state.ui.panel='master' render()
            end)}}
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Close',textSize=16,
            textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function()
                state.ui.visible=false leaveUiMode() render()
            end)}}
    elseif state.ui.panel=='diagnostics' then
        local rows={
            'Runtime status: '..tostring(state.ui.status),
            'Target: '..displayName(state.ui.target),
            'Conversation group: '..audienceNames(),
            'Managed agents: '..tostring(#state.ui.agents),
            'Turn active: '..tostring(turnActive),
            'Voice recording: '..tostring(voiceRecording),
            'Generated speech: '..tostring(speechActive()),
            'Open microphone: '..tostring(openMicEnabled),
            'Open microphone muted: '..tostring(openMicMuted),
            'Nearby combat: '..tostring(nearbyCombat),
            'Managed combat threats: '..tostring(#combatThreats),
            'Rechat depth: '..tostring(rechatDepth),
        }
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Diagnostics',textSize=20,
            textColor=util.color.rgb(0.95,0.9,0.82)}}
        for _,row in ipairs(rows) do
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=row,textSize=16,
                textColor=util.color.rgb(0.92,0.82,0.68)}}
        end
        if state.ui.diagnostics then
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Last detail: '..tostring(state.ui.diagnostics),
                textSize=15,textColor=util.color.rgb(1.0,0.58,0.18)}}
        end
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Server UI: http://127.0.0.1:8089/ALMSIVIserver/manage',
            textSize=14,textColor=util.color.rgb(0.72,0.68,0.62)}}
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Master Menu',textSize=16,
            textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=adapter.callback(function()
                state.ui.panel='master' render()
            end)}}
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Close',textSize=16,
            textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function()
                state.ui.visible=false leaveUiMode() render()
            end)}}
    elseif state.ui.panel=='actions' then
        local function option(label,name,tier,parameters)
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=label,textSize=18,
                textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=adapter.callback(function()
                    submitActionRequest(label,name,tier,parameters)
                end)}}
        end
        local function link(label,callback)
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=label,textSize=16,
                textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(callback)}}
        end
        local function page(rows,renderRow)
            local pageSize=6
            local pages=math.max(1,math.ceil(#rows/pageSize))
            state.ui.actionPage=math.max(1,math.min(state.ui.actionPage or 1,pages))
            local first=(state.ui.actionPage-1)*pageSize+1
            for index=first,math.min(#rows,first+pageSize-1) do renderRow(rows[index]) end
            if pages>1 then
                link('Previous page',function() state.ui.actionPage=math.max(1,state.ui.actionPage-1) render() end)
                link('Next page',function() state.ui.actionPage=math.min(pages,state.ui.actionPage+1) render() end)
                transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Page '..state.ui.actionPage..' / '..pages,
                    textSize=14,textColor=util.color.rgb(0.72,0.68,0.62)}}
            end
        end
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Actor Actions',textSize=20,
            textColor=util.color.rgb(0.95,0.9,0.82)}}
        local view=state.ui.actionView or 'root'
        if view=='root' then
            link('Movement...',function() state.ui.actionView='movement' render() end)
            option('Stop combat with me','combat.stop',1,{})
            link('Attack aimed actor...',function()
                beginSecondaryTarget('Attack selected target','combat.start',2,{})
            end)
            link('Stop combat with aimed actor...',function()
                beginSecondaryTarget('Stop combat with selected target','combat.stop',1,{})
            end)
            option('Play idle animation','animation.play',1,{group='idle2'})
            link('Use inventory item...',function() state.ui.actionView='use-items' state.ui.actionPage=1 render() end)
            link('Equip inventory item...',function() state.ui.actionView='equip-slots' state.ui.actionPage=1 render() end)
            link('Unequip slot...',function() state.ui.actionView='unequip' state.ui.actionPage=1 render() end)
        elseif view=='movement' then
            option('Follow me','ai.follow',1,{distance=192})
            link('Go to aimed point...',function()
                beginDestinationTarget('Go to selected destination','ai.travel',1)
            end)
            link('Escort me to aimed point...',function()
                beginDestinationTarget('Escort me to selected destination','ai.escort',1)
            end)
            option('Face me','ai.face',1,{})
            link('Face aimed actor...',function()
                beginSecondaryTarget('Face selected target','ai.face',1,{})
            end)
            option('Wait here','ai.wander',1,{distance=0,duration_seconds=3600})
            option('Wander nearby','ai.wander',1,{distance=512,duration_seconds=300})
            option('Stop ALMSIVI movement','ai.stop',1,{})
            link('Back',function() state.ui.actionView='root' render() end)
        elseif view=='use-items' or view=='equip-items' then
            local rows,reason=adapter.targetInventory(state.ui.target)
            if #rows==0 then
                transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='No readable inventory items',
                    textSize=16,textColor=util.color.rgb(0.82,0.78,0.72)}}
                state.ui.diagnostics=reason
            end
            page(rows,function(item)
                local label=item.record_id..'  x'..tostring(item.count)
                if view=='use-items' then option(label,'item.use',2,{record_id=item.record_id})
                else option(label,'item.equip',2,{record_id=item.record_id,slot=state.ui.actionSlot}) end
            end)
            link('Back',function() state.ui.actionView=view=='use-items' and 'root' or 'equip-slots'
                state.ui.actionPage=1 render() end)
        elseif view=='equip-slots' then
            page(EQUIPMENT_SLOTS,function(slot)
                link(slot,function() state.ui.actionSlot=slot state.ui.actionView='equip-items'
                    state.ui.actionPage=1 render() end)
            end)
            link('Back',function() state.ui.actionView='root' state.ui.actionPage=1 render() end)
        elseif view=='unequip' then
            local rows,reason=adapter.targetEquipment(state.ui.target)
            if #rows==0 then
                transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='No readable equipped items',
                    textSize=16,textColor=util.color.rgb(0.82,0.78,0.72)}}
                state.ui.diagnostics=reason
            end
            page(rows,function(item)
                option(item.slot..': '..item.record_id,'item.unequip',2,{slot=item.slot})
            end)
            link('Back',function() state.ui.actionView='root' state.ui.actionPage=1 render() end)
        end
        link('Conversation',function() state.ui.panel='conversation' render() end)
        link('Master Menu',function() state.ui.panel='master' render() end)
        link('Close',function() state.ui.visible=false leaveUiMode() render() end)
    elseif state.ui.panel=='master' then
        local function masterOption(label,callback)
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=label,textSize=18,
                textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=adapter.callback(callback)}}
        end
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Master Menu',textSize=20,
            textColor=util.color.rgb(0.95,0.9,0.82)}}
        masterOption('Typed conversation',function() state.ui.panel='conversation' render() end)
        masterOption('Actor actions',function() state.ui.panel='actions' render() end)
        masterOption('Agent manager',function() state.ui.panel='agents' render() end)
        masterOption('Conversation history',function() state.ui.panel='history' render() end)
        masterOption('Diagnostics',function() state.ui.panel='diagnostics' render() end)
        masterOption('Conversation behavior',function() state.ui.panel='behavior' render() end)
        masterOption('Dialogue mode: '..state.ui.mode,function() state.ui.panel='modes' render() end)
        masterOption('LLM model slot',function() refreshSessionControls('models') end)
        masterOption('NPC roleplay profile',function() refreshSessionControls('profiles') end)
        masterOption('Narrator profile',function() refreshSessionControls('narrator') end)
        masterOption('Stop current dialogue',function() send('ALMSIVI_STOP_DIALOGUE_REQUEST',{}) state.ui.status='dialogue stopped' render() end)
        masterOption('Halt actor actions',function() send('ALMSIVI_HALT_ACTIONS_REQUEST',{}) state.ui.status='actions halted' render() end)
        masterOption('Stop all ALMSIVI work',function() send('ALMSIVI_HALT_REQUEST',{}) state.ui.status='stopped' render() end)
        masterOption('Toggle compact status HUD',function() state.ui.statusHudVisible=not state.ui.statusHudVisible render() end)
        local ttsVolumeBoost=math.max(1,math.min(4,math.floor(tonumber(
            presentationSettings and presentationSettings:get('ttsVolumeBoost')) or 3)))
        masterOption('TTS volume boost: '..tostring(ttsVolumeBoost)..'x',function()
            if not presentationSettings then state.ui.status='settings storage unavailable' render() return end
            presentationSettings:set('ttsVolumeBoost',ttsVolumeBoost%4+1)
            settingsSignature=nil
            applySettings()
        end)
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Managed Agents: '..tostring(#state.ui.agents),textSize=17,
            textColor=util.color.rgb(0.92,0.82,0.68)}}
        for index,entry in ipairs(state.ui.agents) do
            if index>8 then break end
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='  '..displayName(entry.identity)..
                ' ['..activityLabel(entry.identity)..']'..(entry.pinned and ' [pinned]' or ''),
                textSize=15,textColor=util.color.rgb(0.82,0.78,0.72)}}
        end
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Settings: Options > Scripts > ALMSIVI',textSize=15,
            textColor=util.color.rgb(0.72,0.68,0.62)}}
        masterOption('Close',function() state.ui.visible=false leaveUiMode() render() end)
    elseif state.ui.panel=='behavior' then
        local function behaviorOption(label,key)
            local enabled=behaviorSettings and behaviorSettings:get(key)==true
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=label..': '..(enabled and 'ON' or 'OFF'),textSize=18,
                textColor=enabled and util.color.rgb(0.45,0.9,0.45) or util.color.rgb(1.0,0.58,0.18)},
                events={mouseClick=adapter.callback(function()
                    if not behaviorSettings then state.ui.status='settings storage unavailable' render() return end
                    behaviorSettings:set(key,not enabled)
                    settingsSignature=nil
                    applySettings()
                end)}}
        end
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Conversation Behavior',textSize=20,
            textColor=util.color.rgb(0.95,0.9,0.82)}}
        behaviorOption('Continue conversations (rechat)','rechat')
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='After '..tostring(behaviorSettings and behaviorSettings:get('rechatDelaySeconds') or 45)
            ..' quiet seconds; maximum '..tostring(behaviorSettings and behaviorSettings:get('rechatMaxDepth') or 10)..' replies.',
            textSize=14,textColor=util.color.rgb(0.72,0.68,0.62)}}
        behaviorOption('Bored events','boredom')
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='After '..tostring(behaviorSettings and behaviorSettings:get('boredomDelaySeconds') or 180)
            ..' quiet seconds. Runs locally around managed nearby actors; this is not background life.',
            textSize=14,textColor=util.color.rgb(0.72,0.68,0.62)}}
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Timers and safety conditions: Options > Scripts > ALMSIVI',
            textSize=14,textColor=util.color.rgb(0.72,0.68,0.62)}}
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Master Menu',textSize=16,
            textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=adapter.callback(function() state.ui.panel='master' render() end)}}
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Close',textSize=16,
            textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function()
                state.ui.visible=false leaveUiMode() render()
            end)}}
    elseif state.ui.panel=='models' or state.ui.panel=='profiles' or state.ui.panel=='narrator' then
        local controls=sessionControls()
        local modelPanel=state.ui.panel=='models'
        local narratorPanel=state.ui.panel=='narrator'
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=modelPanel and 'LLM Model Slot' or (narratorPanel and 'Narrator Profile' or 'NPC Roleplay Profile'),textSize=20,
            textColor=util.color.rgb(0.95,0.9,0.82)}}
        if not controls or not identity.same(controls.target,state.ui.target) then
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Loading server-owned choices...',textSize=16,
                textColor=util.color.rgb(0.72,0.68,0.62)}}
        elseif modelPanel then
            local defaultActive=not controls.selected_model_slot_id and ' [active]' or ''
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Server default'..defaultActive,textSize=18,
                textColor=not controls.selected_model_slot_id and util.color.rgb(0.45,0.9,0.45) or util.color.rgb(1.0,0.58,0.18)},
                events={mouseClick=adapter.callback(function() selectSessionControl('model_slot',nil) end)}}
            for _,slot in ipairs(controls.model_slots or {}) do
                local active=controls.selected_model_slot_id==slot.configuration_id and ' [active]' or ''
                transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=slot.name..active..'  |  '..slot.model,textSize=17,
                    textColor=active~='' and util.color.rgb(0.45,0.9,0.45) or util.color.rgb(1.0,0.58,0.18)},
                    events={mouseClick=adapter.callback(function() selectSessionControl('model_slot',slot.configuration_id) end)}}
            end
        elseif narratorPanel then
            if controls.narrator_profile_id then
                transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Generate narrator profile with AI',textSize=18,
                    textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=adapter.callback(generateNarratorProfile)}}
                transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Queues one revision-safe narrator job and preserves voice routing and enablement.',textSize=14,
                    textColor=util.color.rgb(0.72,0.68,0.62)}}
            else
                transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='No narrator profile is configured. Create one in Server > Configuration > Narration.',textSize=16,
                    textColor=util.color.rgb(0.72,0.68,0.62)}}
            end
        else
            local defaultActive=not controls.selected_profile_id and ' [active]' or ''
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Use playthrough profile'..defaultActive,textSize=18,
                textColor=not controls.selected_profile_id and util.color.rgb(0.45,0.9,0.45) or util.color.rgb(1.0,0.58,0.18)},
                events={mouseClick=adapter.callback(function() selectSessionControl('actor_profile',nil) end)}}
            for _,profile in ipairs(controls.profiles or {}) do
                local active=controls.selected_profile_id==profile.profile_id and ' [active]' or ''
                transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=profile.name..active..'  |  revision '..tostring(profile.revision),textSize=17,
                    textColor=active~='' and util.color.rgb(0.45,0.9,0.45) or util.color.rgb(1.0,0.58,0.18)},
                    events={mouseClick=adapter.callback(function() selectSessionControl('actor_profile',profile.profile_id) end)}}
            end
            if controls.selected_profile_id then
                transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Generate active profile with AI',textSize=17,
                    textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=adapter.callback(generateSelectedProfile)}}
                transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Queues one revision-safe server job. Refresh after it completes.',textSize=14,
                    textColor=util.color.rgb(0.72,0.68,0.62)}}
            end
        end
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Refresh choices',textSize=16,
            textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=adapter.callback(function() refreshSessionControls(state.ui.panel) end)}}
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Master Menu',textSize=16,
            textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function() state.ui.panel='master' render() end)}}
    elseif state.ui.panel=='modes' then
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Dialogue Mode',textSize=20,
            textColor=util.color.rgb(0.95,0.9,0.82)}}
        local descriptions={
            Standard='Selected group plus managed actors inside normal hearing distance.',
            Whisper='Private turn to the selected target only.',
            Close='Only the explicitly selected conversation group hears the turn.',
            Shout='Selected group plus managed actors inside double hearing distance.',
        }
        for _,mode in ipairs(MODES) do
            local active=mode==state.ui.mode and ' [active]' or ''
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=mode..active,textSize=18,
                textColor=mode==state.ui.mode and util.color.rgb(0.45,0.9,0.45) or util.color.rgb(1.0,0.58,0.18)},
                events={mouseClick=adapter.callback(function() setMode(mode) end)}}
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=descriptions[mode],textSize=14,
                textColor=util.color.rgb(0.72,0.68,0.62)}}
        end
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Master Menu',textSize=16,
            textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function()
                state.ui.panel='master' render()
            end)}}
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Close',textSize=16,
            textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function()
                state.ui.visible=false leaveUiMode() render()
            end)}}
    end
    if state.ui.pendingAction then
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Confirm action: '..state.ui.pendingAction.name,textSize=17,
            textColor=util.color.rgb(1.0,0.72,0.2)}}
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Approve',textSize=16,textColor=util.color.rgb(0.45,0.9,0.45)},
            events={mouseClick=adapter.callback(function()
                send('ALMSIVI_CONFIRM_ACTION',{action_id=state.ui.pendingAction.action_id,approved=true})
                state.ui.pendingAction=nil render()
            end)}}
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Reject',textSize=16,textColor=util.color.rgb(1.0,0.45,0.35)},
            events={mouseClick=adapter.callback(function()
                send('ALMSIVI_CONFIRM_ACTION',{action_id=state.ui.pendingAction.action_id,approved=false})
                state.ui.pendingAction=nil render()
            end)}}
    end
    element=openmwUi.create({layer='Windows',type=openmwUi.TYPE.Container,
        props={position=util.vector2(30,60),size=util.vector2(680,460)},content=openmwUi.content({
            {type=openmwUi.TYPE.Flex,props={horizontal=false,size=util.vector2(660,440)},content=openmwUi.content({
                {type=openmwUi.TYPE.Text,props={text='ALMSIVI  |  '..state.ui.status..'  |  '..state.ui.mode,textSize=22,textColor=util.color.rgb(1.0,0.45,0.08)}},
                {type=openmwUi.TYPE.Text,props={text='Target: '..actorLabel(state.ui.target),textSize=18,textColor=util.color.rgb(0.95,0.9,0.82)}},
                {type=openmwUi.TYPE.Text,props={text='Aim: '..displayName(aimCandidate and aimCandidate.identity),textSize=15,textColor=util.color.rgb(0.72,0.68,0.62)}},
                {type=openmwUi.TYPE.Text,props={text='Group: '..audienceNames(),textSize=16,textColor=util.color.rgb(0.82,0.78,0.72)}},
                unpackValues(transcript),
            })},
        })})
end

chooseTarget=function(maxDistance,deferRender)
    maxDistance=maxDistance or 2048
    local candidate=aimCandidate and aimCandidate.distance<=maxDistance and not aimCandidate.dead
        and aimCandidate.available~=false and aimCandidate or nil
    local reason=candidate and 'live_aim_preview' or nil
    if not candidate then candidate,reason=adapter.resolveCameraTarget(maxDistance) end
    if not candidate then
        local nearby=adapter.nearbyActors(maxDistance)
        candidate=nearby[1]
        if candidate then reason='nearest_actor_fallback' end
    end
    if candidate then
        state.ui.status=reason=='nearest_actor_fallback' and ('selecting nearest actor: '..displayName(candidate.identity))
            or ('selecting aimed actor: '..displayName(candidate.identity))
        print('[ALMSIVI] local target candidate: '..displayName(candidate.identity)..' via '..tostring(reason))
        send('ALMSIVI_SELECT_TARGET',{candidate=candidate})
    else
        state.ui.diagnostics=reason
        state.ui.status='selecting nearest active actor'
        print('[ALMSIVI] local target search failed: '..tostring(reason)..'; requesting global fallback')
        send('ALMSIVI_SELECT_NEAREST_TARGET',{maxDistance=maxDistance,local_reason=reason})
    end
    if not deferRender then render() end
    return true
end

local function chooseAudience(maxDistance)
    local candidate=aimCandidate
    local reason=candidate and 'live_aim_preview' or nil
    if not candidate then candidate,reason=adapter.resolveCameraTarget(maxDistance or 2048) end
    if candidate then send('ALMSIVI_ADD_AUDIENCE',{candidate=candidate})
    else state.ui.diagnostics=reason state.ui.status='group actor unavailable' end
    render()
end

local function toggleTalk()
    if not state.ui.visible and not controlsAllowed() then return end
    state.ui.pendingTargetAction=nil
    state.ui.visible=not state.ui.visible
    state.ui.panel='conversation'
    if state.ui.visible then
        chooseTarget(2048,true)
        enterUiMode()
        render()
        print('[ALMSIVI] text chat overlay opened')
    else
        pendingTextSubmit=false
        leaveUiMode()
        render()
        print('[ALMSIVI] text chat overlay closed')
    end
end

-- OpenMW normally delivers the semantic trigger through its binding manager. The configured-key
-- fallback covers load-order or binding-manager failures without hardwiring F6 or defeating rebinds;
-- the short debounce prevents the semantic and raw-key paths from toggling the panel twice.
local function requestTalkToggle()
    local now=core and core.getRealTime and core.getRealTime() or 0
    if lastTalkToggleAt>=0 and now-lastTalkToggleAt<0.1 then return end
    lastTalkToggleAt=now
    toggleTalk()
end

local function isConfiguredTalkKey(event)
    if not event or not inputBindings then return false end
    local binding=inputBindings:get('ALMSIVI_Talk_Binding')
    return binding and binding.device=='keyboard' and binding.type=='trigger'
        and binding.key=='ALMSIVI_Talk' and binding.button==event.code
end

local function cycleMode()
    if not controlsAllowed() then return end
    local index=1
    for current,name in ipairs(MODES) do if name==state.ui.mode then index=current break end end
    setMode(MODES[index%#MODES+1])
end

local function openPanel(panel)
    if not controlsAllowed() and not ownsUiMode then return end
    state.ui.panel=panel state.ui.visible=true
    if panel=='actions' then state.ui.actionView='root' state.ui.actionPage=1 end
    if (panel=='actions' or panel=='conversation') and not state.ui.target then chooseTarget(2048) end
    enterUiMode()
end

local function togglePanel(panel)
    if state.ui.visible and state.ui.panel==panel then
        state.ui.visible=false leaveUiMode() render()
    else
        openPanel(panel) render()
    end
end

local function manualActivate()
    if not controlsAllowed() then return end
    local candidate,reason=adapter.resolveCameraTarget(2048)
    if candidate then send('ALMSIVI_MANUAL_ACTIVATE_REQUEST',{candidate=candidate})
    else
        local exterior=self.cell and self.cell.isExterior==true
        local distance=autoSettings and autoSettings:get(exterior and 'exteriorDistance' or 'interiorDistance')
            or (exterior and 2400 or 1200)
        local candidates=adapter.nearbyActors(tonumber(distance) or (exterior and 2400 or 1200))
        while #candidates>12 do table.remove(candidates) end
        if #candidates>0 then
            send('ALMSIVI_MANUAL_ACTIVATE_NEARBY_REQUEST',{candidates=candidates})
            state.ui.status='pinning nearby agents'
        else
            state.ui.status='no nearby agents' state.ui.diagnostics=reason
        end
        render()
    end
end

local function confirmSecondaryTarget()
    local pending=state.ui.pendingTargetAction
    if not pending then return false end
    if not state.ui.target or not identity.same(pending.actor,state.ui.target) then
        state.ui.pendingTargetAction=nil
        state.ui.status='actor target changed; action cancelled'
        render()
        return true
    end
    if pending.kind=='destination' then
        local destination,reason=adapter.resolveCameraPoint(2048)
        if not destination then
            state.ui.status='destination unavailable; aim nearby and press F8'
            state.ui.diagnostics=reason
            render()
            return true
        end
        submitActionRequest(pending.label,pending.name,pending.tier,destination)
        return true
    end
    local candidate,reason=adapter.resolveCameraTarget(2048)
    if not candidate then
        state.ui.status='action target unavailable; aim and press F8'
        state.ui.diagnostics=reason
        render()
        return true
    end
    if identity.same(candidate.identity,state.ui.target) then
        state.ui.status='choose a different action target'
        render()
        return true
    end
    submitActionRequest(pending.label,pending.name,pending.tier,pending.parameters,candidate.identity)
    return true
end

applySettings=function()
    local exterior=self.cell and self.cell.isExterior==true
    local legacyHearing=autoSettings and autoSettings:get('hearingDistance')
    local interiorHearing=autoSettings and autoSettings:get('interiorHearingDistance') or legacyHearing or 500
    local exteriorHearing=autoSettings and autoSettings:get('exteriorHearingDistance') or legacyHearing or 1000
    local current={
        autoActivate={enabled=autoSettings and autoSettings:get('enabled'),
            interiorDistance=autoSettings and autoSettings:get('interiorDistance'),
            exteriorDistance=autoSettings and autoSettings:get('exteriorDistance'),
            hearingDistance=exterior and exteriorHearing or interiorHearing,
            interiorHearingDistance=interiorHearing,
            exteriorHearingDistance=exteriorHearing,
            addHostile=autoSettings and autoSettings:get('addHostile'),
            addCreatures=autoSettings and autoSettings:get('addCreatures')},
        behavior={actionsEnabled=behaviorSettings and behaviorSettings:get('actionsEnabled'),
            autoGreeting=behaviorSettings and behaviorSettings:get('autoGreeting'),
            rechat=behaviorSettings and behaviorSettings:get('rechat'),
            rechatDelaySeconds=behaviorSettings and behaviorSettings:get('rechatDelaySeconds'),
            rechatMaxDepth=behaviorSettings and behaviorSettings:get('rechatMaxDepth'),
            boredom=behaviorSettings and behaviorSettings:get('boredom'),
            boredomDelaySeconds=behaviorSettings and behaviorSettings:get('boredomDelaySeconds'),
            avoidAutonomyInMenus=behaviorSettings and behaviorSettings:get('avoidAutonomyInMenus'),
            avoidAutonomyInCombat=behaviorSettings and behaviorSettings:get('avoidAutonomyInCombat'),
            avoidAutonomyWhenSneaking=behaviorSettings and behaviorSettings:get('avoidAutonomyWhenSneaking'),
            cancelDialogueOnCombat=behaviorSettings and behaviorSettings:get('cancelDialogueOnCombat'),
            combatBarks=behaviorSettings and behaviorSettings:get('combatBarks'),
            combatBarkPeriodSeconds=behaviorSettings and behaviorSettings:get('combatBarkPeriodSeconds'),
            openMicSensitivity=behaviorSettings and behaviorSettings:get('openMicSensitivity'),
            openMicEndDelayMs=behaviorSettings and behaviorSettings:get('openMicEndDelayMs')},
        presentation={showStatusHud=presentationSettings and presentationSettings:get('showStatusHud'),
            transcriptRows=presentationSettings and presentationSettings:get('transcriptRows'),
            ttsVolumeBoost=presentationSettings and presentationSettings:get('ttsVolumeBoost')},
    }
    local auto=current.autoActivate or {}
    local behavior=current.behavior or {}
    local presentation=current.presentation or {}
    local signature=table.concat({tostring(auto.enabled),tostring(auto.interiorDistance),tostring(auto.exteriorDistance),
        tostring(auto.hearingDistance),tostring(auto.interiorHearingDistance),tostring(auto.exteriorHearingDistance),
        tostring(auto.addHostile),tostring(auto.addCreatures),tostring(behavior.actionsEnabled),
        tostring(behavior.autoGreeting),tostring(behavior.rechat),tostring(behavior.rechatDelaySeconds),
        tostring(behavior.rechatMaxDepth),tostring(behavior.boredom),tostring(behavior.boredomDelaySeconds),
        tostring(behavior.avoidAutonomyInMenus),
        tostring(behavior.avoidAutonomyInCombat),tostring(behavior.avoidAutonomyWhenSneaking),
        tostring(behavior.cancelDialogueOnCombat),
        tostring(behavior.combatBarks),tostring(behavior.combatBarkPeriodSeconds),
        tostring(behavior.openMicSensitivity),tostring(behavior.openMicEndDelayMs),
        tostring(presentation.showStatusHud),tostring(presentation.transcriptRows),
        tostring(presentation.ttsVolumeBoost)},'|')
    if signature==settingsSignature then return end
    settingsSignature=signature
    state.ui.statusHudVisible=presentation.showStatusHud~=false
    state.ui.policy.transcriptRows=presentation.transcriptRows or 12
    send('ALMSIVI_SETTINGS_UPDATE',current)
    render()
end

local function autonomyBlocked()
    local avoidMenus=not behaviorSettings or behaviorSettings:get('avoidAutonomyInMenus')~=false
    local avoidCombat=not behaviorSettings or behaviorSettings:get('avoidAutonomyInCombat')~=false
    local avoidSneaking=not behaviorSettings or behaviorSettings:get('avoidAutonomyWhenSneaking')~=false
    return autonomyPending or turnActive or state.ui.visible or voiceRecording or openMicEnabled
        or state.ui.pendingTargetAction or avoidMenus and not controlsAllowed()
        or avoidCombat and nearbyCombat or avoidSneaking and self.controls and self.controls.sneak==true
end

local function updateLocalAutonomy(dt)
    if autonomyBlocked() then quietElapsed=0 return end
    quietElapsed=quietElapsed+(tonumber(dt) or 0)
    local rechatEnabled=behaviorSettings and behaviorSettings:get('rechat')==true
    local rechatDelay=tonumber(behaviorSettings and behaviorSettings:get('rechatDelaySeconds')) or 45
    local rechatMaxDepth=tonumber(behaviorSettings and behaviorSettings:get('rechatMaxDepth')) or 10
    local boredomEnabled=behaviorSettings and behaviorSettings:get('boredom')==true
    local boredomDelay=tonumber(behaviorSettings and behaviorSettings:get('boredomDelaySeconds')) or 180
    local kind
    if rechatEnabled and rechatDepth<rechatMaxDepth and hadConversation and state.ui.target
        and quietElapsed>=rechatDelay then kind='rechat'
    elseif boredomEnabled and quietElapsed>=boredomDelay then kind='boredom' end
    if kind then
        autonomyPending=true
        quietElapsed=0
        send('ALMSIVI_LOCAL_AUTONOMY_REQUEST',{kind=kind})
    end
end

local function updateCombatBarks(dt)
    if not behaviorSettings or behaviorSettings:get('combatBarks')==false or #combatThreats==0 then
        combatBarkElapsed=0
        return
    end
    if autonomyPending or turnActive or state.ui.visible or voiceRecording or openMicEnabled
        or speechActive() or state.ui.pendingTargetAction or not controlsAllowed() then return end
    combatBarkElapsed=combatBarkElapsed+(tonumber(dt) or 0)
    local period=math.max(10,math.min(300,tonumber(behaviorSettings:get('combatBarkPeriodSeconds')) or 30))
    if combatBarkElapsed<period then return end
    combatBarkElapsed=0
    combatBarkIndex=combatBarkIndex%#combatThreats+1
    autonomyPending=true
    send('ALMSIVI_LOCAL_AUTONOMY_REQUEST',{kind='combat_bark',actor=combatThreats[combatBarkIndex]})
end

if inputOk then
    input.registerTriggerHandler('ALMSIVI_Talk',adapter.callback(requestTalkToggle))
    input.registerTriggerHandler('ALMSIVI_StopDialogue',adapter.callback(function()
        send('ALMSIVI_STOP_DIALOGUE_REQUEST',{}) state.ui.status='dialogue stopped' render()
    end))
    input.registerTriggerHandler('ALMSIVI_Halt',adapter.callback(function()
        openMicEnabled=false openMicMuted=false voiceRecording=false pttHeld=false
        state.ui.pendingTargetAction=nil
        player.onAction(state,'ALMSIVI_Halt',send) state.ui.status='stopped' render()
    end))
    input.registerTriggerHandler('ALMSIVI_ManualActivate',adapter.callback(manualActivate))
    input.registerTriggerHandler('ALMSIVI_ActionsMenu',adapter.callback(function()
        if not confirmSecondaryTarget() then togglePanel('actions') end
    end))
    input.registerTriggerHandler('ALMSIVI_MasterMenu',adapter.callback(function() togglePanel('master') end))
    input.registerTriggerHandler('ALMSIVI_ToggleMode',adapter.callback(cycleMode))
    input.registerTriggerHandler('ALMSIVI_StatusHud',adapter.callback(function()
        if not controlsAllowed() then return end
        state.ui.statusHudVisible=not state.ui.statusHudVisible
        render()
    end))
    input.registerTriggerHandler('ALMSIVI_History',adapter.callback(function() togglePanel('history') end))
    input.registerTriggerHandler('ALMSIVI_Diagnostics',adapter.callback(function() togglePanel('diagnostics') end))
    input.registerTriggerHandler('ALMSIVI_OpenMic',adapter.callback(function()
        if not controlsAllowed() then return end
        if not openMicEnabled and not state.ui.target then chooseTarget(2048) return end
        openMicEnabled=not openMicEnabled openMicMuted=false voiceRecording=openMicEnabled
        if openMicEnabled then
            rechatDepth=0 hadConversation=false activeAutonomyKind=nil activeAutonomySpoke=false
            send('ALMSIVI_OPEN_MIC_START',voicePayload('almsivi_open_mic'))
        else send('ALMSIVI_OPEN_MIC_STOP',{}) end
        render()
    end))
    input.registerTriggerHandler('ALMSIVI_OpenMicMute',adapter.callback(function()
        if not controlsAllowed() then return end
        if not openMicEnabled then state.ui.status='open mic is off' render() return end
        openMicMuted=not openMicMuted voiceRecording=not openMicMuted
        if openMicMuted then send('ALMSIVI_OPEN_MIC_STOP',{})
        else send('ALMSIVI_OPEN_MIC_START',voicePayload('almsivi_open_mic')) end
        state.ui.status=openMicMuted and 'open mic muted' or 'open mic listening'
        render()
    end))
end

return {
    engineHandlers={
        onInputAction=function(action) return player.onAction(state,action,send) end,
        onKeyPress=function(event)
            if inputOk and state.ui.visible and state.ui.panel=='conversation' and event
                and (event.code==input.KEY.Enter or event.code==input.KEY.NP_Enter) then
                print('[ALMSIVI] text chat Enter accepted by engine fallback')
                submitText()
                return
            end
            if inputOk and isConfiguredTalkKey(event) then requestTalkToggle() end
        end,
        onUpdate=function(dt)
            if narratorSpeech and not adapter.isSpeechActive() then reportNarrator('played','playback_completed') end
            applySettings()
            updateLocalAutonomy(dt)
            updateCombatBarks(dt)
            aimScanElapsed=aimScanElapsed+(tonumber(dt) or 0)
            if aimScanElapsed>=0.1 and not state.ui.visible and controlsAllowed() then
                aimScanElapsed=0
                local candidate=adapter.resolveActorRay(2048)
                local signature=candidate and identity.key(candidate.identity) or ''
                if signature~=aimSignature then
                    aimCandidate=candidate aimSignature=signature render()
                elseif candidate then aimCandidate=candidate end
            end
            autoScanElapsed=autoScanElapsed+(tonumber(dt) or 0)
            if autoScanElapsed>=0.25 then
                autoScanElapsed=0
                local enabled=not autoSettings or autoSettings:get('enabled')~=false
                local candidates={}
                if enabled then
                    local exterior=self.cell and self.cell.isExterior==true
                    local distance=autoSettings and autoSettings:get(exterior and 'exteriorDistance' or 'interiorDistance')
                        or (exterior and 2400 or 1200)
                    candidates=adapter.nearbyActors(tonumber(distance) or (exterior and 2400 or 1200))
                    while #candidates>32 do table.remove(candidates) end
                end
                send('ALMSIVI_AUTO_ACTIVATE_SCAN',{candidates=candidates,
                    safe_for_autonomy=not autonomyBlocked()})
            end
            local controls=sessionControls()
            local signature=controls and table.concat({tostring(controls.selected_model_slot_id),tostring(controls.selected_profile_id),
                tostring(#(controls.model_slots or {})),tostring(#(controls.profiles or {})),tostring(controls.pending)},'|') or ''
            if signature~=controlsSignature then controlsSignature=signature
                if state.ui.visible and (state.ui.panel=='models' or state.ui.panel=='profiles') then render() end end
            if not inputOk or not input.getBooleanActionValue then return end
            local held=input.getBooleanActionValue('ALMSIVI_PushToTalk')==true
            if held and not controlsAllowed() then held=false end
            if held==pttHeld then return end
            pttHeld=held
            if held then
                if not state.ui.target then chooseTarget(2048) pttHeld=false return end
                if openMicEnabled then openMicEnabled=false openMicMuted=false send('ALMSIVI_OPEN_MIC_STOP',{}) end
                rechatDepth=0 hadConversation=false activeAutonomyKind=nil activeAutonomySpoke=false
                voiceRecording=true
                send('ALMSIVI_VOICE_START',voicePayload('almsivi_voice'))
            else voiceRecording=false send('ALMSIVI_VOICE_STOP',{}) end
            render()
        end,
    },
    eventHandlers={
        ALMSIVI_NARRATOR_SPEAK=function(command)
            stopNarrator('speech_replaced')
            local ok,reason=adapter.playSpeech(command.media_id,command.subtitle,command.tts_volume_boost)
            if ok then narratorSpeech=command
                send('ALMSIVI_SPEECH_STATUS',{actor=command.actor,media_id=command.media_id,active=true,status='playing'})
            else narratorSpeech=command reportNarrator('failed',reason or 'playback_failed') end
        end,
        ALMSIVI_NARRATOR_STOP=function(event) stopNarrator(event and event.reason or 'client_interrupted') end,
        ALMSIVI_STATUS=function(event) state.ui.status=event.status state.ui.diagnostics=event.reason render() end,
        ALMSIVI_TURN=function(event)
            if not awaitingTextQueue then return end
            awaitingTextQueue=false
            if event.status=='queued' then
                state.ui.input=''
                state.ui.status='queued'
                state.ui.visible=false
                turnActive=true
                leaveUiMode()
                print('[ALMSIVI] text message accepted; chat closed')
            else
                state.ui.status='message failed: '..tostring(event.reason or 'unknown')
                turnActive=false
                print('[ALMSIVI] text message rejected: '..tostring(event.reason or 'unknown'))
            end
            render()
        end,
        ALMSIVI_PLAYER_RESOLVE_TARGET=function(event) chooseTarget(event.maxDistance) end,
        ALMSIVI_PLAYER_RESOLVE_AUDIENCE=function(event) chooseAudience(event.maxDistance) end,
        ALMSIVI_TARGET=function(event)
            state.ui.target=event.target state.ui.audience=event.audience or {event.target}
            state.ui.status='target: '..displayName(event.target)
            print('[ALMSIVI] player target confirmed: '..displayName(event.target))
            local shouldSubmit=pendingTextSubmit and state.ui.visible and state.ui.panel=='conversation'
            local controlPanel=pendingControlPanel
            pendingTextSubmit=false
            pendingControlPanel=nil
            if shouldSubmit then submitText() elseif controlPanel then refreshSessionControls(controlPanel) else render() end
        end,
        ALMSIVI_TARGET_REJECTED=function(event)
            pendingTextSubmit=false
            pendingControlPanel=nil
            state.ui.status='target unavailable: '..tostring(event and event.reason or 'unknown')
            render()
        end,
        ALMSIVI_AUDIENCE=function(event) state.ui.target=event.target state.ui.audience=event.audience or {} render() end,
        ALMSIVI_AGENTS=function(event) state.ui.agents=event.agents or {} render() end,
        ALMSIVI_COMBAT_STATUS=function(event)
            local started=event.active==true and not nearbyCombat
            nearbyCombat=event.active==true
            combatThreats=event.threats or {}
            if started then
                combatBarkElapsed=tonumber(behaviorSettings and behaviorSettings:get('combatBarkPeriodSeconds')) or 30
            elseif not nearbyCombat then combatBarkElapsed=0 end
            if started and (not behaviorSettings or behaviorSettings:get('cancelDialogueOnCombat')~=false)
                and (turnActive or voiceRecording or openMicEnabled or speechActive()) then
                send('ALMSIVI_STOP_DIALOGUE_REQUEST',{})
                voiceRecording=false openMicEnabled=false openMicMuted=false pttHeld=false turnActive=false
                speechActors={}
                state.ui.status='dialogue stopped for combat'
                render()
            end
        end,
        ALMSIVI_ACTOR_ACTIVITY=function(event)
            if event and event.reset==true then actorActivities={} return end
            local key=event and event.actor and identity.key(event.actor)
            if key then
                if event.activity=='inactive' then actorActivities[key]=nil
                else actorActivities[key]={actor=event.actor,activity=event.activity,target=event.target} end
                if state.ui.visible and (state.ui.panel=='agents' or state.ui.panel=='master') then render() end
            end
        end,
        ALMSIVI_SPEECH_STATUS=function(event)
            local key=event.actor and identity.key(event.actor)
            if key then
                if event.active==true then speechActors[key]=true else speechActors[key]=nil end
                render()
            end
        end,
        ALMSIVI_ACTIVATION_STATUS=function(event)
            state.ui.status=event.status=='nearby' and ('nearby agents pinned: '..tostring(event.added or 0))
                or event.status=='deactivated' and 'manual agent unpinned'
                or event.actor and ('manual agent '..tostring(event.status)) or 'manual activation failed'
            state.ui.diagnostics=event.actor and nil or event.status
            render()
        end,
        ALMSIVI_BOOK_READ=function(event)
            if adapter.rememberBook(event) then
                state.ui.status='book remembered: '..tostring(event.title or event.record_id)
                render()
            end
        end,
        ALMSIVI_ACTION_CONFIRMATION=function(event)
            state.ui.pendingAction=event state.ui.panel='actions' state.ui.actionView='root'
            state.ui.visible=true enterUiMode() render()
        end,
        ALMSIVI_ACTION_STATUS=function(event)
            state.ui.status='action '..tostring(event.name or '')..' '..tostring(event.status or 'unknown')
            state.ui.diagnostics=event.submitted and event.reason or event.submit_reason
            render()
        end,
        ALMSIVI_VOICE_STATUS=function(event)
            state.ui.status=event.status
            if event.status=='failed' or event.status=='queued' then voiceRecording=false end
            if (event.status=='open mic off' and not openMicMuted)
                or (event.status=='failed' and event.continuous) then openMicEnabled=false openMicMuted=false end
            state.ui.diagnostics=event.reason render()
        end,
        ALMSIVI_OPEN_MIC_CONTEXT_REQUEST=function()
            if not openMicEnabled or openMicMuted or not state.ui.target then return end
            send('ALMSIVI_OPEN_MIC_CONTEXT',voicePayload('almsivi_open_mic'))
        end,
        ALMSIVI_AUTONOMY_CONTEXT_REQUEST=function(event)
            if not state.ui.target then return end
            activeAutonomyKind=event.directive and event.directive.kind or nil
            activeAutonomySpoke=false
            send('ALMSIVI_AUTONOMY_CONTEXT',{directive=event.directive,speaker=adapter.identity(self),
                context=(function()
                    local context=conversationContext(state.ui.target)
                    context.dialogueMode=state.ui.mode
                    return context
                end)(),language='en-US',capabilities=CAPABILITIES,
                recent_action_results={}})
        end,
        ALMSIVI_AUTONOMY_STATUS=function(event)
            autonomyPending=false
            if event.status=='failed' or event.status=='skipped' then
                activeAutonomyKind=nil activeAutonomySpoke=false
            end
            if event.status~='skipped' then state.ui.status='autonomy '..event.status render() end
        end,
        ALMSIVI_EVENT=function(event)
            if event.type=='turn.accepted' then turnActive=true end
            if event.type=='dialogue.complete' then
                hadConversation=true quietElapsed=0
                if activeAutonomyKind then activeAutonomySpoke=true end
            end
            if event.type=='turn.complete' or event.type=='turn.failed' or event.type=='turn.cancelled' then
                if event.type=='turn.complete' and activeAutonomyKind=='rechat' and activeAutonomySpoke then
                    rechatDepth=rechatDepth+1
                elseif activeAutonomyKind and activeAutonomyKind~='rechat' then
                    rechatDepth=0
                end
                activeAutonomyKind=nil activeAutonomySpoke=false
                turnActive=false quietElapsed=0
            end
            player.event(state,event) render()
        end,
    },
}
