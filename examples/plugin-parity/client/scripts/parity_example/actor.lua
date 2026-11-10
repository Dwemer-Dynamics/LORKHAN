local interfaces=require('openmw.interfaces')
local addonSelf=require('scripts.LORKHAN.addon_self')

-- SELF half of the example. LORKHAN attaches this CUSTOM script to the exact actor only after validation and the
-- player's confirmation; it changes only this actor's AI and completes asynchronously one second later.
local pending

local script=addonSelf.script('parity.example',{
    wander_briefly=function(context,api)
        interfaces.AI.startPackage({type='Wander',distance=context.parameters.distance,duration=10})
        pending={action_id=context.action_id,api=api,remaining=1,distance=context.parameters.distance}
    end,
},{cancel=function(context)
    if pending and pending.action_id==context.action_id then
        pending=nil
        interfaces.AI.removePackages('Wander')
    end
end})

script.engineHandlers.onUpdate=function(dt)
    if not pending then return end
    pending.remaining=pending.remaining-(tonumber(dt) or 0)
    if pending.remaining>0 then return end
    local done=pending
    pending=nil
    done.api.complete(done.action_id,{status='succeeded',reason_code='wander_started',observed={distance=done.distance}})
end

local onInactive=script.engineHandlers.onInactive
script.engineHandlers.onInactive=function()
    pending=nil
    onInactive()
end

return script
