local protocol=require('scripts.LORKHAN.protocol')
local util=require('scripts.LORKHAN.util')

local M={}
local MAX_SEEN=256

local function remember(state,setName,orderName,value)
    local seen=state[setName]
    if seen[value] then return false end
    seen[value]=true
    local order=state[orderName]
    order[#order+1]=value
    if #order>MAX_SEEN then seen[table.remove(order,1)]=nil end
    return true
end

local function pendingCounts(state)
    local dialogue,actions=0,0
    for _,item in ipairs(state.items) do
        if item.kind=='dialogue' then dialogue=dialogue+1 else actions=actions+1 end
    end
    return dialogue,actions
end

local function removeHead(state)
    local item=table.remove(state.items,1)
    if not item then return nil end
    state.byLine[item.line.line_id]=nil
    if item.media then state.byMedia[item.media.media_id]=nil end
    if item.intent then state.byAction[item.intent.action_id]=nil end
    state.active=nil
    state.unfinished=#state.items>0
    if not state.unfinished then state.source=nil end
    return item
end

local function stale(state,reason)
    state.counters.staleDrops=state.counters.staleDrops+1
    return nil,reason
end

function M.new(generation,runtimeGeneration)
    return {generation=generation or 1,runtimeGeneration=runtimeGeneration or generation or 1,
        items={},byLine={},byMedia={},byAction={},active=nil,unfinished=false,source=nil,pendingRechat=false,
        seenResponses={},seenResponseOrder={},seenLines={},seenLineOrder={},seenUtterances={},seenUtteranceOrder={},
        seenMedia={},seenMediaOrder={},seenActions={},seenActionOrder={},
        counters={queued=0,dispatched=0,cancelled=0,staleDrops=0,deduplicated=0,completed=0}}
end

function M.setFence(state,generation,runtimeGeneration,reason)
    local released=M.cancel(state,reason or 'generation_changed')
    state.generation=generation
    state.runtimeGeneration=runtimeGeneration or generation
    state.pendingRechat=false
    return released
end

function M.enqueue(state,response,generation,runtimeGeneration)
    local valid,reason=protocol.validateCanonicalResponse(response)
    if not valid then return nil,reason end
    if response.generation~=generation or response.runtime_generation~=runtimeGeneration
        or response.generation~=state.generation or response.runtime_generation~=state.runtimeGeneration then
        return stale(state,'stale_response_generation')
    end
    if state.seenResponses[response.response_id] then
        state.counters.deduplicated=state.counters.deduplicated+1
        return nil,'duplicate_response'
    end
    remember(state,'seenResponses','seenResponseOrder',response.response_id)
    if not response.ok then
        state.source=response.response_id
        return true,0
    end
    local dialogue,actions={},{}
    for _,line in ipairs(response.lines) do
        if state.seenLines[line.line_id] or state.seenUtterances[line.utterance_id] then
            state.counters.deduplicated=state.counters.deduplicated+1
            return nil,'duplicate_response_line'
        end
        local item={kind=line.action=='say' and 'dialogue' or 'action',status='queued',
            responseId=response.response_id,requestId=response.request_id,turnId=response.turn_id,
            sessionId=response.session_id,generation=response.generation,runtimeGeneration=response.runtime_generation,
            close=response.close,line=util.copy(line)}
        if item.kind=='dialogue' then
            item.status=line.metadata.speech_enabled==false and 'subtitle_ready' or 'waiting_media'
            if line.media then item.media=util.copy(line.media) item.status='new' end
            dialogue[#dialogue+1]=item
        else actions[#actions+1]=item end
    end
    for _,item in ipairs(dialogue) do
        remember(state,'seenLines','seenLineOrder',item.line.line_id)
        remember(state,'seenUtterances','seenUtteranceOrder',item.line.utterance_id)
        state.items[#state.items+1]=item state.byLine[item.line.line_id]=item
        if item.media then
            remember(state,'seenMedia','seenMediaOrder',item.media.media_id)
            state.byMedia[item.media.media_id]=item
        end
    end
    for _,item in ipairs(actions) do
        remember(state,'seenLines','seenLineOrder',item.line.line_id)
        remember(state,'seenUtterances','seenUtteranceOrder',item.line.utterance_id)
        state.items[#state.items+1]=item state.byLine[item.line.line_id]=item
    end
    state.counters.queued=state.counters.queued+#dialogue+#actions
    state.unfinished=#state.items>0
    state.source=response.response_id
    return true,#dialogue+#actions
end

function M.attachMedia(state,event)
    if event.generation~=state.generation then return stale(state,'stale_media_generation') end
    local descriptor=event.payload
    local item=state.byLine[descriptor.dialogue_message_id]
    if not item or item.kind~='dialogue' or item.requestId~=event.request_id or item.turnId~=event.turn_id
        or item.sessionId~=event.session_id then return stale(state,'media_without_response_line') end
    if item.media then
        if item.media.media_id==descriptor.media_id then
            state.counters.deduplicated=state.counters.deduplicated+1 return nil,'duplicate_media'
        end
        return nil,'conflicting_response_media'
    end
    if state.seenMedia[descriptor.media_id] then
        state.counters.deduplicated=state.counters.deduplicated+1 return nil,'duplicate_media'
    end
    remember(state,'seenMedia','seenMediaOrder',descriptor.media_id)
    item.media=util.copy(descriptor) item.status='new' state.byMedia[descriptor.media_id]=item
    return true
end

function M.attachAction(state,event)
    if event.generation~=state.generation then return stale(state,'stale_action_generation') end
    local item=state.byLine[event.message_id]
    local intent=event.payload
    if not item or item.kind~='action' or item.requestId~=event.request_id or item.turnId~=event.turn_id
        or item.sessionId~=event.session_id or item.line.command_name~=intent.name then
        return stale(state,'action_without_response_line')
    end
    if item.intent then
        state.counters.deduplicated=state.counters.deduplicated+1 return nil,'duplicate_action_intent'
    end
    if state.seenActions[intent.action_id] then
        state.counters.deduplicated=state.counters.deduplicated+1 return nil,'duplicate_action_intent'
    end
    remember(state,'seenActions','seenActionOrder',intent.action_id)
    item.intent=util.copy(intent) state.byAction[intent.action_id]=item item.status='ready'
    return true
end

function M.head(state) return state.items[1] end

function M.beginMediaPreparation(state,mediaId,prepareRequestId)
    local item=state.items[1]
    if not item or item.kind~='dialogue' or not item.media or item.media.media_id~=mediaId or item.status~='new' then
        return nil,'media_not_queue_head'
    end
    item.status='preparing' item.prepareRequestId=prepareRequestId
    return true
end

function M.updateMedia(state,mediaId,status,reason)
    local item=state.byMedia[mediaId]
    if not item then return nil,'media_not_queued' end
    if status=='ready' and item.status=='preparing' then item.status='ready' return true end
    if status=='failed' or status=='expired' or status=='cancelled' then
        item.status=status item.reason=reason or status return true
    end
    return nil,'invalid_media_transition'
end

function M.markDispatched(state,item)
    if state.active or state.items[1]~=item then return nil,'response_head_not_dispatchable' end
    if item.kind=='dialogue' and item.status~='ready' and item.status~='subtitle_ready' then return nil,'dialogue_not_ready' end
    if item.kind=='action' and (item.status~='ready' or not item.intent) then return nil,'action_not_ready' end
    item.status='active' state.active=item state.counters.dispatched=state.counters.dispatched+1
    return true
end

local function shouldAdvanceRechat(state)
    if state.pendingRechat and #state.items==0 then state.pendingRechat=false return true end
    return false
end

function M.completeDialogue(state,mediaId,status)
    local item=state.active
    if not item or item.kind~='dialogue' or (item.media and item.media.media_id~=mediaId) then
        return nil,'dialogue_not_active'
    end
    if status=='played' and item.line.final_response_line then state.pendingRechat=true end
    state.counters.completed=state.counters.completed+1
    removeHead(state)
    return true,shouldAdvanceRechat(state)
end

function M.completeAction(state,actionId)
    local item=state.active
    if not item or item.kind~='action' or not item.intent or item.intent.action_id~=actionId then
        return nil,'action_not_active'
    end
    state.counters.completed=state.counters.completed+1
    removeHead(state)
    return true,shouldAdvanceRechat(state)
end

function M.failHead(state,reason)
    local item=state.items[1]
    if not item then return nil,'response_queue_empty' end
    item.reason=reason state.counters.cancelled=state.counters.cancelled+1
    removeHead(state)
    return true,shouldAdvanceRechat(state)
end

function M.cancel(state,reason)
    local released,undelivered={},{}
    for _,item in ipairs(state.items) do
        item.reason=reason
        if item.media then released[#released+1]=item.media.media_id end
        if item.kind=='dialogue' and item~=state.active then undelivered[#undelivered+1]=util.copy(item) end
    end
    state.counters.cancelled=state.counters.cancelled+#state.items
    state.items={} state.byLine={} state.byMedia={} state.byAction={} state.active=nil
    state.unfinished=false state.source=nil state.pendingRechat=false
    return released,undelivered
end

-- Remove actions that have not begun while allowing an executing actor to report its own terminal result.
function M.cancelActions(state,reason,cancelActive)
    local cancelled,kept={},{}
    for _,item in ipairs(state.items) do
        local remove=item.kind=='action' and (item~=state.active or cancelActive==true)
        if remove then
            item.reason=reason
            cancelled[#cancelled+1]=item
            state.byLine[item.line.line_id]=nil
            if item.intent then state.byAction[item.intent.action_id]=nil end
            if item==state.active then state.active=nil end
        else
            kept[#kept+1]=item
        end
    end
    state.counters.cancelled=state.counters.cancelled+#cancelled
    state.items=kept
    state.unfinished=#state.items>0
    if not state.unfinished then state.source=nil end
    state.pendingRechat=false
    return cancelled
end

function M.snapshot(state)
    local dialogue,actions=pendingCounts(state)
    local active=state.active
    return {generation=state.generation,runtime_generation=state.runtimeGeneration,unfinished=state.unfinished,
        source=state.source,pending_dialogue=dialogue,pending_actions=actions,
        queued=state.counters.queued,dispatched=state.counters.dispatched,completed=state.counters.completed,
        cancelled=state.counters.cancelled,stale_drops=state.counters.staleDrops,deduplicated=state.counters.deduplicated,
        active_response_id=active and active.responseId or nil,active_line_id=active and active.line.line_id or nil,
        active_media_id=active and active.media and active.media.media_id or nil,
        active_action_id=active and active.intent and active.intent.action_id or nil}
end

function M.idle(state) return #state.items==0 and state.active==nil end

return M
