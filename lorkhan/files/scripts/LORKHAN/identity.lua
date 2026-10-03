local M = {}

local required = {'kind', 'record_id', 'refnum', 'content_file', 'cell', 'display_name'}

-- actor.identity.dynamic.v1: runtime-generated actors carry a saved UUID plus their exact current
-- generated reference. The sentinel content file contains ':' so it can never alias a placed key.
M.DYNAMIC_CAPABILITY = 'actor.identity.dynamic.v1'
M.DYNAMIC_CONTENT_FILE = 'lorkhan:dynamic'
M.DYNAMIC_BINDING_VERSION = 1
M.MAX_DYNAMIC_BINDINGS = 256

local function isUuid(value)
    return type(value)=='string' and #value==36
        and value:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$')~=nil
        and value:lower()==value
end
M.isUuid = isUuid

-- A durable dynamic actor UUID must be canonical and never the nil UUID; generic IDs keep isUuid.
M.NIL_UUID = '00000000-0000-0000-0000-000000000000'
local function isActorUuid(value)
    return isUuid(value) and value~=M.NIL_UUID
end
M.isActorUuid = isActorUuid

-- OpenMW formats a generated RefNum{mIndex,-1} as "@0x" plus lowercase hex of its non-zero uint32 index.
function M.isRuntimeRef(value)
    return type(value)=='string' and #value<=11 and value:match('^@0x[1-9a-f][0-9a-f]*$')~=nil
end

local function cellKey(cell)
    if type(cell)~='table' then return nil end
    if cell.kind == 'exterior' then
        if type(cell.grid_x) ~= 'number' or type(cell.grid_y) ~= 'number' then return nil end
        return 'exterior:' .. tostring(cell.grid_x) .. ':' .. tostring(cell.grid_y)
    end
    if cell.kind == 'interior' and type(cell.name) == 'string' and cell.name ~= '' then
        return 'interior:' .. cell.name
    end
end

local function validDynamic(identity)
    local dynamic = identity.dynamic
    if type(dynamic)~='table' then return nil, 'identity_dynamic_invalid' end
    for key in pairs(dynamic) do
        if key~='uuid' and key~='runtime_ref' then return nil, 'identity_dynamic_invalid' end
    end
    if not isActorUuid(dynamic.uuid) or not M.isRuntimeRef(dynamic.runtime_ref) then return nil, 'identity_dynamic_invalid' end
    if identity.kind~='npc' and identity.kind~='creature' then return nil, 'identity_dynamic_kind_forbidden' end
    if identity.content_file~=M.DYNAMIC_CONTENT_FILE or identity.refnum.index~=0 or identity.refnum.content_file~=0 then
        return nil, 'identity_dynamic_sentinel_invalid'
    end
    return true
end

function M.validate(identity)
    if type(identity) ~= 'table' then return nil, 'identity_not_table' end
    for _, key in ipairs(required) do
        if identity[key] == nil then return nil, 'identity_missing_' .. key end
    end
    if identity.kind ~= 'npc' and identity.kind ~= 'creature' and identity.kind ~= 'player' and identity.kind ~= 'narrator' then
        return nil, 'identity_kind_forbidden'
    end
    if type(identity.record_id) ~= 'string' or identity.record_id == '' then return nil, 'identity_record_invalid' end
    if type(identity.content_file) ~= 'string' or identity.content_file == '' then return nil, 'identity_content_invalid' end
    if type(identity.refnum) ~= 'table' or type(identity.refnum.index) ~= 'number'
        or type(identity.refnum.content_file) ~= 'number'
        or identity.refnum.index % 1 ~= 0 or identity.refnum.index < 0 or identity.refnum.index > 4294967295
        then return nil, 'identity_refnum_invalid' end
    if not cellKey(identity.cell) then return nil, 'identity_cell_invalid' end
    if identity.dynamic ~= nil then return validDynamic(identity) end
    if identity.content_file == M.DYNAMIC_CONTENT_FILE then return nil, 'identity_content_invalid' end
    return true
end

function M.isDynamic(identity)
    return type(identity)=='table' and identity.dynamic~=nil
end

function M.key(identity)
    local ok, reason = M.validate(identity)
    if not ok then return nil, reason end
    -- Player and Narrator are session-owned identities, not placed references.
    if identity.kind == 'player' or identity.kind == 'narrator' then return identity.kind end
    -- A generated actor is durable only through its saved UUID, never its recyclable runtime slot.
    if identity.dynamic then return 'dynamic|' .. identity.dynamic.uuid end
    -- The file-local reference survives cell movement, renames and load-order changes.
    return string.lower(identity.content_file) .. '|' .. string.format('%.0f', identity.refnum.index)
end

function M.same(left, right)
    local leftKey = M.key(left)
    local rightKey = M.key(right)
    if leftKey == nil or leftKey ~= rightKey or left.kind ~= right.kind
        or string.lower(left.record_id) ~= string.lower(right.record_id) then return false end
    -- The exact runtime snapshot must match too, so a stale slot can never stand in for the actor.
    if left.dynamic then return left.dynamic.runtime_ref == right.dynamic.runtime_ref end
    return true
end

-- Decide whether an actor-local saved binding still describes this exact object in this playthrough.
function M.reconcileDynamic(binding, object, playthroughId)
    if type(binding)~='table' then return 'rebind', 'dynamic_binding_missing' end
    if type(binding.version)=='number' and binding.version>M.DYNAMIC_BINDING_VERSION then
        return 'reject', 'dynamic_identity_future_save'
    end
    if binding.version~=M.DYNAMIC_BINDING_VERSION or not isActorUuid(binding.uuid) or not isUuid(binding.playthrough_id)
        or not M.isRuntimeRef(binding.runtime_ref) or type(binding.record_id)~='string' then
        return 'rebind', 'dynamic_binding_invalid'
    end
    -- Saved state from another playthrough must never contaminate this one.
    if binding.playthrough_id~=playthroughId then return 'rebind', 'dynamic_scope_changed' end
    if type(object)~='table' and type(object)~='userdata' or binding.runtime_ref~=object.id then
        return 'rebind', 'dynamic_runtime_copied'
    end
    if string.lower(binding.record_id)~=string.lower(tostring(object.recordId)) then
        return 'rebind', 'dynamic_record_changed'
    end
    return 'keep'
end

local function alive(object)
    if object == nil then return false end
    if type(object)=='table' and object.isValid == nil then return true end
    local ok, valid = pcall(function() return object:isValid() end)
    return ok and valid == true
end

function M.Registry()
    local entries = {}
    local runtime = {}
    local quarantined = {}
    local dynamicCount = 0
    local dynamicEnabled = false
    local function drop(key)
        local entry = entries[key]
        if not entry then return end
        if entry.identity.dynamic then
            dynamicCount = dynamicCount - 1
            if runtime[entry.identity.dynamic.runtime_ref] == key then runtime[entry.identity.dynamic.runtime_ref] = nil end
        end
        entries[key] = nil
    end
    -- An entry is current only while its object still exists at the exact bound runtime slot.
    local function current(entry)
        if not entry.identity.dynamic then return true end
        return alive(entry.object) and entry.object.id == entry.identity.dynamic.runtime_ref
    end
    local function activateDynamic(key, identity, object)
        if not dynamicEnabled then return nil, 'dynamic_identity_not_negotiated' end
        local uuid = identity.dynamic.uuid
        if quarantined[uuid] then return nil, 'dynamic_identity_duplicate' end
        if not object or object.id ~= identity.dynamic.runtime_ref then return nil, 'actor_identity_mismatch' end
        local previous = entries[key]
        if previous and previous.object ~= object then
            if current(previous) then
                -- Two live objects claim one saved UUID (copied script state): isolate both.
                quarantined[uuid] = true
                drop(key)
                return nil, 'dynamic_identity_duplicate'
            end
            drop(key)
            previous = nil
        end
        local slotKey = runtime[identity.dynamic.runtime_ref]
        if slotKey and slotKey ~= key then
            local occupant = entries[slotKey]
            if occupant and current(occupant) then return nil, 'ambiguous_active_identity' end
            drop(slotKey)
        end
        if not previous and dynamicCount >= M.MAX_DYNAMIC_BINDINGS then return nil, 'dynamic_identity_capacity' end
        if not previous then dynamicCount = dynamicCount + 1 end
        entries[key] = {identity = identity, object = object}
        runtime[identity.dynamic.runtime_ref] = key
        return key
    end
    return {
        activate = function(_, identity, object)
            local key, reason = M.key(identity)
            if not key then return nil, reason end
            if identity.dynamic then return activateDynamic(key, identity, object) end
            local previous = entries[key]
            if previous and (previous.object ~= object or not M.same(previous.identity, identity)) then return nil, 'ambiguous_active_identity' end
            entries[key] = {identity = identity, object = object}
            return key
        end,
        deactivate = function(_, identity, object)
            local key = M.key(identity)
            local entry = key and entries[key]
            if entry and M.same(entry.identity, identity) and (object == nil or entry.object == object) then drop(key) return true end
            return false
        end,
        resolve = function(_, identity)
            local key, reason = M.key(identity)
            if not key then return nil, reason end
            if identity.dynamic then
                if not dynamicEnabled then return nil, 'dynamic_identity_not_negotiated' end
                if quarantined[identity.dynamic.uuid] then return nil, 'dynamic_identity_duplicate' end
            end
            local entry = entries[key]
            if not entry then return nil, 'actor_inactive' end
            if not M.same(entry.identity, identity) then return nil, 'actor_identity_mismatch' end
            if not current(entry) then drop(key) return nil, 'actor_inactive' end
            return entry.object, entry.identity
        end,
        -- Negotiation is per session; losing it withdraws every dynamic binding at once.
        setDynamicEnabled = function(_, enabled)
            dynamicEnabled = enabled == true
            if dynamicEnabled then return end
            for key, entry in pairs(entries) do if entry.identity.dynamic then drop(key) end end
            quarantined = {}
        end,
        dynamicEnabled = function() return dynamicEnabled end,
        isQuarantined = function(_, uuid) return quarantined[uuid] == true end,
        -- Immutable binding rows for emission; stale entries are withdrawn rather than published.
        dynamicBindings = function()
            local rows = {}
            for key, entry in pairs(entries) do
                if entry.identity.dynamic then
                    if current(entry) then
                        rows[#rows + 1] = {runtime_ref = entry.identity.dynamic.runtime_ref,
                            uuid = entry.identity.dynamic.uuid, kind = entry.identity.kind,
                            record_id = entry.identity.record_id}
                    else drop(key) end
                end
            end
            table.sort(rows, function(left, right) return left.uuid < right.uuid end)
            return rows
        end,
        clear = function() entries = {} runtime = {} quarantined = {} dynamicCount = 0 end,
        size = function() local n = 0 for _ in pairs(entries) do n = n + 1 end return n end,
    }
end

return M
