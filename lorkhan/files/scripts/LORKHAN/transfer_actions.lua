local actions=require('scripts.LORKHAN.actions')
local identity=require('scripts.LORKHAN.identity')
local util=require('scripts.LORKHAN.util')

local M={names={['item.give']=true,['item.take']=true,['item.pickup']=true,['gold.give']=true,['gold.take']=true}}
M.names['spell.cast']=true
for _,service in ipairs({'barter','training','spells','travel','spellmaking','enchanting','repair'}) do
    M.names['service.'..service]=true
end

-- GLOBAL owns native mutations and waits for their persisted receipts before advancing dialogue.
function M.new(bridge,completed)
    return {bridge=bridge,completed=completed,pending={}}
end

function M.enqueue(state,command)
    if type(command)~='table' or not M.names[command.name] then return nil,'not_transfer_action' end
    local service=command.name:sub(1,8)=='service.'
    local spell=command.name=='spell.cast'
    if not service and command.confirmation_required~=true then return nil,'transfer_confirmation_required' end
    local execute=service and 'executeService' or spell and 'executeSpell' or 'executeTransfer'
    local cancel=service and 'cancelService' or spell and 'cancelSpell' or 'cancelTransfer'
    local receipt=service and 'serviceReceiptStatus' or spell and 'spellReceiptStatus' or 'transferReceiptStatus'
    for _,method in ipairs({execute,cancel,receipt,'submitActionResult','utcNow'}) do
        if type(state.bridge[method])~='function' then return nil,'transfer_bridge_unavailable' end
    end
    if state.pending[command.action_id] then return true end
    local count=0;for _ in pairs(state.pending) do count=count+1 end
    if count>=4 then return nil,'transfer_queue_full' end
    state.pending[command.action_id]={command=util.copy(command),nextReceipt=0,attempts=0,
        execute=execute,cancel=cancel,receipt=receipt}
    return true
end

-- Cancellation affects only uncommitted native work; a completed transfer keeps its true result.
function M.cancel(state,actor)
    for id,item in pairs(state.pending) do
        if not actor or identity.same(actor,item.command.actor) then
            pcall(state.bridge[item.cancel],id)
        end
    end
end

function M.pump(state,sessionId,generation,now)
    if type(now)~='number' or now~=now then return end
    for id,item in pairs(state.pending) do
        local command=item.command
        if command.session_id~=sessionId or command.generation~=generation then
            pcall(state.bridge[item.cancel],id)
            state.pending[id]=nil
        else
            if not item.result then
                local ok,result=pcall(state.bridge[item.execute],id)
                if ok and type(result)=='table' and ({succeeded=true,failed=true,cancelled=true})[result.status] then
                    local internal={kind='lorkhan.internal.action-terminal',action_id=id,status=result.status,
                        reason=result.reason_code or result.reason,observed=util.copy(result.observed or {})}
                    item.result=actions.canonicalResult(internal,{message_id=command.message_id,
                        request_id=command.request_id,turn_id=command.turn_id,session_id=command.session_id,
                        generation=command.generation},state.bridge.utcNow())
                end
            end
            if item.result then
                local ok,receipt=pcall(state.bridge[item.receipt],id)
                if ok and type(receipt)=='table' and receipt.status=='accepted' then
                    state.pending[id]=nil
                    state.completed({result=item.result,action_name=command.name})
                elseif now>=item.nextReceipt and (not ok or type(receipt)~='table'
                    or receipt.status=='not_submitted' or receipt.status=='failed') then
                    -- The native bridge freezes the DTO and retries transport only, never the mutation.
                    pcall(state.bridge.submitActionResult,item.result)
                    item.attempts=item.attempts+1
                    item.nextReceipt=now+math.min(10,2^math.min(item.attempts,3))
                end
            end
        end
    end
end

return M
