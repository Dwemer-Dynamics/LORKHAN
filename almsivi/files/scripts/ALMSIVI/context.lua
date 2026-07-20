local constants = require('scripts.ALMSIVI.constants')
local util = require('scripts.ALMSIVI.util')

local M = {limits = constants}

local function bounded(values, limit)
    values = values or {}
    return {items = util.arrayCopy(values, limit), total = #values, truncated = #values > limit}
end

local function estimate(value, seen)
    local kind=type(value)
    if kind=='string' then return #value
    elseif kind=='number' then return 16
    elseif kind=='boolean' then return 5
    elseif kind=='nil' then return 4
    elseif kind~='table' then return constants.MAX_CONTEXT_BYTES+1 end
    seen=seen or {}
    if seen[value] then return constants.MAX_CONTEXT_BYTES+1 end
    seen[value]=true
    local bytes=2
    for key,item in pairs(value) do bytes=bytes+estimate(key,seen)+estimate(item,seen)+2 end
    seen[value]=nil
    return bytes
end

function M.snapshot(source)
    source = source or {}
    local snapshot = {
        mode = source.mode or 'full',
        player = util.copy(source.player),
        target = util.copy(source.target),
        audience = bounded(source.audience, constants.MAX_AUDIENCE),
        nearbyActors = bounded(source.nearbyActors, constants.MAX_AUDIENCE),
        nearbyObjects = bounded(source.nearbyObjects, constants.MAX_NEARBY_OBJECTS),
        inventory = bounded(source.inventory, constants.MAX_INVENTORY_ROWS),
        activeEffects = bounded(source.activeEffects, constants.MAX_ACTIVE_EFFECTS),
        journal = bounded(source.journal, constants.MAX_JOURNAL_ENTRIES),
        contentFiles = bounded(source.contentFiles, constants.MAX_CONTENT_FILES),
        capabilities = util.copy(source.capabilities or {}),
        unavailable = util.copy(source.unavailable or {}),
    }
    local estimated = estimate(snapshot)
    snapshot.budget = {maxBytes = constants.MAX_CONTEXT_BYTES, estimatedBytes = estimated,
        truncated = estimated > constants.MAX_CONTEXT_BYTES,
        averageCollectionMs = constants.COLLECTION_AVERAGE_MS, p99CollectionMs = constants.COLLECTION_P99_MS}
    if snapshot.budget.truncated then
        snapshot.nearbyObjects.items = {}
        snapshot.nearbyObjects.truncated = snapshot.nearbyObjects.total > 0
        snapshot.inventory.items = {}
        snapshot.inventory.truncated = snapshot.inventory.total > 0
    end
    return snapshot
end

function M.delta(previous, current)
    local result = M.snapshot(current)
    result.mode = 'delta'
    result.baseRevision = previous and previous.revision or nil
    return result
end

return M
