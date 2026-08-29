local M={}

function M.new() return {text=nil,remaining=0} end

function M.show(state,text,duration)
    if not state or type(text)~='string' or text=='' then return false end
    state.text=text
    state.remaining=tonumber(duration) or 4
    return true
end

function M.update(state,dt)
    if not state or state.remaining<=0 then return false end
    state.remaining=math.max(0,state.remaining-(tonumber(dt) or 0))
    if state.remaining==0 then state.text=nil return true end
    return false
end

function M.active(state) return state and state.remaining>0 and state.text~=nil end

return M
