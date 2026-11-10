local interfaces=require('openmw.interfaces')
local example=require('scripts.parity_example.manifest')

-- GLOBAL half of the example: register once per game start, handle mark_camp here and route wander_briefly to the
-- actor's own CUSTOM script. LORKHAN_Addons must load first (place this content after LORKHAN.omwscripts).
local addons=interfaces.LORKHAN_Addons
local handle

local function markCamp(context)
    local mood=context.parameters.mood
    -- Emission is best effort: rate limits or an inactive session never fail the action itself.
    addons.emit(handle,'camp_marked',{actor=context.actor,mood=mood})
    return {status='succeeded',reason_code='camp_marked',observed={mood=mood}}
end

if addons and addons.version==1 then
    local reason
    handle,reason=addons.register({manifest=example.manifest,manifest_sha256=example.sha256,handlers={
        mark_camp={scope='global',run=markCamp},
        wander_briefly={scope='self',script='scripts/parity_example/actor.lua'},
    }})
    if not handle then print('[ParityExample] registration refused: '..tostring(reason)) end
end

return {}
