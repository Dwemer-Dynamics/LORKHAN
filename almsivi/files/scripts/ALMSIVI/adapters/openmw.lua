local M = {}
local recentBooks = {}

local function optional(name)
    local ok, value = pcall(require, name)
    if ok then return value end
    return nil
end

local function loaded()
    return {
        animation=optional('openmw.animation'), async=optional('openmw.async'), camera=optional('openmw.camera'),
        core=optional('openmw.core'), input=optional('openmw.input'),
        interfaces=optional('openmw.interfaces'), nearby=optional('openmw.nearby'),
        self=optional('openmw.self'), types=optional('openmw.types'),
        ui=optional('openmw.ui'), util=optional('openmw.util'),
    }
end

function M.bridge()
    local ok, bridge = pcall(require, 'openmw.almsivi')
    if not ok then return nil, 'native_bridge_unavailable' end
    return bridge
end

function M.event()
    local ok, core = pcall(require, 'openmw.core')
    if not ok then return nil end
    return core
end

function M.ui()
    local ok, ui = pcall(require, 'openmw.ui')
    if not ok then return nil end
    return ui
end

-- Retain a bounded, deduplicated list of books explicitly opened by the player this session.
function M.rememberBook(book)
    if type(book)~='table' or type(book.record_id)~='string' or book.record_id=='' then return false end
    for index=#recentBooks,1,-1 do
        if recentBooks[index].record_id==book.record_id then table.remove(recentBooks,index) end
    end
    recentBooks[#recentBooks+1]={record_id=book.record_id,title=book.title,text=book.text,
        is_scroll=book.is_scroll==true,skill=book.skill}
    while #recentBooks>8 do table.remove(recentBooks,1) end
    return true
end

function M.callback(fn)
    local async=optional('openmw.async')
    if async and async.callback then return async:callback(fn) end
    return fn
end

-- Convert API-129 objects to the stable identity carried on the ALMSIVI wire. OpenMW exposes the
-- unique player as @0x1 rather than a content-file RefNum; all other dynamic objects remain ineligible.
function M.identity(object, modules)
    modules=modules or loaded()
    if not object or not modules.types or not modules.core or type(object.id)~='string' then
        return nil,'object_identity_unavailable'
    end
    local kind
    if modules.types.Player and modules.types.Player.objectIsInstance(object) then kind='player'
    elseif modules.types.NPC and modules.types.NPC.objectIsInstance(object) then kind='npc'
    elseif modules.types.Creature and modules.types.Creature.objectIsInstance(object) then kind='creature'
    else return nil,'object_not_actor' end
    local hex=object.id:match('^0x([0-9a-fA-F]+)$')
    local formId=hex and tonumber(hex,16) or nil
    local specialPlayer=kind=='player' and object.id:match('^@0x[0-9a-fA-F]+$')~=nil
    if not formId and not specialPlayer then return nil,'dynamic_actor_identity_unsupported' end
    local contentIndex=specialPlayer and 0 or math.floor(formId / 0x1000000)
    local refnumIndex=specialPlayer and 0 or formId%0x1000000
    local contentFiles=modules.core.contentFiles and modules.core.contentFiles.list or {}
    local contentFile=contentFiles[contentIndex+1] or object.contentFile
    if type(contentFile)~='string' or contentFile=='' then return nil,'content_file_unavailable' end
    local cell=object.cell
    if not cell then return nil,'actor_cell_unavailable' end
    local cellIdentity
    if cell.isExterior then
        cellIdentity={kind='exterior',grid_x=cell.gridX,grid_y=cell.gridY}
    else
        local name=cell.name~='' and cell.name or cell.displayName
        if type(name)~='string' or name=='' then return nil,'interior_name_unavailable' end
        cellIdentity={kind='interior',name=name}
    end
    local display=object.recordId
    if (kind=='npc' or kind=='player') and modules.types.NPC.record then
        local ok,record=pcall(modules.types.NPC.record,object)
        if ok and record and type(record.name)=='string' and record.name~='' then display=record.name end
    elseif kind=='creature' and modules.types.Creature.record then
        local ok,record=pcall(modules.types.Creature.record,object)
        if ok and record and type(record.name)=='string' and record.name~='' then display=record.name end
    end
    return {kind=kind,record_id=object.recordId,refnum={index=refnumIndex,content_file=contentIndex},
        content_file=contentFile,cell=cellIdentity,display_name=display}
end

-- Convert the player-local OpenMW DialogueResponse event into bounded serializable context.
function M.dialogueResponse(event, modules)
    modules=modules or loaded()
    if type(event)~='table' or not modules.core then return nil,'dialogue_event_unavailable' end
    local dialogueType=event.type
    if not ({greeting=true,journal=true,persuasion=true,topic=true,voice=true})[dialogueType] then
        return nil,'dialogue_type_unavailable'
    end
    if type(event.recordId)~='string' or type(event.infoId)~='string' then
        return nil,'dialogue_identity_unavailable'
    end
    local actor,reason=M.identity(event.actor,modules)
    if not actor then return nil,reason end
    local records=modules.core.dialogue and modules.core.dialogue[dialogueType]
        and modules.core.dialogue[dialogueType].records
    local record=records and records[event.recordId]
    if not record or not record.infos then return nil,'dialogue_record_unavailable' end
    local text
    for _,info in pairs(record.infos) do
        if info.id==event.infoId and type(info.text)=='string' then text=info.text break end
    end
    if not text or text=='' then return nil,'dialogue_info_unavailable' end
    if #text>4096 then text=text:sub(1,4096) end
    local gameTime
    if modules.core.getGameTime then
        local ok,value=pcall(modules.core.getGameTime)
        if ok and type(value)=='number' then gameTime=value end
    end
    return {source='openmw.DialogueResponse',actor=actor,dialogue_type=dialogueType,
        record_id=event.recordId:sub(1,256),info_id=event.infoId:sub(1,256),text=text,
        captured_game_time=gameTime}
end

function M.resolve(identity, modules)
    modules=modules or loaded()
    if not identity or not modules.core or not modules.nearby then return nil,'resolver_unavailable' end
    if identity.kind=='player' then
        local player=modules.nearby.players and modules.nearby.players[1]
        if not player or (player.isValid and not player:isValid()) then return nil,'actor_inactive' end
        return player
    end
    local ok,formId=pcall(modules.core.getFormId,identity.content_file,identity.refnum.index)
    if not ok then return nil,'invalid_form_id' end
    local object=modules.nearby.getObjectByFormId(formId)
    if not object or (object.isValid and not object:isValid()) then return nil,'actor_inactive' end
    return object
end

function M.candidate(object, maxDistance, origin, modules)
    modules=modules or loaded()
    local actor,reason=M.identity(object,modules)
    if not actor then return nil,reason end
    local distance=origin and object.position and (object.position-origin):length() or 0
    local dead=false
    if modules.types and modules.types.Actor and modules.types.Actor.isDead then
        local ok,value=pcall(modules.types.Actor.isDead,object)
        dead=ok and value or false
    end
    return {identity=actor,distance=distance,maxDistance=maxDistance,dead=dead,hostile=false,
        available=object.enabled~=false}
end

-- Resolve only the actor collision ray. This path is safe for periodic player-context aim previews
-- and avoids the synchronous rendering-ray restriction outside direct input handlers.
function M.resolveActorRay(maxDistance, modules)
    modules=modules or loaded()
    maxDistance=maxDistance or 2048
    if not modules.camera or not modules.nearby or not modules.util or not modules.self then
        return nil,'camera_targeting_unavailable'
    end
    local origin=modules.camera.getPosition()
    local direction=modules.camera.viewportToWorldVector(modules.util.vector2(0.5,0.5)):normalize()
    local destination=origin+direction*maxDistance

    -- Prefer the actor collision shape so a loose item rendered in front of an NPC does not steal
    -- the conversation target. Verify the actor is not hidden behind normal world collision.
    if modules.nearby.castRay and modules.nearby.COLLISION_TYPE then
        local actorHit=modules.nearby.castRay(origin,destination,{ignore=modules.self,
            collisionType=modules.nearby.COLLISION_TYPE.Actor})
        if actorHit and actorHit.hitObject then
            local visible=true
            if actorHit.hitPos then
                local blocker=modules.nearby.castRay(origin,actorHit.hitPos,{ignore=modules.self})
                visible=not blocker or not blocker.hit or blocker.hitObject==actorHit.hitObject
                    or (blocker.hitPos and (blocker.hitPos-actorHit.hitPos):length()<4)
            end
            if visible then
                local actor=M.candidate(actorHit.hitObject,maxDistance,origin,modules)
                if actor then return actor end
            end
        end
    end
    return nil,'no_actor_under_crosshair'
end

function M.resolveCameraTarget(maxDistance, modules)
    modules=modules or loaded()
    maxDistance=maxDistance or 2048
    local actor=M.resolveActorRay(maxDistance,modules)
    if actor then return actor end
    if not modules.camera or not modules.nearby or not modules.util or not modules.self then
        return nil,'camera_targeting_unavailable'
    end
    local origin=modules.camera.getPosition()
    local direction=modules.camera.viewportToWorldVector(modules.util.vector2(0.5,0.5)):normalize()
    local destination=origin+direction*maxDistance

    local hit=modules.nearby.castRenderingRay(origin,destination,{ignore=modules.self})
    if not hit or not hit.hitObject then return nil,'no_actor_under_crosshair' end
    local actor,reason=M.candidate(hit.hitObject,maxDistance,origin,modules)
    if not actor then return nil,reason or 'no_actor_under_crosshair' end
    return actor
end

function M.actorDistance(targetIdentity, modules)
    modules=modules or loaded()
    local object=M.resolve(targetIdentity,modules)
    if not object or not object.position or not modules.self or not modules.self.position then return nil end
    return (object.position-modules.self.position):length()
end

-- Produce the same compact cell key on player and actor scripts so a captured destination
-- cannot be replayed after either side moves to another OpenMW cell.
function M.cellKey(cell)
    if not cell then return nil end
    if cell.isExterior then
        if type(cell.gridX)~='number' or type(cell.gridY)~='number' then return nil end
        return 'exterior:'..tostring(cell.gridX)..':'..tostring(cell.gridY)
    end
    local name=cell.name~='' and cell.name or cell.displayName
    if type(name)~='string' or name=='' then return nil end
    return 'interior:'..name
end

-- Capture a bounded point under the crosshair during an input callback. Movement actions are
-- therefore player-authored and never accept coordinates invented by a model.
function M.resolveCameraPoint(maxDistance, modules)
    modules=modules or loaded()
    maxDistance=maxDistance or 2048
    if not modules.camera or not modules.nearby or not modules.util or not modules.self then
        return nil,'camera_targeting_unavailable'
    end
    local origin=modules.camera.getPosition()
    local direction=modules.camera.viewportToWorldVector(modules.util.vector2(0.5,0.5)):normalize()
    local hit=modules.nearby.castRenderingRay(origin,origin+direction*maxDistance,{ignore=modules.self})
    if not hit or not hit.hit or not hit.hitPos then return nil,'no_destination_under_crosshair' end
    local hitCell=hit.hitObject and hit.hitObject.cell or modules.self.cell
    local destinationCell=M.cellKey(hitCell)
    local currentCell=M.cellKey(modules.self.cell)
    if not destinationCell or not currentCell or destinationCell~=currentCell then
        return nil,'destination_outside_current_cell'
    end
    return {destination_x=hit.hitPos.x,destination_y=hit.hitPos.y,destination_z=hit.hitPos.z,
        destination_cell=destinationCell}
end

local function safe(callable, ...)
    if type(callable)~='function' then return nil end
    local ok,value=pcall(callable,...)
    if ok then return value end
    return nil
end

local function objectRecord(object)
    local objectType=object and safe(function() return object.type end)
    return objectType and safe(objectType.record,object) or nil
end

local function objectDisplayName(object)
    local record=objectRecord(object)
    return record and type(record.name)=='string' and record.name~='' and record.name or nil
end

function M.nearbyActors(maxDistance, modules)
    modules=modules or loaded()
    if not modules.nearby or not modules.self then return {} end
    local result={}
    for _,object in ipairs(modules.nearby.actors or {}) do
        if object~=modules.self then
            local candidate=M.candidate(object,maxDistance or 2048,modules.self.position,modules)
            if candidate and candidate.distance<=candidate.maxDistance and not candidate.dead then
                result[#result+1]=candidate
            end
        end
    end
    table.sort(result,function(a,b) return a.distance<b.distance end)
    return result
end

-- Read follower relationships from Follower Detection Util when it is installed. The interface is
-- optional: the core ALMSIVI target and group flow remains dependency-free.
function M.followerContext(modules)
    modules=modules or loaded()
    local fdu=modules.interfaces and modules.interfaces.FollowerDetectionUtil
    if not fdu or type(fdu.getFollowerList)~='function' then return {},nil end
    local states=safe(fdu.getFollowerList)
    if type(states)~='table' then return {},nil end
    local result={}
    for _,follower in pairs(states) do
        if #result>=32 then break end
        local actor=follower and M.identity(follower.actor,modules) or nil
        if actor then
            result[#result+1]={actor=actor,
                leader=follower.leader and M.identity(follower.leader,modules) or nil,
                super_leader=follower.superLeader and M.identity(follower.superLeader,modules) or nil,
                follows_player=follower.followsPlayer==true}
        end
    end
    table.sort(result,function(left,right)
        local leftName=left.actor.display_name or left.actor.record_id or ''
        local rightName=right.actor.display_name or right.actor.record_id or ''
        if leftName~=rightName then return leftName<rightName end
        return left.actor.refnum.index<right.actor.refnum.index
    end)
    return result,{provider='FollowerDetectionUtil',version=tonumber(fdu.version)}
end

-- Report authoritative actor-local combat state; the AI interface is unavailable for arbitrary
-- nearby actors from the player/global contexts in OpenMW 0.51.
function M.combatStatus(modules)
    modules=modules or loaded()
    local ai=modules.interfaces and modules.interfaces.AI
    if not ai or not ai.getActivePackage or not modules.self then return nil,'ai_interface_unavailable' end
    local package=safe(ai.getActivePackage)
    local fleeing=safe(ai.isFleeing)==true
    local activity=fleeing and 'fleeing' or package and type(package.type)=='string' and package.type:lower() or 'idle'
    local target=package and package.target and M.identity(package.target,modules) or nil
    return {hostile_to_player=package and package.type=='Combat' and target and target.kind=='player' or false,
        activity=activity,target=target}
end

local function dynamicStats(actor, modules)
    local dynamic=modules.types and modules.types.Actor and modules.types.Actor.stats and modules.types.Actor.stats.dynamic
    if not dynamic then return {} end
    local result={}
    for _,name in ipairs({'health','magicka','fatigue'}) do
        local value=safe(dynamic[name],actor)
        if value then result[name]={base=value.base,current=value.current,modifier=value.modifier} end
    end
    local level=safe(modules.types.Actor.stats.level,actor)
    if level then result.level=level.current end
    result.encumbrance=safe(modules.types.Actor.getEncumbrance,actor)
    result.capacity=safe(modules.types.Actor.getCapacity,actor)
    result.dead=safe(modules.types.Actor.isDead,actor) or false
    return result
end

local function factions(actor, modules)
    local npc=modules.types and modules.types.NPC
    if not npc or not safe(npc.objectIsInstance,actor) then return {} end
    local ids=safe(npc.getFactions,actor) or {}
    local result={}
    for _,id in ipairs(ids) do
        result[#result+1]={id=id,rank=safe(npc.getFactionRank,actor,id),reputation=safe(npc.getFactionReputation,actor,id)}
    end
    return result
end

local function inventory(actor, modules)
    local actorType=modules.types and modules.types.Actor
    local source=actorType and safe(actorType.inventory,actor)
    local objects=source and safe(source.getAll,source)
    if not objects then return {} end
    local rows,byRecord={},{}
    for _,item in ipairs(objects) do
        local recordId=item.recordId
        if type(recordId)=='string' and recordId~='' then byRecord[recordId]=(byRecord[recordId] or 0)+(item.count or 1) end
    end
    for recordId,count in pairs(byRecord) do rows[#rows+1]={record_id=recordId,count=count} end
    table.sort(rows,function(a,b)return a.record_id<b.record_id end)
    return rows
end

local function effects(actor, modules)
    local actorType=modules.types and modules.types.Actor
    local source=actorType and safe(actorType.activeEffects,actor)
    local result={}
    if not source then return result end
    for _,effect in pairs(source) do
        if #result>=32 then break end
        result[#result+1]={id=effect.id,magnitude=effect.magnitude,attribute=effect.affectedAttribute,skill=effect.affectedSkill}
    end
    return result
end

local function namedStats(actor, source, names)
    local result={}
    if not source then return result end
    for _,name in ipairs(names) do
        local value=safe(source[name],actor)
        if value then result[name]={base=value.base,modified=value.modified,damage=value.damage,modifier=value.modifier} end
    end
    return result
end

local equipmentSlots={helmet='Helmet',cuirass='Cuirass',greaves='Greaves',left_pauldron='LeftPauldron',
    right_pauldron='RightPauldron',left_gauntlet='LeftGauntlet',right_gauntlet='RightGauntlet',boots='Boots',
    shirt='Shirt',pants='Pants',skirt='Skirt',robe='Robe',left_ring='LeftRing',right_ring='RightRing',
    amulet='Amulet',belt='Belt',carried_right='CarriedRight',carried_left='CarriedLeft',ammunition='Ammunition'}

local function equipment(actor, modules)
    local actorType=modules.types and modules.types.Actor
    local equipped=actorType and safe(actorType.getEquipment,actor) or {}
    local names={}
    if actorType and actorType.EQUIPMENT_SLOT then
        for id,name in pairs(equipmentSlots) do
            local slot=actorType.EQUIPMENT_SLOT[name]
            if slot~=nil then names[slot]=id end
        end
    end
    local result={}
    for slot,item in pairs(equipped or {}) do result[#result+1]={slot=names[slot] or tostring(slot),record_id=item.recordId,
        display_name=objectDisplayName(item),count=item.count or 1} end
    table.sort(result,function(a,b)return a.slot<b.slot end)
    return result
end

function M.targetInventory(targetIdentity, modules)
    modules=modules or loaded()
    local actor,reason=M.resolve(targetIdentity,modules)
    if not actor then return {},reason end
    return inventory(actor,modules)
end

function M.targetEquipment(targetIdentity, modules)
    modules=modules or loaded()
    local actor,reason=M.resolve(targetIdentity,modules)
    if not actor then return {},reason end
    return equipment(actor,modules)
end

local function spells(actor, modules)
    local actorType=modules.types and modules.types.Actor
    local source=actorType and safe(actorType.spells,actor)
    local result={}
    if not source then return result end
    for _,spell in pairs(source) do
        if #result>=64 then break end
        result[#result+1]={id=spell.id,name=spell.name}
    end
    return result
end

local function journal(player, modules)
    local playerType=modules.types and modules.types.Player
    local source=playerType and safe(playerType.journal,player)
    local entries=source and source.journalTextEntries
    local result={}
    if not entries then return result end
    local first=math.max(1,#entries-31)
    for index=first,#entries do
        local entry=entries[index]
        result[#result+1]={id=entry.id,quest_id=entry.questId,text=entry.text,day=entry.day,month=entry.month,day_of_month=entry.dayOfMonth}
    end
    return result
end

local function actorState(actor, player, modules)
    if not actor then return {} end
    local actorType=modules.types and modules.types.Actor
    local npc=modules.types and modules.types.NPC
    local equipped=equipment(actor,modules)
    local held={}
    for _,item in ipairs(equipped) do
        if item.slot=='carried_right' or item.slot=='carried_left' then held[#held+1]=item end
    end
    local state={stats=dynamicStats(actor,modules),factions=factions(actor,modules),equipment=equipped,held_items=held,
        spells=spells(actor,modules),activeEffects=effects(actor,modules),gold=actorType and safe(actorType.getBarterGold,actor)}
    if actorType and actorType.stats then
        state.attributes=namedStats(actor,actorType.stats.attributes,
            {'strength','intelligence','willpower','agility','speed','endurance','personality','luck'})
    end
    if npc and npc.stats then
        state.skills=namedStats(actor,npc.stats.skills,{'block','armorer','mediumarmor','heavyarmor','bluntweapon','longblade',
            'axe','spear','athletics','enchant','destruction','alteration','illusion','conjuration','mysticism','restoration',
            'alchemy','unarmored','security','sneak','acrobatics','lightarmor','shortblade','marksman','mercantile',
            'speechcraft','handtohand'})
    end
    local record=npc and safe(npc.record,actor)
    if record then state.identity={race=record.race,class=record.class,gender=record.isMale and 'Male' or 'Female',
        is_male=record.isMale,is_essential=record.isEssential,primary_faction=record.primaryFaction,
        is_werewolf=safe(npc.isWerewolf,actor)==true} end
    if modules.types and modules.types.Player and safe(modules.types.Player.objectIsInstance,actor) then
        state.birthsign=safe(modules.types.Player.getBirthSign,actor)
    end
    if player and npc and safe(npc.objectIsInstance,actor) then state.disposition=safe(npc.getDisposition,actor,player) end
    return state
end

local function nearbyObjects(maxDistance, modules)
    local result={}
    if not modules.nearby or not modules.self then return result end
    for _,collectionName in ipairs({'items','doors','containers','activators'}) do
        local accepted=0
        for _,object in ipairs(modules.nearby[collectionName] or {}) do
            local distance=object.position and (object.position-modules.self.position):length() or 0
            if distance<=maxDistance then
                local owner=safe(function() return object.owner end)
                local row={kind=collectionName,record_id=object.recordId,display_name=objectDisplayName(object),
                    content_file=safe(function() return object.contentFile end),distance=math.floor(distance+0.5),
                    position={x=object.position.x,y=object.position.y,z=object.position.z},
                    ownership=owner and {record_id=safe(function() return owner.recordId end),
                        faction_id=safe(function() return owner.factionId end),
                        faction_rank=safe(function() return owner.factionRank end)} or nil}
                local lockable=modules.types and modules.types.Lockable
                if lockable and safe(lockable.objectIsInstance,object) then
                    local key=safe(lockable.getKeyRecord,object)
                    local trap=safe(lockable.getTrapSpell,object)
                    row.lock={locked=safe(lockable.isLocked,object)==true,level=safe(lockable.getLockLevel,object),
                        key_record_id=key and key.id or nil,trap_spell_id=trap and trap.id or nil}
                end
                result[#result+1]=row
                accepted=accepted+1
                if accepted>=8 then break end
            end
        end
    end
    table.sort(result,function(a,b)return a.distance<b.distance end)
    return result
end

function M.playerContext(target, modules)
    modules=modules or loaded()
    local playerIdentity=M.identity(modules.self,modules)
    local targetObject=target and M.resolve(target,modules) or nil
    local nearby=M.nearbyActors(2048,modules)
    local actors={}
    for index,candidate in ipairs(nearby) do actors[index]=candidate.identity end
    local weather=modules.core and modules.core.weather and modules.self and modules.self.cell
        and safe(modules.core.weather.getCurrent,modules.self.cell) or nil
    local followers,followerProvider=M.followerContext(modules)
    local contentFiles={}
    local loadedFiles=modules.core and modules.core.contentFiles and modules.core.contentFiles.list or {}
    for index,name in ipairs(loadedFiles) do contentFiles[index]=name end
    return {player=playerIdentity,target=target,nearbyActors=actors,nearbyObjects=nearbyObjects(2048,modules),
        followers=followers,
        inventory=inventory(modules.self,modules),activeEffects=effects(modules.self,modules),journal=journal(modules.self,modules),
        books=recentBooks,
        contentFiles=contentFiles,
        world={game_time=modules.core and safe(modules.core.getGameTime) or nil,
            cell=modules.self and modules.self.cell and (modules.self.cell.name~='' and modules.self.cell.name or modules.self.cell.displayName) or nil,
            weather=weather and {id=weather.id,name=weather.name,is_storm=weather.isStorm} or nil},
        playerState=actorState(modules.self,nil,modules),targetState=actorState(targetObject,modules.self,modules),
        capabilities={targeting='camera_ray',ui='text',group_dialogue=true,inventory='read_only',journal='read_only',stats='read_only',
            follower_detection=followerProvider and followerProvider.provider or 'unavailable',
            follower_detection_version=followerProvider and followerProvider.version or nil}}
end

function M.follow(targetIdentity)
    local modules=loaded()
    local target,reason=M.resolve(targetIdentity,modules)
    local ai=modules.interfaces and modules.interfaces.AI
    if not target or not ai or not ai.startPackage then return nil,reason or 'ai_interface_unavailable' end
    ai.startPackage({type='Follow',target=target,duration=0,isRepeat=true,cancelOther=false})
    return true,'follow_started'
end

function M.stopFollow(targetIdentity)
    local modules=loaded()
    local ai=modules.interfaces and modules.interfaces.AI
    if not ai or not ai.filterPackages then return false end
    local target=M.resolve(targetIdentity,modules)
    ai.filterPackages(function(package)
        return package.type~='Follow' or (target and package.target~=target)
    end)
    return true
end

local function samePosition(position,owned)
    if not position or not owned then return false end
    if type(position.x)~='number' or type(position.y)~='number' or type(position.z)~='number'
        or type(owned.destination_x)~='number' or type(owned.destination_y)~='number'
        or type(owned.destination_z)~='number' then return false end
    local epsilon=0.01
    return math.abs(position.x-owned.destination_x)<=epsilon
        and math.abs(position.y-owned.destination_y)<=epsilon
        and math.abs(position.z-owned.destination_z)<=epsilon
end

function M.stopAi(owned, modules)
    modules=modules or loaded()
    local ai=modules.interfaces and modules.interfaces.AI
    if not ai or not ai.filterPackages or type(owned)~='table' then return nil,'ai_interface_unavailable' end
    local target=owned.target and M.resolve(owned.target,modules) or nil
    ai.filterPackages(function(package)
        if package.type~=owned.type then return true end
        if owned.target and (not target or package.target~=target) then return true end
        if owned.destination and not samePosition(package.destPosition,owned.destination) then return true end
        if owned.distance~=nil and package.distance~=owned.distance then return true end
        return false
    end)
    return true,'ai_packages_stopped'
end

function M.wander(parameters, modules)
    modules=modules or loaded()
    local ai=modules.interfaces and modules.interfaces.AI
    if not ai or not ai.startPackage then return nil,'ai_interface_unavailable' end
    ai.startPackage({type='Wander',distance=parameters.distance,duration=parameters.duration_seconds,
        isRepeat=false,cancelOther=false})
    return true,'wander_started'
end

local function movementDestination(parameters, modules)
    if type(parameters)~='table' or M.cellKey(modules.self and modules.self.cell)~=parameters.destination_cell then
        return nil,'destination_cell_changed'
    end
    if not modules.util or not modules.util.vector3 then return nil,'vector_interface_unavailable' end
    return modules.util.vector3(parameters.destination_x,parameters.destination_y,parameters.destination_z)
end

function M.travel(parameters, modules)
    modules=modules or loaded()
    local ai=modules.interfaces and modules.interfaces.AI
    local destination,reason=movementDestination(parameters,modules)
    if not destination or not ai or not ai.startPackage then return nil,reason or 'ai_interface_unavailable' end
    ai.startPackage({type='Travel',destPosition=destination,isRepeat=false,cancelOther=false})
    return true,'travel_started',{destination_x=parameters.destination_x,destination_y=parameters.destination_y,
        destination_z=parameters.destination_z,destination_cell=parameters.destination_cell}
end

function M.escort(targetIdentity, parameters, modules)
    modules=modules or loaded()
    local target,reason=M.resolve(targetIdentity,modules)
    local ai=modules.interfaces and modules.interfaces.AI
    local destination,destinationReason=movementDestination(parameters,modules)
    if not target or not destination or not ai or not ai.startPackage then
        return nil,reason or destinationReason or 'ai_interface_unavailable'
    end
    ai.startPackage({type='Escort',target=target,destPosition=destination,destCell=modules.self.cell,
        duration=0,isRepeat=false,cancelOther=false})
    return true,'escort_started',{destination_x=parameters.destination_x,destination_y=parameters.destination_y,
        destination_z=parameters.destination_z,destination_cell=parameters.destination_cell}
end

function M.beginFace(targetIdentity, parameters, modules)
    modules=modules or loaded()
    local target,reason=M.resolve(targetIdentity,modules)
    local selfObject=modules.self
    local ai=modules.interfaces and modules.interfaces.AI
    local active=ai and ai.getActivePackage and ai.getActivePackage() or nil
    if active and active.type=='Combat' then return nil,'face_blocked_by_combat' end
    if not target or not selfObject or not selfObject.controls or not selfObject.rotation
        or not selfObject.position or not target.position then return nil,reason or 'face_interface_unavailable' end
    if M.cellKey(target.cell)~=M.cellKey(selfObject.cell) then return nil,'face_target_cell_changed' end
    return true,'face_started',{target=targetIdentity,elapsed=0,timeout=3}
end

local function normalizedAngle(value)
    local full=math.pi*2
    while value>math.pi do value=value-full end
    while value< -math.pi do value=value+full end
    return value
end

function M.stopFace(controller, modules)
    modules=modules or loaded()
    if modules.self and modules.self.controls then modules.self.controls.yawChange=0 end
    return true
end

function M.updateFace(controller, dt, modules)
    modules=modules or loaded()
    if type(controller)~='table' then return false,'face_controller_invalid',{} end
    local target,reason=M.resolve(controller.target,modules)
    local selfObject=modules.self
    local ai=modules.interfaces and modules.interfaces.AI
    local active=ai and ai.getActivePackage and ai.getActivePackage() or nil
    if active and active.type=='Combat' then
        M.stopFace(controller,modules) return false,'face_interrupted_by_combat',{},'cancelled'
    end
    if not target or not selfObject or not selfObject.controls or not selfObject.rotation
        or not selfObject.position or not target.position then
        M.stopFace(controller,modules)
        if not target then return false,reason or 'face_target_inactive',{},'cancelled' end
        return false,'face_interface_unavailable',{}
    end
    if M.cellKey(target.cell)~=M.cellKey(selfObject.cell) then
        M.stopFace(controller,modules) return false,'face_target_cell_changed',{},'cancelled'
    end
    local dx=target.position.x-selfObject.position.x
    local dy=target.position.y-selfObject.position.y
    local frame=math.max(0.001,math.min(tonumber(dt) or 1/60,0.1))
    controller.elapsed=(tonumber(controller.elapsed) or 0)+frame
    if dx*dx+dy*dy<1 then
        M.stopFace(controller,modules) return true,'face_completed',{final_yaw_error=0}
    end
    local desired=math.atan2 and math.atan2(dx,dy) or math.atan(dx,dy)
    local current=selfObject.rotation:getYaw()
    local difference=normalizedAngle(desired-current)
    local absolute=math.abs(difference)
    if absolute<=0.035 then
        M.stopFace(controller,modules)
        return true,'face_completed',{final_yaw_error=math.floor(absolute*10000+0.5)/10000}
    end
    if controller.elapsed>controller.timeout then
        M.stopFace(controller,modules)
        return false,'face_timeout',{final_yaw_error=math.floor(absolute*10000+0.5)/10000}
    end
    local maximum=3*frame
    selfObject.controls.yawChange=math.max(-maximum,math.min(difference,maximum))
    return nil,'face_turning',{}
end

function M.startCombat(targetIdentity)
    local modules=loaded()
    local target,reason=M.resolve(targetIdentity,modules)
    local ai=modules.interfaces and modules.interfaces.AI
    if not target or not ai or not ai.startPackage then return nil,reason or 'ai_interface_unavailable' end
    ai.startPackage({type='Combat',target=target,cancelOther=false})
    return true,'combat_started'
end

function M.stopCombat(targetIdentity)
    local modules=loaded()
    local ai=modules.interfaces and modules.interfaces.AI
    if not ai or not ai.filterPackages then return nil,'ai_interface_unavailable' end
    local target=M.resolve(targetIdentity,modules)
    ai.filterPackages(function(package) return package.type~='Combat' or (target and package.target~=target) end)
    return true,'combat_stopped'
end

function M.playAnimation(parameters)
    local modules=loaded()
    if not modules.animation or not modules.self or not modules.animation.hasGroup
        or not modules.animation.playQueued then return nil,'animation_interface_unavailable' end
    if not modules.animation.hasGroup(modules.self,parameters.group) then return nil,'animation_group_unavailable' end
    modules.animation.playQueued(modules.self,parameters.group,{loops=0,speed=1})
    return true,'animation_started'
end

function M.useItem(parameters)
    local modules=loaded()
    local actorType=modules.types and modules.types.Actor
    local inventory=actorType and safe(actorType.inventory,modules.self)
    local item=inventory and safe(inventory.find,inventory,parameters.record_id)
    if not item then return nil,'item_not_in_inventory' end
    if not modules.core or not modules.core.sendGlobalEvent then return nil,'item_usage_unavailable' end
    modules.core.sendGlobalEvent('UseItem',{object=item,actor=modules.self,force=false})
    return true,'item_use_dispatched'
end

function M.equipItem(parameters)
    local modules=loaded()
    local actorType=modules.types and modules.types.Actor
    local slotName=equipmentSlots[parameters.slot]
    local slot=actorType and actorType.EQUIPMENT_SLOT and actorType.EQUIPMENT_SLOT[slotName]
    local inventory=actorType and safe(actorType.inventory,modules.self)
    local item=inventory and safe(inventory.find,inventory,parameters.record_id)
    if not slot then return nil,'equipment_slot_unavailable' end
    if not item then return nil,'item_not_in_inventory' end
    local equipped=safe(actorType.getEquipment,modules.self)
    if type(equipped)~='table' or type(actorType.setEquipment)~='function' then return nil,'equipment_interface_unavailable' end
    equipped[slot]=item
    local ok=pcall(actorType.setEquipment,modules.self,equipped)
    if not ok then return nil,'engine_rejected_equipment' end
    return true,'item_equipped'
end

function M.unequipItem(parameters)
    local modules=loaded()
    local actorType=modules.types and modules.types.Actor
    local slotName=equipmentSlots[parameters.slot]
    local slot=actorType and actorType.EQUIPMENT_SLOT and actorType.EQUIPMENT_SLOT[slotName]
    if not slot then return nil,'equipment_slot_unavailable' end
    local equipped=safe(actorType.getEquipment,modules.self)
    if type(equipped)~='table' or type(actorType.setEquipment)~='function' then return nil,'equipment_interface_unavailable' end
    if equipped[slot]==nil then return true,'equipment_slot_already_empty' end
    equipped[slot]=nil
    local ok=pcall(actorType.setEquipment,modules.self,equipped)
    if not ok then return nil,'engine_rejected_equipment' end
    return true,'item_unequipped'
end

function M.inspect(targetIdentity)
    local object,reason=M.resolve(targetIdentity)
    if not object then return nil,reason end
    return true,'inspection_completed',{record_id=object.recordId,enabled=object.enabled~=false,
        position={x=object.position.x,y=object.position.y,z=object.position.z}}
end

function M.playSpeech(mediaId, subtitle, volumeBoost)
    local modules=loaded()
    local bridge=M.bridge()
    if not bridge or not bridge.playSpeech or not modules.self then
        return nil,'prepared_media_unavailable'
    end
    return bridge.playSpeech(mediaId,modules.self,subtitle or '',tonumber(volumeBoost) or 3)
end

function M.stopSpeech()
    local modules=loaded()
    local bridge=M.bridge()
    if bridge and bridge.stopSpeech and modules.self then bridge.stopSpeech(modules.self) end
end

function M.isSpeechActive()
    local modules=loaded()
    local bridge=M.bridge()
    return bridge and bridge.isSpeechActive and modules.self and bridge.isSpeechActive(modules.self) or false
end
return M
