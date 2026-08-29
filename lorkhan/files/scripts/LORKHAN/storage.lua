local constants = require('scripts.LORKHAN.constants')
local util = require('scripts.LORKHAN.util')

local M = {}
local allowed = {schemaVersion=true, profileId=true, playthroughId=true, generationSeed=true,
    preferences=true, conversationUi=true, actorStateHints=true}

local function sanitized(state)
    local out = {
        schemaVersion = constants.SAVE_SCHEMA_VERSION,
        profileId = state.profileId,
        playthroughId = state.playthroughId,
        generationSeed = state.generationSeed or 0,
        preferences = util.copy(state.preferences or {}),
        conversationUi = util.copy(state.conversationUi or {}),
        actorStateHints = util.copy(state.actorStateHints or {}),
    }
    if not util.isPrimitiveTree(out) then return nil, 'save_contains_non_primitive' end
    return out
end

function M.save(state)
    if state.futureSchema then return nil, 'future_schema_preserved' end
    return sanitized(state)
end

function M.load(raw, currentGeneration)
    if raw == nil then
        return sanitized({generationSeed = (currentGeneration or 0) + 1}), {migrated=false, disable=false}
    end
    if type(raw) ~= 'table' or type(raw.schemaVersion) ~= 'number' then return nil, {disable=true, reason='invalid_save'} end
    if raw.schemaVersion > constants.SAVE_SCHEMA_VERSION then
        return {futureSchema=true, disabled=true, raw=raw, generation=(currentGeneration or 0) + 1},
            {disable=true, preserve=true, reason='future_schema'}
    end
    for key in pairs(raw) do if not allowed[key] then return nil, {disable=true, reason='unknown_save_field'} end end
    local migrated = raw.schemaVersion < constants.SAVE_SCHEMA_VERSION
    local state, reason = sanitized(raw)
    if not state then return nil, {disable=true, reason=reason} end
    state.generationSeed = math.max(state.generationSeed or 0, currentGeneration or 0) + 1
    state.inFlight = nil
    return state, {migrated=migrated, disable=false}
end

return M
