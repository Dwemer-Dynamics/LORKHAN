local core=require('openmw.core')
local self=require('openmw.self')

-- CUSTOM actor-local holder for one runtime-generated actor's persistent LORKHAN identity.
-- OpenMW saves this script's data with the actor itself and deletes it with the actor, so the UUID
-- never depends on the recyclable runtime slot. Newer binding formats are preserved untouched.
local binding
local function copy(value)
    if type(value)~='table' then return value end
    local out={}
    for key,item in pairs(value) do out[key]=copy(item) end
    return out
end
local function store(data)
    binding=type(data)=='table' and copy(data) or nil
end
local function report(generation)
    local future=type(binding)=='table' and type(binding.version)=='number' and binding.version>1
    core.sendGlobalEvent('LORKHAN_DYNAMIC_IDENTITY_REPORT',{object=self.object,generation=generation,
        binding=not future and copy(binding) or nil,future=future or nil})
end
return {
    engineHandlers={
        onInit=store,
        onSave=function() return copy(binding) end,
        onLoad=store,
    },
    eventHandlers={
        LORKHAN_DYNAMIC_IDENTITY_QUERY=function(event)
            if type(event)=='table' then report(event.generation) end
        end,
        LORKHAN_DYNAMIC_IDENTITY_ASSIGN=function(event)
            -- GLOBAL replaces only missing, foreign-playthrough, copied or invalid bindings.
            if type(event)~='table' or type(event.binding)~='table' or event.binding.version~=1 then return end
            if type(binding)=='table' and type(binding.version)=='number' and binding.version>1 then return end
            store(event.binding)
        end,
    },
}
