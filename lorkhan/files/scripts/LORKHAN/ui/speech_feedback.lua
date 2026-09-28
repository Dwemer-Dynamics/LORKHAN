local M={}
local element,lastText

-- A transient, non-interactive indicator, separate from vanilla subtitles and the opt-in status HUD.
function M.show(text)
    if text==lastText then return end
    lastText=text
    if element then element:destroy() element=nil end
    if not text then return end
    local ok,ui=pcall(require,'openmw.ui')
    local utilOk,util=pcall(require,'openmw.util')
    if not ok or not utilOk then return end
    element=ui.create({layer='HUD',type=ui.TYPE.Text,props={
        text=text,relativePosition=util.vector2(0.5,0.12),anchor=util.vector2(0.5,0),
        size=util.vector2(420,28),textAlignH=ui.ALIGNMENT.Center,textSize=16,
        textColor=util.color.rgb(0.9,0.8,0.6)}})
end
return M
