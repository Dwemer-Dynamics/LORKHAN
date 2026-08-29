local M = {}

function M.copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then error('cycles are not serializable') end
    seen[value] = true
    local out = {}
    for key, item in pairs(value) do out[M.copy(key, seen)] = M.copy(item, seen) end
    seen[value] = nil
    return out
end

function M.arrayCopy(values, limit)
    local out = {}
    for index = 1, math.min(#values, limit or #values) do out[index] = M.copy(values[index]) end
    return out
end

function M.isPrimitiveTree(value, seen)
    local kind = type(value)
    if kind == 'nil' or kind == 'boolean' or kind == 'number' or kind == 'string' then return true end
    if kind ~= 'table' then return false end
    seen = seen or {}
    if seen[value] then return false end
    seen[value] = true
    for key, item in pairs(value) do
        if not M.isPrimitiveTree(key, seen) or not M.isPrimitiveTree(item, seen) then return false end
    end
    seen[value] = nil
    return true
end

function M.count(values)
    local n = 0
    for _ in pairs(values or {}) do n = n + 1 end
    return n
end

return M
