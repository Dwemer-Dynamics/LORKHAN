local util=require('scripts.LORKHAN.util')
local adapter=require('scripts.LORKHAN.adapters.openmw')
local identity=require('scripts.LORKHAN.identity')

-- SELF-only executor for addon CUSTOM scripts (LORKHAN_Addons v1). LORKHAN GLOBAL attaches the addon's declared
-- script to the exact actor and routes already-validated, confirmed intents here. Handlers act only on openmw.self.
-- Usage in an addon CUSTOM script: return require('scripts.LORKHAN.addon_self').script(pluginId, handlers, options)
local M={}

local MAX_SEEN=128

-- Snapshot this script's actual actor; the dispatched payload.actor is a claim to check, never proof.
local function actualSelf()
    local ok,object=pcall(require,'openmw.self')
    if not ok or not object then return nil end
    local actual=adapter.identity(object)
    if actual and identity.validate(actual) then return actual end
end

local function wellFormed(payload,pluginId)
    return type(payload)=='table' and payload.plugin_id==pluginId and type(payload.action_id)=='string'
        and payload.action_id~='' and type(payload.nonce)=='string' and payload.nonce~=''
        and type(payload.generation)=='number' and type(payload.action)=='string' and identity.validate(payload.actor)
end

function M.script(pluginId,handlers,options)
    local core=require('openmw.core')
    local active,seen,seenOrder={},{},{}
    -- Every accepted generation+action_id is remembered (bounded), so a redelivery after a synchronous
    -- completion is ignored just like one that arrives while the action is still pending.
    local function remember(key)
        if #seenOrder>=MAX_SEEN then seen[table.remove(seenOrder,1)]=nil end
        seen[key]=true seenOrder[#seenOrder+1]=key
    end
    local function send(payload,result)
        active[payload.action_id]=nil
        result=type(result)=='table' and result or {}
        core.sendGlobalEvent('LORKHAN_ADDON_SELF_RESULT',{action_id=payload.action_id,nonce=payload.nonce,actor=util.copy(payload.self),
            generation=payload.generation,status=result.status,reason_code=result.reason_code,observed=result.observed})
    end
    local api={}
    -- Complete an asynchronous SELF action once; later calls for the same action are ignored.
    function api.complete(actionId,result)
        local payload=active[actionId]
        if not payload then return nil,'action_not_pending' end
        send(payload,result)
        return true
    end
    return {
        engineHandlers={
            -- An unloaded actor cannot finish its work, so release every pending action with one failure each.
            onInactive=function()
                for _,payload in pairs(active) do send(payload,{status='failed',reason_code='actor_unloaded'}) end
            end,
        },
        eventHandlers={
            LORKHAN_ADDON_SELF_ACTION=function(payload)
                if not wellFormed(payload,pluginId) then return end
                -- A redelivered dispatch never runs the handler a second time, pending or already finished.
                local key=string.format('%.0f',payload.generation)..'|'..payload.action_id
                if seen[key] or active[payload.action_id] then return end
                -- A generated actor proves itself only through GLOBAL's registry rows for this generation.
                adapter.mergeDynamicBindings(payload.dynamic_bindings,payload.generation)
                -- An intent addressed to another actor never reaches a handler here; GLOBAL's deadline ends it.
                local actual=actualSelf()
                if not actual or not identity.same(actual,payload.actor) then return end
                remember(key)
                payload=util.copy(payload)
                payload.self=actual payload.dynamic_bindings=nil
                local handler=handlers[payload.action]
                if type(handler)~='function' then send(payload,{status='failed',reason_code='plugin_handler_unavailable'}) return end
                active[payload.action_id]=payload
                local context=util.copy(payload)
                context.nonce=nil context.self=nil
                local ok,result=pcall(handler,context,api)
                if active[payload.action_id]~=payload then return end
                if not ok then send(payload,{status='failed',reason_code='addon_handler_error'})
                elseif result~=nil then send(payload,result) end
            end,
            LORKHAN_ADDON_SELF_CANCEL=function(payload)
                local pending=type(payload)=='table' and active[payload.action_id] or nil
                if not pending or pending.nonce~=payload.nonce then return end
                active[payload.action_id]=nil
                if options and type(options.cancel)=='function' then
                    local context=util.copy(pending)
                    context.nonce=nil context.self=nil
                    pcall(options.cancel,context,payload.reason)
                end
            end,
        },
    }
end

return M
