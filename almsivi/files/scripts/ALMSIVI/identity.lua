local M = {}

local required = {'kind', 'record_id', 'refnum', 'content_file', 'cell', 'display_name'}

local function cellKey(cell)
    if cell.kind == 'exterior' then
        if type(cell.grid_x) ~= 'number' or type(cell.grid_y) ~= 'number' then return nil end
        return 'exterior:' .. tostring(cell.grid_x) .. ':' .. tostring(cell.grid_y)
    end
    if cell.kind == 'interior' and type(cell.name) == 'string' and cell.name ~= '' then
        return 'interior:' .. cell.name
    end
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
        or type(identity.refnum.content_file) ~= 'number' then return nil, 'identity_refnum_invalid' end
    if not cellKey(identity.cell) then return nil, 'identity_cell_invalid' end
    return true
end

function M.key(identity)
    local ok, reason = M.validate(identity)
    if not ok then return nil, reason end
    return table.concat({identity.kind, identity.record_id, identity.content_file,
        tostring(identity.refnum.content_file), tostring(identity.refnum.index), cellKey(identity.cell)}, '|')
end

function M.same(left, right)
    local leftKey = M.key(left)
    local rightKey = M.key(right)
    return leftKey ~= nil and leftKey == rightKey
end

function M.Registry()
    local entries = {}
    return {
        activate = function(_, identity, object)
            local key, reason = M.key(identity)
            if not key then return nil, reason end
            local previous = entries[key]
            if previous and previous.object ~= object then return nil, 'ambiguous_active_identity' end
            entries[key] = {identity = identity, object = object}
            return key
        end,
        deactivate = function(_, identity, object)
            local key = M.key(identity)
            local entry = key and entries[key]
            if entry and (object == nil or entry.object == object) then entries[key] = nil return true end
            return false
        end,
        resolve = function(_, identity)
            local key, reason = M.key(identity)
            if not key then return nil, reason end
            local entry = entries[key]
            if not entry then return nil, 'actor_inactive' end
            return entry.object, entry.identity
        end,
        clear = function() entries = {} end,
        size = function() local n = 0 for _ in pairs(entries) do n = n + 1 end return n end,
    }
end

return M
