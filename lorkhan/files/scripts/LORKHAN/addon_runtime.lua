local contract=require('scripts.LORKHAN.plugin_contract')
local identity=require('scripts.LORKHAN.identity')
local util=require('scripts.LORKHAN.util')

-- Public LORKHAN_Addons v1 runtime. GLOBAL owns registration, routing, confirmation and the single terminal
-- lorkhan.action-result.v1 for every plugin intent; addon CUSTOM scripts execute SELF-only handlers. The server
-- only names registered typed actions, so no code, path, URL or token crosses this boundary.
local M={}
M.API_VERSION=1
M.SELF_ACTION='LORKHAN_ADDON_SELF_ACTION'
M.SELF_CANCEL='LORKHAN_ADDON_SELF_CANCEL'
M.SELF_RESULT='LORKHAN_ADDON_SELF_RESULT'
M.CONFIRMATION_CLOSED='LORKHAN_ACTION_CONFIRMATION_CLOSED'
local MAX_REQUESTS=8
local MAX_ACTIONS=16
local MAX_SEEN=128
local MAX_REGISTER_ATTEMPTS=4
local MAX_REFRESHES=4
local MAX_OUTBOX=32
local MAX_RESULT_ATTEMPTS=6
local RESULT_LIFETIME=120
local TERMINAL={succeeded=true,failed=true,rejected=true}
local HANDLE={__metatable='LORKHAN_AddonHandle',__newindex=function() error('LORKHAN addon handles are read-only',2) end,
    __tostring=function() return 'LORKHAN_AddonHandle' end}

-- Snapshot keys first: addon callbacks may re-enter the API and add entries while a caller iterates.
local function keys(values)
    local out={}
    for key in pairs(values) do out[#out+1]=key end
    table.sort(out)
    return out
end

local function find(list,name)
    for _,item in ipairs(list) do if item.name==name then return item end end
end

-- Only an addon's own CUSTOM script may be attached; LORKHAN scripts and traversal are never accepted.
local function validScript(path)
    return type(path)=='string' and #path<=128 and path:match('^scripts/[%w_%-/]+%.lua$')~=nil
        and not path:find('..',1,true) and not path:find('//',1,true) and path:lower():sub(1,16)~='scripts/lorkhan/'
end

local function reasonCode(value)
    return type(value)=='string' and #value<=128 and value:match('^[a-z0-9][a-z0-9_.%-]*$')~=nil
end

-- Observed values are a small flat record of scalars, never nested tables or long text.
local function observedValues(value)
    if value==nil then return {} end
    if type(value)~='table' then return nil end
    local out,count={},0
    for key,item in pairs(value) do
        count=count+1
        local kind=type(item)
        if count>16 or type(key)~='string' or not contract.isName(key) then return nil end
        if kind=='number' then if item~=item or item>1000000000 or item< -1000000000 then return nil end
        elseif kind=='string' then if #item>256 or item:find('%c') then return nil end
        elseif kind~='boolean' then return nil end
        out[key]=item
    end
    return out
end

function M.new(deps)
    return {bridge=deps.bridge,now=deps.now,resolve=deps.resolve,attach=deps.attach,send=deps.send,emit=deps.emit,
        allowed=deps.allowed or function() return true end,confirmationBusy=deps.confirmationBusy or function() return false end,
        scriptExists=deps.scriptExists or function() return nil end,log=deps.log or function() end,
        addons={},handles=setmetatable({},{__mode='k'}),plugins=nil,requests={},actions={},seen={},seenOrder={},rates={},
        outbox={},outboxOrder={},
        dirty=false,attempts=0,retryAt=nil,confirming=nil}
end

local function owner(rt,handle)
    local id=type(handle)=='table' and rt.handles[handle] or nil
    local addon=id and rt.addons[id]
    if not addon or addon.handle~=handle then return nil end
    return addon,id
end

local function remember(rt,actionId)
    rt.seen[actionId]=true
    rt.seenOrder[#rt.seenOrder+1]=actionId
    if #rt.seenOrder>MAX_SEEN then rt.seen[table.remove(rt.seenOrder,1)]=nil end
end

local function drop(rt,actionId,why)
    rt.outbox[actionId]=nil
    for index,id in ipairs(rt.outboxOrder) do if id==actionId then table.remove(rt.outboxOrder,index) break end end
    if why then rt.log('[LORKHAN] addon action result abandoned: '..actionId..' '..why) end
end

-- Native freezes the first DTO per action_id and re-enqueues only a failed transport, so a retry resends the same
-- message_id and never re-runs a handler. Without actionReceiptStatus an accepted enqueue is the last observable step.
local function deliver(rt,actionId,entry,now)
    local bridge=rt.bridge
    local receipts=type(bridge.actionReceiptStatus)=='function'
    local receipt
    if receipts and entry.attempts>0 then
        local ok,value=pcall(bridge.actionReceiptStatus,actionId)
        receipt=ok and type(value)=='table' and value.status or nil
        if receipt=='accepted' then return drop(rt,actionId) end
    end
    if now-entry.created>=RESULT_LIFETIME or receipt~='pending' and entry.attempts>=MAX_RESULT_ATTEMPTS then
        return drop(rt,actionId,tostring(receipt or 'result_attempts_exhausted'))
    end
    if receipt=='pending' or now<entry.retryAt then return end
    entry.attempts=entry.attempts+1
    entry.retryAt=now+math.min(10,2^entry.attempts)
    local ok,requestId,failure=pcall(bridge.submitActionResult,entry.result)
    if ok and requestId then
        if not receipts then drop(rt,actionId) end
        return
    end
    -- A generation native no longer serves will never accept this result; other failures retry in this generation.
    if ok and failure=='stale_action_result' then drop(rt,actionId,failure) end
end

-- Freeze one terminal result per action_id in a bounded outbox and attempt delivery now.
local function report(rt,action,status,reason,observed)
    local actionId=action.action_id
    if rt.outbox[actionId] then return true,status end
    if #rt.outboxOrder>=MAX_OUTBOX then drop(rt,rt.outboxOrder[1],'addon_result_outbox_full') end
    local bridge=rt.bridge
    local entry={attempts=0,retryAt=0,created=rt.now(),result={schema='lorkhan.action-result.v1',message_id=bridge.newMessageId(),
        request_id=action.request_id,action_id=actionId,turn_id=action.turn_id,session_id=action.session_id,
        generation=action.generation,status=status,reason_code=reason,observed=observed or {},completed_at=bridge.utcNow()}}
    rt.outbox[actionId]=entry rt.outboxOrder[#rt.outboxOrder+1]=actionId
    deliver(rt,actionId,entry,entry.created)
    return true,status
end

local function context(action)
    local intent=action.intent
    return {api_version=M.API_VERSION,action_id=intent.action_id,plugin_id=intent.plugin_id,action=intent.action,
        actor=util.copy(intent.actor),target=util.copy(intent.target),parameters=util.copy(intent.parameters),
        expires_at=action.expires_at,cancellable=intent.cancellable}
end

-- Only running cancellable work is asked to stop. A committed cancellable=false handler is never interrupted.
local function notifyCancel(rt,action,reason)
    if action.phase~='running' or action.intent.cancellable==false then return end
    local handler=action.handler
    if handler.scope=='global' then
        if handler.cancel then pcall(handler.cancel,context(action),reason) end
        return
    end
    local object=rt.resolve(action.intent.actor)
    if object then pcall(rt.send,object,M.SELF_CANCEL,{action_id=action.action_id,nonce=action.nonce,reason=reason}) end
end

-- The only path to a terminal result for a tracked action; later completions find nothing to finish.
local function finish(rt,action,status,reason,observed)
    if rt.actions[action.action_id]~=action then return nil,'action_not_pending' end
    rt.actions[action.action_id]=nil
    if rt.confirming==action.action_id then
        rt.confirming=nil
        rt.emit(M.CONFIRMATION_CLOSED,{action_id=action.action_id})
    end
    if status=='cancelled' or status=='timed_out' then notifyCancel(rt,action,reason) end
    return report(rt,action,status,reason,observed)
end

local function complete(rt,action,result)
    local observed=type(result)=='table' and observedValues(result.observed)
    if type(result)~='table' or not TERMINAL[result.status] or not reasonCode(result.reason_code) or not observed then
        return finish(rt,action,'failed','addon_result_invalid')
    end
    return finish(rt,action,result.status,result.reason_code,observed)
end

local function dispatch(rt,action)
    action.phase='running'
    local handler=action.handler
    if handler.scope=='self' then
        local object=rt.resolve(action.intent.actor)
        if not object then return finish(rt,action,'failed','actor_unloaded') end
        local attached,reason=rt.attach(object,handler.script)
        if not attached then return finish(rt,action,'failed',reason or 'addon_script_unavailable') end
        action.nonce=rt.bridge.newMessageId()
        local payload=context(action)
        payload.nonce=action.nonce payload.generation=action.generation
        local sent=pcall(rt.send,object,M.SELF_ACTION,payload)
        if not sent then return finish(rt,action,'failed','addon_script_unavailable') end
        return true
    end
    local ok,result=pcall(handler.run,context(action))
    if rt.actions[action.action_id]~=action then return true end
    if not ok then
        rt.log('[LORKHAN] addon handler failed: '..action.intent.plugin_id..'/'..action.intent.action)
        return finish(rt,action,'failed','addon_handler_error')
    end
    if result~=nil then return complete(rt,action,result) end
    return true -- Accepted is not complete; completeAction or the bounded deadline produces the terminal result.
end

-- Stop tracking one action. Committed non-cancellable work is never cancelled: it ends timed_out (outcome unknown,
-- nothing rolled back), or with soft=true it keeps running and still owes its completion or deadline.
local function stop(rt,action,reason,soft)
    if action.phase~='running' or action.intent.cancellable~=false then return finish(rt,action,'cancelled',reason) end
    if not soft then return finish(rt,action,'timed_out',reason) end
end

local function withdraw(rt,addon,state,reason)
    addon.state=state addon.reason=reason addon.sent=nil
    if rt.plugins then contract.deactivate(rt.plugins,addon.manifest.plugin_id) end
    for _,actionId in ipairs(keys(rt.actions)) do
        local action=rt.actions[actionId]
        if action and action.addon==addon then stop(rt,action,'plugin_withdrawn') end
    end
end

local function dependenciesMet(rt,addon,activeOnly)
    for _,dependency in ipairs(addon.manifest.dependencies) do
        local other=rt.addons[dependency.plugin_id]
        local state=other and other.state
        if not other or (activeOnly and state~='active') or (not activeOnly and state~='active' and state~='pending')
            or contract.compareVersions(other.manifest.version,dependency.min_version)<0
            or dependency.max_version_exclusive and contract.compareVersions(other.manifest.version,dependency.max_version_exclusive)>=0 then
            return false
        end
    end
    return true
end

-- Withdraw active dependants of anything no longer active; each pass removes one or more, so this terminates.
local function withdrawDependents(rt)
    local changed=true
    while changed do
        changed=false
        for _,id in ipairs(keys(rt.addons)) do
            local addon=rt.addons[id]
            if addon and addon.state=='active' and not dependenciesMet(rt,addon,true) then
                withdraw(rt,addon,'disabled','dependency_unsatisfied') changed=true
            end
        end
    end
end

local function submitRegistration(rt,operation,plugins)
    local bridge=rt.bridge
    if util.count(rt.requests)>=MAX_REQUESTS then return nil,'plugin_queue_full' end
    local message={schema=contract.REGISTRATION,message_id=bridge.newMessageId(),request_id=bridge.newMessageId(),
        session_id=rt.plugins.session_id,generation=rt.plugins.generation,created_at=bridge.utcNow(),operation=operation,plugins=plugins}
    local requestId,reason=bridge.submitPluginRegistration(message)
    if requestId then rt.requests[requestId]={operation=operation} end
    return requestId,reason
end

-- Register every pending addon whose dependencies are present locally, in one bounded message.
local function flush(rt,now)
    local ids,entries={},{}
    local retrySync=false
    for id,addon in pairs(rt.addons) do
        if addon.state=='pending' and not addon.sent then
            -- Only a successfully registered GLOBAL addon can request its fixed packaged server half.
            if rt.bridge.syncPluginPackage and not addon.packageReady then
                if not addon.packageRequest and util.count(rt.requests)<MAX_REQUESTS then
                    addon.packageAttempts=(addon.packageAttempts or 0)+1
                    local request,reason=rt.bridge.syncPluginPackage(id,addon.manifest.version,addon.entry.manifest_sha256)
                    if request then
                        addon.packageRequest=request
                        addon.packageStatus={status='pending',reason='package_sync_pending'}
                        rt.requests[request]={operation='package',plugin_id=id}
                    elseif addon.packageAttempts<MAX_REGISTER_ATTEMPTS then retrySync=true
                    else addon.packageReady=true addon.packageStatus={status='failed',reason=reason} retrySync=true end
                elseif not addon.packageRequest then retrySync=true end
            elseif dependenciesMet(rt,addon,false) then ids[#ids+1]=id
            else addon.reason='dependency_unsatisfied' end
        end
    end
    rt.dirty=retrySync
    if retrySync then rt.retryAt=now+2 end
    if #ids==0 then return end
    table.sort(ids)
    for _,id in ipairs(ids) do entries[#entries+1]=util.copy(rt.addons[id].entry) end
    local requestId,reason=submitRegistration(rt,'register',entries)
    for _,id in ipairs(ids) do
        rt.addons[id].sent=requestId
        rt.addons[id].reason=requestId and 'awaiting_registration' or reason
    end
    if not requestId then
        rt.attempts=rt.attempts+1
        rt.dirty=rt.attempts<MAX_REGISTER_ATTEMPTS
        rt.retryAt=now+2*rt.attempts
    end
end

local function settle(rt,requestId,receipt,now)
    local request=rt.requests[requestId]
    rt.requests[requestId]=nil
    if request and request.operation=='package' then
        local addon=rt.addons[request.plugin_id]
        if not addon or addon.packageRequest~=requestId then return end
        addon.packageRequest=nil
        addon.packageStatus={status=receipt.package_status or 'failed',reason=receipt.reason_code or receipt.reason,
            enabled=receipt.enabled,installed_version=receipt.installed_version}
        local retry=receipt.package_status=='pending' or receipt.reason=='rate_limited'
            or receipt.reason=='timeout' or receipt.reason=='transport_failure'
        addon.packageReady=not retry or addon.packageAttempts>=MAX_REGISTER_ATTEMPTS
        rt.dirty=true rt.retryAt=retry and now+2 or nil
        return
    end
    if not request or request.operation~='register' then return end
    local rows={}
    if receipt.status=='accepted' then
        for _,row in ipairs(receipt.plugins or {}) do rows[row.plugin_id]=row end
    end
    for _,id in ipairs(keys(rt.addons)) do
        local addon=rt.addons[id]
        if addon and addon.sent==requestId then
            addon.sent=nil
            local row=rows[id]
            if receipt.status~='accepted' then
                -- Transport failures retry a bounded number of times; other failures wait for the next generation.
                addon.reason=receipt.reason or 'registration_failed'
                if (receipt.reason=='rate_limited' or receipt.reason=='timeout' or receipt.reason=='transport_failure')
                    and rt.attempts<MAX_REGISTER_ATTEMPTS then
                    rt.attempts=rt.attempts+1 rt.dirty=true rt.retryAt=now+2*rt.attempts
                end
            elseif not row or row.version~=addon.manifest.version then
                withdraw(rt,addon,'rejected','registration_unacknowledged')
            elseif row.state=='active' then
                local ok,reason=contract.activate(rt.plugins,addon.manifest,addon.entry,'active')
                addon.state=ok and 'active' or 'rejected' addon.reason=ok and row.reason_code or reason
            else
                withdraw(rt,addon,row.state,row.reason_code)
            end
        end
    end
    withdrawDependents(rt)
end

-- Cancel tracked plugin actions. soft=true (halt-actions, AI off) spares committed non-cancellable work.
function M.cancel(rt,reason,soft)
    for _,actionId in ipairs(keys(rt.actions)) do
        local action=rt.actions[actionId]
        if action then stop(rt,action,reason,soft) end
    end
end

function M.haltActions(rt,reason)
    M.cancel(rt,reason,true)
end

-- Bind to the live session generation; each new generation starts empty and re-registers every addon.
function M.session(rt,info)
    local id=type(info)=='table' and info.session_id or nil
    local generation=id and info.generation or nil
    local current=rt.plugins
    if (current and current.session_id or nil)==id and (current and current.generation or nil)==generation then
        local revision=type(info)=='table' and info.plugin_policy_revision
        if current and current.enabled and revision and revision~=rt.policyRevision then
            if rt.policyRevision then
                -- Pause new intents until the server acknowledges the new policy; existing work retains its result.
                for _,addon in pairs(rt.addons) do
                    contract.deactivate(current,addon.manifest.plugin_id)
                    addon.state='pending' addon.reason='package_policy_changed' addon.sent=nil addon.refreshes=nil
                end
                rt.dirty=true rt.retryAt=nil rt.attempts=0
            end
            rt.policyRevision=revision
        end
        return false
    end
    M.cancel(rt,'session_changed')
    -- Native clears its receipts and fences older generations, so their outbox entries end here.
    rt.plugins=id and contract.new(info) or nil
    rt.policyRevision=type(info)=='table' and info.plugin_policy_revision or nil
    rt.requests={} rt.rates={} rt.attempts=0 rt.retryAt=nil rt.outbox={} rt.outboxOrder={}
    local enabled=rt.plugins~=nil and rt.plugins.enabled
    for _,addon in pairs(rt.addons) do
        addon.sent=nil addon.refreshes=nil
        addon.packageReady=nil addon.packageRequest=nil addon.packageAttempts=nil addon.packageStatus=nil
        addon.state=(rt.plugins and not enabled) and 'disabled' or 'pending'
        addon.reason=not rt.plugins and 'awaiting_session' or enabled and 'awaiting_registration' or 'plugin_contract_unsupported'
    end
    rt.dirty=enabled
    return true
end

-- Collect receipts only for outstanding submissions and expire only tracked actions; idle work is nil.
function M.pump(rt,now)
    if not rt.plugins or not rt.dirty and next(rt.requests)==nil and next(rt.actions)==nil and next(rt.outbox)==nil then return end
    for _,requestId in ipairs(keys(rt.requests)) do
        local receipt=rt.bridge.pluginReceipt(requestId)
        if type(receipt)~='table' or receipt.status=='unknown' then
            settle(rt,requestId,{status='failed',reason='receipt_unavailable'},now)
        elseif receipt.status~='pending' then settle(rt,requestId,receipt,now) end
    end
    if rt.dirty and (not rt.retryAt or now>=rt.retryAt) then flush(rt,now) end
    for _,actionId in ipairs(keys(rt.actions)) do
        local action=rt.actions[actionId]
        if action and (now>=action.deadline or (rt.bridge.isExpired and rt.bridge.isExpired(action.expires_at))) then
            finish(rt,action,'timed_out',action.phase=='confirm' and 'confirmation_timeout' or 'action_timeout')
        end
    end
    for _,actionId in ipairs(util.arrayCopy(rt.outboxOrder)) do
        local entry=rt.outbox[actionId]
        if entry then deliver(rt,actionId,entry,now) end
    end
end

-- Offer non-active addons to the server again once package sync completes or the player enables one. The caller
-- decides when installation state changed; nothing polls, and each addon refreshes a bounded number of times.
function M.refresh(rt,handle)
    if not rt.plugins or not rt.plugins.enabled then return nil,'plugin_contract_unsupported' end
    local ids=keys(rt.addons)
    if handle~=nil then
        local addon,id=owner(rt,handle)
        if not addon then return nil,'invalid_addon_handle' end
        ids={id}
    end
    local count=0
    for _,id in ipairs(ids) do
        local addon=rt.addons[id]
        if addon and addon.state~='active' and not addon.sent and (addon.refreshes or 0)<MAX_REFRESHES then
            addon.refreshes=(addon.refreshes or 0)+1
            addon.state='pending' addon.reason='awaiting_registration' count=count+1
        end
    end
    if count>0 then rt.dirty=true rt.attempts=0 rt.retryAt=nil end
    return count
end

function M.register(rt,spec)
    if type(spec)~='table' then return nil,'invalid_addon_registration' end
    local entry,reason=contract.registrationEntry(spec.manifest,spec.manifest_sha256,spec.actor_scopes)
    if not entry then return nil,reason end
    local manifest=util.copy(spec.manifest)
    if rt.addons[manifest.plugin_id] then return nil,'plugin_already_registered' end
    if util.count(rt.addons)>=contract.MAX_PLUGINS then return nil,'plugin_limit_exceeded' end
    -- Prompt- or event-only addons declare no actions and need no handlers.
    local supplied=spec.handlers
    if supplied==nil and #manifest.actions==0 then supplied={} end
    if type(supplied)~='table' then return nil,'invalid_addon_handlers' end
    local handlers,count={},0
    for name,handler in pairs(supplied) do
        count=count+1
        if not find(manifest.actions,name) or type(handler)~='table' then return nil,'invalid_addon_handlers' end
        if handler.scope=='global' and type(handler.run)=='function' and (handler.cancel==nil or type(handler.cancel)=='function') then
            handlers[name]={scope='global',run=handler.run,cancel=handler.cancel}
        elseif handler.scope=='self' and validScript(handler.script) then
            if rt.scriptExists(handler.script)==false then return nil,'addon_script_missing' end
            handlers[name]={scope='self',script=handler.script}
        else
            return nil,'invalid_addon_handlers'
        end
    end
    if count~=#manifest.actions then return nil,'addon_handler_missing' end
    local handle=setmetatable({},HANDLE)
    rt.handles[handle]=manifest.plugin_id
    local enabled=rt.plugins and rt.plugins.enabled
    rt.addons[manifest.plugin_id]={handle=handle,manifest=manifest,entry=entry,handlers=handlers,
        state=(rt.plugins and not enabled) and 'disabled' or 'pending',
        reason=not rt.plugins and 'awaiting_session' or enabled and 'awaiting_registration' or 'plugin_contract_unsupported'}
    rt.dirty=rt.dirty or enabled==true
    return handle
end

function M.unregister(rt,handle)
    local addon,id=owner(rt,handle)
    if not addon then return nil,'invalid_addon_handle' end
    local registered=addon.state=='active' or addon.sent~=nil
    -- Release ownership first so a re-entrant cancel callback cannot unregister or complete through this handle.
    rt.addons[id]=nil rt.handles[handle]=nil
    withdraw(rt,addon,'unregistered','plugin_unregistered')
    if registered and rt.plugins and rt.plugins.enabled then
        submitRegistration(rt,'unregister',{{plugin_id=id,version=addon.manifest.version}})
    end
    withdrawDependents(rt)
    return true
end

function M.status(rt,handle)
    local addon,id=owner(rt,handle)
    if not addon then return nil,'invalid_addon_handle' end
    return {api_version=M.API_VERSION,plugin_id=id,version=addon.manifest.version,state=addon.state,reason=addon.reason,
        package=util.copy(addon.packageStatus),
        contract=rt.plugins~=nil and rt.plugins.enabled==true}
end

function M.emit(rt,handle,name,fields)
    local addon,id=owner(rt,handle)
    if not addon then return nil,'invalid_addon_handle' end
    if addon.state~='active' or not rt.plugins then return nil,'plugin_not_active' end
    local declared=find(addon.manifest.events,name)
    if not declared then return nil,'plugin_event_unregistered' end
    if util.count(rt.requests)>=MAX_REQUESTS then return nil,'plugin_queue_full' end
    -- Mirror the declared server limit locally so addons cannot spend the shared transport on rejected events.
    local now=rt.now()
    local key=id..'/'..name
    local window=rt.rates[key] or {}
    rt.rates[key]=window
    while window[1] and now-window[1]>=60 do table.remove(window,1) end
    if #window>=declared.max_per_minute then return nil,'rate_limited' end
    local bridge=rt.bridge
    local message,reason=contract.event(rt.plugins,{plugin_id=id,event=name,fields=fields or {},
        message_id=bridge.newMessageId(),request_id=bridge.newMessageId(),observed_at=bridge.utcNow()})
    if not message then return nil,reason end
    local requestId,failure=bridge.submitPluginEvent(message)
    if not requestId then return nil,failure end
    window[#window+1]=now
    rt.requests[requestId]={operation='event'}
    return requestId
end

function M.completeAction(rt,handle,actionId,result)
    local addon=owner(rt,handle)
    if not addon then return nil,'invalid_addon_handle' end
    local action=rt.actions[actionId]
    if not action or action.addon~=addon or action.phase~='running' or action.handler.scope~='global' then
        return nil,'action_not_pending'
    end
    return complete(rt,action,result)
end

-- SELF results carry the per-dispatch nonce that only the exact actor's addon script received.
function M.selfResult(rt,event)
    local action=type(event)=='table' and type(event.action_id)=='string' and rt.actions[event.action_id] or nil
    if not action or action.phase~='running' or action.nonce==nil or event.nonce~=action.nonce
        or event.generation~=action.generation or not identity.same(event.actor,action.intent.actor) then
        return nil,'action_not_pending'
    end
    return complete(rt,action,{status=event.status,reason_code=event.reason_code,observed=event.observed})
end

-- Route one polled plugin.action.intent. Validation precedes confirmation, which precedes any handler.
function M.intent(rt,event)
    local payload=type(event)=='table' and event.payload or nil
    local actionId=type(payload)=='table' and payload.action_id or nil
    if type(actionId)~='string' or rt.seen[actionId] then return nil,'duplicate_plugin_intent' end
    remember(rt,actionId)
    if not rt.plugins then return nil,'stale_action' end
    local action={action_id=actionId,request_id=event.request_id,turn_id=payload.turn_id,session_id=payload.session_id,
        generation=payload.generation,expires_at=payload.expires_at}
    local intent,reason=contract.validateIntent(rt.plugins,payload,{session_id=rt.plugins.session_id,
        generation=rt.plugins.generation,resolve=rt.resolve,expired=rt.bridge.isExpired})
    -- Stale work belongs to a generation native no longer accepts results for.
    if reason=='stale_action' or reason=='plugin_contract_unsupported' then return nil,reason end
    if not intent then return report(rt,action,reason=='action_expired' and 'timed_out' or 'rejected',reason) end
    local addon=rt.addons[intent.plugin_id]
    local handler=addon and addon.state=='active' and addon.handlers[intent.action]
    if not handler then return report(rt,action,'rejected','plugin_handler_unavailable') end
    local allowed,gate=rt.allowed()
    if not allowed then return report(rt,action,'cancelled',gate or 'ai_disabled') end
    if util.count(rt.actions)>=MAX_ACTIONS then return report(rt,action,'rejected','plugin_action_queue_full') end
    local declared=find(addon.manifest.actions,intent.action)
    action.intent=intent action.addon=addon action.handler=handler action.phase='validated'
    action.deadline=rt.now()+declared.timeout_seconds
    rt.actions[actionId]=action
    if not intent.confirmation_required then return dispatch(rt,action) end
    if rt.confirming or rt.confirmationBusy() then return finish(rt,action,'rejected','confirmation_busy') end
    action.phase='confirm' rt.confirming=actionId
    rt.emit('LORKHAN_ACTION_CONFIRMATION',{action_id=actionId,name=intent.action,display_name=declared.display_name,
        actor=util.copy(intent.actor),target=util.copy(intent.target),parameters={},
        summary=addon.manifest.display_name..' addon, performed by '..tostring(intent.actor.display_name or intent.actor.record_id)
            ..'.\n'..declared.description..(declared.tier==2 and '\nChanges affect this save.' or '')})
    return true
end

-- Answer a plugin confirmation. Returns false when the action is not a pending plugin confirmation.
function M.confirm(rt,actionId,approved)
    local action=rt.actions[actionId]
    if not action or action.phase~='confirm' then return false end
    rt.confirming=nil
    if not approved then finish(rt,action,'rejected','user_declined') return true end
    -- A late click must not outrun the pump: the local deadline and the server expiry both still apply here.
    if rt.now()>=action.deadline then finish(rt,action,'timed_out','confirmation_timeout') return true end
    if rt.bridge.isExpired and rt.bridge.isExpired(action.expires_at) then finish(rt,action,'timed_out','action_expired') return true end
    local allowed,gate=rt.allowed()
    if not allowed then finish(rt,action,'cancelled',gate or 'ai_disabled') return true end
    dispatch(rt,action)
    return true
end

function M.interface(rt)
    return {version=M.API_VERSION,
        register=function(spec) return M.register(rt,spec) end,
        unregister=function(handle) return M.unregister(rt,handle) end,
        refresh=function(handle) if handle==nil then return nil,'invalid_addon_handle' end return M.refresh(rt,handle) end,
        status=function(handle) return M.status(rt,handle) end,
        emit=function(handle,name,fields) return M.emit(rt,handle,name,fields) end,
        completeAction=function(handle,actionId,result) return M.completeAction(rt,handle,actionId,result) end}
end

return M
