local identity=require('scripts.LORKHAN.identity')

-- GLOBAL coordinator for actor.identity.dynamic.v1. The durable UUID lives in the CUSTOM
-- dynamic_actor.lua script saved with the actual OpenMW actor; this module only reconciles that
-- saved binding with the current playthrough/generation and publishes the exact runtime snapshot.
local M={}
M.SCRIPT='scripts/LORKHAN/dynamic_actor.lua'
M.MAX_PENDING=256

local function isGeneratedActor(object)
    return object~=nil and type(object.id)=='string' and identity.isRuntimeRef(object.id)
end

-- options: registry, mint() -> uuid, identify(object) -> wire identity, publish(rows), isPlayer(object)
function M.new(options)
    return {registry=options.registry,mint=options.mint,identify=options.identify,
        publish=options.publish or function() end,isPlayer=options.isPlayer or function() return false end,
        enabled=false,playthroughId=nil,generation=nil,pending={},pendingCount=0,signature=nil}
end

local function publish(coordinator)
    coordinator.publish(coordinator.registry:dynamicBindings(),coordinator.generation)
end

-- Returns true when the effective scope changed and active actors must be observed again.
function M.configure(coordinator,enabled,playthroughId,generation)
    enabled=enabled==true and identity.isUuid(playthroughId)
    local signature=tostring(enabled)..'|'..tostring(playthroughId)..'|'..tostring(generation)
    if signature==coordinator.signature then return false end
    coordinator.signature=signature
    coordinator.enabled=enabled
    coordinator.playthroughId=enabled and playthroughId or nil
    coordinator.generation=generation
    coordinator.pending={} coordinator.pendingCount=0
    -- Any scope change withdraws every binding; active actors re-prove theirs from saved state.
    coordinator.registry:setDynamicEnabled(false)
    coordinator.registry:setDynamicEnabled(enabled)
    publish(coordinator)
    return true
end

local function bind(coordinator,object,binding)
    local wire,reason=coordinator.identify(object,binding)
    if not wire then return nil,reason end
    local key
    key,reason=coordinator.registry:activate(wire,object)
    publish(coordinator)
    if not key then return nil,reason end
    return wire
end

local function freshBinding(coordinator,object)
    local uuid=coordinator.mint and coordinator.mint()
    if not identity.isActorUuid(uuid) then return nil,'dynamic_identity_mint_failed' end
    return {version=identity.DYNAMIC_BINDING_VERSION,uuid=uuid,playthrough_id=coordinator.playthroughId,
        runtime_ref=object.id,record_id=object.recordId}
end

-- Called for every active actor. Placed actors and the player are left to the v1 identity path.
function M.observe(coordinator,object)
    if not isGeneratedActor(object) or coordinator.isPlayer(object) then return nil,'not_dynamic_actor' end
    if not coordinator.enabled then return nil,'dynamic_identity_not_negotiated' end
    if not object.hasScript or not object.addScript or not object.sendEvent then return nil,'actor_script_unavailable' end
    local okScript,hasScript=pcall(function() return object:hasScript(M.SCRIPT) end)
    if not okScript then return nil,'actor_script_unavailable' end
    if hasScript then
        if not coordinator.pending[object.id] then
            if coordinator.pendingCount>=M.MAX_PENDING then return nil,'dynamic_identity_capacity' end
            coordinator.pendingCount=coordinator.pendingCount+1
        end
        coordinator.pending[object.id]={object=object}
        object:sendEvent('LORKHAN_DYNAMIC_IDENTITY_QUERY',{generation=coordinator.generation})
        return nil,'dynamic_identity_pending'
    end
    local binding,reason=freshBinding(coordinator,object)
    if not binding then return nil,reason end
    local attached=pcall(function() object:addScript(M.SCRIPT,binding) end)
    if not attached then return nil,'actor_script_unavailable' end
    return bind(coordinator,object,binding)
end

-- Immutable proof for the dynamic identities one GLOBAL command names: each row is re-proven against
-- the registry now (UUID, slot, kind, record, liveness). Unproven identities are omitted and reported
-- as incomplete, so actor scripts and native consumers fail closed instead of trusting the slot.
function M.proof(coordinator,...)
    local rows,complete={},true
    for index=1,select('#',...) do
        local actor=select(index,...)
        if identity.isDynamic(actor) then
            local object=coordinator.enabled and coordinator.registry:resolve(actor)
            if object then
                rows[#rows+1]={runtime_ref=actor.dynamic.runtime_ref,uuid=actor.dynamic.uuid,
                    kind=actor.kind,record_id=actor.record_id}
            else complete=false end
        end
    end
    if #rows==0 then return nil,complete end
    return {generation=coordinator.generation,bindings=rows},complete
end

-- Accept only the current generation's answer from the exact object that was queried.
function M.report(coordinator,event)
    if type(event)~='table' or not coordinator.enabled or event.generation~=coordinator.generation then return nil,'stale_dynamic_report' end
    local object=event.object
    local runtimeRef=object and object.id
    local pending=type(runtimeRef)=='string' and coordinator.pending[runtimeRef]
    if not pending or pending.object~=object then return nil,'unexpected_dynamic_report' end
    coordinator.pending[runtimeRef]=nil coordinator.pendingCount=coordinator.pendingCount-1
    local decision,reason=identity.reconcileDynamic(event.binding,object,coordinator.playthroughId)
    if event.future then decision,reason='reject','dynamic_identity_future_save' end
    if decision=='reject' then return nil,reason end
    local binding=event.binding
    if decision=='rebind' then
        binding,reason=freshBinding(coordinator,object)
        if not binding then return nil,reason end
        object:sendEvent('LORKHAN_DYNAMIC_IDENTITY_ASSIGN',{generation=coordinator.generation,binding=binding})
    end
    return bind(coordinator,object,binding)
end

return M
