local identity=require('scripts.LORKHAN.identity')
local copy=require('scripts.LORKHAN.util').copy
local M={}

local function finite(value)
    return type(value)=='number' and value==value and value~=math.huge and value~=-math.huge
end

-- Movement changes cell identity; reference identity remains stable for matching its saved return pose.
local function actorKey(actor)
    if not identity.validate(actor) or (actor.kind~='npc' and actor.kind~='creature') then return nil end
    return table.concat({actor.kind,actor.record_id,actor.content_file,tostring(actor.refnum.content_file),tostring(actor.refnum.index)},'|')
end

local function pose(object)
    local cell=object.cell
    if not cell then error('actor_cell_unavailable') end
    if type(cell.id)~='string' or #cell.id>256 or type(cell.name)~='string' or #cell.name>256 then error('actor_cell_unavailable') end
    local pitch,yaw=object.rotation:getAnglesXZ()
    local position=object.position
    if not finite(position.x) or not finite(position.y) or not finite(position.z)
        or not finite(pitch) or not finite(yaw) then error('actor_pose_unavailable') end
    return {cell_id=cell.id,cell_name=cell.name,exterior=cell.isExterior==true,
        grid_x=cell.isExterior and cell.gridX or nil,grid_y=cell.isExterior and cell.gridY or nil,
        x=position.x,y=position.y,z=position.z,pitch=pitch,yaw=yaw}
end

local function savedPose(value)
    return type(value)=='table' and type(value.cell_id)=='string' and type(value.cell_name)=='string'
        and #value.cell_id<=256 and #value.cell_name<=256
        and type(value.exterior)=='boolean' and finite(value.x) and finite(value.y) and finite(value.z)
        and finite(value.pitch) and finite(value.yaw)
        and (not value.exterior or (finite(value.grid_x) and finite(value.grid_y)))
end

local function loadCell(world,value)
    if value.exterior then return world.getExteriorCell(value.grid_x,value.grid_y) end
    if value.cell_id and value.cell_id~='' then return world.getCellById(value.cell_id) end
    return world.getCellByName(value.cell_name)
end

function M.new(modules)
    return {modules=modules,returns={},pending=nil}
end

-- Return tickets contain only bounded primitives; pending engine objects are never serialized.
function M.save(state) return copy(state.returns) end
function M.load(state,data)
    state.returns={};state.pending=nil
    if type(data)~='table' then return end
    local count=0
    for key,entry in pairs(data) do
        if count>=32 then break end
        if type(entry)=='table' and key==actorKey(entry.actor) and savedPose(entry.pose) then
            state.returns[key]={actor=copy(entry.actor),pose=copy(entry.pose)};count=count+1
        end
    end
end

-- Resolve a single exact reference; loading its explicitly known cell cannot select another same-name actor.
local function resolve(state,actor,allowLoad)
    local modules=state.modules
    local formId=modules.core.getFormId(actor.content_file,actor.refnum.index)
    local function exact()
        local object=modules.world.getObjectByFormId(formId)
        if not object or not object:isValid() or object.recordId~=actor.record_id then return nil end
        local kind=actor.kind=='npc' and modules.types.NPC or modules.types.Creature
        if not kind or not kind.objectIsInstance(object) then return nil end
        return object
    end
    local object=exact()
    if object or not allowLoad then return object end
    local cell
    if actor.cell.kind=='exterior' then
        cell=modules.world.getExteriorCell(actor.cell.grid_x,actor.cell.grid_y)
    else cell=modules.world.getCellByName(actor.cell.name) end
    -- Force only this known cell's references to materialize; never enumerate other cells or actors.
    if cell then cell:getAll() end
    return exact()
end

local function observed(state,actor,object)
    local ticket=state.returns[actorKey(actor)]
    local result={target=actor.record_id,actor_available=object~=nil,return_available=ticket~=nil}
    if ticket then result.return_cell=ticket.pose.cell_name~='' and ticket.pose.cell_name or ticket.pose.cell_id end
    if object then
        local ok,location=pcall(pose,object)
        if ok then
            result.cell=location.cell_name~='' and location.cell_name or location.cell_id
            result.x=location.x;result.y=location.y;result.z=location.z
        else result.actor_available=false end
    end
    return result
end

-- Scheduling is not completion: the next global update verifies the deferred engine teleport.
function M.start(state,event,sessionId,generation,now)
    local command=event and event.command
    local actor=command and command.parameters and command.parameters.actor
    local key=actorKey(actor)
    if not command or not key then return 'rejected','invalid_actor',{} end
    if event.session_id~=sessionId or event.generation~=generation then return 'rejected','stale_session',{} end
    if not finite(event.deadline) or not finite(now) or now>=event.deadline then return 'rejected','command_expired',{} end
    if state.pending then return 'rejected','npc_command_pending',{} end
    local ok,object=pcall(resolve,state,actor,true)
    if not ok then object=nil end
    local reported=observed(state,actor,object)
    if command.name=='npc.status' then return 'succeeded','npc_status',reported end
    if not object then return 'rejected','actor_unavailable',reported end
    if command.name=='npc.teleport' and state.returns[key] then return 'rejected','return_pending',reported end
    if command.name=='npc.return' and not state.returns[key] then return 'rejected','return_unavailable',reported end
    if command.name~='npc.visit' and command.name~='npc.teleport' and command.name~='npc.return' then
        return 'rejected','unknown_command',reported
    end
    local modules=state.modules
    local player=modules.world.players and modules.world.players[1]
    if not player then return 'rejected','player_unavailable',reported end
    local moved=command.name=='npc.visit' and player or object
    local applied,destination=pcall(function()
        local destination
        if command.name=='npc.return' then destination=copy(state.returns[key].pose)
        elseif command.name=='npc.visit' then destination=pose(object)
        else
            local count=0;for _ in pairs(state.returns) do count=count+1 end
            if count>=32 then error('return_storage_full') end
            local original=pose(object)
            destination=pose(player);destination.pitch=original.pitch;destination.yaw=original.yaw
            state.returns[key]={actor=copy(actor),pose=original}
        end
        local cell=loadCell(modules.world,destination)
        -- OpenMW applies pitch first, then yaw (see its first_person_auto_switch.lua).
        local rotation=modules.util.transform.rotateZ(destination.yaw)*modules.util.transform.rotateX(destination.pitch)
        moved:teleport(cell,modules.util.vector3(destination.x,destination.y,destination.z),{rotation=rotation,onGround=false})
        return destination
    end)
    if not applied then return 'failed','teleport_schedule_failed',observed(state,actor,object) end
    state.pending={command_id=command.command_id,name=command.name,actor=copy(actor),key=key,object=moved,
        destination=destination,session_id=sessionId,generation=generation,deadline=event.deadline}
    return nil
end

function M.poll(state,sessionId,generation,now)
    local pending=state.pending
    if not pending then return nil end
    if sessionId~=pending.session_id or generation~=pending.generation then state.pending=nil;return nil end
    local ok,actual=pcall(pose,pending.object)
    local destination=pending.destination
    local matched=ok and actual.cell_id==destination.cell_id and actual.exterior==destination.exterior
        and (not actual.exterior or (actual.grid_x==destination.grid_x and actual.grid_y==destination.grid_y))
        and math.abs(actual.x-destination.x)<1 and math.abs(actual.y-destination.y)<1 and math.abs(actual.z-destination.z)<1
        and math.abs(actual.pitch-destination.pitch)<0.05
        and math.abs((actual.yaw-destination.yaw+math.pi)%(2*math.pi)-math.pi)<0.05
    if not matched and now<pending.deadline then return nil end
    state.pending=nil
    if matched and pending.name=='npc.return' then state.returns[pending.key]=nil end
    local actorOk,actorObject=pcall(resolve,state,pending.actor,false)
    local report=observed(state,pending.actor,actorOk and actorObject or nil)
    return {command_id=pending.command_id,status=matched and 'succeeded' or 'failed',
        reason_code=matched and 'command_applied' or 'teleport_verification_timeout',observed=report,
        session_id=sessionId,generation=generation}
end

return M
