local M={}

function M.new() return {entries={},attempts=0,nextAt=0,signature=nil} end

-- Cancel speculative work without playing it or leaving it across menu/session changes.
function M.reset(state,native,signature)
    for _,entry in pairs(state.entries) do
        if native.cancelMenuDialogueTts then pcall(native.cancelMenuDialogueTts,entry.request) end
    end
    state.entries={} state.attempts=0 state.nextAt=0 state.signature=signature
end

-- Reuse the selected request, including in-flight work, and cancel all other speculation.
function M.take(state,native,text,now)
    local key=text:lower()
    local selected=state.entries[key]
    state.entries[key]=nil
    for _,entry in pairs(state.entries) do
        if native.cancelMenuDialogueTts then pcall(native.cancelMenuDialogueTts,entry.request) end
    end
    state.entries={}
    if not selected then return nil end
    local status=native.menuDialogueTtsStatus(selected.request)
    if now-selected.created<120 and status and status.state~='failed' then return selected.request end
    if native.cancelMenuDialogueTts then pcall(native.cancelMenuDialogueTts,selected.request) end
    return nil
end

-- Warm at most three options per menu, one request at a time, only while speech is idle.
function M.update(state,native,actor,signature,now,busy)
    if state.signature~=signature then M.reset(state,native,signature) state.nextAt=now+1 end
    if not signature or not actor or busy or now<state.nextAt or state.attempts>=3 then return end
    if not native.visibleDialogueTopics or not native.requestMenuDialogueTts then return end
    for _,entry in pairs(state.entries) do
        local status=native.menuDialogueTtsStatus(entry.request)
        if status and status.state~='ready' and status.state~='failed' then return end
    end
    state.nextAt=now+0.5
    for _,text in ipairs(native.visibleDialogueTopics() or {}) do
        local key=text:lower()
        if not state.entries[key] then
            local request=native.requestMenuDialogueTts(actor,text)
            state.attempts=state.attempts+1
            if request then
                state.entries[key]={request=request,created=now}
                print('[LORKHAN] speech_trace request='..request..' stage=prefetch_queued')
            end
            return
        end
    end
end
return M
