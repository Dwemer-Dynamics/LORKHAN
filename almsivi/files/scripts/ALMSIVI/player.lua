local adapter=require('scripts.ALMSIVI.adapters.openmw')
local identity=require('scripts.ALMSIVI.identity')
local player=require('scripts.ALMSIVI.player_state')
local protocol=require('scripts.ALMSIVI.protocol')
local chatbox=require('scripts.ALMSIVI.ui.chatbox')
local selector=require('scripts.ALMSIVI.ui.selector')
local actorTools=require('scripts.ALMSIVI.ui.actor_tools')
local notifications=require('scripts.ALMSIVI.ui.notifications')
local core=adapter.event()
local inputOk,input=pcall(require,'openmw.input')
local uiOk,openmwUi=pcall(require,'openmw.ui')
local utilOk,util=pcall(require,'openmw.util')
local self=require('openmw.self')
local interfacesOk,interfaces=pcall(require,'openmw.interfaces')
local storageOk,openmwStorage=pcall(require,'openmw.storage')
local nativeOk,native=pcall(require,'openmw.almsivi')
local state=player.new()
local notification=notifications.new()
local dialogueNotification=notifications.new()
local lastNotificationStatus
local element
local statusElement
local settingsSignature
local autoScanElapsed=0
local turnActive=false
local nearbyCombat=false
local actorActivities={}
local speechActors={}
local narratorSpeech
local ownsUiMode=false
local controlsSignature
local MODES={'Standard','Whisper','Close','Shout'}
local EQUIPMENT_SLOTS={'helmet','cuirass','greaves','left_pauldron','right_pauldron','left_gauntlet',
    'right_gauntlet','boots','shirt','pants','skirt','robe','left_ring','right_ring','amulet','belt',
    'carried_right','carried_left','ammunition'}
local autoSettings=storageOk and openmwStorage.playerSection('SettingsALMSIVIAutoActivate') or nil
local behaviorSettings=storageOk and openmwStorage.playerSection('SettingsALMSIVIBehavior') or nil
local soundSettings=storageOk and openmwStorage.playerSection('SettingsALMSIVISound') or nil
local agentSettings=storageOk and openmwStorage.playerSection('SettingsALMSIVIAgents') or nil
local presentationSettings=storageOk and openmwStorage.playerSection('SettingsALMSIVIPresentation') or nil
local inputBindings=storageOk and openmwStorage.playerSection('OMWInputBindings') or nil
local unpackValues=table.unpack or unpack
local whiteTexture=uiOk and openmwUi.texture and openmwUi.texture({path='white'}) or nil
local lastTalkToggleAt=-1
local pendingTextSubmit=false
local awaitingTextQueue=false
local pendingHistory
local pendingControlPanel
local aimCandidate
local aimScanElapsed=0
local aimSignature=''
local function send(name,payload) if core and core.sendGlobalEvent then core.sendGlobalEvent(name,payload) end end
local CAPABILITIES={'dialogue.text','speech.say','action.ai.follow','action.ai.stop',
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
    if type(base)~='string' then return 'Unavailable (check ALMSIVI client configuration)' end
    local root=base:gsub('/api/v1/?$','')
    return root..'/ui/home.php'
end
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
    local context=conversationContext(state.ui.target)
    context.dialogueMode=state.ui.mode
    send('ALMSIVI_SUBMIT_TEXT',{text=text,language='en-US',speaker=speaker,
        context=context,capabilities=CAPABILITIES,
        recent_action_results={},ui_source='almsivi_text'})
    pendingHistory={speaker=speaker,text=text}
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

local function refreshSessionControls(panel,quiet)
    if not state.ui.target then state.ui.status='actor target required' render() return end
    if not nativeOk or not native or not native.requestSessionControls then
        if not quiet then state.ui.status='session controls unavailable' render() end
        return
    end
    local request,error=native.requestSessionControls(state.ui.target)
    if not quiet then
        if not request then state.ui.status=tostring(error or 'session controls unavailable') else state.ui.status='loading controls' end
        if panel then state.ui.panel=panel end
        render()
    end
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
    local actionsEnabled=agentSettings and agentSettings:get('actionsEnabled')
    if actionsEnabled==nil and behaviorSettings then actionsEnabled=behaviorSettings:get('actionsEnabled') end
    if actionsEnabled==false then
        state.ui.status='actions disabled in settings' render() return
    end
    if not state.ui.target then state.ui.status='actor target required' render() return end
    local request={name=name,tier=tier,parameters=parameters}
    if actionTarget then request.target=actionTarget end
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
    local dialogueVisible=notifications.active(dialogueNotification)
    local statusVisible=notifications.active(notification)
    if state.ui.visible or not uiOk or not utilOk
        or not state.ui.statusHudVisible and not statusVisible and not dialogueVisible then
        if statusElement then statusElement:destroy() statusElement=nil end
        return
    end
    local text
    if dialogueVisible then
        text=tostring(dialogueNotification.text)
    elseif state.ui.statusHudVisible then
        text='ALMSIVI  |  Connection: '..tostring(nativeValue('status','unavailable'))..
            '  |  Request: '..(turnActive and 'active' or 'idle')..
            '  |  Speech: '..(speechActive() and 'speaking' or 'idle')..
            '  |  Target: '..actorLabel(state.ui.target)..'  |  '..state.ui.mode
    else
        text='ALMSIVI  |  '..tostring(notification.text or state.ui.status)
    end
    local width=dialogueVisible and 900 or 520
    local height=dialogueVisible and 72 or 42
    local layout={layer='HUD',type=openmwUi.TYPE.Container,
        props={position=util.vector2(26,24),size=util.vector2(width,height)},content=openmwUi.content({
            {type=openmwUi.TYPE.Text,props={text=text,
                size=util.vector2(width,height),wordWrap=dialogueVisible,
                textSize=dialogueVisible and 18 or 15,textColor=util.color.rgb(1.0,0.58,0.18)}}
        })}
    if statusElement then statusElement.layout=layout statusElement:update()
    else statusElement=openmwUi.create(layout) end
end
render=function()
    if state.ui.status~=lastNotificationStatus then
        lastNotificationStatus=state.ui.status
        notifications.show(notification,tostring(state.ui.status),4)
    end
    renderStatusHud()
    if not state.ui.visible or not uiOk or not utilOk then
        if element then element:destroy() element=nil end
        return
    end
    local transcript={}
    if state.ui.panel=='conversation' then
        transcript=chatbox.build({ui=openmwUi,util=util,whiteTexture=whiteTexture,text=state.ui.input,
            target=displayName(state.ui.target),
            onTextChanged=adapter.callback(function(value) state.ui.input=player.consumeTextEdit(value) end),
            onKeyPress=adapter.callback(function(event)
                if inputOk and event and event.code==input.KEY.Escape then
                    pendingTextSubmit=false state.ui.visible=false leaveUiMode() render()
                end
            end),
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
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Dynamic Profiles',textSize=16,
            textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function()
                state.ui.panel='profile-menu' render()
            end)}}
    elseif state.ui.panel=='history' then
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Conversation History',textSize=20,
            textColor=util.color.rgb(0.95,0.9,0.82)}}
        if #state.ui.transcript==0 then
            transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='No ALMSIVI dialogue in this session yet.',
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
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Targeted NPC Tools',textSize=16,
            textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=adapter.callback(function()
                state.ui.panel='actor-tools' render()
            end)}}
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
            'Generated speech: '..tostring(speechActive()),
            'Nearby combat: '..tostring(nearbyCombat),
            'Bridge queue: '..tostring(bridge and bridge.outbound or 'unavailable')..' outbound / '..
                tostring(bridge and bridge.inbound or 'unavailable')..' inbound',
            'Last bridge error: '..tostring(nativeValue('lastError','none')),
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
        local ids=state.ui.lastCorrelation or {}
        local copyText='message_id='..tostring(ids.messageId or 'unavailable')..'  request_id='..
            tostring(ids.requestId or 'unavailable')..'  turn_id='..tostring(ids.turnId or 'unavailable')
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Correlation IDs (click, select, Ctrl+C)',textSize=14,
            textColor=util.color.rgb(0.72,0.68,0.62)}}
        transcript[#transcript+1]={type=openmwUi.TYPE.TextEdit,props={text=copyText,textSize=14,
            size=util.vector2(720,52),multiline=true,wordWrap=true,readOnly=true,autoSize=false,
            textColor=util.color.rgb(0.92,0.82,0.68)}}
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Targeted NPC Tools',textSize=16,
            textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=adapter.callback(function()
                state.ui.panel='actor-tools' render()
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
        link('Targeted NPC Tools',function() state.ui.panel='actor-tools' render() end)
        link('Close',function() state.ui.visible=false leaveUiMode() render() end)
    elseif state.ui.panel=='actor-tools' then
        transcript=actorTools.build({ui=openmwUi,util=util,target=displayName(state.ui.target),options={
            {label='Activate or deactivate aimed NPC',onSelect=adapter.callback(manualActivate)},
            {label='Add aimed NPC to conversation',onSelect=adapter.callback(function()
                send('ALMSIVI_AUDIENCE_REQUEST',{maxDistance=2048})
                state.ui.status='adding aimed NPC to conversation' render()
            end)},
            {label='Dynamic profiles...',onSelect=adapter.callback(function() state.ui.panel='profile-menu' render() end)},
            {label='Actor actions...',onSelect=adapter.callback(function()
                state.ui.panel='actions' state.ui.actionView='root' state.ui.actionPage=1 render()
            end)},
            {label='Stop current dialogue',onSelect=adapter.callback(function()
                send('ALMSIVI_STOP_DIALOGUE_REQUEST',{}) state.ui.status='dialogue stopped' render()
            end)},
            {label='Halt actor actions',danger=true,onSelect=adapter.callback(function()
                send('ALMSIVI_HALT_ACTIONS_REQUEST',{}) state.ui.status='actions halted' render()
            end)},
        },onClose=adapter.callback(function() state.ui.visible=false leaveUiMode() render() end)})
    elseif state.ui.panel=='profile-menu' then
        transcript=selector.build({ui=openmwUi,util=util,title='Dynamic Profiles',options={
            {label='Targeted NPC',onSelect=adapter.callback(function() refreshSessionControls('profiles') end)},
            {label='Nearby AI NPCs',onSelect=adapter.callback(function() state.ui.panel='nearby-profiles' render() end)},
            {label='Narrator',onSelect=adapter.callback(function() refreshSessionControls('narrator') end)},
        },onBack=adapter.callback(function() state.ui.panel='actor-tools' render() end),
        onClose=adapter.callback(function() state.ui.visible=false leaveUiMode() render() end)})
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
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Targeted NPC Tools',textSize=16,
            textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function() state.ui.panel='actor-tools' render() end)}}
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
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Targeted NPC Tools',textSize=16,
            textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=adapter.callback(function()
                state.ui.panel='actor-tools' render()
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
    local panelSizes={conversation={560,210},['actor-tools']={540,360},['profile-menu']={520,300},
        modes={540,390},models={580,420},profiles={580,420},narrator={580,330},
        ['nearby-profiles']={680,460},history={760,620},diagnostics={760,620}}
    local panelSize=panelSizes[state.ui.panel] or {680,460}
    local contentWidth=panelSize[1]-20
    local contentHeight=panelSize[2]-20
    local layout={layer='Windows',type=openmwUi.TYPE.Container,
        props={position=util.vector2(30,60),size=util.vector2(panelSize[1],panelSize[2])},content=openmwUi.content({
            {type=openmwUi.TYPE.Flex,props={horizontal=false,size=util.vector2(contentWidth,contentHeight)},content=openmwUi.content({
                {type=openmwUi.TYPE.Text,props={text='ALMSIVI  |  '..state.ui.status,textSize=16,
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

local function openPanel(panel)
    if not controlsAllowed() and not ownsUiMode then return end
    state.ui.panel=panel state.ui.visible=true
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

applySettings=function()
    local exterior=self.cell and self.cell.isExterior==true
    local session=nativeOk and native.sessionInfo and native.sessionInfo() or nil
    local controls=sessionControls()
    local effective=controls and state.ui.target and identity.same(controls.target,state.ui.target)
        and controls.effective_settings or nil
    local targetSettings=effective and effective.settings or {}
    local serverSafety=targetSettings.safety or {}
    local function restricted(localValue,serverValue,localDefault)
        if localValue==nil then localValue=localDefault end
        return localValue==true and serverValue==true
    end
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
            addHostile=restricted(autoSettings and autoSettings:get('addHostile'),serverSafety.allowHostile,false),
            addCreatures=restricted(autoSettings and autoSettings:get('addCreatures'),serverSafety.allowCreatures,false)},
        behavior={actionsEnabled=restricted(actionsEnabled,serverSafety.actionsEnabled,true),
            cancelDialogueOnCombat=behaviorSettings and behaviorSettings:get('cancelDialogueOnCombat')},
        presentation={showStatusHud=presentationSettings and presentationSettings:get('showStatusHud')==true,
            transcriptRows=tonumber(presentationSettings and presentationSettings:get('transcriptRows')) or 12,
            ttsVolumeBoost=tonumber(ttsVolumeBoost) or 3},
        narrator=targetSettings.narrator or {},memory=targetSettings.memory or {},
    }
    local auto=current.autoActivate or {}
    local behavior=current.behavior or {}
    local presentation=current.presentation or {}
    local signature=table.concat({tostring(auto.enabled),tostring(auto.interiorDistance),tostring(auto.exteriorDistance),
        tostring(auto.hearingDistance),tostring(auto.interiorHearingDistance),tostring(auto.exteriorHearingDistance),
        tostring(auto.addHostile),tostring(auto.addCreatures),tostring(behavior.actionsEnabled),
        tostring(behavior.cancelDialogueOnCombat),
        tostring(presentation.showStatusHud),tostring(presentation.transcriptRows),
        tostring(presentation.ttsVolumeBoost),tostring(effective and effective.change_token),tostring(session and session.config_revision)},'|')
    if signature==settingsSignature then return end
    settingsSignature=signature
    state.ui.statusHudVisible=presentation.showStatusHud==true
    state.ui.policy.transcriptRows=presentation.transcriptRows or 12
    send('ALMSIVI_SETTINGS_UPDATE',current)
    render()
end

if inputOk then
    input.registerTriggerHandler('ALMSIVI_Talk',adapter.callback(requestTalkToggle))
    input.registerTriggerHandler('ALMSIVI_StopDialogue',adapter.callback(function()
        send('ALMSIVI_STOP_DIALOGUE_REQUEST',{}) state.ui.status='dialogue stopped' render()
    end))
    input.registerTriggerHandler('ALMSIVI_Halt',adapter.callback(function()
        state.ui.pendingTargetAction=nil
        player.onAction(state,'ALMSIVI_Halt',send) state.ui.status='stopped' render()
    end))
    input.registerTriggerHandler('ALMSIVI_ManualActivate',adapter.callback(manualActivate))
    input.registerTriggerHandler('ALMSIVI_ActionsMenu',adapter.callback(function()
        if not confirmSecondaryTarget() then togglePanel('actor-tools') end
    end))
    input.registerTriggerHandler('ALMSIVI_MasterMenu',adapter.callback(function() togglePanel('actor-tools') end))
    input.registerTriggerHandler('ALMSIVI_ToggleMode',adapter.callback(function() togglePanel('modes') end))
    input.registerTriggerHandler('ALMSIVI_ModelMenu',adapter.callback(function()
        openPanel('models') refreshSessionControls('models')
    end))
    input.registerTriggerHandler('ALMSIVI_ProfileMenu',adapter.callback(function() togglePanel('profile-menu') end))
    input.registerTriggerHandler('ALMSIVI_StatusHud',adapter.callback(function()
        if not controlsAllowed() then return end
        state.ui.statusHudVisible=not state.ui.statusHudVisible
        if presentationSettings then presentationSettings:set('showStatusHud',state.ui.statusHudVisible) end
        render()
    end))
    input.registerTriggerHandler('ALMSIVI_History',adapter.callback(function() togglePanel('history') end))
    input.registerTriggerHandler('ALMSIVI_Diagnostics',adapter.callback(function() togglePanel('diagnostics') end))
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
            local statusChanged=notifications.update(notification,dt)
            local dialogueChanged=notifications.update(dialogueNotification,dt)
            if statusChanged or dialogueChanged then renderStatusHud() end
            applySettings()
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
                send('ALMSIVI_AUTO_ACTIVATE_SCAN',{candidates=candidates})
            end
            local controls=sessionControls()
            local signature=controls and table.concat({tostring(controls.selected_model_slot_id),tostring(controls.selected_profile_id),
                tostring(controls.effective_settings and controls.effective_settings.change_token),
                tostring(#(controls.model_slots or {})),tostring(#(controls.profiles or {})),tostring(controls.pending)},'|') or ''
            if signature~=controlsSignature then controlsSignature=signature
                if state.ui.visible and (state.ui.panel=='models' or state.ui.panel=='profiles') then render() end end
        end,
    },
    eventHandlers={
        DialogueResponse=function(event)
            local response=adapter.dialogueResponse(event)
            if response then send('ALMSIVI_VANILLA_DIALOGUE',response) end
        end,
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
                if pendingHistory then player.queued(state,pendingHistory.speaker,pendingHistory.text,event) end
                pendingHistory=nil
                state.ui.input=''
                state.ui.status='queued'
                state.ui.visible=false
                turnActive=true
                leaveUiMode()
                print('[ALMSIVI] text message accepted; chat closed')
            else
                state.ui.status='message failed: '..tostring(event.reason or 'unknown')
                turnActive=false
                pendingHistory=nil
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
            if controlPanel then refreshSessionControls(controlPanel)
            else
                refreshSessionControls(nil,true)
                if shouldSubmit then submitText() else render() end
            end
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
            if started and (not behaviorSettings or behaviorSettings:get('cancelDialogueOnCombat')~=false)
                and (turnActive or speechActive()) then
                send('ALMSIVI_STOP_DIALOGUE_REQUEST',{})
                turnActive=false
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
                if state.ui.visible and (state.ui.panel=='nearby-profiles' or state.ui.panel=='actor-tools') then render() end
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
        ALMSIVI_EVENT=function(event)
            if event.type=='turn.accepted' then turnActive=true end
            if (event.type=='dialogue.delta' or event.type=='dialogue.complete') and event.payload
                and type(event.payload.text)=='string' and event.payload.text~='' then
                local speaker=event.payload.speaker or state.ui.target
                local duration=event.type=='dialogue.complete'
                    and math.max(6,math.min(14,#event.payload.text/12)) or 4
                notifications.show(dialogueNotification,displayName(speaker)..': '..event.payload.text,duration)
            end
            if event.type=='turn.complete' or event.type=='turn.failed' or event.type=='turn.cancelled' then
                turnActive=false
            end
            player.event(state,event) render()
        end,
    },
}
