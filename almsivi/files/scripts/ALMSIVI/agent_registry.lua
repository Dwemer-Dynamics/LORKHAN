local identity=require('scripts.ALMSIVI.identity')
local util=require('scripts.ALMSIVI.util')

local M={}

function M.new(maximum)
    return {entries={},scan=0,maximum=maximum or 32}
end

local function count(entries)
    local total=0
    for _ in pairs(entries) do total=total+1 end
    return total
end

function M.get(state,actor)
    local key=identity.key(actor)
    return key and state.entries[key] or nil
end

function M.activate(state,actor,source,distance)
    local key,reason=identity.key(actor)
    if not key then return nil,reason end
    local targetPromotion=source=='target'
    source=(source=='manual' or targetPromotion) and 'manual' or 'auto'
    local entry=state.entries[key]
    if entry then
        entry.distance=distance or entry.distance
        entry.lastSeenScan=state.scan
        if source=='manual' and entry.source=='manual' and not targetPromotion then
            state.entries[key]=nil
            return {identity=util.copy(entry.identity),source='manual'},'deactivated'
        end
        if source=='manual' and entry.source~='manual' then
            entry.source='manual' entry.pinned=true
            return entry,'upgraded'
        end
        return entry,'existing'
    end
    if count(state.entries)>=state.maximum then return nil,'agent_limit' end
    entry={identity=util.copy(actor),source=source,pinned=source=='manual',distance=distance or 0,
        lastSeenScan=state.scan}
    state.entries[key]=entry
    return entry,'activated'
end

function M.markSeen(state,actor,distance)
    local entry=M.get(state,actor)
    if not entry then return false end
    entry.lastSeenScan=state.scan entry.distance=distance or entry.distance
    return true
end

function M.beginScan(state)
    state.scan=state.scan+1
    return state.scan
end

function M.sweep(state,missingScans)
    missingScans=missingScans or 4
    local removed={}
    for key,entry in pairs(state.entries) do
        if entry.source=='auto' and state.scan-entry.lastSeenScan>=missingScans then
            removed[#removed+1]=util.copy(entry.identity)
            state.entries[key]=nil
        end
    end
    return removed
end

function M.remove(state,actor)
    local key=identity.key(actor)
    local entry=key and state.entries[key]
    if not entry then return nil,'agent_not_found' end
    state.entries[key]=nil
    return util.copy(entry.identity)
end

function M.clear(state)
    local removed=M.snapshot(state)
    state.entries={} state.scan=0
    return removed
end

function M.snapshot(state)
    local result={}
    for _,entry in pairs(state.entries) do
        result[#result+1]={identity=util.copy(entry.identity),source=entry.source,pinned=entry.pinned,
            distance=entry.distance,lastSeenScan=entry.lastSeenScan}
    end
    table.sort(result,function(left,right)
        if left.distance~=right.distance then return left.distance<right.distance end
        return identity.key(left.identity)<identity.key(right.identity)
    end)
    return result
end

return M
