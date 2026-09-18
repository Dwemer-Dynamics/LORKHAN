local adapter=require('scripts.LORKHAN.adapters.openmw')
local identity=require('scripts.LORKHAN.identity')
local player=require('scripts.LORKHAN.player_state')
local protocol=require('scripts.LORKHAN.protocol')
local playerInput=require('scripts.LORKHAN.player_input')
local chatbox=require('scripts.LORKHAN.ui.chatbox')
local uiState=require('scripts.LORKHAN.ui.state')
local selector=require('scripts.LORKHAN.ui.selector')
local actorTools=require('scripts.LORKHAN.ui.actor_tools')
local settingsMenu=require('scripts.LORKHAN.ui.settings')
local support=require('scripts.LORKHAN.util')
local core=adapter.event()
local inputOk,input=pcall(require,'openmw.input')
local uiOk,openmwUi=pcall(require,'openmw.ui')
local utilOk,util=pcall(require,'openmw.util')
local self=require('openmw.self')
local interfacesOk,interfaces=pcall(require,'openmw.interfaces')
local storageOk,openmwStorage=pcall(require,'openmw.storage')
local nativeOk,native=pcall(require,'openmw.lorkhan')
local debugOk,debugApi=pcall(require,'openmw.debug')
local state=player.new()
local element
local statusElement
local voiceRecording=false
local pttHeld=false
local openMicEnabled=false
local openMicMuted=false
local openMicControl={suspended=false,retryAt=0}
local settingsSignature
local autoScanElapsed=0
local turnActive=false
local nearbyCombat=false
local actorActivities={}
local contextCollectionSamples={}
local speechActors={}
local narratorSpeech
local menuDialogueSpeech
local playerSpeech
local bookSpeech
local pendingAutochat
local pendingCapturedDialogue={}
local capturedDialogueSeen={}
local capturedDialogueFlushElapsed=0
local pendingActorProfiles={}
local pendingActorProfileKeys={}
local actorProfileFlushElapsed=0
local pendingAutomaticDiaries={}
local automaticDiaryFlushElapsed=0
local automaticDiaryTimerElapsed=0
local restDiaryState
local observedPlayerLevel,observedRpgSession
local ownsUiMode=false
local controlsSignature
local responseQueueSnapshot={}
local MODES=uiState.MODES
local EQUIPMENT_SLOTS={'helmet','cuirass','greaves','left_pauldron','right_pauldron','left_gauntlet',
    'right_gauntlet','boots','shirt','pants','skirt','robe','left_ring','right_ring','amulet','belt',
    'carried_right','carried_left','ammunition'}
local autoSettings=storageOk and openmwStorage.playerSection('SettingsLORKHANAutoActivate') or nil
local hearingSettings=storageOk and openmwStorage.playerSection('SettingsLORKHANHearing') or nil
local behaviorSettings=storageOk and openmwStorage.playerSection('SettingsLORKHANBehavior') or nil
local soundSettings=storageOk and openmwStorage.playerSection('SettingsLORKHANSound') or nil
local agentSettings=storageOk and openmwStorage.playerSection('SettingsLORKHANAgents') or nil
local presentationSettings=storageOk and openmwStorage.playerSection('SettingsLORKHANPresentation') or nil
local playerInputSettings=storageOk and openmwStorage.playerSection('SettingsLORKHANPlayerInput') or nil
local narratorEventStorage=storageOk and openmwStorage.playerSection('LORKHANNarratorEvents') or nil
local inputBindings=storageOk and openmwStorage.playerSection('OMWInputBindings') or nil
local unpackValues=table.unpack or unpack
local whiteTexture=uiOk and openmwUi.texture and openmwUi.texture({path='white'}) or nil
local lastTalkToggleAt=-1
local pendingTextSubmit=false
local awaitingTextQueue=false
local pendingHistory
local pendingDirectorInput
local pendingControlPanel
-- Panels whose contents are owned by the server, so an in-flight controls request has to settle
-- before they can show the player anything new.
local SERVER_CONTROL_PANELS={models=true,profiles=true,narrator=true,settings=true}
local settingScope,settingField,settingValue,settingToken,settingTarget
local settingPage=1
local settingsControls={}
local aiEnabled=true
local pendingAiToggle=false
local controlsRequestActive=false
local debugRequestActive=false
local nextDebugPollAt=0
local pendingGlobalDebugCommand
local aimCandidate
local aimScanElapsed=0
local aimSignature=''
local settingsRefreshElapsed=0.5
local journalScanElapsed=0
local currentNarratorSettings={}
local SETTINGS_REFRESH_INTERVAL=0.5
local AIM_SCAN_INTERVAL=0.25
local AUTO_SCAN_INTERVAL=1.0
local AUTOMATIC_DIARY_POLL_INTERVAL=30
local DEBUG_POLL_INTERVAL=0.25
local GLOBAL_DEBUG_COMMANDS={
    ['npc.status']=true,['npc.visit']=true,['npc.teleport']=true,['npc.return']=true,
    ['player.inventory.add']=true,['player.inventory.remove']=true,
    ['player.spell.add']=true,['player.spell.remove']=true,['player.vitals.restore']=true,
    ['player.stat.set']=true,['player.attribute.set']=true,['player.skill.set']=true,
    ['player.level.set']=true,['player.bounty.set']=true,['player.teleport']=true,['player.scale.set']=true,
    ['world.time.advance']=true,['world.timescale.set']=true,['world.weather.set']=true,
    ['target.actor.kill']=true,['target.actor.restore']=true,['target.teleport.to_player']=true,['target.scale.set']=true,
}
if playerInputSettings then
    uiState.setMood(state.ui,playerInputSettings:get('mood') or 'None')
    if state.ui.mood=='Custom' then uiState.setMoodDirection(state.ui,playerInputSettings:get('customMood') or '') end
end
state.ui.autoChat=playerInputSettings and playerInputSettings:get('autoChat')==true or false
local function send(name,payload) if core and core.sendGlobalEvent then core.sendGlobalEvent(name,payload) end end
local CAPABILITIES={'dialogue.text','speech.say','speech.listen','relationship.disposition','action.ai.follow','action.ai.stop','action.conversation.end',
    'action.ai.approach','action.ai.wait','action.ai.travel','action.ai.escort','action.ai.face','action.ai.wander',
    'action.combat.start','action.combat.stop','action.weapon.sheathe','action.inspect.report','action.inventory.inspect',
    'action.animation.play','action.item.equip','action.item.unequip','action.item.use',
    'action.item.give','action.item.take','action.item.pickup','action.gold.give','action.gold.take',
    'action.service.barter','action.service.training','action.service.spells','action.service.travel',
    'action.service.spellmaking','action.service.enchanting','action.service.repair',
    'action.spell.cast','action.item.create','action.gold.create','action.actor.spawn',
    'action.actor.teleport_to_player','action.player.teleport','action.actor.restore',
    'action.actor.resurrect','action.actor.kill',
    'action.confirmation','action.result-followup'}

local function conversationContext(target,executionMode)
    local started=core and core.getRealTime and core.getRealTime() or nil
    local snapshot=adapter.playerContext(target,nil,(executionMode or state.ui.executionMode)=='narrator')
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
        execution_mode=(uiSource=='lorkhan_open_mic' and (state.ui.executionMode=='injection_log' or state.ui.executionMode=='injection_chat'))
            and 'standard' or state.ui.executionMode,selectedTargetPresent=true,selectedTarget=state.ui.target,
        vad_sensitivity=tonumber(behaviorSettings and behaviorSettings:get('openMicSensitivity')) or 1000,
        end_delay_ms=tonumber(behaviorSettings and behaviorSettings:get('openMicEndDelayMs')) or 1000,
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
local function speechActive() return next(speechActors)~=nil or playerSpeech~=nil or bookSpeech~=nil end

local function narratorCooldownReady(key,minutes)
    local now=adapter.gameTime()
    local previous=narratorEventStorage and tonumber(narratorEventStorage:get(key)) or nil
    if not now or not previous then return true end
    return now<previous or now-previous>=math.max(1,tonumber(minutes) or 1)*60
end

local function markNarratorEvent(key)
    local now=adapter.gameTime()
    if narratorEventStorage and now then narratorEventStorage:set(key,now) end
end

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

-- Keep typed player speech asynchronous so submitting a turn never waits for synthesis or playback.
local function stopPlayerSpeech(continueAfter)
    local current=playerSpeech
    if not current then return end
    if current.state=='playing' then adapter.stopSpeech() end
    if current.request_id and nativeOk and native and native.cancelMenuDialogueTts then
        pcall(native.cancelMenuDialogueTts,current.request_id)
    end
    playerSpeech=nil
    if continueAfter and current.onComplete then current.onComplete() end
end

local function startPlayerSpeech(actor,text,onComplete)
    stopPlayerSpeech()
    stopNarrator('player_speech_started')
    if not nativeOk or not native or not native.requestMenuDialogueTts then return false end
    local request,reason=native.requestMenuDialogueTts(actor,text)
    -- Carry the already-validated typed text so playback shows the player's own subtitle.
    if request then playerSpeech={request_id=request,state='requesting',subtitle=type(text)=='string' and text or '',
        onComplete=onComplete};return true
    elseif reason~='provider_unavailable' then print('[LORKHAN] player TTS rejected: '..tostring(reason)) end
    return false
end

local function updatePlayerSpeech()
    local current=playerSpeech
    if not current then return end
    if current.state=='playing' then
        if not adapter.isSpeechActive() then stopPlayerSpeech(true) end
        return
    end
    if not nativeOk or not native or not native.menuDialogueTtsStatus then stopPlayerSpeech(true) return end
    local status=native.menuDialogueTtsStatus(current.request_id)
    if not status then stopPlayerSpeech(true) return end
    if status.state=='failed' then
        if status.reason~='provider_unavailable' then
            print('[LORKHAN] player TTS failed: '..tostring(status.reason or 'unavailable'))
        end
        stopPlayerSpeech(true)
        return
    end
    current.state=status.state
    if status.state=='ready' and status.media_id then
        local volume=tonumber(soundSettings and soundSettings:get('ttsVolumeBoost')) or 3
        local ok,reason=adapter.playSpeech(status.media_id,current.subtitle or '',volume)
        if ok then current.state='playing'
        else print('[LORKHAN] player TTS playback failed: '..tostring(reason or 'playback_failed'));stopPlayerSpeech(true) end
    end
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

local function stopBookSpeech()
    if not bookSpeech then return end
    if bookSpeech.playing then adapter.stopSpeech() end
    for _,sentence in ipairs(bookSpeech.sentences) do
        if sentence.request_id and nativeOk and native.cancelMenuDialogueTts then pcall(native.cancelMenuDialogueTts,sentence.request_id) end
    end
    bookSpeech=nil
end

-- Reading stays in its own local speech lane and never turns book prose into player/NPC dialogue.
local function startBookSpeech(event)
    stopBookSpeech()
    if not soundSettings or soundSettings:get('bookReadAloud')~=true or not nativeOk or not native.requestBookReadAloud then return end
    local text=tostring(event.text or ''):gsub('<[^>]*>',' '):gsub('&nbsp;',' '):gsub('&quot;','"')
        :gsub('&apos;',"'"):gsub('&lt;','<'):gsub('&gt;','>'):gsub('&amp;','&')
    local sentences={}
    for _,chunk in ipairs(support.speechChunks(text,240)) do sentences[#sentences+1]={text=chunk} end
    if #sentences==0 then return end
    stopPlayerSpeech() stopNarrator('book_reading_started') stopMenuDialogueSpeech()
    bookSpeech={book_id=event.record_id,title=event.title or '',sentences=sentences,index=1,seenOpen=false,
        session=native.sessionInfo(),
        started=core and core.getRealTime and core.getRealTime() or 0}
end

local function updateBookSpeech()
    local current=bookSpeech
    if not current then return end
    local session=native.sessionInfo()
    if not session or not current.session or session.session_id~=current.session.session_id
        or session.generation~=current.session.generation then stopBookSpeech() return end
    local mode=interfacesOk and interfaces.UI and interfaces.UI.getMode and interfaces.UI.getMode()
    if mode=='Book' or mode=='Scroll' then current.seenOpen=true
    elseif current.seenOpen or (core and core.getRealTime and core.getRealTime()-current.started>1) then stopBookSpeech() return end
    if soundSettings and soundSettings:get('bookReadAloud')~=true then stopBookSpeech() return end
    if current.playing and not adapter.isSpeechActive() then
        local previous=current.sentences[current.index]
        pcall(native.cancelMenuDialogueTts,previous.request_id)
        current.index=current.index+1 current.playing=false
    end
    local sentence=current.sentences[current.index]
    if not sentence then stopBookSpeech() return end
    -- Prefetch only the next sentence once this one has media, so the first sentence wins the FIFO.
    for index=current.index,math.min(current.index+1,#current.sentences) do
        local item=current.sentences[index]
        if not item.request_id and (index==current.index or current.playing) then
            local request,reason=native.requestBookReadAloud(current.book_id,current.title,item.text)
            if not request then state.ui.status='Book voice unavailable: '..tostring(reason) stopBookSpeech() return end
            item.request_id=request
        end
    end
    if current.playing then return end
    local status=native.menuDialogueTtsStatus(sentence.request_id)
    if not status or status.state=='failed' then
        state.ui.status='Book voice unavailable: '..tostring(status and status.reason or 'request expired')
        stopBookSpeech() return
    end
    if status.state=='ready' and status.media_id then
        local volume=tonumber(soundSettings and soundSettings:get('ttsVolumeBoost')) or 3
        local ok,reason=adapter.playSpeech(status.media_id,sentence.text,volume)
        if ok then current.playing=true else state.ui.status=tostring(reason) stopBookSpeech() end
    end
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

-- Queue one newly auto-managed NPC until the authenticated native bridge can persist its profile.
local function submitAutoActorProfile(event)
    if not aiEnabled then return end
    local actor=type(event)=='table' and event.actor or nil
    local key=actor and identity.key(actor) or nil
    if not key or pendingActorProfileKeys[key] then return end
    local snapshot,reason=adapter.actorProfile(actor)
    if not snapshot then
        print('[LORKHAN] auto-activated profile snapshot unavailable: '..tostring(reason))
        return
    end
    local payload
    payload,reason=protocol.actorProfile(snapshot)
    if not payload then
        print('[LORKHAN] auto-activated profile rejected: '..tostring(reason))
        return
    end
    local request,submitReason
    if nativeOk and native and native.submitActorProfile then
        request,submitReason=native.submitActorProfile(payload)
    else submitReason='bridge_not_ready' end
    if request then return end
    if #pendingActorProfiles>=32 then
        pendingActorProfileKeys[pendingActorProfiles[1].key]=nil
        table.remove(pendingActorProfiles,1)
    end
    pendingActorProfileKeys[key]=true
    pendingActorProfiles[#pendingActorProfiles+1]={key=key,payload=payload,attempts=0}
    if submitReason~='bridge_not_ready' then
        print('[LORKHAN] auto-activated profile queued: '..tostring(submitReason))
    end
end

local function flushActorProfiles(dt)
    if not aiEnabled then pendingActorProfiles={} pendingActorProfileKeys={} return end
    if #pendingActorProfiles==0 then return end
    actorProfileFlushElapsed=actorProfileFlushElapsed+(tonumber(dt) or 0)
    if actorProfileFlushElapsed<0.1 then return end
    actorProfileFlushElapsed=0
    local item=pendingActorProfiles[1]
    local request,reason
    if nativeOk and native and native.submitActorProfile then
        request,reason=native.submitActorProfile(item.payload)
    else reason='bridge_not_ready' end
    if request then
        pendingActorProfileKeys[item.key]=nil
        table.remove(pendingActorProfiles,1)
        return
    end
    item.attempts=item.attempts+1
    if item.attempts>=20 and reason~='bridge_not_ready' then
        print('[LORKHAN] auto-activated profile failed: '..tostring(reason))
        pendingActorProfileKeys[item.key]=nil
        table.remove(pendingActorProfiles,1)
    end
end

-- Persist the observation and freeze the eligible responder before the server makes its profile policy decision.
local function submitRpgEvent(kind,text)
    if not aiEnabled then return end
    if not nativeOk or not native.submitRpgEvent or not native.sessionInfo then return end
    local session=native.sessionInfo()
    if not session then return end
    local responder=state.ui.target
    local distance=responder and adapter.actorDistance(responder)
    if turnActive or nearbyCombat or speechActive() or state.ui.visible or not distance or distance>2048 then responder=nil end
    local payload=protocol.rpgEvent({kind=kind,player=adapter.identity(self),game_time=adapter.gameTime(),text=text,responder=responder})
    if not payload then return end
    local request,reason=native.submitRpgEvent(payload)
    if request and responder then
        player.rememberRpgComment(state,request,responder,session,core.getRealTime())
    elseif not request then print('[LORKHAN] RPG event not queued: '..tostring(reason)) end
end

-- Freeze the NPC and actual journal update while the server evaluates its Core quest policy.
local function submitQuestEvent(entries,session)
    if not nativeOk or not native.submitQuestEvent or not session then return end
    local responder=state.ui.target
    local distance=responder and adapter.actorDistance(responder)
    if turnActive or nearbyCombat or speechActive() or state.ui.visible or not distance or distance>2048 then return end
    local payload=protocol.questEvent({entries=entries,responder=responder,game_time=adapter.gameTime()})
    if not payload then return end
    local request=native.submitQuestEvent(payload)
    if request then player.rememberRpgComment(state,request,responder,session,core.getRealTime()) end
end

local function submitAutomaticDiary(trigger)
    if not aiEnabled then return end
    if not nativeOk or not native or type(native.sessionInfo)~='function' or not native.sessionInfo() then return end
    local gameTime=adapter.gameTime()
    if type(gameTime)~='number' then return end
    local actors={}
    for _,candidate in ipairs(adapter.nearbyActors(2048)) do
        if candidate.identity then actors[#actors+1]=candidate.identity end
        if #actors>=12 then break end
    end
    local payload,reason=protocol.automaticDiary({trigger=trigger,game_time=gameTime,actors=actors})
    if not payload then print('[LORKHAN] automatic diary rejected: '..tostring(reason)) return end
    local request,submitReason
    if nativeOk and native and native.submitAutomaticDiary then
        request,submitReason=native.submitAutomaticDiary(payload)
    else submitReason='bridge_not_ready' end
    if request then return end
    if #pendingAutomaticDiaries>=8 then table.remove(pendingAutomaticDiaries,1) end
    pendingAutomaticDiaries[#pendingAutomaticDiaries+1]={payload=payload,attempts=0}
    if submitReason~='bridge_not_ready' then print('[LORKHAN] automatic diary queued: '..tostring(submitReason)) end
end

local function flushAutomaticDiaries(dt)
    if not aiEnabled then pendingAutomaticDiaries={} return end
    if #pendingAutomaticDiaries==0 then return end
    automaticDiaryFlushElapsed=automaticDiaryFlushElapsed+(tonumber(dt) or 0)
    if automaticDiaryFlushElapsed<0.25 then return end
    automaticDiaryFlushElapsed=0
    local item=pendingAutomaticDiaries[1]
    local request,reason
    if nativeOk and native and native.submitAutomaticDiary then
        request,reason=native.submitAutomaticDiary(item.payload)
    else reason='bridge_not_ready' end
    if request then table.remove(pendingAutomaticDiaries,1) return end
    item.attempts=item.attempts+1
    if item.attempts>=20 and reason~='bridge_not_ready' then
        print('[LORKHAN] automatic diary failed: '..tostring(reason))
        table.remove(pendingAutomaticDiaries,1)
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

local function queueTypedTurn(args,speechAlreadyPlayed)
    if args.execution_mode=='director' then pendingDirectorInput={text=args.text} end
    if not speechAlreadyPlayed and args.execution_mode~='director' and args.execution_mode~='cheat'
        and args.execution_mode~='injection_log' and args.execution_mode~='injection_chat' then
        startPlayerSpeech(args.speaker,args.text)
    end
    send('LORKHAN_SUBMIT_TEXT',args)
    pendingHistory=(args.execution_mode~='injection_log' and args.execution_mode~='injection_chat') and {speaker=args.speaker,text=args.text} or nil
    awaitingTextQueue=true
    state.ui.status='submitting'
    print('[LORKHAN] text message submitted for '..displayName(state.ui.target))
    render()
end

-- Finish the rewrite lane before starting the normal turn so player speech cannot overlap the NPC response.
local function updatePlayerAutochat()
    local pending=pendingAutochat
    if not pending then return end
    if not nativeOk or not native or not native.playerAutochatStatus then
        pendingAutochat=nil state.ui.status='Auto Chat unavailable' render() return
    end
    local status=native.playerAutochatStatus(pending.request_id)
    if not status then pendingAutochat=nil state.ui.status='Auto Chat request lost' render() return end
    if status.state=='failed' then
        pcall(native.cancelPlayerAutochat,pending.request_id)
        pendingAutochat=nil state.ui.status='Auto Chat failed: '..tostring(status.reason or 'provider unavailable') render() return
    end
    if status.state~='ready' then return end
    pcall(native.cancelPlayerAutochat,pending.request_id)
    pendingAutochat=nil
    if not identity.same(state.ui.target,pending.target) then
        state.ui.status='Auto Chat cancelled because the target changed' render() return
    end
    pending.args.text=status.text
    local queued=false
    local function continueTurn()
        if queued then return end
        queued=true queueTypedTurn(pending.args,true)
    end
    state.ui.status='speaking rewritten player line' render()
    if not startPlayerSpeech(pending.args.speaker,status.text,continueTurn) then continueTurn() end
end

local function submitText()
    if not aiEnabled then state.ui.status='AI is off; microphone transcription remains available' render() return false end
    if pendingTextSubmit or awaitingTextQueue or pendingAutochat
        or pendingGlobalDebugCommand and pendingGlobalDebugCommand.browser_args then return false end
    local parsed,parseReason=playerInput.parse(state.ui.input)
    if not parsed then
        state.ui.status='message required'
        print('[LORKHAN] text submit rejected: '..tostring(parseReason))
        render()
        return false
    end
    local selected=uiState.turnSelection(state.ui,parsed)
    if not state.ui.target and selected.execution~='director' and selected.execution~='narrator'
        and selected.execution~='cheat' and selected.execution~='injection_log' and selected.execution~='injection_chat' then
        pendingTextSubmit=true
        state.ui.status='finding actor target'
        print('[LORKHAN] text submit waiting for actor target')
        if not chooseTarget(2048) then pendingTextSubmit=false end
        render()
        return false
    end
    local speaker=adapter.identity(self)
    local context=conversationContext(state.ui.target,selected.execution)
    local effectiveMode=selected.hearing
    context.dialogueMode=effectiveMode
    local args={text=parsed.text,input_parsed=true,language='en-US',speaker=speaker,dialogueMode=effectiveMode,
        execution_mode=selected.execution,target=state.ui.target,selectedTargetPresent=true,selectedTarget=state.ui.target,
        mood=uiState.moodSelection(state.ui),
        context=context,capabilities=CAPABILITIES,
        recent_action_results={},ui_source='lorkhan_text'}
    if selected.autoChat then
        if not nativeOk or not native or not native.requestPlayerAutochat then
            state.ui.status='Auto Chat unavailable' render() return false
        end
        local request,reason=native.requestPlayerAutochat(speaker,state.ui.target,parsed.text)
        if not request then state.ui.status='Auto Chat failed: '..tostring(reason or 'unavailable') render() return false end
        pendingAutochat={request_id=request,args=args,target=state.ui.target}
        state.ui.status='rewriting player intent'
    else queueTypedTurn(args) end
    pendingTextSubmit=false
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

local function debugSnapshot()
    return {god_mode=debugApi.isGodMode(),collision_enabled=debugApi.isCollisionEnabled(),
        ai_enabled=debugApi.isAIEnabled(),mwscript_enabled=debugApi.isMWScriptEnabled()}
end

-- Apply explicit boolean state through OpenMW's toggle-only debug primitives without accidental inversion.
local function setDebugBoolean(getter,toggle,enabled)
    local current=getter()
    if current~=enabled then toggle() end
end

local function executeDebugCommand(command)
    if not debugOk or not debugApi then return 'rejected','debug_api_unavailable',{} end
    local ok,result=pcall(function()
        local name=command.name
        local parameters=command.parameters or {}
        if name=='status.snapshot' then return debugSnapshot() end
        if name=='god_mode.set' then setDebugBoolean(debugApi.isGodMode,debugApi.toggleGodMode,parameters.enabled)
        elseif name=='collision.set' then setDebugBoolean(debugApi.isCollisionEnabled,debugApi.toggleCollision,parameters.enabled)
        elseif name=='ai.set' then setDebugBoolean(debugApi.isAIEnabled,debugApi.toggleAI,parameters.enabled)
        elseif name=='mwscript.set' then setDebugBoolean(debugApi.isMWScriptEnabled,debugApi.toggleMWScript,parameters.enabled)
        elseif name=='shader_hot_reload.set' then debugApi.setShaderHotReloadEnabled(parameters.enabled)
        elseif name=='shaders.reload' then debugApi.triggerShaderReload()
        elseif name=='render_mode.toggle' then
            local modes={collision='CollisionDebug',wireframe='Wireframe',pathgrid='Pathgrid',water='Water',scene='Scene',
                navmesh='NavMesh',actors_paths='ActorsPaths',recast_mesh='RecastMesh'}
            local mode=modes[parameters.mode]
            if not mode or not debugApi.RENDER_MODE[mode] then error('unsupported render mode') end
            debugApi.toggleRenderMode(debugApi.RENDER_MODE[mode])
        else return nil end
        local observed=debugSnapshot()
        if name=='shader_hot_reload.set' then observed.shader_hot_reload_enabled=parameters.enabled end
        if name=='shaders.reload' then observed.shaders_reload_requested=true end
        if name=='render_mode.toggle' then observed.render_mode_toggled=parameters.mode end
        return observed
    end)
    if not ok then return 'failed','execution_failed',{error=tostring(result):sub(1,256)} end
    if result==nil then return 'rejected','unknown_command',{} end
    return 'succeeded','command_applied',result
end

local function submitDebugResult(command,status,reason,observed)
    local submitted,submitReason=native.submitDebugCommandResult(command.command_id,status,reason,observed or {})
    if not submitted then print('[LORKHAN] debug command result failed: '..tostring(submitReason)) end
end

-- Poll and execute the operator queue from onFrame so debug controls remain responsive while menus pause simulation.
local function pumpDebugCommands()
    if not nativeOk or not native or not native.requestDebugCommand or not native.pumpDebugCommand
        or not native.submitDebugCommandResult then return end
    local now=core and core.getRealTime and core.getRealTime() or 0
    if pendingGlobalDebugCommand then
        if now-pendingGlobalDebugCommand.started_at>25 then
            submitDebugResult(pendingGlobalDebugCommand.command,'failed','global_command_timeout',{})
            pendingGlobalDebugCommand=nil
        end
        return
    end
    if not debugRequestActive and now>=nextDebugPollAt then
        local request=select(1,native.requestDebugCommand())
        if request then debugRequestActive=true end
        nextDebugPollAt=now+DEBUG_POLL_INTERVAL
    end
    if not debugRequestActive then return end
    local ok,status=pcall(native.pumpDebugCommand)
    if not ok or type(status)~='table' then debugRequestActive=false return end
    if status.pending==true then return end
    debugRequestActive=false
    if type(status.command)~='table' then return end
    if status.command.name=='player.dialogue.submit' then
        if awaitingTextQueue or pendingTextSubmit or pendingAutochat or voiceRecording or openMicEnabled then
            submitDebugResult(status.command,'rejected','player_input_busy',{}) return
        end
        local session=native.sessionInfo and native.sessionInfo()
        if not session then submitDebugResult(status.command,'rejected','session_unavailable',{}) return end
        local parsed,parseReason=playerInput.parse(status.command.parameters.text)
        if not parsed then submitDebugResult(status.command,'rejected',parseReason or 'message_required',{}) return end
        local candidate
        if not state.ui.target then
            candidate=select(1,adapter.resolveCameraTarget(2048))
            if not candidate then candidate=(adapter.nearbyActors(2048) or {})[1] end
        end
        local target=state.ui.target or (candidate and candidate.identity)
        local args={text=parsed.text,language=status.command.parameters.language,
            speaker=adapter.identity(self),dialogueMode=parsed.mode or state.ui.mode,mood=uiState.moodSelection(state.ui),
            context=conversationContext(target),capabilities=CAPABILITIES,recent_action_results={},
            ui_source='lorkhan_browser_speech'}
        pendingGlobalDebugCommand={command=status.command,started_at=now,browser_args=args,
            session_id=session.session_id,generation=session.generation}
        send('LORKHAN_DEBUG_COMMAND',{command=status.command,browser_args=args,candidate=candidate,
            session_id=session.session_id,generation=session.generation,deadline=now+20})
        return
    end
    if GLOBAL_DEBUG_COMMANDS[status.command.name] then
        local session=native.sessionInfo and native.sessionInfo()
        if not session then submitDebugResult(status.command,'rejected','session_unavailable',{}) return end
        pendingGlobalDebugCommand={command=status.command,started_at=now,session_id=session.session_id,generation=session.generation}
        send('LORKHAN_DEBUG_COMMAND',{command=status.command,session_id=session.session_id,generation=session.generation,deadline=now+20})
        return
    end
    local outcome,reason,observed=executeDebugCommand(status.command)
    submitDebugResult(status.command,outcome,reason,observed)
end

local function refreshSessionControls(panel,quiet)
    if settingsControls.profileUpdates then return end
    local target=panel=='settings' and (state.ui.target or adapter.identity(self)) or state.ui.target
    if not target then state.ui.status='actor target required' render() return end
    if not nativeOk or not native or not native.requestSessionControls then
        if not quiet then state.ui.status='session controls unavailable' render() end
        return
    end
    local request,error=noteControlsRequest(native.requestSessionControls(target,panel=='settings'))
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

-- Save only the field and snapshot explicitly opened by the player; never reuse a changed target.
local function saveSessionSetting(value)
    if controlsRequestActive or not settingField or not settingTarget then return end
    local target=state.ui.target or adapter.identity(self)
    if not target or not identity.same(target,settingTarget) then
        state.ui.status='Target changed. Refresh settings before saving.' render() return
    end
    value=tostring(value or '')
    if #value>512 then state.ui.status='Value must be at most 512 bytes' render() return end
    if settingField.kind=='integer' then
        local number=tonumber(value)
        if not number or number~=math.floor(number) or (settingField.minimum and number<settingField.minimum)
            or (settingField.maximum and number>settingField.maximum) then
            state.ui.status='Enter a whole number within the shown range' render() return
        end
        value=tostring(math.floor(number))
    end
    local request,error=noteControlsRequest(native.updateSessionSetting(settingScope,settingField.key,value,settingToken,settingTarget))
    if request then settingField=nil settingValue=nil settingPage=1 end
    state.ui.status=request and 'Saving setting' or tostring(error or 'Setting update failed')
    render()
end

local function selectSessionControl(kind,selection)
    if settingsControls.profileUpdates then return end
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
    if settingsControls.profileUpdates or uiState.modelSlotBusy(state.ui) then return end
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

-- Keep the simple Dynamic Profiles menu on screen while its bounded requests settle.
function settingsControls.requestProfiles(kind)
    if settingsControls.profileUpdates or controlsRequestActive then
        state.ui.status='Profile request already pending';render();return
    end
    if not nativeOk or not native or not native.requestSessionControls or not native.selectSessionControl then
        state.ui.status='Profile updates unavailable';render();return
    end
    local targets={}
    if kind=='nearby' then
        local exterior=self.cell and self.cell.isExterior==true
        local limit=tonumber(hearingSettings and hearingSettings:get(exterior and 'exteriorDistance' or 'interiorDistance')) or (exterior and 2400 or 1200)
        for _,agent in ipairs(state.ui.agents) do
            if agent.identity and agent.identity.kind=='npc' and (adapter.actorDistance(agent.identity) or math.huge)<=limit then
                targets[#targets+1]=agent.identity
            end
        end
    else
        local target=state.ui.target or (kind=='narrator' and adapter.identity(self))
        if target then targets[1]=target end
    end
    local requests=require('scripts.LORKHAN.ui.profile_requests')
    local pending,reason=requests.start(native,targets,kind=='narrator',core.getRealTime())
    settingsControls.profileUpdates=pending
    state.ui.status=pending and 'Sending profile update request...' or reason
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

local function toggleAutoChat()
    if pendingAutochat then state.ui.status='Auto Chat rewrite already in progress' render() return state.ui.autoChat end
    state.ui.autoChat=not state.ui.autoChat
    if playerInputSettings then playerInputSettings:set('autoChat',state.ui.autoChat) end
    state.ui.status='Auto Chat '..(state.ui.autoChat and 'on' or 'off')
    render()
    return state.ui.autoChat
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
    local text='LORKHAN  |  Speech: '..(speechActive() and 'speaking' or 'idle')..
        '  |  Target: '..actorLabel(state.ui.previewTarget)..'  |  '..uiState.selectedChatMode(state.ui).label
    local width=520
    local height=42
    local layout={layer='HUD',type=openmwUi.TYPE.Container,
        props={position=util.vector2(26,24),size=util.vector2(width,height)},content=openmwUi.content({
            {type=openmwUi.TYPE.Text,props={text=text,
                size=util.vector2(width,height),wordWrap=false,
                textSize=15,textColor=util.color.rgb(188/255,157/255,90/255)}}
        })}
    if statusElement then statusElement.layout=layout statusElement:update()
    else statusElement=openmwUi.create(layout) end
end
-- Isolate the server editor from the main menu renderer's LuaJIT upvalue budget.
function settingsControls.build()
        local controls=sessionControls()
        local target=state.ui.target or adapter.identity(self)
        local editor=controls and target and identity.same(controls.target,target) and controls.settings_editor or nil
        return settingsMenu.build({ui=openmwUi,util=util,wrap=adapter.callback,editor=editor,
            scope=settingScope,field=settingField,value=settingValue,page=settingPage,pending=controlsRequestActive,
            openSection=function(scope) settingScope=scope settingPage=1 render() end,
            edit=function(field)
                if controlsRequestActive then return end
                settingField=field settingValue=field.value settingPage=1
                settingToken=editor.change_token settingTarget=target
                if field.kind=='boolean' then saveSessionSetting(field.value=='true' and 'false' or 'true') else render() end
            end,
            save=saveSessionSetting,changeValue=function(value) settingValue=tostring(value) end,
            cancel=function() settingField=nil settingValue=nil settingPage=1 render() end,
            setPage=function(page) settingPage=page render() end,
            backToHub=function() settingScope=nil settingPage=1 render() end,
            refresh=function() refreshSessionControls('settings') end,
            models=function() refreshSessionControls('models') end,
            profiles=function() state.ui.panel='profile-menu' render() end,
            readBooks=soundSettings and soundSettings:get('bookReadAloud')==true,
            toggleBooks=function()
                if soundSettings then soundSettings:set('bookReadAloud',soundSettings:get('bookReadAloud')~=true) end
                if bookSpeech then stopBookSpeech() end
                render()
            end,
            back=function() settingField=nil state.ui.panel='conversation' render() end})
end
function settingsControls.open()
    settingScope=nil settingField=nil settingPage=1
    openFromConversation('settings') refreshSessionControls('settings')
end

-- Keep panel closures separate so the renderer stays below LuaJIT's 60-upvalue limit.
local renderPanels={}
function renderPanels.conversation()
    local transcript
    uiState.refreshTurnPreview(state.ui)
    transcript=chatbox.build({ui=openmwUi,util=util,whiteTexture=whiteTexture,text=state.ui.input,
        target=displayName(state.ui.target),
        mood=uiState.moodSummary(state.ui),mode=uiState.selectedChatMode(state.ui).label,
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
        autoChat=state.ui.autoChat,
        onSelectMood=adapter.callback(function() openFromConversation('moods') render() end),
        onSelectModes=adapter.callback(function() openFromConversation('modes') render() end),
        onSelectModel=adapter.callback(function()
            openFromConversation('models') refreshSessionControls('models')
        end),
        onSelectProfiles=adapter.callback(function() openFromConversation('profile-menu') render() end),
        aiEnabled=aiEnabled,
        onToggleAI=adapter.callback(function()
            if controlsRequestActive then return end
            pendingAiToggle=true
            refreshSessionControls('settings')
            if not controlsRequestActive then pendingAiToggle=false end
        end),
        onSelectSettings=adapter.callback(settingsControls.open),
        onWaitHere=adapter.callback(function()
            if not state.ui.target or state.ui.target.kind=='narrator' then
                state.ui.status='Select a nearby NPC first.' render() return
            end
            send('LORKHAN_WAIT_HERE_REQUEST',{target=state.ui.target})
            state.ui.status='Requesting wait...'
            state.ui.visible=false leaveUiMode() render()
        end),
        onSelectHistory=adapter.callback(function() openFromConversation('history') render() end),
        onToggleStatusHud=adapter.callback(toggleStatusHud),
        onToggleAutoChat=adapter.callback(toggleAutoChat),
        onSelectDiagnostics=adapter.callback(function() openFromConversation('diagnostics') render() end),
        onSend=adapter.callback(submitText),
        onClose=adapter.callback(function() pendingTextSubmit=false state.ui.visible=false leaveUiMode() render() end)})
    return transcript
end

-- Resolve the pending prompt once and leave the menu before the queued action resumes.
local function answerActionConfirmation(approved)
    local pending=state.ui.pendingAction
    if not pending then return end
    state.ui.pendingAction=nil
    state.ui.visible=false
    state.ui.panel='conversation'
    leaveUiMode()
    send('LORKHAN_CONFIRM_ACTION',{action_id=pending.action_id,approved=approved==true})
    render()
end

render=function()
    renderStatusHud()
    if not state.ui.visible or not uiOk or not utilOk then
        if element then element:destroy() element=nil end
        return
    end
    local transcript={}
    if state.ui.pendingAction then
        -- The standalone confirmation below replaces every normal menu while pending.
    elseif state.ui.panel=='conversation' then
        transcript=renderPanels.conversation()
    elseif state.ui.panel=='settings' then
        transcript=settingsControls.build()
    elseif state.ui.panel=='nearby-profiles' then
        local exterior=self.cell and self.cell.isExterior==true
        local distance=hearingSettings and hearingSettings:get(exterior and 'exteriorDistance' or 'interiorDistance')
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
                textColor=util.color.rgb(188/255,157/255,90/255)},events={mouseClick=adapter.callback(function()
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
            textColor=util.color.rgb(188/255,157/255,90/255)},events={mouseClick=adapter.callback(function()
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
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=displayName(line.speaker)..': '..line.text,
                textSize=16,wordWrap=true,textColor=util.color.rgb(0.92,0.82,0.68)}}
        end
        if pages>1 then
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Newer',textSize=15,
                textColor=util.color.rgb(188/255,157/255,90/255)},events={mouseClick=adapter.callback(function()
                    state.ui.historyPage=math.max(1,state.ui.historyPage-1) render()
                end)}}
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Older',textSize=15,
                textColor=util.color.rgb(188/255,157/255,90/255)},events={mouseClick=adapter.callback(function()
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
                textSize=15,textColor=util.color.rgb(188/255,157/255,90/255)}}
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
                textColor=util.color.rgb(188/255,157/255,90/255)},events={mouseClick=adapter.callback(function()
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
        transcript=selector.build({ui=openmwUi,util=util,title='Dynamic Profiles',message=state.ui.status,options={
            {label='Targeted NPC: '..(state.ui.target and displayName(state.ui.target) or 'No target'),onSelect=adapter.callback(function() settingsControls.requestProfiles('target') end)},
            {label='Nearby AI NPCs',onSelect=adapter.callback(function() settingsControls.requestProfiles('nearby') end)},
            {label='Narrator',onSelect=adapter.callback(function() settingsControls.requestProfiles('narrator') end)},
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
                    textColor=util.color.rgb(188/255,157/255,90/255)},events={mouseClick=adapter.callback(generateNarratorProfile)}}
                transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Queues one revision-safe narrator job and preserves voice routing and enablement.',textSize=14,
                    textColor=util.color.rgb(0.72,0.68,0.62)}}
            else
                transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='No narrator profile is configured. Create one in Server > Configuration > Narration.',textSize=16,
                    textColor=util.color.rgb(0.72,0.68,0.62)}}
            end
        else
            local defaultActive=not controls.selected_profile_id and ' [active]' or ''
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Use playthrough profile'..defaultActive,textSize=18,
                textColor=not controls.selected_profile_id and util.color.rgb(0.45,0.9,0.45) or util.color.rgb(188/255,157/255,90/255)},
                events={mouseClick=adapter.callback(function() selectSessionControl('actor_profile',nil) end)}}
            for _,profile in ipairs(controls.profiles or {}) do
                local active=controls.selected_profile_id==profile.profile_id and ' [active]' or ''
                transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=profile.name..active..'  |  revision '..tostring(profile.revision),textSize=17,
                    textColor=active~='' and util.color.rgb(0.45,0.9,0.45) or util.color.rgb(188/255,157/255,90/255)},
                    events={mouseClick=adapter.callback(function() selectSessionControl('actor_profile',profile.profile_id) end)}}
            end
            if controls.selected_profile_id then
                transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Generate active profile with AI',textSize=17,
                    textColor=util.color.rgb(188/255,157/255,90/255)},events={mouseClick=adapter.callback(generateSelectedProfile)}}
                transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Queues one revision-safe server job. Refresh after it completes.',textSize=14,
                    textColor=util.color.rgb(0.72,0.68,0.62)}}
            end
        end
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Refresh choices',textSize=16,
            textColor=util.color.rgb(188/255,157/255,90/255)},events={mouseClick=adapter.callback(function() refreshSessionControls(state.ui.panel) end)}}
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
        local selected=uiState.selectedChatMode(state.ui)
        for _,entry in ipairs(uiState.CHAT_MODES) do
            local active=entry.key==selected.key
            local label=entry.label..(entry.prefix and (entry.prefix:sub(1,1)=='(' and ' '..entry.prefix or ' ('..entry.prefix..')') or '')
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=label..(active and ' [active]' or ''),textSize=16,
                textColor=active and util.color.rgb(0.45,0.9,0.45) or util.color.rgb(188/255,157/255,90/255)},
                events={mouseClick=adapter.callback(function()
                    uiState.selectChatMode(state.ui,entry.key)
                    if playerInputSettings then playerInputSettings:set('autoChat',state.ui.autoChat) end
                    send('LORKHAN_MODE_CHANGED',{mode=state.ui.mode})
                    render()
                end)}}
        end
        transcript[#transcript+1]=backRow()
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Close',textSize=16,
            textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function()
                state.ui.visible=false leaveUiMode() render()
            end)}}
    end
    if state.ui.pendingAction then
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Allow '..
            (state.ui.pendingAction.display_name or state.ui.pendingAction.name)..'?',textSize=17,
            textColor=util.color.rgb(218/255,187/255,120/255)}}
        local pending=state.ui.pendingAction
        local parameters=pending.parameters or {}
        local details={'Target: '..displayName(pending.target)}
        if parameters.record_id then details[#details+1]='Record: '..tostring(parameters.record_id) end
        if parameters.count then details[#details+1]='Quantity: '..tostring(parameters.count) end
        if parameters.amount then details[#details+1]='Gold: '..tostring(parameters.amount) end
        if parameters.destination_id then details[#details+1]='Destination: '..tostring(parameters.destination_id) end
        if pending.summary then details[#details+1]=tostring(pending.summary) end
        local advanced=({['item.create']=true,['gold.create']=true,['actor.spawn']=true,
            ['actor.teleport_to_player']=true,['player.teleport']=true,['actor.restore']=true,
            ['actor.resurrect']=true,['actor.kill']=true})[pending.name]
        if pending.name=='actor.kill' or pending.name=='actor.resurrect' then
            details[#details+1]='Warning: this can break quests. Resurrection does not undo quest consequences.'
        end
        if advanced then details[#details+1]='Changes affect this save. Cancelling afterward does not undo them.' end
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=table.concat(details,'\n'),textSize=15,
            multiline=true,wordWrap=true,size=util.vector2(500,200),autoSize=false,
            textColor=util.color.rgb(0.88,0.85,0.78)}}
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Yes',textSize=16,textColor=util.color.rgb(0.45,0.9,0.45)},
            events={mouseClick=adapter.callback(function()
                answerActionConfirmation(true)
            end)}}
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='No',textSize=16,textColor=util.color.rgb(1.0,0.45,0.35)},
            events={mouseClick=adapter.callback(function()
                answerActionConfirmation(false)
            end)}}
    end
    local panelSizes={conversation={560,400},['actor-tools']={540,360},['profile-menu']={520,300},
        settings={660,600},modes={540,480},moods={520,470},models={580,420},profiles={580,420},narrator={580,330},
        ['nearby-profiles']={680,460},history={760,620},diagnostics={760,620}}
    local panelSize=state.ui.pendingAction and {540,320} or panelSizes[state.ui.panel] or {680,460}
    local contentWidth=panelSize[1]-20
    local contentHeight=panelSize[2]-20
    local layout={layer='Windows',type=openmwUi.TYPE.Container,
        props={position=util.vector2(30,60),size=util.vector2(panelSize[1],panelSize[2])},content=openmwUi.content({
            {type=openmwUi.TYPE.Flex,props={horizontal=false,size=util.vector2(contentWidth,contentHeight)},content=openmwUi.content({
                {type=openmwUi.TYPE.Text,props={text=state.ui.pendingAction and 'LORKHAN' or 'LORKHAN  |  '..state.ui.status,textSize=16,
                    textColor=util.color.rgb(188/255,157/255,90/255)}},
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
        candidate=uiState.targetPreview(nil,nearby,maxDistance)
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
        if state.ui.executionMode=='injection_log' or state.ui.executionMode=='injection_chat' then
            state.ui.status='Injection modes require typed text. Select another mode for push-to-talk.' render() return
        end
        if not controlsAllowed() and not ownsUiMode then
            print('[LORKHAN] push-to-talk blocked by another UI mode via '..tostring(source))
            return
        end
        if not state.ui.target and state.ui.executionMode~='director' and state.ui.executionMode~='narrator' and state.ui.executionMode~='cheat' then
            print('[LORKHAN] push-to-talk needs a target; starting target selection via '..tostring(source))
            chooseTarget(2048)
            return
        end
        pttHeld=true
        if openMicEnabled then
            openMicEnabled=false
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
    if state.ui.pendingAction then answerActionConfirmation(false) return end
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
    if state.ui.pendingAction then return end
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
        local distance=hearingSettings and hearingSettings:get(exterior and 'exteriorDistance' or 'interiorDistance')
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
    local settingsTarget=state.ui.target or adapter.identity(self)
    local effective=controls and settingsTarget and identity.same(controls.target,settingsTarget)
        and controls.effective_settings or nil
    local targetSettings=effective and effective.settings or session and session.client_settings or {}
    local interiorHearing=hearingSettings and hearingSettings:get('interiorHearingDistance') or 1000
    local exteriorHearing=hearingSettings and hearingSettings:get('exteriorHearingDistance') or 1800
    local actionsEnabled=agentSettings and agentSettings:get('actionsEnabled')
    if actionsEnabled==nil and behaviorSettings then actionsEnabled=behaviorSettings:get('actionsEnabled') end
    if actionsEnabled==nil then actionsEnabled=true end
    local ttsVolumeBoost=soundSettings and soundSettings:get('ttsVolumeBoost')
    if ttsVolumeBoost==nil and presentationSettings then ttsVolumeBoost=presentationSettings:get('ttsVolumeBoost') end
    local current={
        autoActivate={enabled=autoSettings and autoSettings:get('enabled'),
            interiorDistance=hearingSettings and hearingSettings:get('interiorDistance'),
            exteriorDistance=hearingSettings and hearingSettings:get('exteriorDistance'),
            hearingDistance=exterior and exteriorHearing or interiorHearing,
            autoHearingRadiusMeters=hearingSettings and hearingSettings:get('autoHearingRadiusMeters') or 10,
            interiorHearingDistance=interiorHearing,
            exteriorHearingDistance=exteriorHearing,
            addHostile=autoSettings and autoSettings:get('addHostile'),
            addCreatures=autoSettings and autoSettings:get('addCreatures')},
        behavior={actionsEnabled=actionsEnabled,
            allowCombatDialogue=not behaviorSettings or behaviorSettings:get('allowCombatDialogue')~=false,
            combatBarks=not behaviorSettings or behaviorSettings:get('combatBarks')~=false,
            combatBarkInterval=tonumber(behaviorSettings and behaviorSettings:get('combatBarkInterval')) or 30,
            cancelDialogueOnCombat=behaviorSettings and behaviorSettings:get('cancelDialogueOnCombat')},
        presentation={showStatusHud=presentationSettings and presentationSettings:get('showStatusHud')==true,
            transcriptRows=tonumber(presentationSettings and presentationSettings:get('transcriptRows')) or 12,
            ttsVolumeBoost=tonumber(ttsVolumeBoost) or 3},
    }
    current.playback={}
    local playbackDefaults={voice_volume_percent=100,head_voice_volume_percent=100,distance_scale=1,dropoff_inside_percent=70,
        dropoff_outside_percent=70,legacy_distance_scale=1,clip_start_ms=0,clip_end_ms=0,
        lip_intensity=1,lip_resolution_ms=0,camera_based_audio=true,invert_heading=false,pause_on_game_pause=false}
    local audioSignature={}
    for key,default in pairs(playbackDefaults) do
        local value=soundSettings and soundSettings:get(key)
        if value==nil then value=default end
        current.playback[key]=value
        audioSignature[#audioSignature+1]=key..'='..tostring(value)
    end
    table.sort(audioSignature)
    current.playback.audio_mode=({Flat3D=0,Normal3D=1,Realistic3D=2,Mono=3,MonoEffects=4})[
        soundSettings and soundSettings:get('audio_mode') or 'Normal3D'] or 1
    current.transport={connection_timeout_seconds=tonumber(presentationSettings and presentationSettings:get('connectionTimeoutSeconds')) or 30}
    audioSignature[#audioSignature+1]=tostring(current.playback.audio_mode)
    audioSignature[#audioSignature+1]=tostring(current.transport.connection_timeout_seconds)
    player.applyTargetSettings(current,targetSettings)
    local auto=current.autoActivate or {}
    local behavior=current.behavior or {}
    aiEnabled=behavior.aiEnabled~=false
    local presentation=current.presentation or {}
    local narrator=current.narrator or {}
    narrator.welcomeReady=narratorCooldownReady('lastWelcomeGameTime',narrator.welcome_cooldown_minutes or 10)
    narrator.questReady=narratorCooldownReady('lastQuestGameTime',narrator.quest_cooldown_minutes or 3)
    currentNarratorSettings=narrator
    local signature=table.concat({tostring(auto.enabled),tostring(auto.interiorDistance),tostring(auto.exteriorDistance),
        tostring(auto.autoHearingRadiusMeters),tostring(auto.hearingDistance),tostring(auto.interiorHearingDistance),tostring(auto.exteriorHearingDistance),
        tostring(auto.addHostile),tostring(auto.addCreatures),tostring(behavior.actionsEnabled),
        table.concat(audioSignature,','),tostring(behavior.allowCombatDialogue),tostring(behavior.cancelDialogueOnCombat),tostring(behavior.aiEnabled),tostring(behavior.autoGreeting),tostring(behavior.boredom),
        tostring(behavior.boredomDelaySeconds),tostring(behavior.combatBarks),tostring(behavior.combatBarkPeriodSeconds),
        tostring(behavior.rechat),tostring(behavior.rechatMaxDepth),
        tostring(behavior.rechatProbabilityPercent),tostring(behavior.rechatMode),tostring(behavior.rechatStrictTargeting),
        tostring(behavior.openRechat),tostring(behavior.endConversationCooldownSeconds),
        tostring(narrator.enabled),tostring(narrator.welcome_events),tostring(narrator.welcome_cooldown_minutes),
        tostring(narrator.random_events),tostring(narrator.random_chance_percent),tostring(narrator.random_cooldown_rounds),
        tostring(narrator.bored_events),tostring(narrator.bored_chance_percent),tostring(narrator.quest_events),
        tostring(narrator.quest_chance_percent),tostring(narrator.quest_cooldown_minutes),tostring(narrator.book_events),
        tostring(narrator.welcomeReady),tostring(narrator.questReady),
        tostring(presentation.showStatusHud),tostring(presentation.transcriptRows),
        tostring(presentation.ttsVolumeBoost),tostring(effective and effective.change_token),tostring(session and session.config_revision)},'|')
    if signature==settingsSignature then return end
    settingsSignature=signature
    state.ui.statusHudVisible=presentation.showStatusHud==true
    state.ui.policy.transcriptRows=presentation.transcriptRows or 12
    send('LORKHAN_SETTINGS_UPDATE',current)
    render()
end

-- Keep CHIM-style enablement separate from temporary mute, menus and push-to-talk.
function settingsControls.syncOpenMic()
    local desired=behaviorSettings and behaviorSettings:get('openMicEnabled')==true
    if not desired then
        if openMicEnabled or openMicControl.suspended then send('LORKHAN_OPEN_MIC_STOP',{}) end
        openMicEnabled=false openMicMuted=false openMicControl.suspended=false
        return
    end
    if not controlsAllowed() or not state.ui.target or state.ui.target.kind=='narrator'
        or nearbyCombat and behaviorSettings:get('cancelDialogueOnCombat')~=false then
        if openMicEnabled and not openMicControl.suspended and not pttHeld then
            if nativeOk and native.cancelVoiceCapture then pcall(native.cancelVoiceCapture) end
            send('LORKHAN_OPEN_MIC_MUTE',{})
            openMicControl.suspended=true voiceRecording=false
        end
        return
    end
    if openMicMuted or pttHeld then return end
    local session=nativeOk and native.sessionInfo and native.sessionInfo() or nil
    if not session or not state.ui.target or state.ui.target.kind=='narrator' then return end
    local scope=tostring(session.session_id)..':'..tostring(session.generation)
    if openMicControl.scope~=scope then openMicEnabled=false openMicControl.scope=scope end
    if core.getRealTime()<openMicControl.retryAt then return end
    if not openMicEnabled or openMicControl.suspended then
        openMicEnabled=true openMicControl.suspended=false
        openMicControl.retryAt=core.getRealTime()+1
        send('LORKHAN_OPEN_MIC_START',voicePayload('lorkhan_open_mic'))
    end
end

if inputOk then
    input.registerTriggerHandler('LORKHAN_Talk',adapter.callback(requestTalkToggle))
    input.registerTriggerHandler('LORKHAN_StopDialogue',adapter.callback(function()
        stopBookSpeech()
        send('LORKHAN_STOP_DIALOGUE_REQUEST',{}) state.ui.status='dialogue stopped' render()
    end))
    input.registerTriggerHandler('LORKHAN_Halt',adapter.callback(function()
        if behaviorSettings and behaviorSettings:get('openMicEnabled')==true then openMicMuted=true end
        state.ui.pendingTargetAction=nil
        stopPlayerSpeech()
        stopBookSpeech()
        if pendingAutochat and nativeOk and native.cancelPlayerAutochat then
            pcall(native.cancelPlayerAutochat,pendingAutochat.request_id) pendingAutochat=nil
        end
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
        if behaviorSettings then behaviorSettings:set('openMicEnabled',behaviorSettings:get('openMicEnabled')~=true) end
        openMicMuted=false settingsControls.syncOpenMic()
        state.ui.status=behaviorSettings and behaviorSettings:get('openMicEnabled')==true and 'open mic enabled' or 'open mic off';render()
    end))
    input.registerTriggerHandler('LORKHAN_OpenMicMute',adapter.callback(function()
        if not controlsAllowed() then return end
        if not behaviorSettings or behaviorSettings:get('openMicEnabled')~=true then state.ui.status='open mic is off';render();return end
        openMicMuted=not openMicMuted;voiceRecording=not openMicMuted
        if openMicMuted then send('LORKHAN_OPEN_MIC_MUTE',{})
        else openMicControl.suspended=true settingsControls.syncOpenMic() end
        state.ui.status=openMicMuted and 'open mic muted' or 'open mic listening';render()
    end))
end

return {
    engineHandlers={
        onInputAction=function(action)
            if action=='LORKHAN_Halt' then stopPlayerSpeech() stopBookSpeech() end
            return player.onAction(state,action,send)
        end,
        onKeyPress=function(event)
            if inputOk and state.ui.pendingAction and event and event.code==input.KEY.Escape then
                answerActionConfirmation(false)
                return
            end
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
        -- bounded pause-safe pump plus disposition snapshots on menu transitions. No game mutation,
        -- settings scan, or response-event processing belongs here.
        onFrame=function()
            local dispositionOpen=dialogueMenuOpen()
            if dispositionOpen~=nil and dispositionOpen~=state.dispositionDialogueOpen then
                state.dispositionDialogueOpen=dispositionOpen
                send('LORKHAN_DISPOSITION_MENU',{open=dispositionOpen,actor=state.dispositionDialogueActor})
                local observed=adapter.dispositionSnapshot(state.dispositionDialogueActor,dispositionOpen)
                if observed and nativeOk and native.submitDisposition then native.submitDisposition(observed) end
            end
            if not controlsAllowed() then settingsControls.syncOpenMic() end
            if nativeOk and native.pumpMenuDialogueTts and (bookSpeech or playerSpeech or menuDialogueSpeech) then native.pumpMenuDialogueTts() end
            updateBookSpeech()
            pumpDebugCommands()
            if pendingAutochat and nativeOk and native.pumpPlayerAutochat then pcall(native.pumpPlayerAutochat) end
            updatePlayerAutochat()
            updatePlayerSpeech()
            if settingsControls.profileUpdates then
                local ok,done,message=pcall(require('scripts.LORKHAN.ui.profile_requests').pump,
                    settingsControls.profileUpdates,native,core.getRealTime())
                if not ok then done=true;message='Profile update request failed' end
                if done then settingsControls.profileUpdates=nil end
                if message then state.ui.status=message;render() end
                return
            end
            if not controlsRequestActive or not state.ui.visible
                or not SERVER_CONTROL_PANELS[state.ui.panel] then return end
            if not nativeOk or not native or not native.pumpSessionControls then
                controlsRequestActive=false return
            end
            local ok,status=pcall(native.pumpSessionControls)
            if not ok or type(status)~='table' then controlsRequestActive=false return end
            if status.pending==true then return end
            controlsRequestActive=false
            if status.error then state.ui.status=tostring(status.error) pendingAiToggle=false end
            if pendingAiToggle then
                pendingAiToggle=false
                local controls=sessionControls()
                local target=state.ui.target or adapter.identity(self)
                local editor=controls and identity.same(controls.target,target) and controls.settings_editor
                local found=false
                for _,section in ipairs(editor and editor.sections or {}) do
                    for _,field in ipairs(section.fields or {}) do
                        if field.key=='client.behavior.ai_enabled' or field.key=='behavior.ai_enabled' then
                            settingScope=section.scope settingField=field settingTarget=target settingToken=editor.change_token
                            saveSessionSetting(field.value=='true' and 'false' or 'true') found=true break
                        end
                    end
                    if found then break end
                end
                if not found then state.ui.status='AI switch unavailable; refresh server settings' end
            elseif not status.error then
                local session=native.sessionInfo and native.sessionInfo() or nil
                applySettings(session,sessionControls())
            end
            -- Rerendering is what settles the panel: the models branch feeds the returned snapshot to
            -- uiState.settleModelSlot, which clears the pending mark and shows the selected slot.
            render()
        end,
        onUpdate=function(dt)
            settingsControls.syncOpenMic()
            if narratorSpeech and not adapter.isSpeechActive() then reportNarrator('played','playback_completed') end
            updatePlayerAutochat()
            updatePlayerSpeech()
            updateMenuDialogueSpeech()
            flushCapturedDialogue(dt)
            if nativeOk and native.submitItemPickup and native.sessionInfo then
                player.flushItemPickups(state,native.sessionInfo(),native.submitItemPickup,core.getRealTime())
            end
            if nativeOk and native.submitSpellCast and native.sessionInfo then
                player.flushSpellCasts(state,native.sessionInfo(),native.submitSpellCast,core.getRealTime())
            end
            if nativeOk and native.submitActorResurrected and native.sessionInfo then
                player.flushResurrections(state,native.sessionInfo(),native.submitActorResurrected,core.getRealTime())
            end
            flushActorProfiles(dt)
            flushAutomaticDiaries(dt)
            local elapsed=tonumber(dt) or 0
            automaticDiaryTimerElapsed=automaticDiaryTimerElapsed+elapsed
            if automaticDiaryTimerElapsed>=AUTOMATIC_DIARY_POLL_INTERVAL then
                automaticDiaryTimerElapsed=0
                submitAutomaticDiary('timer')
            end
            settingsRefreshElapsed=settingsRefreshElapsed+elapsed
            if settingsRefreshElapsed>=SETTINGS_REFRESH_INTERVAL then
                settingsRefreshElapsed=0
                local session=nativeOk and native.sessionInfo and native.sessionInfo() or nil
                local rpgSession=session and (session.session_id..':'..tostring(session.generation)) or nil
                local level=adapter.playerLevel()
                if rpgSession~=observedRpgSession then observedPlayerLevel=level observedRpgSession=rpgSession
                elseif level and observedPlayerLevel and level>observedPlayerLevel then
                    submitRpgEvent('levelup','The player reached level '..tostring(level)..'.')
                end
                observedPlayerLevel=level
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
                aimCandidate=candidate
                local preview=uiState.targetPreview(candidate,nil,2048)
                if not preview then preview=uiState.targetPreview(nil,adapter.nearbyActors(2048),2048) end
                state.ui.previewTarget=preview and preview.identity or nil
                local signature=preview and table.concat({identity.key(preview.identity),
                    displayName(preview.identity),tostring(math.floor(preview.distance+0.5))},'|') or ''
                if signature~=aimSignature then
                    aimSignature=signature render()
                end
            end
            autoScanElapsed=autoScanElapsed+elapsed
            if autoScanElapsed>=AUTO_SCAN_INTERVAL then
                autoScanElapsed=0
                local enabled=not autoSettings or autoSettings:get('enabled')~=false
                local candidates={}
                if enabled then
                    local exterior=self.cell and self.cell.isExterior==true
                    local distance=hearingSettings and hearingSettings:get(exterior and 'exteriorDistance' or 'interiorDistance')
                        or (exterior and 2400 or 1200)
                    candidates=adapter.nearbyActors(tonumber(distance) or (exterior and 2400 or 1200))
                    while #candidates>32 do table.remove(candidates) end
                end
                send('LORKHAN_AUTO_ACTIVATE_SCAN',{candidates=candidates})
            end
            journalScanElapsed=journalScanElapsed+elapsed
            if journalScanElapsed>=5 then
                journalScanElapsed=0
                local session=nativeOk and native.sessionInfo and native.sessionInfo() or nil
                local changes=player.journalChanges(state,adapter.journalEntries(),session)
                if #changes>0 then
                    if session then
                        if currentNarratorSettings.enabled==true and currentNarratorSettings.quest_events==true then
                            send('LORKHAN_NARRATOR_EVENT_CANDIDATE',{kind='quest',context_actor=state.ui.target,observed_text=protocol.questText(changes),
                                cooldown_ready=narratorCooldownReady('lastQuestGameTime',
                                    currentNarratorSettings.quest_cooldown_minutes or 3)})
                        else submitQuestEvent(changes,session) end
                    end
                end
            end
        end,
    },
    eventHandlers={
        UiModeChanged=function(event)
            if type(event)~='table' then return end
            if (event.oldMode=='Book' or event.oldMode=='Scroll') and event.newMode~='Book' and event.newMode~='Scroll' then stopBookSpeech() end
            if event.newMode=='Rest' then
                restDiaryState={game_time=adapter.gameTime(),opened_from_bed=event.arg~=nil,
                    exterior=self.cell and self.cell.isExterior==true}
                return
            end
            if event.oldMode~='Rest' or not restDiaryState then return end
            local entered=restDiaryState;restDiaryState=nil
            local finished=adapter.gameTime()
            if type(entered.game_time)~='number' or type(finished)~='number' or finished<=entered.game_time then return end
            local trigger=(entered.opened_from_bed or entered.exterior) and 'sleep' or 'wait'
            submitAutomaticDiary(trigger)
            submitRpgEvent(trigger,'The player finished '..(trigger=='sleep' and 'sleeping' or 'waiting')..'.')
        end,
        LORKHAN_DEBUG_COMMAND_RESULT=function(event)
            if not pendingGlobalDebugCommand or type(event)~='table'
                or event.command_id~=pendingGlobalDebugCommand.command.command_id then return end
            if pendingGlobalDebugCommand.session_id then
                local session=native.sessionInfo and native.sessionInfo()
                if not session or session.session_id~=pendingGlobalDebugCommand.session_id
                    or session.generation~=pendingGlobalDebugCommand.generation then pendingGlobalDebugCommand=nil return end
            end
            local browserArgs=pendingGlobalDebugCommand.browser_args
            if browserArgs then
                local session=native.sessionInfo and native.sessionInfo()
                if not session or session.session_id~=pendingGlobalDebugCommand.session_id
                    or session.generation~=pendingGlobalDebugCommand.generation then
                    pendingGlobalDebugCommand=nil return
                end
            end
            if browserArgs and event.status=='succeeded' then
                player.queued(state,browserArgs.speaker,browserArgs.text,event.observed or {})
                startPlayerSpeech(browserArgs.speaker,browserArgs.text)
                turnActive=true
                state.ui.status='browser speech queued'
                render()
            end
            submitDebugResult(pendingGlobalDebugCommand.command,event.status or 'failed',
                event.reason_code or 'global_command_failed',event.observed or {})
            pendingGlobalDebugCommand=nil
        end,
        LorkhanItemPickup=function(event)
            if not nativeOk or not native.submitItemPickup or not native.sessionInfo then return end
            player.captureItemPickup(state,event,native.sessionInfo(),adapter.itemPickupObservation,native.submitItemPickup,core.getRealTime())
        end,
        LorkhanActorResurrected=function(event)
            if not nativeOk or not native.submitActorResurrected or not native.sessionInfo then return end
            player.captureResurrection(state,event,native.sessionInfo(),adapter.resurrectionObservation,native.submitActorResurrected,core.getRealTime())
        end,
        LorkhanSpellCast=function(event)
            if not nativeOk or not native.submitSpellCast or not native.sessionInfo then return end
            player.captureSpellCast(state,event,native.sessionInfo(),adapter.spellCastObservation,native.submitSpellCast,core.getRealTime())
        end,
        DialogueResponse=function(event)
            local response=adapter.dialogueResponse(event)
            if response then
                state.dispositionDialogueActor=response.actor
                send('LORKHAN_DISPOSITION_MENU',{open=dialogueMenuOpen()==true,actor=response.actor})
                local observed=adapter.dispositionSnapshot(response.actor,dialogueMenuOpen()==true)
                if observed and nativeOk and native.submitDisposition then native.submitDisposition(observed) end
                send('LORKHAN_VANILLA_DIALOGUE',response)
                captureVanillaDialogue(response)
                startMenuDialogueSpeech(response)
            end
        end,
        LORKHAN_AUTO_ACTIVATED=submitAutoActorProfile,
        LORKHAN_BORED_POLICY_REQUEST=function(event)
            if not aiEnabled then return end
            local session=nativeOk and native.sessionInfo and native.sessionInfo() or nil
            if not session or not native.submitBoredEvent or type(event)~='table'
                or event.session_id~=session.session_id or event.generation~=session.generation then return end
            local gameTime=adapter.gameTime()
            if type(gameTime)~='number' or not identity.validate(event.actor) or event.actor.kind~='npc' then return end
            local request=native.submitBoredEvent({responder=event.actor,game_time=gameTime})
            if request then send('LORKHAN_BORED_POLICY_SUBMITTED',{request_id=request,actor=event.actor,
                session_id=event.session_id,generation=event.generation,opportunity=event.opportunity}) end
        end,
        LORKHAN_RPG_COMMENT=function(event)
            local session=nativeOk and native.sessionInfo and native.sessionInfo() or nil
            local responder=player.takeRpgComment(state,event,session,core.getRealTime())
            if not responder or not identity.same(responder,state.ui.target)
                or turnActive or nearbyCombat or speechActive() or state.ui.visible then return end
            local distance=adapter.actorDistance(responder)
            if not distance or distance>2048 then return end
            local snapshot=conversationContext(responder)
            snapshot.dialogueMode='Standard'
            send('LORKHAN_SUBMIT_TEXT',{text=(event.type=='quest.comment' and '[Quest update] ' or '[RPG:'..event.kind..'] ')..event.text,language='en-US',
                speaker=adapter.identity(self),dialogueMode='Standard',context=snapshot,
                rpg_responder=responder,rpg_session_id=event.session_id,rpg_generation=event.generation,
                capabilities=CAPABILITIES,recent_action_results={},ui_source=event.type=='quest.comment' and 'lorkhan_quest_event' or 'lorkhan_rpg_event'})
        end,
        LORKHAN_PROFILE_EVOLUTION_REQUEST=function(event)
            if type(event)~='table' or type(event.actors)~='table' then return end
            for _,actor in ipairs(event.actors) do submitAutoActorProfile({actor=actor}) end
        end,
        LORKHAN_INVENTORY_OBSERVE=function(event)
            if not nativeOk or not native.submitInventory or not native.sessionInfo then return end
            player.observeInventory(state,event,native.sessionInfo(),adapter.inventoryObservation,native.submitInventory,core.getRealTime())
        end,
        LORKHAN_DIRECTOR_CONTEXT_REQUEST=function(event)
            if not aiEnabled then return end
            local session=nativeOk and native.sessionInfo and native.sessionInfo() or nil
            if type(event)~='table' or not session or event.session_id~=session.session_id
                or event.generation~=session.generation or not identity.validate(event.target) then return end
            send('LORKHAN_DIRECTOR_CONTEXT',{request_id=event.request_id,session_id=event.session_id,
                generation=event.generation,instruction_id=event.instruction_id,target=event.target,
                context=conversationContext(event.target)})
        end,
        LORKHAN_RECHAT_CONTEXT_REQUEST=function(event)
            if not aiEnabled then return end
            local session=nativeOk and native.sessionInfo and native.sessionInfo() or nil
            if type(event)~='table' or not session or event.session_id~=session.session_id
                or event.generation~=session.generation or not identity.validate(event.target) then return end
            -- Capture this exact requested actor, not the UI selection or the previous speaker.
            local snapshot=conversationContext(event.target)
            send('LORKHAN_RECHAT_CONTEXT',{request_id=event.request_id,session_id=event.session_id,
                generation=event.generation,chain_id=event.chain_id,depth=event.depth,
                target=event.target,context=snapshot})
        end,
        LORKHAN_AUTONOMY_CONTEXT_REQUEST=function(event)
            if not aiEnabled then return end
            if type(event)~='table' or type(event.actor)~='table' then return end
            local prompts={
                greeting='[Autonomy:greeting]',
                boredom='[Autonomy:boredom]',
                combat_bark='[Autonomy:combat_bark]',
                narrator_welcome='[Narrator:welcome]',
                narrator_random='[Narrator:random]',
                narrator_boredom='[Narrator:boredom]',
                narrator_quest='[Narrator:quest]',
                narrator_book='[Narrator:book]',
            }
            local text=prompts[event.kind]
            if not text then return end
            if event.kind=='narrator_quest' and type(event.observed_text)=='string' then text=text..'\n'..event.observed_text end
            if event.kind=='narrator_welcome' then markNarratorEvent('lastWelcomeGameTime') end
            if event.kind=='narrator_quest' then markNarratorEvent('lastQuestGameTime') end
            local snapshot=conversationContext(event.context_actor or event.actor)
            snapshot.dialogueMode='Standard'
            local source=event.kind:match('^narrator_') and 'lorkhan_'..event.kind or 'lorkhan_auto_'..event.kind
            send('LORKHAN_SUBMIT_TEXT',{text=text,language='en-US',speaker=adapter.identity(self),
                dialogueMode='Standard',context=snapshot,capabilities=CAPABILITIES,recent_action_results={},
                ui_source=source,autonomy_kind=event.kind})
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
            stopBookSpeech()
            stopPlayerSpeech()
            stopNarrator('speech_replaced')
            local ok,reason=adapter.playSpeech(command.media_id,command.subtitle,command.tts_volume_boost)
            if ok then narratorSpeech=command
                send('LORKHAN_SPEECH_STATUS',{actor=command.actor,media_id=command.media_id,active=true,status='playing'})
            else narratorSpeech=command reportNarrator('failed',reason or 'playback_failed') end
        end,
        LORKHAN_NARRATOR_SUBTITLE=function(command)
            stopPlayerSpeech()
            stopNarrator('subtitle_replaced') narratorSpeech=command
            local ok,reason=adapter.showSubtitle(command.subtitle)
            reportNarrator(ok and 'played' or 'failed',ok and 'subtitle_displayed' or (reason or 'subtitle_unavailable'))
        end,
        LORKHAN_NARRATOR_STOP=function(event) stopNarrator(event and event.reason or 'client_interrupted') end,
        LORKHAN_AI_STATUS=function(event)
            aiEnabled=event.enabled~=false
            if not aiEnabled then
                if pendingAutochat and nativeOk and native.cancelPlayerAutochat then pcall(native.cancelPlayerAutochat,pendingAutochat.request_id) end
                pendingAutochat=nil pendingTextSubmit=false awaitingTextQueue=false pendingHistory=nil
                turnActive=false
                stopPlayerSpeech()
            end
            state.ui.status=aiEnabled and 'AI on' or 'AI off; transcription and observations remain active'
            render()
        end,
        LORKHAN_STATUS=function(event) state.ui.status=event.status state.ui.diagnostics=event.reason render() end,
        LORKHAN_WAIT_HERE_STATUS=function(event)
            if not event or not identity.same(event.target,state.ui.target) then return end
            if event.status=='waiting' then state.ui.status=displayName(event.target)..' will wait for 90 seconds.'
            elseif event.status=='ended' then state.ui.status='Wait ended.'
            else state.ui.status='Cannot wait: '..tostring(event.reason or 'NPC unavailable') end
            render()
        end,
        LORKHAN_VOICE_STATUS=function(event)
            state.ui.status=event.status;state.ui.diagnostics=event.reason
            if event.status=='failed' or event.status=='queued' or event.status=='transcribed' then voiceRecording=false end
            if event.status=='open mic off' or event.status=='failed' and event.continuous then openMicEnabled=false end
            render()
        end,
        LORKHAN_OPEN_MIC_CONTEXT_REQUEST=function()
            if openMicEnabled and not openMicMuted and not openMicControl.suspended and not pttHeld
                and controlsAllowed() and state.ui.target then send('LORKHAN_OPEN_MIC_CONTEXT',voicePayload('lorkhan_open_mic')) end
        end,
        LORKHAN_TURN=function(event)
            if event.status=='queued' and event.execution_mode=='director' and type(event.director_text)=='string' then
                pendingDirectorInput={text=event.director_text,request_id=event.request_id}
            end
            if not awaitingTextQueue then return end
            awaitingTextQueue=false
            if event.status=='queued' then
                if event.execution_mode=='director' and pendingDirectorInput then pendingDirectorInput.request_id=event.request_id end
                if pendingHistory then player.queued(state,pendingHistory.speaker,pendingHistory.text,event) end
                pendingHistory=nil
                state.ui.input=''
                state.ui.status='queued'
                state.ui.visible=false
                turnActive=true
                leaveUiMode()
                print('[LORKHAN] text message accepted; chat closed')
            else
                if pendingDirectorInput then
                    state.ui.input='> '..pendingDirectorInput.text;pendingDirectorInput=nil
                end
                state.ui.status='message failed: '..tostring(event.reason or 'unknown')
                turnActive=false
                stopPlayerSpeech()
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
            local session=nativeOk and native.sessionInfo and native.sessionInfo()
            local sameSession=session and observedRpgSession==session.session_id..':'..tostring(session.generation)
            if sameSession and nearbyCombat and event.active==false then submitRpgEvent('combat_end','Combat nearby has ended.') end
            nearbyCombat=event.active==true
            if started and (not behaviorSettings or behaviorSettings:get('cancelDialogueOnCombat')~=false)
                and (turnActive or voiceRecording or openMicEnabled or speechActive()) then
                send('LORKHAN_STOP_DIALOGUE_REQUEST',{})
                voiceRecording=false;openMicEnabled=false;pttHeld=false;turnActive=false
                stopPlayerSpeech()
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
            startBookSpeech(event)
            if adapter.rememberBook(event) then
                state.ui.status='book remembered: '..tostring(event.title or event.record_id)
                send('LORKHAN_NARRATOR_EVENT_CANDIDATE',{kind='book',context_actor=state.ui.target,cooldown_ready=true})
                render()
            end
        end,
        LORKHAN_ACTION_CONFIRMATION=function(event)
            state.ui.pendingAction=event state.ui.panel='confirmation'
            state.ui.visible=true enterUiMode() render()
        end,
        LORKHAN_ACTION_STATUS=function(event)
            state.ui.status='action '..tostring(event.name or '')..' '..tostring(event.status or 'unknown')
            state.ui.diagnostics=event.submitted and event.reason or event.submit_reason
            render()
        end,
        LORKHAN_EVENT=function(event)
            if pendingDirectorInput and event.request_id==pendingDirectorInput.request_id then
                -- A submitted one-turn prefix never changes the selected menu mode.
                if event.type=='turn.complete' then pendingDirectorInput=nil
                elseif event.type=='turn.failed' then
                    state.ui.input='> '..pendingDirectorInput.text;pendingDirectorInput=nil
                elseif event.type=='turn.cancelled' then pendingDirectorInput=nil end
            end
            if event.type=='turn.accepted' then turnActive=true end
            if event.type=='turn.complete' or event.type=='turn.failed' or event.type=='turn.cancelled' then
                turnActive=false
            end
            player.event(state,event) render()
        end,
    },
}
