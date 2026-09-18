local identity=require('scripts.LORKHAN.identity')
local M={}

-- Resolve existing server-owned profile IDs, then submit one update at a time without opening panels.
function M.start(native,targets,narrator,now)
    local session=native.sessionInfo()
    if not session or not session.session_id then return nil,'Bridge not ready' end
    local unique,seen={},{}
    for _,target in ipairs(targets) do
        local key=identity.key(target)
        if key and not seen[key] and #unique<32 then unique[#unique+1]=target;seen[key]=true end
    end
    if #unique==0 then return nil,'No eligible NPCs' end
    return {targets=unique,index=1,queued=0,failed=0,narrator=narrator,
        session=session.session_id,generation=session.generation,phase='next',deadline=now+35}
end

-- Acknowledgement means queued on the server, not that model generation has completed.
function M.pump(state,native,now)
    local session=native.sessionInfo()
    if not session or session.session_id~=state.session or session.generation~=state.generation then
        return true,'Profile update stopped: session changed'
    end
    if now>state.deadline then return true,'Profile update timed out' end
    local target=state.targets[state.index]
    if not target then return true,string.format('Profile updates queued: %d; skipped or failed: %d',state.queued,state.failed) end
    if state.phase=='next' then
        local request=native.requestSessionControls(target,false)
        if not request then return true,'Profile update unavailable: controls busy' end
        state.phase='query';state.deadline=now+35;return false
    end
    local status=native.pumpSessionControls()
    if not status or status.pending then return false end
    if status.error then
        state.failed=state.failed+1;state.index=state.index+1;state.phase='next'
        return false,'Profile update failed: '..tostring(status.error)
    end
    if state.phase=='select' then
        state.queued=state.queued+1;state.index=state.index+1;state.phase='next';return false
    end
    local controls=native.sessionControls()
    local id=controls and controls.selected_profile_id
    if state.narrator then id=controls and controls.narrator_profile_id end
    if not controls or not identity.same(controls.target,target) or not id then
        state.failed=state.failed+1;state.index=state.index+1;state.phase='next';return false
    end
    local request,err=native.selectSessionControl(state.narrator and 'narrator_profile_generate' or 'profile_generate',id,target)
    if not request then return true,'Profile update failed: '..tostring(err or 'unavailable') end
    state.phase='select';state.deadline=now+35
    return false
end
return M