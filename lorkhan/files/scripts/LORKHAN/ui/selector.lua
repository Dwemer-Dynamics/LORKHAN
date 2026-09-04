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
            textColor=option.active and util.color.rgb(0.45,0.9,0.45) or util.color.rgb(188/255,157/255,90/255)},
            events={mouseClick=option.onSelect}}
        if option.detail then
            rows[#rows+1]={type=ui.TYPE.Text,props={text=option.detail,textSize=14,
                textColor=util.color.rgb(0.72,0.68,0.62)}}
        end
    end
    if context.onRefresh then
        rows[#rows+1]={type=ui.TYPE.Text,props={text='Refresh',textSize=16,
            textColor=util.color.rgb(188/255,157/255,90/255)},events={mouseClick=context.onRefresh}}
    end
    if context.onBack then
        rows[#rows+1]={type=ui.TYPE.Text,props={text='Back',textSize=16,
            textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=context.onBack}}
    end
    rows[#rows+1]={type=ui.TYPE.Text,props={text='Close',textSize=16,
        textColor=util.color.rgb(0.82,0.78,0.72)},events={mouseClick=context.onClose}}
    return rows
end

-- One colour per slot state, taken from the palette the other panels already use.
local MODEL_SLOT_COLORS={active={0.45,0.9,0.45},fallback={0.45,0.9,0.45},selected={218/255,187/255,120/255},
    selecting={218/255,187/255,120/255},ready={188/255,157/255,90/255},unavailable={0.72,0.68,0.62},loading={0.72,0.68,0.62}}

-- Build the fixed eight-row LLM Model panel: title, state line, the four semantic slots, refresh,
-- back. The count never changes, so no server state can move a row out from under the virtual
-- cursor, and a row the view marks unclickable is drawn without any click event at all.
function M.buildModelSlots(context)
    local ui,util=context.ui,context.util
    local view=context.view or {}
    local function row(value,size,color,events)
        return {type=ui.TYPE.Text,props={text=value,textSize=size,
            textColor=util.color.rgb(color[1],color[2],color[3])},events=events}
    end
    local rows={row('LLM Model',20,{0.95,0.9,0.82}),row(view.message or '',15,{0.72,0.68,0.62})}
    for _,slot in ipairs(view.rows or {}) do
        local color=MODEL_SLOT_COLORS[slot.mark] or MODEL_SLOT_COLORS.ready
        if not slot.clickable and slot.mark=='ready' then color=MODEL_SLOT_COLORS.unavailable end
        local select=slot.clickable and context.select and context.select[slot.key] or nil
        rows[#rows+1]=row(slot.text,17,color,select and {mouseClick=select} or nil)
    end
    rows[#rows+1]=row('Refresh choices',16,view.refreshable and MODEL_SLOT_COLORS.ready
        or MODEL_SLOT_COLORS.unavailable,view.refreshable and {mouseClick=context.onRefresh} or nil)
    rows[#rows+1]=row(context.backLabel or 'Back',16,{0.82,0.78,0.72},{mouseClick=context.onBack})
    return rows
end

return M
