local M={}

-- Build a compact single-purpose selector from server-owned or local choices.
function M.build(context)
    local ui,util=context.ui,context.util
    local rows={{type=ui.TYPE.Text,props={text=context.title,textSize=20,
        textColor=util.color.rgb(0.95,0.9,0.82)}}}
    if context.message then
        rows[#rows+1]={type=ui.TYPE.Text,props={text=context.message,textSize=15,
            textColor=util.color.rgb(0.72,0.68,0.62)}}
    end
    for _,option in ipairs(context.options or {}) do
        rows[#rows+1]={type=ui.TYPE.Text,props={text=option.label..(option.active and '  [active]' or ''),textSize=18,
            textColor=option.active and util.color.rgb(0.45,0.9,0.45) or util.color.rgb(1.0,0.58,0.18)},
            events={mouseClick=option.onSelect}}
        if option.detail then
            rows[#rows+1]={type=ui.TYPE.Text,props={text=option.detail,textSize=14,
                textColor=util.color.rgb(0.72,0.68,0.62)}}
        end
    end
    if context.onRefresh then
        rows[#rows+1]={type=ui.TYPE.Text,props={text='Refresh',textSize=16,
            textColor=util.color.rgb(1.0,0.58,0.18)},events={mouseClick=context.onRefresh}}
    end
    if context.onBack then
        rows[#rows+1]={type=ui.TYPE.Text,props={text='Back',textSize=16,
            textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=context.onBack}}
    end
    rows[#rows+1]={type=ui.TYPE.Text,props={text='Close',textSize=16,
        textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=context.onClose}}
    return rows
end

return M
