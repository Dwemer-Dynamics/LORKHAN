local constants = require('scripts.LORKHAN.constants')
local identity = require('scripts.LORKHAN.identity')
local util = require('scripts.LORKHAN.util')

local M = {}

-- Speaking story characters use creature records but should be discovered like NPCs.
local namedCharacters={
    vivec_god=true,['yagrum bagarn']=true,almalexia=true,almalexia_warrior=true,
    bm_hircine=true,bm_hircine2=true,bm_hircine_huntaspect=true,
    bm_hircine_straspect=true,bm_hircine_spdaspect=true,
    dagoth_ur_1=true,dagoth_ur_2=true,['dagoth gares']=true,
    ['dagoth odros']=true,['dagoth vemyn']=true,['dagoth endus']=true,
    ['dagoth tureynul']=true,['dagoth gilvoth']=true,['dagoth araynys']=true,['dagoth uthol']=true,
}

function M.isNamedCharacter(actor)
    return type(actor)=='table' and actor.kind=='creature'
        and namedCharacters[string.lower(tostring(actor.record_id or ''))]==true
end

function M.validate(candidate, registry, policy)
    policy=policy or {}
    if type(candidate)~='table' or not identity.validate(candidate.identity) then return nil,'invalid_target' end
    if candidate.identity.kind~='npc' and candidate.identity.kind~='creature' then return nil,'not_actor' end
    if type(candidate.distance)~='number' or type(candidate.maxDistance)~='number' or candidate.distance > candidate.maxDistance then return nil,'target_out_of_range' end
    if candidate.dead then return nil,'target_dead' end
    if candidate.hostile and not policy.allowHostile then return nil,'target_hostile' end
    if candidate.identity.kind=='creature' and not policy.allowCreatures
        and not M.isNamedCharacter(candidate.identity) then return nil,'target_creature' end
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
