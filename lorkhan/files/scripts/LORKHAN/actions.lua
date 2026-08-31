local constants = require('scripts.LORKHAN.constants')
local identity = require('scripts.LORKHAN.identity')
local util = require('scripts.LORKHAN.util')

local M = {}
local equipmentSlots={helmet=true,cuirass=true,greaves=true,left_pauldron=true,right_pauldron=true,
    left_gauntlet=true,right_gauntlet=true,boots=true,shirt=true,pants=true,skirt=true,robe=true,
    left_ring=true,right_ring=true,amulet=true,belt=true,carried_right=true,carried_left=true,ammunition=true}

local function terminal(status)
    return status=='succeeded' or status=='failed' or status=='rejected' or status=='timed_out' or status=='cancelled'
end

function M.new(capabilities)
    local enabled={}
    for _, name in ipairs(capabilities or {}) do enabled[name]=true end
    return {enabled=enabled, byTurn={}, results={}, continuations={}}
end

function M.validate(state, intent, authority)
    if type(intent) ~= 'table' or intent.schema ~= 'lorkhan.action-intent.v1' then return nil,'invalid_action_schema' end
    local definitions={
        ['inspect.report']={capability='action.inspect.report',tier=0},
        ['inventory.inspect']={capability='action.inventory.inspect',tier=0},
        ['ai.follow']={capability='action.ai.follow',tier=1},
        ['ai.stop']={capability='action.ai.stop',tier=1},
        ['ai.approach']={capability='action.ai.approach',tier=1},
        ['ai.wait']={capability='action.ai.wait',tier=1},
        ['ai.travel']={capability='action.ai.travel',tier=1},
        ['ai.escort']={capability='action.ai.escort',tier=1},
        ['ai.face']={capability='action.ai.face',tier=1},
        ['ai.wander']={capability='action.ai.wander',tier=1},
        ['combat.start']={capability='action.combat.start',tier=2},
        ['combat.stop']={capability='action.combat.stop',tier=1},
        ['animation.play']={capability='action.animation.play',tier=1},
        ['item.equip']={capability='action.item.equip',tier=2},
        ['item.unequip']={capability='action.item.unequip',tier=2},
        ['item.use']={capability='action.item.use',tier=2},
    }
    local definition=definitions[intent.name]
    if not definition then return nil,'action_not_allowlisted' end
    local capability=definition.capability
    if not state.enabled[capability] then return nil,'capability_disabled' end
    if intent.tier ~= definition.tier then return nil,'invalid_action_tier' end
    if intent.generation ~= authority.generation or intent.session_id ~= authority.session_id then return nil,'stale_action' end
    if not identity.same(intent.actor, authority.actor) then return nil,'wrong_actor' end
    if not authority.resolve(intent.actor) then return nil,'actor_inactive' end
    if not identity.validate(intent.target) or not authority.resolve(intent.target) then return nil,'target_inactive' end
    if type(authority.expired)~='function' or authority.expired(intent.expires_at) then return nil,'action_expired' end
    if intent.display_name~=nil and (type(intent.display_name)~='string' or #intent.display_name<1 or #intent.display_name>128) then
        return nil,'invalid_action_display_name'
    end
    if intent.confirmation_required~=nil and type(intent.confirmation_required)~='boolean' then
        return nil,'invalid_action_confirmation'
    end
    if intent.followup_enabled~=nil and type(intent.followup_enabled)~='boolean' then
        return nil,'invalid_action_followup'
    end
    local count=state.byTurn[intent.turn_id] or 0
    if count >= constants.MAX_ACTIONS_PER_TURN then return nil,'turn_action_limit' end
    if type(intent.parameters)~='table' then return nil,'invalid_action_parameters' end
    local parameters={}
    if intent.name=='ai.follow' then
        for key in pairs(intent.parameters) do if key~='distance' then return nil,'unknown_follow_parameter' end end
        local distance=intent.parameters.distance
        if type(distance)~='number' or distance%1~=0 or distance~=192 then return nil,'invalid_follow_distance' end
        parameters.distance=distance
    elseif intent.name=='ai.travel' or intent.name=='ai.escort' then
        local allowed={destination_x=true,destination_y=true,destination_z=true,destination_cell=true}
        for key in pairs(intent.parameters) do if not allowed[key] then return nil,'unknown_destination_parameter' end end
        for _,axis in ipairs({'destination_x','destination_y','destination_z'}) do
            local value=intent.parameters[axis]
            if type(value)~='number' or value~=value or value<-100000000 or value>100000000 then
                return nil,'invalid_destination_coordinate'
            end
            parameters[axis]=value
        end
        local cell=intent.parameters.destination_cell
        if type(cell)~='string' or #cell<1 or #cell>300
            or not (cell:match('^interior:.+$') or cell:match('^exterior:%-?%d+:%-?%d+$')) then
            return nil,'invalid_destination_cell'
        end
        parameters.destination_cell=cell
    elseif intent.name=='ai.wait' then
        for key in pairs(intent.parameters) do if key~='duration_seconds' then return nil,'unknown_wait_parameter' end end
        local duration=intent.parameters.duration_seconds
        if type(duration)~='number' or duration%3600~=0 or duration<3600 or duration>86400 then return nil,'invalid_wait_duration' end
        parameters.duration_seconds=duration
    elseif intent.name=='ai.wander' then
        for key in pairs(intent.parameters) do if key~='distance' and key~='duration_seconds' then return nil,'unknown_wander_parameter' end end
        local distance=intent.parameters.distance
        local duration=intent.parameters.duration_seconds
        if type(distance)~='number' or distance%1~=0 or distance<0 or distance>2048 then return nil,'invalid_wander_distance' end
        if type(duration)~='number' or duration%3600~=0 or duration<3600 or duration>86400 then return nil,'invalid_wander_duration' end
        parameters.distance=distance parameters.duration_seconds=duration
    elseif intent.name=='animation.play' then
        for key in pairs(intent.parameters) do if key~='group' then return nil,'unknown_animation_parameter' end end
        local allowed={idle2=true,idle3=true,idle4=true,idle5=true,idle6=true,idle7=true,idle8=true,idle9=true}
        if type(intent.parameters.group)~='string' or not allowed[intent.parameters.group] then return nil,'invalid_animation_group' end
        parameters.group=intent.parameters.group
    elseif intent.name=='item.use' or intent.name=='item.equip' then
        for key in pairs(intent.parameters) do
            if key~='record_id' and (intent.name~='item.equip' or key~='slot') then return nil,'unknown_item_parameter' end
        end
        local recordId=intent.parameters.record_id
        if type(recordId)~='string' or #recordId<1 or #recordId>128 or recordId:find('[%c/\\]') then return nil,'invalid_item_record_id' end
        parameters.record_id=recordId
        if intent.name=='item.equip' then
            if not equipmentSlots[intent.parameters.slot] then return nil,'invalid_equipment_slot' end
            parameters.slot=intent.parameters.slot
        end
    elseif intent.name=='item.unequip' then
        for key in pairs(intent.parameters) do if key~='slot' then return nil,'unknown_item_parameter' end end
        if not equipmentSlots[intent.parameters.slot] then return nil,'invalid_equipment_slot' end
        parameters.slot=intent.parameters.slot
    elseif intent.name=='inspect.report' then
        for _ in pairs(intent.parameters) do return nil,'unknown_inspect_parameter' end
    elseif intent.name=='inventory.inspect' then
        for _ in pairs(intent.parameters) do return nil,'unknown_inventory_parameter' end
    elseif intent.name=='ai.approach' then
        for _ in pairs(intent.parameters) do return nil,'unknown_approach_parameter' end
    else
        for _ in pairs(intent.parameters) do return nil,'unknown_action_parameter' end
    end
    state.byTurn[intent.turn_id]=count+1
    return {action_id=intent.action_id, turn_id=intent.turn_id, request_id=intent.request_id,
        generation=intent.generation, actor=util.copy(intent.actor), target=util.copy(intent.target),
        name=intent.name,display_name=intent.display_name,confirmation_required=intent.confirmation_required,
        followup_enabled=intent.followup_enabled,parameters=parameters,expires_at=intent.expires_at}
end

function M.result(state, actionId, status, reason, observed)
    if state.results[actionId] then return nil,'terminal_result_exists' end
    if not terminal(status) then return nil,'non_terminal_status' end
    local result={kind='lorkhan.internal.action-terminal',action_id=actionId,status=status,
        reason=reason,observed=util.copy(observed or {})}
    state.results[actionId]=result
    return result
end

function M.canonicalResult(internal, correlation, completedAt)
    if type(internal)~='table' or internal.kind~='lorkhan.internal.action-terminal' then return nil,'invalid_internal_result' end
    if type(correlation)~='table' then return nil,'correlation_required' end
    local function uuid(value)
        if type(value)~='string' then return false end
        local a,b,c,d,e=value:match('^([0-9a-f]+)%-([0-9a-f]+)%-([0-9a-f]+)%-([0-9a-f]+)%-([0-9a-f]+)$')
        return a and #a==8 and #b==4 and #c==4 and #d==4 and #e==12 or false
    end
    if not uuid(internal.action_id) then return nil,'invalid_action_id' end
    for _,key in ipairs({'message_id','request_id','turn_id','session_id'}) do
        if not uuid(correlation[key]) then return nil,'invalid_'..key end
    end
    if type(correlation.generation)~='number' or correlation.generation%1~=0 or correlation.generation<0 then return nil,'invalid_generation' end
    if type(completedAt)~='string' or not completedAt:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$') then return nil,'completed_at_required' end
    return {schema='lorkhan.action-result.v1',message_id=correlation.message_id,request_id=correlation.request_id,
        action_id=internal.action_id,turn_id=correlation.turn_id,session_id=correlation.session_id,
        generation=correlation.generation,status=internal.status,reason_code=internal.reason or 'unspecified',
        observed=util.copy(internal.observed),completed_at=completedAt}
end

function M.claimContinuation(state, actionId)
    local n=state.continuations[actionId] or 0
    if n >= constants.MAX_CONTINUATIONS_PER_ACTION then return nil,'continuation_limit' end
    state.continuations[actionId]=n+1 return true
end

return M
