local identity=require('scripts.LORKHAN.identity')
local protocol=require('scripts.LORKHAN.protocol')
local M={}
local methods={'requestDiaryBook','pumpDiaryBook','materializeDiaryBook','diaryBookStatus',
    'submitDiaryBookResult','pumpDiaryBookResult','cancelDiaryBook'}
local PHASE_TIMEOUT=30
local reasons={target_unavailable=true,target_mismatch=true,book_unavailable=true,
    record_creation_failed=true,inventory_update_failed=true,invalid_payload=true}

function M.new(bridge,resolve)
    return {bridge=bridge,resolve=resolve,nextPoll=0}
end

-- Only transient transport state lives in Lua. Native dynamic records carry save-backed book identity.
function M.reset(state)
    if state.phase and type(state.bridge.cancelDiaryBook)=='function' then pcall(state.bridge.cancelDiaryBook) end
    state.sessionId=nil;state.generation=nil;state.phase=nil;state.book=nil
    state.nextPoll=0;state.attempts=0;state.nextReceipt=0;state.deadline=nil
end

local function validBook(book)
    return type(book)=='table' and protocol.isUuid(book.delivery_id) and protocol.isUuid(book.book_id)
        and identity.validate(book.target) and (book.target.kind=='npc' or book.target.kind=='creature')
        and type(book.title)=='string' and #book.title>0 and #book.title<=128
        and type(book.content)=='string' and #book.content>0 and #book.content<=8192
        and type(book.content_hash)=='string' and #book.content_hash==64
        and not book.content_hash:find('[^0-9a-f]')
end

local function finish(state,now)
    state.phase=nil;state.book=nil;state.attempts=0;state.nextPoll=now+2;state.deadline=nil
end

-- Cancellation invalidates the native callback too; replay can then recover without a false receipt.
local function abandon(state,now)
    pcall(state.bridge.cancelDiaryBook)
    finish(state,now)
end

local function receipt(state,status,reason,now)
    state.status=status;state.reason=nil
    if status~='succeeded' then state.reason=reasons[reason] and reason or 'book_unavailable' end
    state.phase='receipt';state.attempts=0;state.nextReceipt=now
end

-- One authenticated delivery is resolved, materialized and acknowledged before another is requested.
function M.pump(state,sessionId,generation,now,disabled)
    if state.sessionId~=sessionId or state.generation~=generation or disabled then
        M.reset(state);state.sessionId=sessionId;state.generation=generation
    end
    if disabled or not sessionId or type(now)~='number' or now~=now or now==math.huge or now==-math.huge then return end
    local bridge=state.bridge
    for _,name in ipairs(methods) do if type(bridge[name])~='function' then return end end
    if not state.phase then
        if now<state.nextPoll then return end
        state.nextPoll=now+2
        local ok,request=pcall(bridge.requestDiaryBook)
        if ok and request then state.phase='query';state.deadline=now+PHASE_TIMEOUT end
        return
    end
    if state.deadline and now>=state.deadline
        and (state.phase=='query' or state.phase=='materializing' or state.phase=='receipt_pending') then
        abandon(state,now);return
    end
    if state.phase=='query' then
        local ok,result=pcall(bridge.pumpDiaryBook)
        if not ok or type(result)~='table' then abandon(state,now);return end
        if result.pending then return end
        if result.error or not validBook(result.book) then abandon(state,now);return end
        state.book=result.book
        local resolved,actor=pcall(state.resolve,result.book.target)
        if not resolved or not actor then receipt(state,'failed','target_unavailable',now);return end
        -- Lua supplies only the retained delivery ID, never text or a record mutation description.
        local applied,queued,reason=pcall(bridge.materializeDiaryBook,actor,result.book.delivery_id)
        if not applied then abandon(state,now);return end
        if not queued then receipt(state,'failed',reason or 'record_creation_failed',now);return end
        state.phase='materializing';state.deadline=now+PHASE_TIMEOUT
        return
    end
    if state.phase=='materializing' then
        local ok,result=pcall(bridge.diaryBookStatus,state.book.delivery_id)
        if not ok or type(result)~='table' then abandon(state,now);return end
        if result.pending then return end
        if result.status=='succeeded' or result.status=='failed' then receipt(state,result.status,result.reason_code,now) end
        if result.status~='succeeded' and result.status~='failed' then abandon(state,now) end
        return
    end
    if state.phase=='receipt_pending' then
        local ok,result=pcall(bridge.pumpDiaryBookResult)
        if ok and type(result)=='table' and result.pending then return end
        if ok and type(result)=='table' and result.ok then finish(state,now);return end
        state.phase='receipt';state.nextReceipt=now+math.min(8,2^state.attempts)
    end
    if state.phase=='receipt' and now>=state.nextReceipt then
        if state.attempts>=5 then abandon(state,now);return end
        state.attempts=state.attempts+1
        local ok,request=pcall(bridge.submitDiaryBookResult,state.book.delivery_id,state.status,state.reason)
        if ok and request then state.phase='receipt_pending';state.deadline=now+PHASE_TIMEOUT
        else state.nextReceipt=now+math.min(8,2^state.attempts) end
    end
end

return M
