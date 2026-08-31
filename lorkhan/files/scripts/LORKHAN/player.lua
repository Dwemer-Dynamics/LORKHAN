local adapter=require('scripts.LORKHAN.adapters.openmw')
local identity=require('scripts.LORKHAN.identity')
local player=require('scripts.LORKHAN.player_state')
local protocol=require('scripts.LORKHAN.protocol')
local playerInput=require('scripts.LORKHAN.player_input')
local chatbox=require('scripts.LORKHAN.ui.chatbox')
local uiState=require('scripts.LORKHAN.ui.state')
local selector=require('scripts.LORKHAN.ui.selector')
local actorTools=require('scripts.LORKHAN.ui.actor_tools')
local support=require('scripts.LORKHAN.util')
local core=adapter.event()
local inputOk,input=pcall(require,'openmw.input')
local uiOk,openmwUi=pcall(require,'openmw.ui')
local utilOk,util=pcall(require,'openmw.util')
local self=require('openmw.self')
local interfacesOk,interfaces=pcall(require,'openmw.interfaces')
local storageOk,openmwStorage=pcall(require,'openmw.storage')
local nativeOk,native=pcall(require,'openmw.lorkhan')
local state=player.new()
local element
local statusElement
local voiceRecording=false
local pttHeld=false
local openMicEnabled=false
local openMicMuted=false
local settingsSignature
local autoScanElapsed=0
local turnActive=false
local nearbyCombat=false
local actorActivities={}
local contextCollectionSamples={}
local speechActors={}
local narratorSpeech
local menuDialogueSpeech
local pendingCapturedDialogue={}
local capturedDialogueSeen={}
local capturedDialogueFlushElapsed=0
local ownsUiMode=false
local controlsSignature
local responseQueueSnapshot={}
local MODES=uiState.MODES
local EQUIPMENT_SLOTS={'helmet','cuirass','greaves','left_pauldron','right_pauldron','left_gauntlet',
    'right_gauntlet','boots','shirt','pants','skirt','robe','left_ring','right_ring','amulet','belt',
    'carried_right','carried_left','ammunition'}
local autoSettings=storageOk and openmwStorage.playerSection('SettingsLORKHANAutoActivate') or nil
local behaviorSettings=storageOk and openmwStorage.playerSection('SettingsLORKHANBehavior') or nil
local soundSettings=storageOk and openmwStorage.playerSection('SettingsLORKHANSound') or nil
local agentSettings=storageOk and openmwStorage.playerSection('SettingsLORKHANAgents') or nil
local presentationSettings=storageOk and openmwStorage.playerSection('SettingsLORKHANPresentation') or nil
local playerInputSettings=storageOk and openmwStorage.playerSection('SettingsLORKHANPlayerInput') or nil
local inputBindings=storageOk and openmwStorage.playerSection('OMWInputBindings') or nil
local unpackValues=table.unpack or unpack
local whiteTexture=uiOk and openmwUi.texture and openmwUi.texture({path='white'}) or nil
local lastTalkToggleAt=-1
local pendingTextSubmit=false
local awaitingTextQueue=false
local pendingHistory
local pendingControlPanel
-- Panels whose contents are owned by the server, so an in-flight controls request has to settle
-- before they can show the player anything new.
local SERVER_CONTROL_PANELS={models=true,profiles=true,narrator=true}
local controlsRequestActive=false
local aimCandidate
local aimScanElapsed=0
local aimSignature=''
local settingsRefreshElapsed=0.5
local SETTINGS_REFRESH_INTERVAL=0.5
local AIM_SCAN_INTERVAL=0.25
local AUTO_SCAN_INTERVAL=1.0
if playerInputSettings then
    uiState.setMood(state.ui,playerInputSettings:get('mood') or 'None')
    if state.ui.mood=='Custom' then uiState.setMoodDirection(state.ui,playerInputSettings:get('customMood') or '') end
end
local function send(name,payload) if core and core.sendGlobalEvent then core.sendGlobalEvent(name,payload) end end
local CAPABILITIES={'dialogue.text','speech.say','speech.listen','action.ai.follow','action.ai.stop',
    'action.ai.approach','action.ai.wait','action.ai.travel','action.ai.escort','action.ai.face','action.ai.wander',
    'action.combat.start','action.combat.stop','action.inspect.report','action.inventory.inspect',
    'action.animation.play','action.item.equip','action.item.unequip','action.item.use',
    'action.confirmation','action.result-followup'}

local function conversationContext(target)
    local started=core and core.getRealTime and core.getRealTime() or nil
    local snapshot=adapter.playerContext(target)
    local activities={}
    for _,status in pairs(actorActivities) do activities[#activities+1]=status end
    table.sort(activities,function(left,right) return identity.key(left.actor)<identity.key(right.actor) end)
    while #activities>12 do table.remove(activities) end
    snapshot.actorActivities=activities
    if started and core and core.getRealTime then
        local elapsed=math.max(0,(core.getRealTime()-started)*1000)
        contextCollectionSamples[#contextCollectionSamples+1]=elapsed
        while #contextCollectionSamples>64 do table.remove(contextCollectionSamples,1) end
        local sorted={}
        local total=0
        for index,value in ipairs(contextCollectionSamples) do sorted[index]=value total=total+value end
        table.sort(sorted)
        snapshot.collectionTiming={latestMs=elapsed,averageMs=total/#sorted,
            p99Ms=sorted[math.max(1,math.ceil(#sorted*0.99))],samples=#sorted}
    end
    return snapshot
end

local function voicePayload(uiSource)
    local snapshot=conversationContext(state.ui.target);snapshot.dialogueMode=state.ui.mode
    return {speaker=adapter.identity(self),target=state.ui.target,context=snapshot,language='en-US',capabilities=CAPABILITIES,
        recent_action_results={},ui_source=uiSource,dialogueMode=state.ui.mode,mood=uiState.moodSelection(state.ui),
        vad_sensitivity=tonumber(behaviorSettings and behaviorSettings:get('openMicSensitivity')) or 700,
        end_delay_ms=tonumber(behaviorSettings and behaviorSettings:get('openMicEndDelayMs')) or 900,
        recording_device=math.floor(tonumber(behaviorSettings and behaviorSettings:get('recordingDevice')) or -1)}
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
local function nativeValue(name,fallback)
    if not nativeOk or not native or type(native[name])~='function' then return fallback end
    local ok,value=pcall(native[name])
    return ok and value~=nil and value~='' and value or fallback
end
local function serverUiUrl()
    local base=nativeValue('serverBaseUrl',nil)
    if type(base)~='string' then return 'Unavailable (check LORKHAN client configuration)' end
    local root=base:gsub('/api/v1/?$','')
    return root..'/ui/home.php'
end
local function reportNarrator(status,reason)
    local command=narratorSpeech
    if not command then return end
    narratorSpeech=nil
    send('LORKHAN_SPEECH_STATUS',{actor=command.actor,media_id=command.media_id,active=false,status=status,reason=reason})
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

local function dialogueMenuOpen()
    if not interfacesOk or not interfaces or not interfaces.UI or not interfaces.UI.getMode then return nil end
    local ok,mode=pcall(interfaces.UI.getMode)
    if not ok then return nil end
    return mode=='Dialogue'
end

-- Stop only the regular-menu speech lane so a newly selected response replaces it immediately.
local function stopMenuDialogueSpeech()
    local current=menuDialogueSpeech
    if current then
        local active=current.sentences and current.sentences[current.index]
        if active and active.dispatched then
            send('LORKHAN_MENU_DIALOGUE_STOP',{actor=current.actor,request_id=active.request_id,
                media_id=active.media_id})
        end
        if nativeOk and native and native.cancelMenuDialogueTts then
            for _,sentence in ipairs(current.sentences or {}) do
                if sentence.request_id then pcall(native.cancelMenuDialogueTts,sentence.request_id) end
            end
        end
    end
    menuDialogueSpeech=nil
end

-- Submit one sentence at a time so its media download enters the FIFO bridge before later synthesis work.
local function submitMenuDialogueSentence(current,sentence)
    local request,reason=native.requestMenuDialogueTts(current.actor,sentence.text)
    if request then sentence.request_id=request;sentence.state='requesting'
    else sentence.state='failed';sentence.reason=reason or 'request_unavailable' end
end

local function startMenuDialogueSpeech(response)
    stopMenuDialogueSpeech()
    if not response or not ({greeting=true,persuasion=true,topic=true})[response.dialogue_type] then return end
    local enabled=not soundSettings or soundSettings:get('menuDialogueTts')~=false
    if not enabled or not nativeOk or not native or not native.requestMenuDialogueTts then return end
    local queued={}
    for _,text in ipairs(support.splitSentences(response.text,8)) do
        queued[#queued+1]={text=text,state='pending'}
    end
    if #queued>0 then
        menuDialogueSpeech={actor=response.actor,sentences=queued,index=1,
            dialogueSeenOpen=dialogueMenuOpen()==true}
        submitMenuDialogueSentence(menuDialogueSpeech,queued[1])
    end
end

-- Persist vanilla ambient and menu speech as bounded CHIM-style conversation history.
local function captureVanillaDialogue(response)
    if not response or not ({voice=true,greeting=true,persuasion=true,topic=true})[response.dialogue_type] then return end
    local listener=adapter.identity(self)
    if not listener then return end
    local source=response.dialogue_type=='voice' and 'background' or 'menu'
    local now=core and core.getRealTime and core.getRealTime() or 0
    local signature=table.concat({source,identity.key(response.actor),response.info_id or '',response.text},'|')
    local previous=capturedDialogueSeen[signature]
    if previous and now-previous<2 then return end
    capturedDialogueSeen[signature]=now
    local audience,seen={},{}
    seen[identity.key(response.actor)]=true
    seen[identity.key(listener)]=true
    for _,candidate in ipairs(adapter.nearbyActors(2048)) do
        local actor=candidate.identity
        local key=actor and identity.key(actor) or nil
        if key and not seen[key] then
            seen[key]=true audience[#audience+1]=actor
            if #audience>=12 then break end
        end
    end
    local payload,reason=protocol.capturedDialogue({source=source,speaker=response.actor,listener=listener,
        audience=audience,text=response.text,topic=response.record_id or '',game_time=response.captured_game_time})
    if not payload then print('[LORKHAN] vanilla dialogue capture rejected: '..tostring(reason)) return end
    local request,submitReason
    if nativeOk and native and native.submitCapturedDialogue then
        request,submitReason=native.submitCapturedDialogue(payload)
    else submitReason='bridge_not_ready' end
    if request then return end
    if #pendingCapturedDialogue>=32 then table.remove(pendingCapturedDialogue,1) end
    pendingCapturedDialogue[#pendingCapturedDialogue+1]={payload=payload,attempts=0}
    if submitReason~='bridge_not_ready' then
        print('[LORKHAN] vanilla dialogue capture queued: '..tostring(submitReason))
    end
end

local function flushCapturedDialogue(dt)
    local now=core and core.getRealTime and core.getRealTime() or 0
    for signature,capturedAt in pairs(capturedDialogueSeen) do
        if now-capturedAt>=2 then capturedDialogueSeen[signature]=nil end
    end
    if #pendingCapturedDialogue==0 then return end
    capturedDialogueFlushElapsed=capturedDialogueFlushElapsed+(tonumber(dt) or 0)
    if capturedDialogueFlushElapsed<0.1 then return end
    capturedDialogueFlushElapsed=0
    local item=pendingCapturedDialogue[1]
    local request,reason
    if nativeOk and native and native.submitCapturedDialogue then
        request,reason=native.submitCapturedDialogue(item.payload)
    else reason='bridge_not_ready' end
    if request then table.remove(pendingCapturedDialogue,1) return end
    item.attempts=item.attempts+1
    if item.attempts>=20 and reason~='bridge_not_ready' then
        print('[LORKHAN] vanilla dialogue capture failed: '..tostring(reason))
        table.remove(pendingCapturedDialogue,1)
    end
end

local function updateMenuDialogueSpeech()
    if not menuDialogueSpeech then return end
    local menuOpen=dialogueMenuOpen()
    if menuOpen==true then menuDialogueSpeech.dialogueSeenOpen=true
    elseif menuOpen==false and menuDialogueSpeech.dialogueSeenOpen then stopMenuDialogueSpeech() return end
    if soundSettings and soundSettings:get('menuDialogueTts')==false then stopMenuDialogueSpeech() return end
    if not nativeOk or not native or not native.menuDialogueTtsStatus then stopMenuDialogueSpeech() return end
    for _,sentence in ipairs(menuDialogueSpeech.sentences) do
        if sentence.state=='requesting' or sentence.state=='preparing' then
            local status=native.menuDialogueTtsStatus(sentence.request_id)
            if not status then sentence.state='failed';sentence.reason='request_unavailable'
            elseif status.state=='failed' then sentence.state='failed';sentence.reason=status.reason or 'unavailable'
            else sentence.state=status.state;sentence.media_id=status.media_id or sentence.media_id end
        end
    end
    for index=1,#menuDialogueSpeech.sentences-1 do
        local sentence=menuDialogueSpeech.sentences[index]
        local following=menuDialogueSpeech.sentences[index+1]
        if following.state=='pending' and (sentence.state=='preparing' or sentence.state=='ready'
            or sentence.state=='failed' or sentence.dispatched) then
            submitMenuDialogueSentence(menuDialogueSpeech,following)
            break
        end
    end
    local sentence=menuDialogueSpeech.sentences[menuDialogueSpeech.index]
    while sentence and sentence.state=='failed' do
        print('[LORKHAN] menu dialogue TTS failed: '..tostring(sentence.reason))
        if sentence.request_id then pcall(native.cancelMenuDialogueTts,sentence.request_id) end
        menuDialogueSpeech.index=menuDialogueSpeech.index+1
        sentence=menuDialogueSpeech.sentences[menuDialogueSpeech.index]
    end
    if not sentence then menuDialogueSpeech=nil return end
    if sentence.state=='ready' and not sentence.dispatched then
        local volume=tonumber(soundSettings and soundSettings:get('ttsVolumeBoost')) or 3
        sentence.dispatched=true
        send('LORKHAN_MENU_DIALOGUE_SPEAK',{actor=menuDialogueSpeech.actor,request_id=sentence.request_id,
            media_id=sentence.media_id,volume_boost=volume})
    end
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
    local parsed,parseReason=playerInput.parse(state.ui.input)
    if not parsed then
        state.ui.status='message required'
        print('[LORKHAN] text submit rejected: '..tostring(parseReason))
        render()
        return false
    end
    if not state.ui.target then
        pendingTextSubmit=true
        state.ui.status='finding actor target'
        print('[LORKHAN] text submit waiting for actor target')
        if not chooseTarget(2048) then pendingTextSubmit=false end
        render()
        return false
    end
    local speaker=adapter.identity(self)
    local context=conversationContext(state.ui.target)
    local effectiveMode=parsed.mode or state.ui.mode
    context.dialogueMode=effectiveMode
    send('LORKHAN_SUBMIT_TEXT',{text=parsed.text,language='en-US',speaker=speaker,dialogueMode=effectiveMode,
        mood=uiState.moodSelection(state.ui),
        context=context,capabilities=CAPABILITIES,
        recent_action_results={},ui_source='lorkhan_text'})
    pendingHistory={speaker=speaker,text=parsed.text}
    awaitingTextQueue=true
    state.ui.status='submitting'
    pendingTextSubmit=false
    print('[LORKHAN] text message submitted for '..displayName(state.ui.target))
    render()
    return true
end

-- One in-flight controls request at a time already, so a single flag is enough to know whether the
-- pause-safe pump has anything to settle.
local function noteControlsRequest(request,error)
    if request then controlsRequestActive=true end
    return request,error
end

local function sessionControls()
    if not nativeOk or not native or not native.sessionControls then return nil end
    local ok,value=pcall(native.sessionControls)
    return ok and value or nil
end

local function refreshSessionControls(panel,quiet)
    if not state.ui.target then state.ui.status='actor target required' render() return end
    if not nativeOk or not native or not native.requestSessionControls then
        if not quiet then state.ui.status='session controls unavailable' render() end
        return
    end
    local request,error=noteControlsRequest(native.requestSessionControls(state.ui.target))
    if not quiet then
        if not request then state.ui.status=tostring(error or 'session controls unavailable') else state.ui.status='loading controls' end
        if panel then state.ui.panel=panel end
        render()
    end
end

-- The controls snapshot only describes the actor it was requested for, so every panel that reads it
-- confirms the target first instead of presenting another NPC's choices.
local function targetedControls()
    local controls=sessionControls()
    if controls and state.ui.target and identity.same(controls.target,state.ui.target) then return controls end
    return nil
end

local function selectSessionControl(kind,selection)
    if not state.ui.target or not nativeOk or not native or not native.selectSessionControl then
        state.ui.status='session controls unavailable' render() return
    end
    local request,error=noteControlsRequest(native.selectSessionControl(kind,selection,state.ui.target))
    state.ui.status=request and 'control update queued' or tostring(error or 'control update failed')
    render()
end

-- One semantic model slot write, and only from a player click. The clicked slot stays marked until
-- the next controls snapshot settles, so a duplicate click cannot queue a second write.
local function selectModelSlot(key)
    if uiState.modelSlotBusy(state.ui) then return end
    if not state.ui.target or not nativeOk or not native or not native.selectSessionControl then
        state.ui.status='session controls unavailable' render() return
    end
    local request,error=noteControlsRequest(native.selectSessionControl('model_slot',key,state.ui.target))
    if request then
        uiState.beginModelSlot(state.ui,key)
        state.ui.status='selecting '..key..' model'
    else
        state.ui.status=tostring(error or 'model slot update failed')
    end
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
    local request,error=noteControlsRequest(native.selectSessionControl('profile_generate',controls.selected_profile_id,state.ui.target))
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
    local request,error=noteControlsRequest(native.selectSessionControl('narrator_profile_generate',controls.narrator_profile_id,state.ui.target))
    state.ui.status=request and 'narrator generation queued' or tostring(error or 'narrator generation failed')
    render()
end

local function setMode(mode)
    for _,candidate in ipairs(MODES) do
        if candidate==mode then
            state.ui.mode=mode
            state.ui.status='mode: '..mode
            send('LORKHAN_MODE_CHANGED',{mode=mode})
            render()
            return true
        end
    end
    return false
end

-- Mood is player-side presentation reused by typed and spoken input. It never changes the saved mode.
local function setMood(mood)
    if not uiState.setMood(state.ui,mood) then return false end
    if playerInputSettings then
        playerInputSettings:set('mood',state.ui.mood)
        playerInputSettings:set('customMood',state.ui.moodDirection)
    end
    state.ui.status='mood: '..uiState.moodLabel(state.ui)
    render()
    return true
end

-- Panels the Interact menu opens for the aimed actor still need a resolved target, exactly as the
-- legacy hotkeys did through openPanel.
local TARGETED_PANELS={models=true,profiles=true,['profile-menu']=true}
local function openFromConversation(panel)
    if TARGETED_PANELS[panel] and not state.ui.target then chooseTarget(2048,true) end
    uiState.setPanel(state.ui,panel,'conversation')
end

-- One status HUD toggle shared by the legacy hotkey and the Interact entry, so the saved setting,
-- the HUD strip, and the menu label can never disagree.
local function toggleStatusHud()
    state.ui.statusHudVisible=not state.ui.statusHudVisible
    if presentationSettings then presentationSettings:set('showStatusHud',state.ui.statusHudVisible) end
    state.ui.status='status HUD '..(state.ui.statusHudVisible and 'on' or 'off')
    render()
    return state.ui.statusHudVisible
end

-- One back row for every panel that Interact and Targeted NPC Tools both reach, so the label and
-- the destination always describe the menu the player actually came from.
local function backRow()
    local route=uiState.backRoute(state.ui)
    return {type=openmwUi.TYPE.Text,props={text=route.label,textSize=16,
        textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function()
            state.ui.panel=route.panel render()
        end)}}
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
    local actionsEnabled=agentSettings and agentSettings:get('actionsEnabled')
    if actionsEnabled==nil and behaviorSettings then actionsEnabled=behaviorSettings:get('actionsEnabled') end
    if actionsEnabled==false then
        state.ui.status='actions disabled in settings' render() return
    end
    if not state.ui.target then state.ui.status='actor target required' render() return end
    local request={name=name,tier=tier,parameters=parameters}
    if actionTarget then request.target=actionTarget end
    send('LORKHAN_SUBMIT_TEXT',{text=label,language='en-US',speaker=adapter.identity(self),
        context=actionContext(actionTarget),capabilities=CAPABILITIES,
        recent_action_results={},ui_source='lorkhan_action_menu',action_request=request})
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
    state.ui.status='aim at the action target, then use Targeted NPC Tools again'
    leaveUiMode()
    render()
end

local function beginDestinationTarget(label,name,tier)
    state.ui.pendingTargetAction={kind='destination',label=label,name=name,tier=tier,actor=state.ui.target}
    state.ui.visible=false
    state.ui.status='aim at a nearby destination, then use Targeted NPC Tools again'
    leaveUiMode()
    render()
end

local function renderStatusHud()
    -- The top-left HUD is strictly opt-in: with the Status HUD toggle off nothing is drawn here.
    if state.ui.visible or not uiOk or not utilOk or not state.ui.statusHudVisible then
        if statusElement then statusElement:destroy() statusElement=nil end
        return
    end
    local text='LORKHAN  |  Connection: '..tostring(nativeValue('status','unavailable'))..
        '  |  Request: '..(turnActive and 'active' or 'idle')..
        '  |  Speech: '..(speechActive() and 'speaking' or 'idle')..
        '  |  Target: '..actorLabel(state.ui.target)..'  |  '..state.ui.mode
    local width=520
    local height=42
    local layout={layer='HUD',type=openmwUi.TYPE.Container,
        props={position=util.vector2(26,24),size=util.vector2(width,height)},content=openmwUi.content({
            {type=openmwUi.TYPE.Text,props={text=text,
                size=util.vector2(width,height),wordWrap=false,
                textSize=15,textColor=util.color.rgb(1.0,0.58,0.18)}}
        })}
    if statusElement then statusElement.layout=layout statusElement:update()
    else statusElement=openmwUi.create(layout) end
end
render=function()
    renderStatusHud()
    if not state.ui.visible or not uiOk or not utilOk then
        if element then element:destroy() element=nil end
        return
    end
    local transcript={}
    if state.ui.panel=='conversation' then
        uiState.refreshTurnPreview(state.ui)
        transcript=chatbox.build({ui=openmwUi,util=util,whiteTexture=whiteTexture,text=state.ui.input,
            target=displayName(state.ui.target),
            mood=uiState.moodSummary(state.ui),mode=state.ui.mode,shortcuts=uiState.SHORTCUTS,
            turnMode=state.ui.turnMode,turnPrefix=state.ui.turnPrefix,
            onTextChanged=adapter.callback(function(value)
                state.ui.input=player.consumeTextEdit(value)
                -- Redraw only when the previewed one-turn mode actually changes so typing stays uninterrupted.
                if uiState.shortcutPreview(state.ui.input)~=state.ui.turnMode then render() end
            end),
            onKeyPress=adapter.callback(function(event)
                if inputOk and event and event.code==input.KEY.Escape then
                    pendingTextSubmit=false state.ui.visible=false leaveUiMode() render()
                end
            end),
            statusHudVisible=state.ui.statusHudVisible,
            onSelectMood=adapter.callback(function() openFromConversation('moods') render() end),
            onSelectModes=adapter.callback(function() openFromConversation('modes') render() end),
            onSelectModel=adapter.callback(function()
                openFromConversation('models') refreshSessionControls('models')
            end),
            onSelectProfiles=adapter.callback(function() openFromConversation('profile-menu') render() end),
            onSelectHistory=adapter.callback(function() openFromConversation('history') render() end),
            onToggleStatusHud=adapter.callback(toggleStatusHud),
            onSelectDiagnostics=adapter.callback(function() openFromConversation('diagnostics') render() end),
            onSend=adapter.callback(submitText),
            onClose=adapter.callback(function() pendingTextSubmit=false state.ui.visible=false leaveUiMode() render() end)})
    elseif state.ui.panel=='nearby-profiles' then
        local exterior=self.cell and self.cell.isExterior==true
        local distance=autoSettings and autoSettings:get(exterior and 'exteriorDistance' or 'interiorDistance')
            or (exterior and 2400 or 1200)
        local nearby=adapter.nearbyActors(tonumber(distance) or (exterior and 2400 or 1200))
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Nearby AI NPC Profiles',textSize=20,
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
                    send('LORKHAN_SELECT_TARGET',{candidate=candidate}) state.ui.panel='conversation' render()
                end)}}
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Add '..label..' to group',textSize=14,
                textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function()
                    send('LORKHAN_ADD_AUDIENCE',{candidate=candidate})
                end)}}
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Manage profile for '..label,textSize=14,
                textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function()
                    pendingControlPanel='profiles'
                    state.ui.status='loading profile for '..displayName(candidate.identity)
                    send('LORKHAN_SELECT_TARGET',{candidate=candidate}) render()
                end)}}
        end
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Pin bounded nearby group',textSize=16,
            textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=adapter.callback(function()
                while #nearby>12 do table.remove(nearby) end
                send('LORKHAN_MANUAL_ACTIVATE_NEARBY_REQUEST',{candidates=nearby})
            end)}}
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Dynamic Profiles',textSize=16,
            textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function()
                state.ui.panel='profile-menu' render()
            end)}}
    elseif state.ui.panel=='history' then
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Context History',textSize=20,
            textColor=util.color.rgb(0.95,0.9,0.82)}}
        if #state.ui.transcript==0 then
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='No LORKHAN dialogue in this session yet.',
                textSize=16,textColor=util.color.rgb(0.72,0.68,0.62)}}
        end
        local pageSize=5
        local pages=math.max(1,math.ceil(#state.ui.transcript/pageSize))
        state.ui.historyPage=math.max(1,math.min(state.ui.historyPage or 1,pages))
        local newest=#state.ui.transcript-(state.ui.historyPage-1)*pageSize
        for index=newest,math.max(1,newest-pageSize+1),-1 do
            local line=state.ui.transcript[index]
            local order=line.sequence and ('#'..tostring(line.sequence)) or ('local '..tostring(index))
            local timestamp=tostring(line.createdAt or line.terminalCreatedAt or 'time pending')
            local request=line.requestId and line.requestId:sub(1,8) or 'pending'
            local metadata=order..'  |  '..timestamp..'  |  '..tostring(line.status or 'unknown')..'  |  request '..request
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=metadata,textSize=13,
                textColor=util.color.rgb(0.72,0.68,0.62)}}
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=displayName(line.speaker)..': '..line.text,
                textSize=16,wordWrap=true,textColor=util.color.rgb(0.92,0.82,0.68)}}
        end
        if pages>1 then
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Newer',textSize=15,
                textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=adapter.callback(function()
                    state.ui.historyPage=math.max(1,state.ui.historyPage-1) render()
                end)}}
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Older',textSize=15,
                textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=adapter.callback(function()
                    state.ui.historyPage=math.min(pages,state.ui.historyPage+1) render()
                end)}}
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Page '..state.ui.historyPage..' / '..pages,
                textSize=13,textColor=util.color.rgb(0.72,0.68,0.62)}}
        end
        transcript[#transcript+1]=backRow()
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Close',textSize=16,
            textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function()
                state.ui.visible=false leaveUiMode() render()
            end)}}
    elseif state.ui.panel=='diagnostics' then
        local session=nativeValue('sessionInfo',nil)
        local bridge=nativeValue('diagnostics',nil)
        local rows={
            'Runtime status: '..tostring(state.ui.status),
            'Server connection: '..tostring(nativeValue('status','unavailable')),
            'Server URL: '..serverUiUrl(),
            'Session ID: '..tostring(session and session.session_id or 'unavailable'),
            'Generation: '..tostring(session and session.generation or nativeValue('generation','unavailable')),
            'Target: '..displayName(state.ui.target),
            'Conversation group: '..audienceNames(),
            'Managed agents: '..tostring(#state.ui.agents),
            'Turn active: '..tostring(turnActive),
            'Voice recording: '..tostring(voiceRecording),
            'Open microphone: '..tostring(openMicEnabled),
            'Open microphone muted: '..tostring(openMicMuted),
            'Generated speech: '..tostring(speechActive()),
            'Nearby combat: '..tostring(nearbyCombat),
            'Bridge queue: '..tostring(bridge and bridge.outbound or 'unavailable')..' outbound / '..
                tostring(bridge and bridge.inbound or 'unavailable')..' inbound',
            'Response queue: '..tostring(responseQueueSnapshot.pending_dialogue or 0)..' dialogue / '..
                tostring(responseQueueSnapshot.pending_actions or 0)..' actions; unfinished='..
                tostring(responseQueueSnapshot.unfinished==true),
            'Response dispatch: '..tostring(responseQueueSnapshot.dispatched or 0)..' dispatched / '..
                tostring(responseQueueSnapshot.completed or 0)..' completed / '..
                tostring(responseQueueSnapshot.cancelled or 0)..' cancelled',
            'Response drops: '..tostring(responseQueueSnapshot.stale_drops or 0)..' stale / '..
                tostring(responseQueueSnapshot.deduplicated or 0)..' duplicate',
            'Active response: '..tostring(responseQueueSnapshot.active_response_id or 'none')..' line='..
                tostring(responseQueueSnapshot.active_line_id or 'none'),
            'Last bridge error: '..tostring(nativeValue('lastError','none')),
        }
        local selectedDeviceId=math.floor(tonumber(behaviorSettings and behaviorSettings:get('recordingDevice')) or -1)
        local selectedDeviceName='Unavailable'
        if nativeOk and native.currentVoiceCaptureDeviceName then
            local called,name=pcall(native.currentVoiceCaptureDeviceName,selectedDeviceId)
            if called and type(name)=='string' then selectedDeviceName=name end
        end
        rows[#rows+1]='Selected recording device: '..tostring(selectedDeviceId)..' - '..selectedDeviceName
        if nativeOk and native.voiceCaptureDevices then
            local called,devices=pcall(native.voiceCaptureDevices)
            if called and type(devices)=='table' then
                for _,device in ipairs(devices) do
                    rows[#rows+1]='Recording device '..tostring(device.id)..': '..tostring(device.name)
                end
            end
        end
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
        local ids=state.ui.lastCorrelation or {}
        local copyText='message_id='..tostring(ids.messageId or 'unavailable')..'  request_id='..
            tostring(ids.requestId or 'unavailable')..'  turn_id='..tostring(ids.turnId or 'unavailable')
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Correlation IDs (click, select, Ctrl+C)',textSize=14,
            textColor=util.color.rgb(0.72,0.68,0.62)}}
        transcript[#transcript+1]={type=openmwUi.TYPE.TextEdit,props={text=copyText,textSize=14,
            size=util.vector2(720,52),multiline=true,wordWrap=true,readOnly=true,autoSize=false,
            textColor=util.color.rgb(0.92,0.82,0.68)}}
        transcript[#transcript+1]=backRow()
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
            option('Check inventory','inventory.inspect',0,{})
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
            option('Come closer','ai.approach',1,{})
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
            option('Wait here','ai.wait',1,{duration_seconds=3600})
            option('Wander nearby','ai.wander',1,{distance=512,duration_seconds=3600})
            option('Stop LORKHAN movement','ai.stop',1,{})
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
        link('Targeted NPC Tools',function() uiState.setPanel(state.ui,'actor-tools','actor-tools') render() end)
        link('Close',function() state.ui.visible=false leaveUiMode() render() end)
    elseif state.ui.panel=='actor-tools' then
        transcript=actorTools.build({ui=openmwUi,util=util,target=displayName(state.ui.target),options={
            {label='Activate or deactivate aimed NPC',onSelect=adapter.callback(manualActivate)},
            {label='Add aimed NPC to conversation',onSelect=adapter.callback(function()
                send('LORKHAN_AUDIENCE_REQUEST',{maxDistance=2048})
                state.ui.status='adding aimed NPC to conversation' render()
            end)},
            {label='Dynamic profiles...',onSelect=adapter.callback(function()
                uiState.setPanel(state.ui,'profile-menu','actor-tools') render()
            end)},
            {label='Actor actions...',onSelect=adapter.callback(function()
                state.ui.panel='actions' state.ui.actionView='root' state.ui.actionPage=1 render()
            end)},
            {label='Stop current dialogue',onSelect=adapter.callback(function()
                send('LORKHAN_STOP_DIALOGUE_REQUEST',{}) state.ui.status='dialogue stopped' render()
            end)},
            {label='Halt actor actions',danger=true,onSelect=adapter.callback(function()
                send('LORKHAN_HALT_ACTIONS_REQUEST',{}) state.ui.status='actions halted' render()
            end)},
        },onClose=adapter.callback(function() state.ui.visible=false leaveUiMode() render() end)})
    elseif state.ui.panel=='profile-menu' then
        transcript=selector.build({ui=openmwUi,util=util,title='Dynamic Profiles',options={
            {label='Targeted NPC',onSelect=adapter.callback(function() refreshSessionControls('profiles') end)},
            {label='Nearby AI NPCs',onSelect=adapter.callback(function() state.ui.panel='nearby-profiles' render() end)},
            {label='Narrator',onSelect=adapter.callback(function() refreshSessionControls('narrator') end)},
        },onBack=adapter.callback(function() state.ui.panel=uiState.backRoute(state.ui).panel render() end),
        onClose=adapter.callback(function() state.ui.visible=false leaveUiMode() render() end)})
    elseif state.ui.panel=='models' then
        -- Four semantic slots, one state line, and no connector enumeration. The panel is read-only
        -- until the player clicks a slot, so opening it never writes a selection.
        local controls=targetedControls()
        uiState.settleModelSlot(state.ui,controls)
        local select={}
        for _,slot in ipairs(uiState.MODEL_SLOTS) do
            select[slot.key]=adapter.callback(function() selectModelSlot(slot.key) end)
        end
        transcript=selector.buildModelSlots({ui=openmwUi,util=util,select=select,
            view=uiState.modelSlotView(controls,state.ui.modelSlotPending),
            onRefresh=adapter.callback(function() refreshSessionControls('models') end),
            backLabel=uiState.backRoute(state.ui).label,
            onBack=adapter.callback(function()
                state.ui.panel=uiState.backRoute(state.ui).panel render()
            end)})
    elseif state.ui.panel=='profiles' or state.ui.panel=='narrator' then
        local controls=sessionControls()
        local narratorPanel=state.ui.panel=='narrator'
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=narratorPanel and 'Narrator Profile' or 'NPC Roleplay Profile',textSize=20,
            textColor=util.color.rgb(0.95,0.9,0.82)}}
        if not controls or not identity.same(controls.target,state.ui.target) then
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Loading server-owned choices...',textSize=16,
                textColor=util.color.rgb(0.72,0.68,0.62)}}
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
        transcript[#transcript+1]=backRow()
    elseif state.ui.panel=='moods' then
        local moods={}
        for _,mood in ipairs(uiState.MOODS) do
            moods[#moods+1]={label=mood,active=mood==state.ui.mood,
                onSelect=adapter.callback(function() setMood(mood) end)}
        end
        transcript=chatbox.buildMoodPanel({ui=openmwUi,util=util,whiteTexture=whiteTexture,moods=moods,
            customVisible=state.ui.mood=='Custom',customText=state.ui.moodDirection,
            customLimit=uiState.MOOD_DIRECTION_LIMIT,
            onCustomChanged=adapter.callback(function(value)
                uiState.setMoodDirection(state.ui,value)
                if playerInputSettings then playerInputSettings:set('customMood',state.ui.moodDirection) end
            end),
            onCustomKeyPress=adapter.callback(function(event)
                if inputOk and event and event.code==input.KEY.Escape then
                    state.ui.panel='conversation' render()
                end
            end),
            onBack=adapter.callback(function() state.ui.panel='conversation' render() end),
            onClose=adapter.callback(function() state.ui.visible=false leaveUiMode() render() end)})
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
        for _,row in ipairs(chatbox.buildShortcutHelp({ui=openmwUi,util=util,shortcuts=uiState.SHORTCUTS})) do
            transcript[#transcript+1]=row
        end
        transcript[#transcript+1]=backRow()
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Close',textSize=16,
            textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function()
                state.ui.visible=false leaveUiMode() render()
            end)}}
    end
    if state.ui.pendingAction then
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Confirm action: '..
            (state.ui.pendingAction.display_name or state.ui.pendingAction.name),textSize=17,
            textColor=util.color.rgb(1.0,0.72,0.2)}}
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Approve',textSize=16,textColor=util.color.rgb(0.45,0.9,0.45)},
            events={mouseClick=adapter.callback(function()
                send('LORKHAN_CONFIRM_ACTION',{action_id=state.ui.pendingAction.action_id,approved=true})
                state.ui.pendingAction=nil render()
            end)}}
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Reject',textSize=16,textColor=util.color.rgb(1.0,0.45,0.35)},
            events={mouseClick=adapter.callback(function()
                send('LORKHAN_CONFIRM_ACTION',{action_id=state.ui.pendingAction.action_id,approved=false})
                state.ui.pendingAction=nil render()
            end)}}
    end
    local panelSizes={conversation={560,400},['actor-tools']={540,360},['profile-menu']={520,300},
        modes={540,480},moods={520,470},models={580,420},profiles={580,420},narrator={580,330},
        ['nearby-profiles']={680,460},history={760,620},diagnostics={760,620}}
    local panelSize=panelSizes[state.ui.panel] or {680,460}
    local contentWidth=panelSize[1]-20
    local contentHeight=panelSize[2]-20
    local layout={layer='Windows',type=openmwUi.TYPE.Container,
        props={position=util.vector2(30,60),size=util.vector2(panelSize[1],panelSize[2])},content=openmwUi.content({
            {type=openmwUi.TYPE.Flex,props={horizontal=false,size=util.vector2(contentWidth,contentHeight)},content=openmwUi.content({
                {type=openmwUi.TYPE.Text,props={text='LORKHAN  |  '..state.ui.status,textSize=16,
                    textColor=util.color.rgb(1.0,0.45,0.08)}},
                unpackValues(transcript),
            })},
        })}
    if element then element.layout=layout element:update()
    else element=openmwUi.create(layout) end
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
        print('[LORKHAN] local target candidate: '..displayName(candidate.identity)..' via '..tostring(reason))
        send('LORKHAN_SELECT_TARGET',{candidate=candidate})
    else
        state.ui.diagnostics=reason
        state.ui.status='selecting nearest active actor'
        print('[LORKHAN] local target search failed: '..tostring(reason)..'; requesting global fallback')
        send('LORKHAN_SELECT_NEAREST_TARGET',{maxDistance=maxDistance,local_reason=reason})
    end
    if not deferRender then render() end
    return true
end

-- Owns the press/release transition shared by OpenMW's semantic action and the configured-key fallback.
local function handlePushToTalk(held,source)
    held=held==true
    if held==pttHeld then return end
    if held then
        if not controlsAllowed() and not ownsUiMode then
            print('[LORKHAN] push-to-talk blocked by another UI mode via '..tostring(source))
            return
        end
        if not state.ui.target then
            print('[LORKHAN] push-to-talk needs a target; starting target selection via '..tostring(source))
            chooseTarget(2048)
            return
        end
        pttHeld=true
        if openMicEnabled then
            openMicEnabled=false;openMicMuted=false
            send('LORKHAN_OPEN_MIC_STOP',{})
        end
        voiceRecording=true
        print('[LORKHAN] push-to-talk pressed; requesting voice capture via '..tostring(source))
        send('LORKHAN_VOICE_START',voicePayload('lorkhan_voice'))
    else
        pttHeld=false
        if voiceRecording then
            voiceRecording=false
            print('[LORKHAN] push-to-talk released; stopping voice capture via '..tostring(source))
            send('LORKHAN_VOICE_STOP',{})
        end
    end
    render()
end

local function chooseAudience(maxDistance)
    local candidate=aimCandidate
    local reason=candidate and 'live_aim_preview' or nil
    if not candidate then candidate,reason=adapter.resolveCameraTarget(maxDistance or 2048) end
    if candidate then send('LORKHAN_ADD_AUDIENCE',{candidate=candidate})
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
        print('[LORKHAN] text chat overlay opened')
    else
        pendingTextSubmit=false
        leaveUiMode()
        render()
        print('[LORKHAN] text chat overlay closed')
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
    local binding=inputBindings:get('LORKHAN_Talk_Binding')
    return binding and binding.device=='keyboard' and binding.type=='trigger'
        and binding.key=='LORKHAN_Talk' and binding.button==event.code
end

local function isConfiguredPushToTalkKey(event)
    if not event or not inputBindings then return false end
    local binding=inputBindings:get('LORKHAN_PushToTalk_Binding')
    return binding and binding.device=='keyboard' and binding.type=='action'
        and binding.key=='LORKHAN_PushToTalk' and binding.button==event.code
end

local function openPanel(panel)
    if not controlsAllowed() and not ownsUiMode then return end
    -- Saved hotkeys still open these panels directly, so they keep the Targeted NPC Tools back route.
    uiState.setPanel(state.ui,panel,'actor-tools') state.ui.visible=true
    if panel=='actions' then state.ui.actionView='root' state.ui.actionPage=1 end
    if (panel=='actions' or panel=='conversation' or panel=='actor-tools' or panel=='models'
        or panel=='profiles' or panel=='profile-menu') and not state.ui.target then chooseTarget(2048) end
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
    if not controlsAllowed() and not ownsUiMode then return end
    local candidate,reason=adapter.resolveCameraTarget(2048)
    if candidate then send('LORKHAN_MANUAL_ACTIVATE_REQUEST',{candidate=candidate})
    else
        local exterior=self.cell and self.cell.isExterior==true
        local distance=autoSettings and autoSettings:get(exterior and 'exteriorDistance' or 'interiorDistance')
            or (exterior and 2400 or 1200)
        local candidates=adapter.nearbyActors(tonumber(distance) or (exterior and 2400 or 1200))
        while #candidates>12 do table.remove(candidates) end
        if #candidates>0 then
            send('LORKHAN_MANUAL_ACTIVATE_NEARBY_REQUEST',{candidates=candidates})
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
            state.ui.status='destination unavailable; aim nearby and use Targeted NPC Tools again'
            state.ui.diagnostics=reason
            render()
            return true
        end
        submitActionRequest(pending.label,pending.name,pending.tier,destination)
        return true
    end
    local candidate,reason=adapter.resolveCameraTarget(2048)
    if not candidate then
        state.ui.status='action target unavailable; aim and use Targeted NPC Tools again'
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

applySettings=function(session,controls)
    local exterior=self.cell and self.cell.isExterior==true
    local effective=controls and state.ui.target and identity.same(controls.target,state.ui.target)
        and controls.effective_settings or nil
    local targetSettings=effective and effective.settings or {}
    local legacyHearing=autoSettings and autoSettings:get('hearingDistance')
    local interiorHearing=autoSettings and autoSettings:get('interiorHearingDistance') or legacyHearing or 500
    local exteriorHearing=autoSettings and autoSettings:get('exteriorHearingDistance') or legacyHearing or 1000
    local actionsEnabled=agentSettings and agentSettings:get('actionsEnabled')
    if actionsEnabled==nil and behaviorSettings then actionsEnabled=behaviorSettings:get('actionsEnabled') end
    if actionsEnabled==nil then actionsEnabled=true end
    local ttsVolumeBoost=soundSettings and soundSettings:get('ttsVolumeBoost')
    if ttsVolumeBoost==nil and presentationSettings then ttsVolumeBoost=presentationSettings:get('ttsVolumeBoost') end
    local current={
        autoActivate={enabled=autoSettings and autoSettings:get('enabled'),
            interiorDistance=autoSettings and autoSettings:get('interiorDistance'),
            exteriorDistance=autoSettings and autoSettings:get('exteriorDistance'),
            hearingDistance=exterior and exteriorHearing or interiorHearing,
            interiorHearingDistance=interiorHearing,
            exteriorHearingDistance=exteriorHearing,
            addHostile=autoSettings and autoSettings:get('addHostile'),
            addCreatures=autoSettings and autoSettings:get('addCreatures')},
        behavior={actionsEnabled=actionsEnabled,
            cancelDialogueOnCombat=behaviorSettings and behaviorSettings:get('cancelDialogueOnCombat')},
        presentation={showStatusHud=presentationSettings and presentationSettings:get('showStatusHud')==true,
            transcriptRows=tonumber(presentationSettings and presentationSettings:get('transcriptRows')) or 12,
            ttsVolumeBoost=tonumber(ttsVolumeBoost) or 3},
    }
    player.applyTargetSettings(current,targetSettings)
    local auto=current.autoActivate or {}
    local behavior=current.behavior or {}
    local presentation=current.presentation or {}
    local signature=table.concat({tostring(auto.enabled),tostring(auto.interiorDistance),tostring(auto.exteriorDistance),
        tostring(auto.hearingDistance),tostring(auto.interiorHearingDistance),tostring(auto.exteriorHearingDistance),
        tostring(auto.addHostile),tostring(auto.addCreatures),tostring(behavior.actionsEnabled),
        tostring(behavior.cancelDialogueOnCombat),tostring(behavior.rechat),tostring(behavior.rechatMaxDepth),
        tostring(behavior.rechatProbabilityPercent),tostring(behavior.rechatMode),tostring(behavior.rechatStrictTargeting),
        tostring(behavior.openRechat),tostring(behavior.endConversationCooldownSeconds),
        tostring(presentation.showStatusHud),tostring(presentation.transcriptRows),
        tostring(presentation.ttsVolumeBoost),tostring(effective and effective.change_token),tostring(session and session.config_revision)},'|')
    if signature==settingsSignature then return end
    settingsSignature=signature
    state.ui.statusHudVisible=presentation.showStatusHud==true
    state.ui.policy.transcriptRows=presentation.transcriptRows or 12
    send('LORKHAN_SETTINGS_UPDATE',current)
    render()
end

if inputOk then
    input.registerTriggerHandler('LORKHAN_Talk',adapter.callback(requestTalkToggle))
    input.registerTriggerHandler('LORKHAN_StopDialogue',adapter.callback(function()
        send('LORKHAN_STOP_DIALOGUE_REQUEST',{}) state.ui.status='dialogue stopped' render()
    end))
    input.registerTriggerHandler('LORKHAN_Halt',adapter.callback(function()
        state.ui.pendingTargetAction=nil
        player.onAction(state,'LORKHAN_Halt',send) state.ui.status='stopped' render()
    end))
    input.registerTriggerHandler('LORKHAN_ManualActivate',adapter.callback(manualActivate))
    input.registerTriggerHandler('LORKHAN_ActionsMenu',adapter.callback(function()
        if not confirmSecondaryTarget() then togglePanel('actor-tools') end
    end))
    input.registerTriggerHandler('LORKHAN_MasterMenu',adapter.callback(function() togglePanel('actor-tools') end))
    input.registerTriggerHandler('LORKHAN_ToggleMode',adapter.callback(function() togglePanel('modes') end))
    input.registerTriggerHandler('LORKHAN_ModelMenu',adapter.callback(function()
        openPanel('models') refreshSessionControls('models')
    end))
    input.registerTriggerHandler('LORKHAN_ProfileMenu',adapter.callback(function() togglePanel('profile-menu') end))
    input.registerTriggerHandler('LORKHAN_StatusHud',adapter.callback(function()
        if not controlsAllowed() then return end
        toggleStatusHud()
    end))
    input.registerTriggerHandler('LORKHAN_History',adapter.callback(function() togglePanel('history') end))
    input.registerTriggerHandler('LORKHAN_Diagnostics',adapter.callback(function() togglePanel('diagnostics') end))
    input.registerActionHandler('LORKHAN_PushToTalk',adapter.callback(function(value)
        handlePushToTalk(value==true,'action_handler')
    end))
    input.registerTriggerHandler('LORKHAN_OpenMic',adapter.callback(function()
        if not controlsAllowed() then return end
        if not openMicEnabled and not state.ui.target then chooseTarget(2048) return end
        openMicEnabled=not openMicEnabled;openMicMuted=false;voiceRecording=openMicEnabled
        send(openMicEnabled and 'LORKHAN_OPEN_MIC_START' or 'LORKHAN_OPEN_MIC_STOP',openMicEnabled and voicePayload('lorkhan_open_mic') or {})
        state.ui.status=openMicEnabled and 'open mic listening' or 'open mic off';render()
    end))
    input.registerTriggerHandler('LORKHAN_OpenMicMute',adapter.callback(function()
        if not controlsAllowed() then return end
        if not openMicEnabled then state.ui.status='open mic is off';render();return end
        openMicMuted=not openMicMuted;voiceRecording=not openMicMuted
        send(openMicMuted and 'LORKHAN_OPEN_MIC_MUTE' or 'LORKHAN_OPEN_MIC_START',openMicMuted and {} or voicePayload('lorkhan_open_mic'))
        state.ui.status=openMicMuted and 'open mic muted' or 'open mic listening';render()
    end))
end

return {
    engineHandlers={
        onInputAction=function(action) return player.onAction(state,action,send) end,
        onKeyPress=function(event)
            if inputOk and state.ui.visible and state.ui.panel=='conversation' and event
                and (event.code==input.KEY.Enter or event.code==input.KEY.NP_Enter) then
                print('[LORKHAN] text chat Enter accepted by engine fallback')
                submitText()
                return
            end
            if inputOk and isConfiguredPushToTalkKey(event) then
                handlePushToTalk(true,'configured_key')
                return
            end
            if inputOk and isConfiguredTalkKey(event) then requestTalkToggle() end
        end,
        onKeyRelease=function(event)
            if inputOk and isConfiguredPushToTalkKey(event) then
                handlePushToTalk(false,'configured_key')
            end
        end,
        -- The Interact overlay owns Interface UI mode and pauses simulation, so onUpdate stops running
        -- while a server-owned control panel is open. onFrame still runs every frame, so it does one
        -- bounded pause-safe pump of the in-flight controls response and nothing else. No gameplay,
        -- settings scan, or event processing belongs here.
        onFrame=function()
            if not controlsRequestActive or not state.ui.visible
                or not SERVER_CONTROL_PANELS[state.ui.panel] then return end
            if not nativeOk or not native or not native.pumpSessionControls then
                controlsRequestActive=false return
            end
            local ok,status=pcall(native.pumpSessionControls)
            if not ok or type(status)~='table' then controlsRequestActive=false return end
            if status.pending==true then return end
            controlsRequestActive=false
            if status.error then state.ui.status=tostring(status.error) end
            -- Rerendering is what settles the panel: the models branch feeds the returned snapshot to
            -- uiState.settleModelSlot, which clears the pending mark and shows the selected slot.
            render()
        end,
        onUpdate=function(dt)
            if narratorSpeech and not adapter.isSpeechActive() then reportNarrator('played','playback_completed') end
            updateMenuDialogueSpeech()
            flushCapturedDialogue(dt)
            local elapsed=tonumber(dt) or 0
            settingsRefreshElapsed=settingsRefreshElapsed+elapsed
            if settingsRefreshElapsed>=SETTINGS_REFRESH_INTERVAL then
                settingsRefreshElapsed=0
                local session=nativeOk and native.sessionInfo and native.sessionInfo() or nil
                local controls=sessionControls()
                applySettings(session,controls)
                local signature=controls and table.concat({tostring(controls.selected_model_slot_key),
                    tostring(controls.resolved_model_slot_key),tostring(controls.selected_profile_id),
                    tostring(controls.effective_settings and controls.effective_settings.change_token),
                    tostring(#(controls.model_slots or {})),tostring(#(controls.profiles or {})),tostring(controls.pending)},'|') or ''
                if signature~=controlsSignature then controlsSignature=signature
                    if state.ui.visible and (state.ui.panel=='models' or state.ui.panel=='profiles') then render() end end
            end
            aimScanElapsed=aimScanElapsed+elapsed
            if aimScanElapsed>=AIM_SCAN_INTERVAL and not state.ui.visible and controlsAllowed() then
                aimScanElapsed=0
                local candidate=adapter.resolveActorRay(2048)
                local signature=candidate and identity.key(candidate.identity) or ''
                if signature~=aimSignature then
                    aimCandidate=candidate aimSignature=signature render()
                elseif candidate then aimCandidate=candidate end
            end
            autoScanElapsed=autoScanElapsed+elapsed
            if autoScanElapsed>=AUTO_SCAN_INTERVAL then
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
                send('LORKHAN_AUTO_ACTIVATE_SCAN',{candidates=candidates})
            end
        end,
    },
    eventHandlers={
        DialogueResponse=function(event)
            local response=adapter.dialogueResponse(event)
            if response then
                send('LORKHAN_VANILLA_DIALOGUE',response)
                captureVanillaDialogue(response)
                startMenuDialogueSpeech(response)
            end
        end,
        LORKHAN_MENU_DIALOGUE_SPEECH_STATUS=function(event)
            if not menuDialogueSpeech or not event then return end
            local sentence=menuDialogueSpeech.sentences[menuDialogueSpeech.index]
            if not sentence or event.request_id~=sentence.request_id then return end
            if event.active==true then return end
            if event.status=='failed' then
                print('[LORKHAN] menu dialogue playback failed: '..tostring(event.reason or 'playback_failed'))
            end
            if nativeOk and native and native.cancelMenuDialogueTts then
                pcall(native.cancelMenuDialogueTts,sentence.request_id)
            end
            menuDialogueSpeech.index=menuDialogueSpeech.index+1
            updateMenuDialogueSpeech()
        end,
        LORKHAN_NARRATOR_SPEAK=function(command)
            stopNarrator('speech_replaced')
            local ok,reason=adapter.playSpeech(command.media_id,command.subtitle,command.tts_volume_boost)
            if ok then narratorSpeech=command
                send('LORKHAN_SPEECH_STATUS',{actor=command.actor,media_id=command.media_id,active=true,status='playing'})
            else narratorSpeech=command reportNarrator('failed',reason or 'playback_failed') end
        end,
        LORKHAN_NARRATOR_SUBTITLE=function(command)
            stopNarrator('subtitle_replaced') narratorSpeech=command
            local ok,reason=adapter.showSubtitle(command.subtitle)
            reportNarrator(ok and 'played' or 'failed',ok and 'subtitle_displayed' or (reason or 'subtitle_unavailable'))
        end,
        LORKHAN_NARRATOR_STOP=function(event) stopNarrator(event and event.reason or 'client_interrupted') end,
        LORKHAN_STATUS=function(event) state.ui.status=event.status state.ui.diagnostics=event.reason render() end,
        LORKHAN_VOICE_STATUS=function(event)
            state.ui.status=event.status;state.ui.diagnostics=event.reason
            if event.status=='failed' or event.status=='queued' then voiceRecording=false end
            if event.status=='open mic off' or event.status=='failed' and event.continuous then openMicEnabled=false;openMicMuted=false end
            render()
        end,
        LORKHAN_OPEN_MIC_CONTEXT_REQUEST=function()
            if openMicEnabled and not openMicMuted and state.ui.target then send('LORKHAN_OPEN_MIC_CONTEXT',voicePayload('lorkhan_open_mic')) end
        end,
        LORKHAN_TURN=function(event)
            if not awaitingTextQueue then return end
            awaitingTextQueue=false
            if event.status=='queued' then
                if pendingHistory then player.queued(state,pendingHistory.speaker,pendingHistory.text,event) end
                pendingHistory=nil
                state.ui.input=''
                state.ui.status='queued'
                state.ui.visible=false
                turnActive=true
                leaveUiMode()
                print('[LORKHAN] text message accepted; chat closed')
            else
                state.ui.status='message failed: '..tostring(event.reason or 'unknown')
                turnActive=false
                pendingHistory=nil
                print('[LORKHAN] text message rejected: '..tostring(event.reason or 'unknown'))
            end
            render()
        end,
        LORKHAN_PLAYER_RESOLVE_TARGET=function(event) chooseTarget(event.maxDistance) end,
        LORKHAN_PLAYER_RESOLVE_AUDIENCE=function(event) chooseAudience(event.maxDistance) end,
        LORKHAN_TARGET=function(event)
            state.ui.target=event.target state.ui.audience=event.audience or {event.target}
            state.ui.status='target: '..displayName(event.target)
            print('[LORKHAN] player target confirmed: '..displayName(event.target))
            local shouldSubmit=pendingTextSubmit and state.ui.visible and state.ui.panel=='conversation'
            local controlPanel=pendingControlPanel
            pendingTextSubmit=false
            pendingControlPanel=nil
            if controlPanel then refreshSessionControls(controlPanel)
            else
                refreshSessionControls(nil,true)
                if shouldSubmit then submitText() else render() end
            end
        end,
        LORKHAN_TARGET_REJECTED=function(event)
            pendingTextSubmit=false
            pendingControlPanel=nil
            state.ui.status='target unavailable: '..tostring(event and event.reason or 'unknown')
            render()
        end,
        LORKHAN_AUDIENCE=function(event) state.ui.target=event.target state.ui.audience=event.audience or {} render() end,
        LORKHAN_AGENTS=function(event) state.ui.agents=event.agents or {} render() end,
        LORKHAN_COMBAT_STATUS=function(event)
            local started=event.active==true and not nearbyCombat
            nearbyCombat=event.active==true
            if started and (not behaviorSettings or behaviorSettings:get('cancelDialogueOnCombat')~=false)
                and (turnActive or voiceRecording or openMicEnabled or speechActive()) then
                send('LORKHAN_STOP_DIALOGUE_REQUEST',{})
                voiceRecording=false;openMicEnabled=false;openMicMuted=false;pttHeld=false;turnActive=false
                speechActors={}
                state.ui.status='dialogue stopped for combat'
                render()
            end
        end,
        LORKHAN_ACTOR_ACTIVITY=function(event)
            if event and event.reset==true then actorActivities={} return end
            local key=event and event.actor and identity.key(event.actor)
            if key then
                if event.activity=='inactive' then actorActivities[key]=nil
                else actorActivities[key]={actor=event.actor,activity=event.activity,target=event.target} end
                if state.ui.visible and (state.ui.panel=='nearby-profiles' or state.ui.panel=='actor-tools') then render() end
            end
        end,
        LORKHAN_SPEECH_STATUS=function(event)
            local key=event.actor and identity.key(event.actor)
            if key then
                if event.active==true then speechActors[key]=true else speechActors[key]=nil end
                render()
            end
        end,
        LORKHAN_QUEUE=function(event)
            responseQueueSnapshot=event or {}
            if state.ui.visible and state.ui.panel=='diagnostics' then render() end
        end,
        LORKHAN_ACTIVATION_STATUS=function(event)
            state.ui.status=event.status=='nearby' and ('nearby agents pinned: '..tostring(event.added or 0))
                or event.status=='deactivated' and 'manual agent unpinned'
                or event.actor and ('manual agent '..tostring(event.status)) or 'manual activation failed'
            state.ui.diagnostics=event.actor and nil or event.status
            render()
        end,
        LORKHAN_BOOK_READ=function(event)
            if adapter.rememberBook(event) then
                state.ui.status='book remembered: '..tostring(event.title or event.record_id)
                render()
            end
        end,
        LORKHAN_ACTION_CONFIRMATION=function(event)
            state.ui.pendingAction=event state.ui.panel='actions' state.ui.actionView='root'
            state.ui.visible=true enterUiMode() render()
        end,
        LORKHAN_ACTION_STATUS=function(event)
            state.ui.status='action '..tostring(event.name or '')..' '..tostring(event.status or 'unknown')
            state.ui.diagnostics=event.submitted and event.reason or event.submit_reason
            render()
        end,
        LORKHAN_EVENT=function(event)
            if event.type=='turn.accepted' then turnActive=true end
            if event.type=='turn.complete' or event.type=='turn.failed' or event.type=='turn.cancelled' then
                turnActive=false
            end
            player.event(state,event) render()
        end,
    },
}
