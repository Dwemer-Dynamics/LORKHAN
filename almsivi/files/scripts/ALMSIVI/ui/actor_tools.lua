local M={}

-- Build the one compact entry point for controls scoped to the aimed or selected NPC.
function M.build(context)
    local ui,util=context.ui,context.util
    local rows={{type=ui.TYPE.Text,props={text='Targeted NPC Tools',textSize=20,
        textColor=util.color.rgb(0.95,0.9,0.82)}},
        {type=ui.TYPE.Text,props={text='Target: '..context.target,textSize=16,
        textColor=util.color.rgb(0.82,0.78,0.72)}}}
    for _,option in ipairs(context.options or {}) do
        rows[#rows+1]={type=ui.TYPE.Text,props={text=option.label,textSize=18,
            textColor=option.danger and util.color.rgb(1.0,0.45,0.35) or util.color.rgb(1.0,0.58,0.18)},
            events={mouseClick=option.onSelect}}
    end
    rows[#rows+1]={type=ui.TYPE.Text,props={text='Close',textSize=16,
        textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=context.onClose}}
    return rows
end

return M
