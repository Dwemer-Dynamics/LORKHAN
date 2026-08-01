local M = {}

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

function M.callback(fn)
    local async=optional('openmw.async')
    if async and async.callback then return async:callback(fn) end
    return fn
end

-- Convert API-129 objects to the stable identity carried on the ALMSIVI wire. Dynamic objects have
-- no durable RefNum and are deliberately not eligible conversation actors.
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
    if not formId then return nil,'dynamic_actor_identity_unsupported' end
    local contentIndex=math.floor(formId / 0x1000000)
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
    if kind=='npc' and modules.types.NPC.record then
        local ok,record=pcall(modules.types.NPC.record,object)
        if ok and record and type(record.name)=='string' and record.name~='' then display=record.name end
    elseif kind=='creature' and modules.types.Creature.record then
        local ok,record=pcall(modules.types.Creature.record,object)
        if ok and record and type(record.name)=='string' and record.name~='' then display=record.name end
    end
    return {kind=kind,record_id=object.recordId,refnum={index=formId%0x1000000,content_file=contentIndex},
        content_file=contentFile,cell=cellIdentity,display_name=display}
end

function M.resolve(identity, modules)
    modules=modules or loaded()
    if not identity or not modules.core or not modules.nearby then return nil,'resolver_unavailable' end
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

function M.resolveCameraTarget(maxDistance, modules)
    modules=modules or loaded()
    maxDistance=maxDistance or 2048
    if not modules.camera or not modules.nearby or not modules.util or not modules.self then
        return nil,'camera_targeting_unavailable'
    end
    local origin=modules.camera.getPosition()
    local direction=modules.camera.viewportToWorldVector(modules.util.vector2(0.5,0.5)):normalize()
    local hit=modules.nearby.castRenderingRay(origin,origin+direction*maxDistance,{ignore=modules.self})
    if not hit or not hit.hitObject then return nil,'no_actor_under_crosshair' end
    return M.candidate(hit.hitObject,maxDistance,origin,modules)
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

local function safe(callable, ...)
    if type(callable)~='function' then return nil end
    local ok,value=pcall(callable,...)
    if ok then return value end
    return nil
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

local function equipment(actor, modules)
    local actorType=modules.types and modules.types.Actor
    local equipped=actorType and safe(actorType.getEquipment,actor) or {}
    local names={}
    if actorType and actorType.EQUIPMENT_SLOT then
        for name,slot in pairs(actorType.EQUIPMENT_SLOT) do names[slot]=name end
    end
    local result={}
    for slot,item in pairs(equipped or {}) do result[#result+1]={slot=names[slot] or tostring(slot),record_id=item.recordId,count=item.count or 1} end
    table.sort(result,function(a,b)return a.slot<b.slot end)
    return result
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
    local state={stats=dynamicStats(actor,modules),factions=factions(actor,modules),equipment=equipment(actor,modules),
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
    if record then state.identity={race=record.race,class=record.class,is_male=record.isMale,is_essential=record.isEssential} end
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
        for _,object in ipairs(modules.nearby[collectionName] or {}) do
            if #result>=32 then return result end
            local distance=object.position and (object.position-modules.self.position):length() or 0
            if distance<=maxDistance then result[#result+1]={kind=collectionName,record_id=object.recordId,
                distance=math.floor(distance+0.5),position={x=object.position.x,y=object.position.y,z=object.position.z}} end
        end
    end
    table.sort(result,function(a,b)return a.distance<b.distance end)
    return result
end

function M.playerContext(target)
    local modules=loaded()
    local playerIdentity=M.identity(modules.self,modules)
    local targetObject=target and M.resolve(target,modules) or nil
    local nearby=M.nearbyActors(2048,modules)
    local actors={}
    for index,candidate in ipairs(nearby) do actors[index]=candidate.identity end
    local weather=modules.core and modules.core.weather and modules.self and modules.self.cell
        and safe(modules.core.weather.getCurrent,modules.self.cell) or nil
    return {player=playerIdentity,target=target,nearbyActors=actors,nearbyObjects=nearbyObjects(2048,modules),
        inventory=inventory(modules.self,modules),activeEffects=effects(modules.self,modules),journal=journal(modules.self,modules),
        contentFiles=modules.core and modules.core.contentFiles and modules.core.contentFiles.list or {},
        world={game_time=modules.core and safe(modules.core.getGameTime) or nil,
            cell=modules.self and modules.self.cell and (modules.self.cell.name~='' and modules.self.cell.name or modules.self.cell.displayName) or nil,
            weather=weather and {id=weather.id,name=weather.name,is_storm=weather.isStorm} or nil},
        playerState=actorState(modules.self,nil,modules),targetState=actorState(targetObject,modules.self,modules),
        capabilities={targeting='camera_ray',ui='text',group_dialogue=true,inventory='read_only',journal='read_only',stats='read_only'}}
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

function M.stopAi(owned)
    local modules=loaded()
    local ai=modules.interfaces and modules.interfaces.AI
    if not ai or not ai.filterPackages or type(owned)~='table' then return nil,'ai_interface_unavailable' end
    local target=owned.target and M.resolve(owned.target,modules) or nil
    ai.filterPackages(function(package)
        if package.type~=owned.type then return true end
        if owned.target then return not target or package.target~=target end
        return false
    end)
    return true,'ai_packages_stopped'
end

function M.wander(parameters)
    local modules=loaded()
    local ai=modules.interfaces and modules.interfaces.AI
    if not ai or not ai.startPackage then return nil,'ai_interface_unavailable' end
    ai.startPackage({type='Wander',distance=parameters.distance,duration=parameters.duration_seconds,
        isRepeat=false,cancelOther=false})
    return true,'wander_started'
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

local equipmentSlots={helmet='Helmet',cuirass='Cuirass',greaves='Greaves',left_pauldron='LeftPauldron',
    right_pauldron='RightPauldron',left_gauntlet='LeftGauntlet',right_gauntlet='RightGauntlet',boots='Boots',
    shirt='Shirt',pants='Pants',skirt='Skirt',robe='Robe',left_ring='LeftRing',right_ring='RightRing',
    amulet='Amulet',belt='Belt',carried_right='CarriedRight',carried_left='CarriedLeft',ammunition='Ammunition'}

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

function M.playSpeech(mediaId, subtitle)
    local modules=loaded()
    local bridge=M.bridge()
    local vfsName=bridge and bridge.mediaVfsName and bridge.mediaVfsName(mediaId)
    if not vfsName or not modules.core or not modules.core.sound or not modules.self then
        return nil,'prepared_media_unavailable'
    end
    modules.core.sound.say(vfsName,modules.self,subtitle or '')
    return true
end

function M.stopSpeech()
    local modules=loaded()
    if modules.core and modules.core.sound and modules.self then modules.core.sound.stopSay(modules.self) end
end

function M.isSpeechActive()
    local modules=loaded()
    return modules.core and modules.core.sound and modules.core.sound.isSayActive and modules.self
        and modules.core.sound.isSayActive(modules.self) or false
end
return M
