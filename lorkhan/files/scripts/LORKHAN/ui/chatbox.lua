local M={}

local COLORS={
    title={0.95,0.9,0.82},
    status={0.92,0.82,0.68},
    detail={0.72,0.68,0.62},
    action={188/255,157/255,90/255},
    quiet={0.82,0.78,0.72},
    active={0.45,0.9,0.45},
    highlight={218/255,187/255,120/255},
}

local function text(ui,util,value,size,color,events)
    local swatch=COLORS[color] or COLORS.detail
    return {type=ui.TYPE.Text,props={text=value,textSize=size,
        textColor=util.color.rgb(swatch[1],swatch[2],swatch[3])},events=events}
end

-- One single-line editor drawn the same way everywhere so focus behaviour stays identical.
local function lineEdit(context,width,value,events)
    local ui,util=context.ui,context.util
    local content={}
    if context.whiteTexture then
        content[#content+1]={type=ui.TYPE.Image,props={resource=context.whiteTexture,
            size=util.vector2(width,44),color=util.color.rgb(0.08,0.06,0.04),alpha=0.96,
            propagateEvents=false}}
    end
    content[#content+1]={type=ui.TYPE.TextEdit,props={position=util.vector2(8,4),
        text=value or '',size=util.vector2(width-16,34),multiline=false,wordWrap=false,
        readOnly=false,autoSize=false,textSize=18,textColor=util.color.rgb(1.0,0.92,0.72),
        propagateEvents=false},events=events}
    return {type=ui.TYPE.Container,props={size=util.vector2(width,44)},content=ui.content(content)}
end

-- Every LORKHAN control the player can reach from Interact, in one compact list. Each entry names
-- the callback the panel owner supplies, so labels and routes stay described in one place.
-- The order and count are fixed: a live prefix preview must only rewrite text on existing widgets.
local MENU={
    {key='modes',label='Dialogue mode...',callback='onSelectModes'},
    {key='mood',label='Mood',callback='onSelectMood'},
    {key='model',label='LLM model...',callback='onSelectModel'},
    {key='profiles',label='Dynamic profiles...',callback='onSelectProfiles'},
    {key='waitHere',label='Wait Here (90 seconds)',callback='onWaitHere'},
    {key='history',label='Context history...',callback='onSelectHistory'},
    {key='statusHud',label='Status HUD',callback='onToggleStatusHud'},
    {key='diagnostics',label='Diagnostics...',callback='onSelectDiagnostics'},
}
M.MENU=MENU

-- The status HUD is a toggle rather than a panel, so its row carries its own on/off state.
function M.statusHudLabel(visible) return 'Status HUD: '..(visible and 'on' or 'off') end
function M.autoChatLabel(enabled) return 'Auto Chat: '..(enabled and 'on' or 'off') end

-- Build the focused Interact rows without owning targeting or protocol state.
-- The row structure is constant so a live prefix preview only rewrites text on an existing widget.
function M.build(context)
    local ui,util=context.ui,context.util
    local rows={}
    local savedMode=context.mode or 'Standard'
    local turnMode=context.turnMode
    local mood=context.mood or 'None'
    rows[#rows+1]=text(ui,util,'Text Chat and Interact: '..context.target,20,'title')
    rows[#rows+1]=text(ui,util,'Mood: '..mood..'  |  Mode: '..(turnMode or savedMode)..
        (turnMode and ' (this turn)' or ''),15,turnMode and 'highlight' or 'status')
    rows[#rows+1]=lineEdit(context,520,context.text,
        {textChanged=context.onTextChanged,keyPress=context.onKeyPress})
    rows[#rows+1]=text(ui,util,'Press Enter or select Send',14,'detail')
    for _,entry in ipairs(MENU) do
        if entry.key=='statusHud' then
            rows[#rows+1]=text(ui,util,M.statusHudLabel(context.statusHudVisible),15,
                context.statusHudVisible and 'active' or 'action',{mouseClick=context[entry.callback]})
        else
            rows[#rows+1]=text(ui,util,entry.label,15,'action',{mouseClick=context[entry.callback]})
        end
    end
    rows[#rows+1]=text(ui,util,'Send',18,'action',{mouseClick=context.onSend})
    rows[#rows+1]=text(ui,util,'Close',16,'quiet',{mouseClick=context.onClose})
    return rows
end

-- Build the compact mood picker reached from the conversation panel.
function M.buildMoodPanel(context)
    local ui,util=context.ui,context.util
    local rows={text(ui,util,'Player Mood',20,'title')}
    rows[#rows+1]=text(ui,util,'Used by typed and spoken input. None keeps ordinary chat unchanged.',14,'detail')
    for _,option in ipairs(context.moods or {}) do
        rows[#rows+1]=text(ui,util,option.label..(option.active and '  [active]' or ''),17,
            option.active and 'active' or 'action',{mouseClick=option.onSelect})
    end
    if context.customVisible then
        rows[#rows+1]=text(ui,util,'Custom delivery direction',16,'title')
        rows[#rows+1]=lineEdit(context,480,context.customText,
            {textChanged=context.onCustomChanged,keyPress=context.onCustomKeyPress})
        rows[#rows+1]=text(ui,util,'One short line, up to '..tostring(context.customLimit or 80)..
            ' characters. Leave it empty to keep ordinary chat.',13,'detail')
    end
    rows[#rows+1]=text(ui,util,'Back to conversation',16,'quiet',{mouseClick=context.onBack})
    rows[#rows+1]=text(ui,util,'Close',16,'quiet',{mouseClick=context.onClose})
    return rows
end

return M
