local adapter=require('scripts.ALMSIVI.adapters.openmw')
local player=require('scripts.ALMSIVI.player_state')
local core=adapter.event()
local inputOk,input=pcall(require,'openmw.input')
local uiOk,openmwUi=pcall(require,'openmw.ui')
local utilOk,util=pcall(require,'openmw.util')
local self=require('openmw.self')
local state=player.new()
local element
local voiceRecording=false
local pttHeld=false
local openMicEnabled=false
local unpackValues=table.unpack or unpack
local function send(name,payload) if core and core.sendGlobalEvent then core.sendGlobalEvent(name,payload) end end
local CAPABILITIES={'dialogue.text','speech.say','speech.listen','action.ai.follow','action.ai.stop',
    'action.ai.wander','action.combat.start','action.combat.stop','action.inspect.report',
    'action.animation.play','action.item.equip','action.item.unequip','action.item.use'}

local function voicePayload(uiSource)
    return {speaker=adapter.identity(self),target=state.ui.target,context=adapter.playerContext(state.ui.target),
        language='en-US',capabilities=CAPABILITIES,recent_action_results={},ui_source=uiSource}
end

local function displayName(actor) return actor and actor.display_name or 'No target' end
local function audienceNames()
    local names={}
    for _,actor in ipairs(state.ui.audience or {}) do names[#names+1]=displayName(actor) end
    return #names>0 and table.concat(names,', ') or 'None'
end
local function render()
    if element then element:destroy() element=nil end
    if not state.ui.visible or not uiOk or not utilOk then return end
    local transcript={}
    for _,line in ipairs(state.ui.transcript) do
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=displayName(line.speaker)..': '..line.text,
            textColor=util.color.rgb(0.92,0.82,0.68),textSize=16}}
    end
    if state.ui.subtitle then
        transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=displayName(state.ui.subtitle.speaker)..': '..state.ui.subtitle.text,
            textColor=util.color.rgb(1.0,0.58,0.18),textSize=16}}
    end
    local submit=function()
        local text=state.ui.input
        if not text or text:match('^%s*$') or not state.ui.target then return end
        local speaker=adapter.identity(self)
        send('ALMSIVI_SUBMIT_TEXT',{text=text,input_key=text,language='en-US',speaker=speaker,
            context=adapter.playerContext(state.ui.target),capabilities=CAPABILITIES,
            recent_action_results={},ui_source='almsivi_text'})
        state.ui.input='' state.ui.status='queued' render()
    end
    transcript[#transcript+1]={type=openmwUi.TYPE.TextEdit,props={text=state.ui.input,size=util.vector2(620,42),
        multiline=false,textSize=18,textColor=util.color.rgb(0.95,0.9,0.82)},events={textChanged=adapter.callback(function(text) state.ui.input=text end)}}
    transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Send',textSize=18,textColor=util.color.rgb(1.0,0.58,0.18)},
        events={mouseClick=adapter.callback(submit)}}
    transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Add aimed NPC to group',textSize=16,textColor=util.color.rgb(1.0,0.58,0.18)},
        events={mouseClick=adapter.callback(function() send('ALMSIVI_AUDIENCE_REQUEST',{maxDistance=2048}) end)}}
    transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text='Reset group to target',textSize=16,textColor=util.color.rgb(1.0,0.58,0.18)},
        events={mouseClick=adapter.callback(function() send('ALMSIVI_CLEAR_AUDIENCE',{}) end)}}
    transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=voiceRecording and 'Stop voice recording' or 'Start voice recording',textSize=16,
        textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=adapter.callback(function()
            if openMicEnabled then openMicEnabled=false send('ALMSIVI_OPEN_MIC_STOP',{}) end
            voiceRecording=not voiceRecording
            if voiceRecording then
                if not state.ui.target then voiceRecording=false state.ui.status='target required'
                else send('ALMSIVI_VOICE_START',voicePayload('almsivi_voice')) end
            else send('ALMSIVI_VOICE_STOP',{}) end
            render()
        end)}}
    transcript[#transcript+1]={type=openmwUi.TYPE.Text,props={text=openMicEnabled and 'Open mic: ON (voice activated)' or 'Open mic: Off',textSize=16,
        textColor=openMicEnabled and util.color.rgb(0.45,0.9,0.45) or util.color.rgb(1.0,0.58,0.18)},
        events={mouseClick=adapter.callback(function()
            if not openMicEnabled and not state.ui.target then state.ui.status='target required' render() return end
            openMicEnabled=not openMicEnabled voiceRecording=openMicEnabled
            if openMicEnabled then send('ALMSIVI_OPEN_MIC_START',voicePayload('almsivi_open_mic'))
            else send('ALMSIVI_OPEN_MIC_STOP',{}) end
            render()
        end)}}
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
                {type=openmwUi.TYPE.Text,props={text='ALMSIVI  |  '..state.ui.status,textSize=22,textColor=util.color.rgb(1.0,0.45,0.08)}},
                {type=openmwUi.TYPE.Text,props={text='Target: '..displayName(state.ui.target),textSize=18,textColor=util.color.rgb(0.95,0.9,0.82)}},
                {type=openmwUi.TYPE.Text,props={text='Group: '..audienceNames(),textSize=16,textColor=util.color.rgb(0.82,0.78,0.72)}},
                unpackValues(transcript),
            })},
        })})
end

local function chooseTarget(maxDistance)
    local candidate,reason=adapter.resolveCameraTarget(maxDistance or 2048)
    if candidate then send('ALMSIVI_SELECT_TARGET',{candidate=candidate})
    else state.ui.diagnostics=reason state.ui.status='target unavailable' end
    render()
end

local function chooseAudience(maxDistance)
    local candidate,reason=adapter.resolveCameraTarget(maxDistance or 2048)
    if candidate then send('ALMSIVI_ADD_AUDIENCE',{candidate=candidate})
    else state.ui.diagnostics=reason state.ui.status='group actor unavailable' end
    render()
end

local function toggleTalk()
    state.ui.visible=not state.ui.visible
    if state.ui.visible then chooseTarget(2048) else render() end
end

if inputOk then
    input.registerTriggerHandler('ALMSIVI_Talk',adapter.callback(toggleTalk))
    input.registerTriggerHandler('ALMSIVI_Halt',adapter.callback(function() player.onAction(state,'ALMSIVI_Halt',send) render() end))
    input.registerTriggerHandler('ALMSIVI_OpenMic',adapter.callback(function()
        if not openMicEnabled and not state.ui.target then chooseTarget(2048) return end
        openMicEnabled=not openMicEnabled voiceRecording=openMicEnabled
        if openMicEnabled then send('ALMSIVI_OPEN_MIC_START',voicePayload('almsivi_open_mic'))
        else send('ALMSIVI_OPEN_MIC_STOP',{}) end
        render()
    end))
end

return {
    engineHandlers={
        onInputAction=function(action) return player.onAction(state,action,send) end,
        onUpdate=function()
            if not inputOk or not input.getBooleanActionValue then return end
            local held=input.getBooleanActionValue('ALMSIVI_PushToTalk')==true
            if held==pttHeld then return end
            pttHeld=held
            if held then
                if not state.ui.target then chooseTarget(2048) pttHeld=false return end
                if openMicEnabled then openMicEnabled=false send('ALMSIVI_OPEN_MIC_STOP',{}) end
                voiceRecording=true
                send('ALMSIVI_VOICE_START',voicePayload('almsivi_voice'))
            else voiceRecording=false send('ALMSIVI_VOICE_STOP',{}) end
            render()
        end,
    },
    eventHandlers={
        ALMSIVI_STATUS=function(event) state.ui.status=event.status state.ui.diagnostics=event.reason render() end,
        ALMSIVI_PLAYER_RESOLVE_TARGET=function(event) chooseTarget(event.maxDistance) end,
        ALMSIVI_PLAYER_RESOLVE_AUDIENCE=function(event) chooseAudience(event.maxDistance) end,
        ALMSIVI_TARGET=function(event) state.ui.target=event.target state.ui.audience=event.audience or {event.target} render() end,
        ALMSIVI_AUDIENCE=function(event) state.ui.target=event.target state.ui.audience=event.audience or {} render() end,
        ALMSIVI_ACTION_CONFIRMATION=function(event) state.ui.pendingAction=event state.ui.visible=true render() end,
        ALMSIVI_VOICE_STATUS=function(event)
            state.ui.status=event.status
            if event.status=='failed' or event.status=='queued' then voiceRecording=false end
            if event.status=='open mic off' or (event.status=='failed' and event.continuous) then openMicEnabled=false end
            state.ui.diagnostics=event.reason render()
        end,
        ALMSIVI_OPEN_MIC_CONTEXT_REQUEST=function()
            if not openMicEnabled or not state.ui.target then return end
            send('ALMSIVI_OPEN_MIC_CONTEXT',voicePayload('almsivi_open_mic'))
        end,
        ALMSIVI_AUTONOMY_CONTEXT_REQUEST=function(event)
            if not state.ui.target then return end
            send('ALMSIVI_AUTONOMY_CONTEXT',{directive=event.directive,speaker=adapter.identity(self),
                context=adapter.playerContext(state.ui.target),language='en-US',capabilities=CAPABILITIES,
                recent_action_results={}})
        end,
        ALMSIVI_AUTONOMY_STATUS=function(event)
            if event.status~='skipped' then state.ui.status='autonomy '..event.status render() end
        end,
        ALMSIVI_EVENT=function(event) player.event(state,event) render() end,
    },
}
