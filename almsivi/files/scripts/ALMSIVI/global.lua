local adapter=require('scripts.ALMSIVI.adapters.openmw')
local orchestrator=require('scripts.ALMSIVI.orchestrator')
local bridge=assert(adapter.bridge())
local core=adapter.event()
local interfacesOk,interfaces=pcall(require,'openmw.interfaces')
local typesOk,types=pcall(require,'openmw.types')
local worldOk,world=pcall(require,'openmw.world')
local state
local pendingPlayerEvents={}
local bridgeStatus
local bridgePollElapsed=0.05
local BRIDGE_POLL_INTERVAL=0.05

local function currentPlayer()
    if not worldOk or not world then return nil end
    local ok,players=pcall(function() return world.players end)
    return ok and players and players[1] or nil
end

-- Global events are inbound-only in OpenMW. Deliver orchestrator output directly to the player-local
-- ALMSIVI script, retaining a small bounded queue while a save is still attaching the player.
local function emit(name,payload)
    local player=currentPlayer()
    if player and player.sendEvent then
        player:sendEvent(name,payload)
        return true
    end
    if #pendingPlayerEvents>=64 then table.remove(pendingPlayerEvents,1) end
    pendingPlayerEvents[#pendingPlayerEvents+1]={name=name,payload=payload}
    return false
end

local function flushPlayerEvents(player)
    player=player or currentPlayer()
    if not player or not player.sendEvent then return false end
    for _,event in ipairs(pendingPlayerEvents) do player:sendEvent(event.name,event.payload) end
    pendingPlayerEvents={}
    return true
end

local function sendActor(actor,name,payload)
    local object=state and state.registry:resolve(actor)
    if not object or not object.sendEvent then return nil,'actor_inactive' end
    object:sendEvent(name,payload)
    return true
end
local function manageActor(actor,generation)
    local object=state and state.registry:resolve(actor)
    if not object then return nil,'actor_inactive' end
    local path='scripts/ALMSIVI/actor.lua'
    if actor.kind~='player' and object.hasScript and object.addScript then
        local attach={actor=actor,generation=generation,
            capabilities=bridge.capabilities and bridge.capabilities() or {}}
        if not object:hasScript(path) then object:addScript(path,attach)
        elseif object.sendEvent then object:sendEvent('ALMSIVI_ACTOR_ATTACH',attach) end
        return true
    end
    return nil,'actor_script_unavailable'
end
state=orchestrator.new(bridge,emit,sendActor,manageActor)
local configuredSession
local morrowindMonths={'Morning Star','Sun\'s Dawn','First Seed','Rain\'s Hand','Second Seed','Midyear',
    'Sun\'s Height','Last Seed','Hearthfire','Frostfall','Sun\'s Dusk','Evening Star'}

-- Calendar globals are authoritative only in global context. Add them immediately before the
-- immutable turn envelope is created so prompts receive Morrowind dates rather than wall-clock time.
local function enrichWorldCalendar(event)
    if type(event)~='table' or type(event.context)~='table' then return end
    event.context.world=type(event.context.world)=='table' and event.context.world or {}
    local player=currentPlayer()
    local mwscript=worldOk and world and world.mwscript
    if not player or not mwscript or type(mwscript.getGlobalVariables)~='function' then
        event.context.unavailable=type(event.context.unavailable)=='table' and event.context.unavailable or {}
        event.context.unavailable[#event.context.unavailable+1]='morrowind_calendar'
        return
    end
    local ok,variables=pcall(mwscript.getGlobalVariables,player)
    if not ok or not variables then return end
    local month=tonumber(variables.month)
    local hour=tonumber(variables.gamehour)
    event.context.world.calendar={year=tonumber(variables.year),month=month,
        month_name=month and morrowindMonths[month+1] or nil,day=tonumber(variables.day),
        days_passed=tonumber(variables.dayspassed),hour=hour,
        time=hour and string.format('%02d:%02d',math.floor(hour)%24,math.floor((hour%1)*60)) or nil}
end

-- Observe vanilla NPC/creature activation as a target hint without consuming or replacing the
-- standard Morrowind activation action. Dedicated ALMSIVI controls remain the primary input path.
local function observeActivatedActor(object,actor)
    if not typesOk or not types or not actor or actor.type~=types.Player then return end
    local candidate=adapter.candidate(object,2048,actor.position)
    if candidate and candidate.distance<=candidate.maxDistance and not candidate.dead and candidate.available~=false then
        orchestrator.activate(state,candidate.identity,object)
        orchestrator.selectTarget(state,candidate)
    end
end

local function boundedBookText(value,limit)
    local text=tostring(value or '')
    return #text>limit and text:sub(1,limit) or text
end

-- Observe vanilla book opening without consuming or replacing the normal Morrowind use action.
local function observeReadBook(object,actor)
    if not typesOk or not types or not actor or actor.type~=types.Player or not types.Book then return end
    local ok,record=pcall(types.Book.record,object)
    if not ok or not record then return end
    emit('ALMSIVI_BOOK_READ',{record_id=boundedBookText(record.id or object.recordId,512),
        title=boundedBookText(record.name,512),text=boundedBookText(record.text,8192),
        is_scroll=record.isScroll==true,skill=boundedBookText(record.skill,128)})
end

if interfacesOk and interfaces and interfaces.Activation and interfaces.Activation.addHandlerForType
    and typesOk and types then
    interfaces.Activation.addHandlerForType(types.NPC,observeActivatedActor)
    interfaces.Activation.addHandlerForType(types.Creature,observeActivatedActor)
    interfaces.Activation.addHandlerForType(types.Book,observeReadBook)
end

if interfacesOk and interfaces and interfaces.ItemUsage and interfaces.ItemUsage.addHandlerForType
    and typesOk and types and types.Book then
    interfaces.ItemUsage.addHandlerForType(types.Book,observeReadBook)
end

local function activate(object)
    local actor=adapter.identity(object)
    if actor then orchestrator.activate(state,actor,object) end
end

-- Lifecycle loading clears stale object handles, so rebuild the registry from OpenMW's current
-- active object lists before the player can select an actor from the freshly loaded cell.
local function activateWorldActors()
    if not worldOk or not world then return end
    local ok,actors=pcall(function() return world.activeActors end)
    if ok and actors then for _,object in ipairs(actors) do activate(object) end end
    local playersOk,players=pcall(function() return world.players end)
    if playersOk and players then for _,object in ipairs(players) do activate(object) end end
end

-- Provide a global fallback when the player-context camera and nearby APIs cannot produce a
-- serializable candidate. Global scripts can still authoritatively inspect active world actors.
local function nearestWorldCandidate(maxDistance)
    if not worldOk or not world then return nil,'world_actor_list_unavailable' end
    local actorsOk,actors=pcall(function() return world.activeActors end)
    local playersOk,players=pcall(function() return world.players end)
    if not actorsOk or not actors or not playersOk or not players then
        return nil,'world_actor_list_unavailable'
    end
    local player=players[1]
    if not player or not player.position then return nil,'player_position_unavailable' end
    local nearest
    for _,object in ipairs(actors) do
        if object~=player then
            local candidate=adapter.candidate(object,maxDistance,player.position)
            if candidate and candidate.distance<=candidate.maxDistance and not candidate.dead
                and candidate.available~=false and (not nearest or candidate.distance<nearest.distance) then
                nearest=candidate
            end
        end
    end
    if nearest then return nearest end
    return nil,'no_eligible_actor_nearby'
end

local function selectCandidate(candidate,source)
    activateWorldActors()
    local actor,reason=orchestrator.selectTarget(state,candidate)
    if actor then
        print('[ALMSIVI] target committed from '..tostring(source)..': '..tostring(actor.display_name))
        return actor
    end
    print('[ALMSIVI] target rejected from '..tostring(source)..': '..tostring(reason))
    emit('ALMSIVI_TARGET_REJECTED',{reason=reason})
end

return {
    engineHandlers={
        onNewGame=function()
            pendingPlayerEvents={}
            orchestrator.lifecycle(state,'new_game')
            activateWorldActors()
            flushPlayerEvents()
        end,
        onLoad=function(data)
            pendingPlayerEvents={}
            orchestrator.load(state,data)
            activateWorldActors()
            flushPlayerEvents()
        end,
        onSave=function() return orchestrator.save(state) end,
        onActorActive=activate,
        onPlayerAdded=function(object)
            activate(object)
            flushPlayerEvents(object)
        end,
        onUpdate=function(dt)
            bridgePollElapsed=bridgePollElapsed+(tonumber(dt) or 0)
            if bridgePollElapsed<BRIDGE_POLL_INTERVAL then return end
            bridgePollElapsed=0
            flushPlayerEvents()
            local session=bridge.sessionInfo and bridge.sessionInfo()
            -- Session initialization completes through the same inbound queue as gameplay events.
            -- Pump it before a cursored session exists so the initial handshake cannot deadlock.
            if not session and bridge.pollResults then
                bridge.pollResults(8)
                session=bridge.sessionInfo and bridge.sessionInfo()
            end
            local currentStatus=bridge.status and bridge.status()
            if currentStatus and currentStatus~=bridgeStatus then
                bridgeStatus=currentStatus
                local reason=bridge.lastError and bridge.lastError() or nil
                print('[ALMSIVI] native bridge status: '..tostring(currentStatus)
                    ..(reason and reason~='' and ' ('..tostring(reason)..')' or ''))
                if currentStatus=='error' or currentStatus=='unconfigured' then
                    emit('ALMSIVI_STATUS',{status=currentStatus,reason=reason})
                end
            end
            if session and session.session_id~=configuredSession then
                configuredSession=session.session_id
                state.generation=session.generation
                state.conversation.generation=session.generation
                orchestrator.configureSession(state,session.session_id)
            end
            if state.events then orchestrator.poll(state) end
            orchestrator.pollVoice(state)
            orchestrator.pollOpenMic(state)
        end,
    },
    eventHandlers={
        ALMSIVI_SESSION=function(event) orchestrator.configureSession(state,event.session_id) end,
        ALMSIVI_TARGET_REQUEST=function(event) emit('ALMSIVI_PLAYER_RESOLVE_TARGET',{maxDistance=event.maxDistance}) end,
        ALMSIVI_AUDIENCE_REQUEST=function(event) emit('ALMSIVI_PLAYER_RESOLVE_AUDIENCE',{maxDistance=event.maxDistance}) end,
        ALMSIVI_SELECT_TARGET=function(event) selectCandidate(event.candidate,'aimed_actor') end,
        ALMSIVI_SELECT_NEAREST_TARGET=function(event)
            local candidate,reason=nearestWorldCandidate(tonumber(event and event.maxDistance) or 2048)
            if candidate then selectCandidate(candidate,'nearest_active_actor')
            else
                print('[ALMSIVI] nearest target rejected: '..tostring(reason))
                emit('ALMSIVI_TARGET_REJECTED',{reason=reason})
            end
        end,
        ALMSIVI_ADD_AUDIENCE=function(event) orchestrator.addAudience(state,event.candidate) end,
        ALMSIVI_MANUAL_ACTIVATE_REQUEST=function(event)
            local actor,status=orchestrator.manageCandidate(state,event.candidate,'manual')
            emit('ALMSIVI_ACTIVATION_STATUS',{actor=actor,status=status})
        end,
        ALMSIVI_MANUAL_ACTIVATE_NEARBY_REQUEST=function(event)
            local added,retained=orchestrator.manageNearby(state,event.candidates)
            emit('ALMSIVI_ACTIVATION_STATUS',{status='nearby',added=added,retained=retained})
        end,
        ALMSIVI_AUTO_ACTIVATE_SCAN=function(event)
    orchestrator.scanAgents(state,event.candidates)
        end,
        ALMSIVI_ACTOR_COMBAT_STATUS=function(event) orchestrator.actorCombatStatus(state,event) end,
        ALMSIVI_CLEAR_AUDIENCE=function() orchestrator.clearAudience(state) end,
        ALMSIVI_SUBMIT_TEXT=function(event)
            enrichWorldCalendar(event)
            local metadata=bridge.nextTurnMetadata and bridge.nextTurnMetadata() or {}
            for key,value in pairs(metadata) do if event[key]==nil then event[key]=value end end
            if event.input_key==nil then event.input_key=event.request_id end
            local submitted,reason=orchestrator.submitText(state,event)
            if submitted then
                print('[ALMSIVI] text turn queued: '..tostring(event.request_id))
            else
                print('[ALMSIVI] text turn rejected: '..tostring(reason))
                emit('ALMSIVI_TURN',{status='failed',reason=reason})
            end
        end,
        ALMSIVI_HALT_REQUEST=function() orchestrator.interrupt(state,'halt_ai_actions') end,
        ALMSIVI_STOP_DIALOGUE_REQUEST=function() orchestrator.stopDialogue(state,'stop_dialogue') end,
        ALMSIVI_VOICE_START=function(event)
            print('[ALMSIVI] voice capture start event received')
            local started,reason=orchestrator.startVoice(state,event)
            if not started then
                print('[ALMSIVI] voice capture start rejected: '..tostring(reason))
                emit('ALMSIVI_VOICE_STATUS',{status='failed',reason=reason,continuous=false})
            else print('[ALMSIVI] voice capture started') end
        end,
        ALMSIVI_VOICE_STOP=function()
            local stopped,reason=orchestrator.stopVoice(state)
            if stopped then print('[ALMSIVI] voice capture stop requested')
            else print('[ALMSIVI] voice capture stop rejected: '..tostring(reason)) end
        end,
        ALMSIVI_OPEN_MIC_START=function(event)
            local started,reason=orchestrator.enableOpenMic(state,event)
            if not started then emit('ALMSIVI_VOICE_STATUS',{status='failed',reason=reason,continuous=true}) end
        end,
        ALMSIVI_OPEN_MIC_STOP=function() orchestrator.disableOpenMic(state) end,
        ALMSIVI_OPEN_MIC_MUTE=function() orchestrator.muteOpenMic(state) end,
        ALMSIVI_OPEN_MIC_CONTEXT=function(event) orchestrator.runOpenMicContext(state,event) end,
        ALMSIVI_HALT_ACTIONS_REQUEST=function() orchestrator.haltActions(state,'halt_ai_actions') end,
        ALMSIVI_HARD_HALT_REQUEST=function() orchestrator.hardHalt(state) end,
        ALMSIVI_SETTINGS_UPDATE=function(event) state.settings=event end,
        ALMSIVI_VANILLA_DIALOGUE=function(event) orchestrator.recordVanillaDialogue(state,event) end,
        ALMSIVI_MODE_CHANGED=function(event) state.dialogueMode=event.mode end,
        ALMSIVI_CONFIRM_ACTION=function(event) orchestrator.confirmAction(state,event.action_id,event.approved==true) end,
        ALMSIVI_ACTION_RESULT=function(event)
            local result=event and event.result
            if not result then return end
            local submitted,reason=bridge.submitActionResult and bridge.submitActionResult(result)
            emit('ALMSIVI_ACTION_STATUS',{name=event.action_name,status=result.status,reason=result.reason_code,
                submitted=submitted~=nil and submitted~=false,submit_reason=reason})
        end,
        ALMSIVI_SPEECH_STATUS=function(event)
            orchestrator.speechStatus(state,event)
            emit('ALMSIVI_SPEECH_STATUS',event)
        end,
    },
}
