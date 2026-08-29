local constants = require('scripts.LORKHAN.constants')
local identity = require('scripts.LORKHAN.identity')
local util = require('scripts.LORKHAN.util')

local M = {}

function M.validate(candidate, registry, policy)
    policy=policy or {}
    if type(candidate)~='table' or not identity.validate(candidate.identity) then return nil,'invalid_target' end
    if candidate.identity.kind~='npc' and candidate.identity.kind~='creature' then return nil,'not_actor' end
    if type(candidate.distance)~='number' or type(candidate.maxDistance)~='number' or candidate.distance > candidate.maxDistance then return nil,'target_out_of_range' end
    if candidate.dead then return nil,'target_dead' end
    if candidate.hostile and not policy.allowHostile then return nil,'target_hostile' end
    if candidate.identity.kind=='creature' and not policy.allowCreatures then return nil,'target_creature' end
    if candidate.available==false then return nil,'target_unavailable' end
    if not registry:resolve(candidate.identity) then return nil,'target_inactive' end
    return util.copy(candidate.identity)
end

function M.nearby(candidates, registry)
    local accepted={}
    for _,candidate in ipairs(candidates or {}) do
        local actor=M.validate(candidate,registry)
        if actor then table.insert(accepted,{identity=actor,distance=candidate.distance}) end
    end
    table.sort(accepted,function(a,b)
        if a.distance~=b.distance then return a.distance<b.distance end
        return identity.key(a.identity)<identity.key(b.identity)
    end)
    local limit=constants.MAX_AUDIENCE
    return util.arrayCopy(accepted,limit)
end

return M
