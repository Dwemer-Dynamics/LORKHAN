local M={}

-- Build the focused typed-chat rows without owning targeting or protocol state.
function M.build(context)
    local ui,util=context.ui,context.util
    local rows={}
    local inputContent={}
    if context.whiteTexture then
        inputContent[#inputContent+1]={type=ui.TYPE.Image,props={resource=context.whiteTexture,
            size=util.vector2(520,44),color=util.color.rgb(0.08,0.06,0.04),alpha=0.96,
            propagateEvents=false}}
    end
    inputContent[#inputContent+1]={type=ui.TYPE.TextEdit,props={position=util.vector2(8,4),
        text=context.text or '',size=util.vector2(504,34),multiline=false,wordWrap=false,
        readOnly=false,autoSize=false,textSize=18,textColor=util.color.rgb(1.0,0.92,0.72),
        propagateEvents=false},events={textChanged=context.onTextChanged,keyPress=context.onKeyPress}}
    rows[#rows+1]={type=ui.TYPE.Text,props={text='Chat with '..context.target,textSize=20,
        textColor=util.color.rgb(0.95,0.9,0.82)}}
    rows[#rows+1]={type=ui.TYPE.Container,props={size=util.vector2(520,44)},content=ui.content(inputContent)}
    rows[#rows+1]={type=ui.TYPE.Text,props={text='Press Enter or select Send',textSize=14,
        textColor=util.color.rgb(0.72,0.68,0.62)}}
    rows[#rows+1]={type=ui.TYPE.Text,props={text='Send',textSize=18,
        textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=context.onSend}}
    rows[#rows+1]={type=ui.TYPE.Text,props={text='Close',textSize=16,
        textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=context.onClose}}
    return rows
end

return M
