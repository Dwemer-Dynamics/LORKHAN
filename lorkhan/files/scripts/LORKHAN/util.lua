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

-- Split complete dialogue into a bounded ordered speech queue without dropping trailing text.
function M.splitSentences(text, limit)
    text = type(text) == 'string' and text:gsub('%s+', ' '):match('^%s*(.-)%s*$') or ''
    if text == '' then return {} end
    limit = math.max(1, math.floor(tonumber(limit) or 8))
    local sentences, start, index = {}, 1, 1
    while index <= #text and #sentences < limit - 1 do
        local character = text:sub(index, index)
        if character == '.' or character == '!' or character == '?' then
            local finish = index
            while finish < #text and text:sub(finish + 1, finish + 1):match('[.!?]') do finish = finish + 1 end
            while finish < #text and text:sub(finish + 1, finish + 1):match('["%)%]%}]') do finish = finish + 1 end
            local following = text:sub(finish + 1, finish + 1)
            if finish == #text or following:match('%s') then
                local sentence = text:sub(start, finish):match('^%s*(.-)%s*$')
                if sentence ~= '' then sentences[#sentences + 1] = sentence end
                start = finish + 1
                while start <= #text and text:sub(start, start):match('%s') do start = start + 1 end
                index = start
            else index = finish + 1 end
        else index = index + 1 end
    end
    local remainder = text:sub(start):match('^%s*(.-)%s*$')
    if remainder ~= '' then sentences[#sentences + 1] = remainder end
    return sentences
end

return M
