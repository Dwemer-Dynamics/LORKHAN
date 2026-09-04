local adapter=require('scripts.LORKHAN.adapters.openmw')
local orchestrator=require('scripts.LORKHAN.orchestrator')
local bridge=assert(adapter.bridge())
local core=adapter.event()
local interfacesOk,interfaces=pcall(require,'openmw.interfaces')
local typesOk,types=pcall(require,'openmw.types')
local worldOk,world=pcall(require,'openmw.world')
local worldUtilOk,worldUtil=pcall(require,'openmw.util')
local state
local pendingPlayerEvents={}
local bridgeStatus
local bridgePollElapsed=0.05
local lastBridgePollAt
local BRIDGE_POLL_INTERVAL=0.05

local function currentPlayer()
    if not worldOk or not world then return nil end
    local ok,players=pcall(function() return world.players end)
    return ok and players and players[1] or nil
end

-- Global events are inbound-only in OpenMW. Deliver orchestrator output directly to the player-local
-- LORKHAN script, retaining a small bounded queue while a save is still attaching the player.
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
    local path='scripts/LORKHAN/actor.lua'
    if actor.kind~='player' and object.hasScript and object.addScript then
        local attach={actor=actor,generation=generation,
            capabilities=bridge.capabilities and bridge.capabilities() or {}}
        if not object:hasScript(path) then object:addScript(path,attach)
        elseif object.sendEvent then object:sendEvent('LORKHAN_ACTOR_ATTACH',attach) end
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
-- standard Morrowind activation action. Dedicated LORKHAN controls remain the primary input path.
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
    emit('LORKHAN_BOOK_READ',{record_id=boundedBookText(record.id or object.recordId,512),
        title=boundedBookText(record.name,512),text=boundedBookText(record.text,16384),
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
        print('[LORKHAN] target committed from '..tostring(source)..': '..tostring(actor.display_name))
        return actor
    end
    print('[LORKHAN] target rejected from '..tostring(source)..': '..tostring(reason))
    emit('LORKHAN_TARGET_REJECTED',{reason=reason})
end

local function inventoryCount(inventory,recordId)
    local total=0
    for _,item in ipairs(inventory:getAll()) do
        if item.recordId==recordId then total=total+(tonumber(item.count) or 1) end
    end
    return total
end

-- Execute only the typed operator commands negotiated by the native bridge; command text is never evaluated.
local function executeGlobalDebugCommand(command)
    if type(command)~='table' or type(command.name)~='string' then return 'rejected','invalid_command',{} end
    if not worldOk or not world or not typesOk or not types then return 'rejected','world_api_unavailable',{} end
    local player=currentPlayer()
    if not player then return 'failed','player_unavailable',{} end
    local parameters=type(command.parameters)=='table' and command.parameters or {}
    local ok,result=pcall(function()
        local name=command.name
        local actorType=types.Actor
        if name=='player.inventory.add' then
            local inventory=actorType.inventory(player)
            world.createObject(parameters.record_id,parameters.count):moveInto(inventory)
            return {record_id=parameters.record_id,count=inventoryCount(inventory,parameters.record_id)}
        elseif name=='player.inventory.remove' then
            local inventory=actorType.inventory(player)
            local remaining=parameters.count
            for _,item in ipairs(inventory:getAll()) do
                if item.recordId==parameters.record_id and remaining>0 then
                    local removed=math.min(remaining,tonumber(item.count) or 1)
                    item:remove(removed);remaining=remaining-removed
                end
            end
            if remaining>0 then return {rejected=true,reason='insufficient_item_count',
                observed={record_id=parameters.record_id,count=inventoryCount(inventory,parameters.record_id)}} end
            return {record_id=parameters.record_id,count=inventoryCount(inventory,parameters.record_id)}
        elseif name=='player.spell.add' or name=='player.spell.remove' then
            local spells=actorType.spells(player)
            if name=='player.spell.add' then spells:add(parameters.record_id) else spells:remove(parameters.record_id) end
            return {record_id=parameters.record_id,operation=name}
        elseif name=='player.vitals.restore' then
            local observed={}
            for _,statName in ipairs({'health','magicka','fatigue'}) do
                local stat=actorType.stats.dynamic[statName](player);stat.current=stat.base;observed[statName]=stat.base
            end
            return observed
        elseif name=='player.stat.set' then
            local stat=actorType.stats.dynamic[parameters.stat](player);stat.current=parameters.value
            return {stat=parameters.stat,current=parameters.value,base=stat.base}
        elseif name=='player.attribute.set' then
            local stat=actorType.stats.attributes[parameters.attribute](player);stat.base=parameters.value
            return {attribute=parameters.attribute,base=parameters.value}
        elseif name=='player.skill.set' then
            local stat=types.NPC.stats.skills[parameters.skill](player);stat.base=parameters.value
            return {skill=parameters.skill,base=parameters.value}
        elseif name=='player.level.set' then
            local stat=actorType.stats.level(player);stat.current=parameters.value
            return {level=parameters.value}
        elseif name=='player.bounty.set' then
            types.Player.setCrimeLevel(player,parameters.value);return {bounty=types.Player.getCrimeLevel(player)}
        elseif name=='player.scale.set' then
            player:setScale(parameters.value);return {scale=parameters.value}
        elseif name=='player.teleport' then
            if not worldUtilOk or not worldUtil then error('vector_api_unavailable') end
            player:teleport(parameters.cell,worldUtil.vector3(parameters.x,parameters.y,parameters.z),{onGround=true})
            return {cell=parameters.cell,x=parameters.x,y=parameters.y,z=parameters.z}
        elseif name=='world.time.advance' then
            world.advanceTime(parameters.value);return {hours_advanced=parameters.value}
        elseif name=='world.timescale.set' then
            world.setGameTimeScale(parameters.value);return {timescale=world.getGameTimeScale()}
        elseif name=='world.weather.set' then
            local weather=core.weather and core.weather.records[parameters.weather]
            if not weather then return {rejected=true,reason='weather_record_not_found',observed={}} end
            core.weather.changeWeather(parameters.region_id,weather)
            return {region_id=parameters.region_id,weather=weather.recordId or parameters.weather}
        elseif name=='target.actor.kill' or name=='target.actor.restore' or name=='target.scale.set'
            or name=='target.teleport.to_player' then
            local target=state.conversation.target and state.registry:resolve(state.conversation.target)
            if not target then return {rejected=true,reason='target_required',observed={}} end
            if name=='target.actor.kill' then
                actorType.stats.dynamic.health(target).current=0;return {target=target.recordId,health=0}
            elseif name=='target.actor.restore' then
                local observed={target=target.recordId}
                for _,statName in ipairs({'health','magicka','fatigue'}) do
                    local stat=actorType.stats.dynamic[statName](target);stat.current=stat.base;observed[statName]=stat.base
                end
                return observed
            elseif name=='target.scale.set' then
                target:setScale(parameters.value);return {target=target.recordId,scale=parameters.value}
            else
                target:teleport(player.cell,player.position,{onGround=true})
                return {target=target.recordId,cell=player.cell and player.cell.name or ''}
            end
        end
        return nil
    end)
    if not ok then return 'failed','execution_failed',{error=tostring(result):sub(1,256)} end
    if result==nil then return 'rejected','unknown_command',{} end
    if result.rejected then return 'rejected',result.reason,result.observed or {} end
    return 'succeeded','command_applied',result
end

local function handleGlobalDebugCommand(event)
    local command=event and event.command
    local status,reason,observed=executeGlobalDebugCommand(command)
    emit('LORKHAN_DEBUG_COMMAND_RESULT',{command_id=command and command.command_id,status=status,
        reason_code=reason,observed=observed})
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
            local elapsed=tonumber(dt) or 0
            if core and core.getRealTime then
                local now=core.getRealTime()
                if lastBridgePollAt then elapsed=math.max(0,now-lastBridgePollAt) end
                lastBridgePollAt=now
            end
            bridgePollElapsed=bridgePollElapsed+elapsed
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
                print('[LORKHAN] native bridge status: '..tostring(currentStatus)
                    ..(reason and reason~='' and ' ('..tostring(reason)..')' or ''))
                if currentStatus=='error' or currentStatus=='unconfigured' then
                    emit('LORKHAN_STATUS',{status=currentStatus,reason=reason})
                end
            end
            if session and session.session_id~=configuredSession then
                configuredSession=session.session_id
                state.generation=session.generation
                state.conversation.generation=session.generation
                orchestrator.configureSession(state,session.session_id)
            end
            if state.events then orchestrator.poll(state) end
            orchestrator.pollRechatEligibility(state,BRIDGE_POLL_INTERVAL)
            orchestrator.runAutonomy(state,BRIDGE_POLL_INTERVAL)
            orchestrator.pollVoice(state)
            orchestrator.pollOpenMic(state)
        end,
    },
    eventHandlers={
        LORKHAN_DEBUG_COMMAND=handleGlobalDebugCommand,
        LORKHAN_SESSION=function(event) orchestrator.configureSession(state,event.session_id) end,
        LORKHAN_TARGET_REQUEST=function(event) emit('LORKHAN_PLAYER_RESOLVE_TARGET',{maxDistance=event.maxDistance}) end,
        LORKHAN_AUDIENCE_REQUEST=function(event) emit('LORKHAN_PLAYER_RESOLVE_AUDIENCE',{maxDistance=event.maxDistance}) end,
        LORKHAN_SELECT_TARGET=function(event) selectCandidate(event.candidate,'aimed_actor') end,
        LORKHAN_SELECT_NEAREST_TARGET=function(event)
            local candidate,reason=nearestWorldCandidate(tonumber(event and event.maxDistance) or 2048)
            if candidate then selectCandidate(candidate,'nearest_active_actor')
            else
                print('[LORKHAN] nearest target rejected: '..tostring(reason))
                emit('LORKHAN_TARGET_REJECTED',{reason=reason})
            end
        end,
        LORKHAN_ADD_AUDIENCE=function(event) orchestrator.addAudience(state,event.candidate) end,
        LORKHAN_MANUAL_ACTIVATE_REQUEST=function(event)
            local actor,status=orchestrator.manageCandidate(state,event.candidate,'manual')
            emit('LORKHAN_ACTIVATION_STATUS',{actor=actor,status=status})
        end,
        LORKHAN_MANUAL_ACTIVATE_NEARBY_REQUEST=function(event)
            local added,retained=orchestrator.manageNearby(state,event.candidates)
            emit('LORKHAN_ACTIVATION_STATUS',{status='nearby',added=added,retained=retained})
        end,
        LORKHAN_AUTO_ACTIVATE_SCAN=function(event)
    orchestrator.scanAgents(state,event.candidates)
        end,
        LORKHAN_ACTOR_COMBAT_STATUS=function(event) orchestrator.actorCombatStatus(state,event) end,
        LORKHAN_CLEAR_AUDIENCE=function() orchestrator.clearAudience(state) end,
        LORKHAN_SUBMIT_TEXT=function(event)
            enrichWorldCalendar(event)
            local metadata=bridge.nextTurnMetadata and bridge.nextTurnMetadata() or {}
            for key,value in pairs(metadata) do if event[key]==nil then event[key]=value end end
            if event.input_key==nil then event.input_key=event.request_id end
            local submitted,reason=orchestrator.submitText(state,event)
            if submitted then
                print('[LORKHAN] text turn queued: '..tostring(event.request_id))
            else
                print('[LORKHAN] text turn rejected: '..tostring(reason))
                emit('LORKHAN_TURN',{status='failed',reason=reason})
            end
        end,
        LORKHAN_HALT_REQUEST=function() orchestrator.interrupt(state,'halt_ai_actions') end,
        LORKHAN_STOP_DIALOGUE_REQUEST=function() orchestrator.stopDialogue(state,'stop_dialogue') end,
        LORKHAN_VOICE_START=function(event)
            print('[LORKHAN] voice capture start event received')
            local started,reason=orchestrator.startVoice(state,event)
            if not started then
                print('[LORKHAN] voice capture start rejected: '..tostring(reason))
                emit('LORKHAN_VOICE_STATUS',{status='failed',reason=reason,continuous=false})
            else print('[LORKHAN] voice capture started') end
        end,
        LORKHAN_VOICE_STOP=function()
            local stopped,reason=orchestrator.stopVoice(state)
            if stopped then print('[LORKHAN] voice capture stop requested')
            else print('[LORKHAN] voice capture stop rejected: '..tostring(reason)) end
        end,
        LORKHAN_OPEN_MIC_START=function(event)
            local started,reason=orchestrator.enableOpenMic(state,event)
            if not started then emit('LORKHAN_VOICE_STATUS',{status='failed',reason=reason,continuous=true}) end
        end,
        LORKHAN_OPEN_MIC_STOP=function() orchestrator.disableOpenMic(state) end,
        LORKHAN_OPEN_MIC_MUTE=function() orchestrator.muteOpenMic(state) end,
        LORKHAN_OPEN_MIC_CONTEXT=function(event) orchestrator.runOpenMicContext(state,event) end,
        LORKHAN_HALT_ACTIONS_REQUEST=function() orchestrator.haltActions(state,'halt_ai_actions') end,
        LORKHAN_HARD_HALT_REQUEST=function() orchestrator.hardHalt(state) end,
        LORKHAN_SETTINGS_UPDATE=function(event) state.settings=event end,
        LORKHAN_NARRATOR_EVENT_CANDIDATE=function(event)
            if type(event)=='table' then orchestrator.queueNarratorEvent(state,event.kind,event.context_actor,event.cooldown_ready) end
        end,
        LORKHAN_VANILLA_DIALOGUE=function(event) orchestrator.recordVanillaDialogue(state,event) end,
        LORKHAN_MENU_DIALOGUE_SPEAK=function(event)
            if type(event)~='table' or type(event.actor)~='table' or type(event.media_id)~='string' then return end
            local managed,reason=manageActor(event.actor,state.generation)
            if managed then
                event.generation=state.generation
                local sent,sendReason=sendActor(event.actor,'LORKHAN_MENU_DIALOGUE_SPEAK',event)
                if sent then return end
                reason=sendReason
            end
            if bridge.releaseMedia then bridge.releaseMedia(event.media_id) end
            emit('LORKHAN_MENU_DIALOGUE_SPEECH_STATUS',{actor=event.actor,request_id=event.request_id,
                media_id=event.media_id,active=false,status='failed',reason=reason or 'actor_speech_unavailable'})
        end,
        LORKHAN_MENU_DIALOGUE_STOP=function(event)
            if type(event)=='table' and type(event.actor)=='table' then
                sendActor(event.actor,'LORKHAN_MENU_DIALOGUE_STOP',event)
            end
        end,
        LORKHAN_MODE_CHANGED=function(event) state.dialogueMode=event.mode end,
        LORKHAN_CONFIRM_ACTION=function(event) orchestrator.confirmAction(state,event.action_id,event.approved==true) end,
        LORKHAN_ACTION_RESULT=function(event)
            local result=event and event.result
            if not result then return end
            local submitted,reason=bridge.submitActionResult and bridge.submitActionResult(result)
            local queued,queueReason=orchestrator.actionResult(state,event)
            emit('LORKHAN_ACTION_STATUS',{name=event.action_name,status=result.status,reason=result.reason_code,
                submitted=submitted~=nil and submitted~=false,submit_reason=reason,
                queue_completed=queued==true,queue_reason=queueReason})
        end,
        LORKHAN_SPEECH_STATUS=function(event)
            orchestrator.speechStatus(state,event)
            emit('LORKHAN_SPEECH_STATUS',event)
        end,
        LORKHAN_MENU_DIALOGUE_SPEECH_STATUS=function(event)
            emit('LORKHAN_MENU_DIALOGUE_SPEECH_STATUS',event)
        end,
    },
}
