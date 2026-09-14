local playerInput = require('scripts.LORKHAN.player_input')
local util = require('scripts.LORKHAN.util')

local M = {}

-- Saved delivery modes the player selects and keeps between turns.
local MODES={'Standard','Whisper','Close','Shout'}
-- Borrowed from the parser so the preview can never disagree with what a submitted turn actually does.
-- It is already ordered longest prefix first, and it is the only set of shortcuts offered.
local SHORTCUTS=playerInput.SHORTCUTS
-- None is the default and keeps ordinary chat unchanged. Custom carries one short delivery direction.
local MOODS={'None','Happy','Sad','Angry','Annoyed','Scared','Surprised','Confused','Suspicious',
    'Playful','Flirty','Custom'}
local MOOD_DIRECTION_LIMIT=playerInput.CUSTOM_LIMIT
local MOOD_SUMMARY_LIMIT=34
-- Semantic LLM model slots. The keys, the order, and the fallback labels are fixed, so the model
-- panel keeps one shape whatever the server reports, Standard is what the player sees before any
-- snapshot arrives, and no raw connector row can ever be enumerated into the menu.
local MODEL_SLOTS={{key='standard',label='Standard'},{key='fast',label='Fast'},
    {key='powerful',label='Powerful'},{key='experimental',label='Experimental'}}
local DEFAULT_MODEL_SLOT='standard'
local MODEL_SLOT_LABELS={}
for _,slot in ipairs(MODEL_SLOTS) do MODEL_SLOT_LABELS[slot.key]=slot.label end
-- A server connector name can be far longer than a menu row, so the detail is clipped instead of
-- widening the panel or wrapping a slot onto a second line.
local MODEL_SLOT_DETAIL_LIMIT=38

-- Panels that Interact and Targeted NPC Tools both reach remember which menu opened them, so the
-- back row returns to the menu the player actually used instead of a fixed destination.
local BACK_ROUTES={
    conversation={panel='conversation',label='Back to conversation'},
    ['actor-tools']={panel='actor-tools',label='Targeted NPC Tools'},
}
local DEFAULT_ORIGIN='actor-tools'

M.MODES=MODES
M.EXECUTION_MODES={{key='standard',label='Standard'},{key='narrator',label='Narrator'},
    {key='director',label='Director'},{key='cheat',label='Cheat'}}
M.SHORTCUTS=SHORTCUTS
M.MOODS=MOODS
M.MOOD_DIRECTION_LIMIT=MOOD_DIRECTION_LIMIT
M.MODEL_SLOTS=MODEL_SLOTS
M.DEFAULT_MODEL_SLOT=DEFAULT_MODEL_SLOT
M.BACK_ROUTES=BACK_ROUTES

function M.new(policy)
    return {visible=false, status='offline', target=nil, audience={}, nearby={}, agents={}, input='', transcript={}, subtitle=nil,
        diagnostics=nil, lastCorrelation=nil, mode='Standard',panel='conversation',actionView='root',actionPage=1,actionSlot=nil,
        historyPage=1,panelOrigin=DEFAULT_ORIGIN,
        mood='None',moodDirection='',executionMode='standard',
        -- turnMode/turnPrefix stay nil until a typed prefix is previewed; they never replace `mode`.
        pendingTargetAction=nil,
        statusHudVisible=false,policy=util.copy(policy or {})}
end

local function trim(value)
    if type(value)~='string' then return '' end
    return (value:gsub('^%s+',''):gsub('%s+$',''))
end

-- Presentation-only prefix match. The UI never strips the prefix or rewrites the saved mode;
-- the authoritative parse of a submitted turn stays with the runtime.
function M.shortcutPreview(text)
    local parsed=playerInput.parse(text)
    return parsed and parsed.mode or nil,parsed and parsed.prefix or nil
end

-- Accept an effective one-turn mode from any source and report whether the display changed.
function M.setTurnPreview(state,mode,prefix)
    local changed=state.turnMode~=mode or state.turnPrefix~=prefix
    state.turnMode=mode
    state.turnPrefix=prefix
    return changed
end

function M.refreshTurnPreview(state)
    local mode,prefix=M.shortcutPreview(state.input)
    return M.setTurnPreview(state,mode,prefix)
end

-- The saved mode always survives a prefix; only the presented one-turn mode differs.
function M.effectiveMode(state) return state.turnMode or state.mode end

function M.setMood(state,mood)
    for _,candidate in ipairs(MOODS) do
        if candidate==mood then
            state.mood=mood
            if mood~='Custom' then state.moodDirection='' end
            return true
        end
    end
    return false
end

-- Cap at `limit` characters, matching the parser's UTF-8 length rule rather than a byte count,
-- and never split a multi-byte character.
local function clip(value,limit)
    local count,index=0,1
    while index<=#value do
        if count>=limit then return value:sub(1,index-1) end
        local byte=value:byte(index)
        local length=1
        if byte>=0xF0 then length=4 elseif byte>=0xE0 then length=3 elseif byte>=0xC0 then length=2 end
        count=count+1
        index=index+length
    end
    return value
end

-- Keep the custom direction to one short single line; a pasted block collapses instead of growing the panel.
function M.setMoodDirection(state,value)
    if type(value)~='string' then state.moodDirection='' return '' end
    local cleaned=clip(value:gsub('[%z\1-\31\127]+',' '),MOOD_DIRECTION_LIMIT)
    state.moodDirection=cleaned
    return cleaned
end

function M.moodLabel(state)
    if state.mood~='Custom' then return state.mood or 'None' end
    local direction=trim(state.moodDirection)
    if direction=='' then return 'Custom (no direction set)' end
    return 'Custom: '..direction
end

-- Short form for the conversation status line so a long direction cannot crowd the text box.
function M.moodSummary(state)
    local label=M.moodLabel(state)
    local shortened=clip(label,MOOD_SUMMARY_LIMIT-3)
    if shortened~=label then return shortened..'...' end
    return label
end

-- Presentation handoff shaped for the turn request `mood` field. nil means ordinary chat,
-- which is what None and an empty Custom direction both mean.
function M.moodSelection(state)
    if not state.mood or state.mood=='None' then return nil end
    if state.mood=='Custom' then
        local direction=trim(state.moodDirection)
        if direction=='' then return nil end
        return {kind='custom',custom=direction}
    end
    return {kind=state.mood:lower()}
end

-- Semantic slot rows keyed for lookup. A row the client does not know is ignored, so a newer
-- server can never grow a fifth row under the virtual cursor.
local function modelSlotRows(controls)
    local rows={}
    if type(controls)~='table' or type(controls.model_slots)~='table' then return rows end
    for _,slot in ipairs(controls.model_slots) do
        if type(slot)=='table' and MODEL_SLOT_LABELS[slot.key] then rows[slot.key]=slot end
    end
    return rows
end

local function modelSlotKey(value)
    return MODEL_SLOT_LABELS[value] and value or nil
end

-- Random routing is a server setting. The panel only reports it and stops writing while it is on.
function M.modelRandomizerEnabled(controls)
    local routing=type(controls)=='table' and type(controls.effective_settings)=='table'
        and controls.effective_settings.routing or nil
    return type(routing)=='table' and routing.llm_randomizer_enabled==true
end

-- One compact connector line. `driver` only separates a real connector from the mock one, so the
-- connector name and the model carry the detail and the row stays a single line.
local function modelSlotDetail(slot)
    local connector,model=trim(slot.configuration_name),trim(slot.model)
    local detail
    if connector~='' and model~='' then detail=connector..' / '..model
    elseif model~='' then detail=model
    elseif connector~='' then detail=connector end
    if detail and trim(slot.driver)=='mock' then detail=detail..' (mock)' end
    if not detail then return nil end
    local shortened=clip(detail,MODEL_SLOT_DETAIL_LIMIT-3)
    if shortened~=detail then return shortened..'...' end
    return detail
end

-- One short state line so the four choices never have to explain themselves with extra rows.
local function modelSlotMessage(view)
    if not view.loaded then return 'Loading server-owned choices...' end
    if view.randomized then
        return 'Random LLM is on, so the server picks a model every turn and these choices are disabled.'
    end
    if view.pending then return 'Selecting '..MODEL_SLOT_LABELS[view.pending]..'...' end
    if view.busy then return 'Refreshing choices...' end
    local selected=MODEL_SLOT_LABELS[view.selected]
    if view.resolved==view.selected then return 'Active: '..selected..'.' end
    if not view.resolved then
        return 'Selected '..selected..' has no configured model and the server resolved none.'
    end
    local resolved=MODEL_SLOT_LABELS[view.resolved]
    if view.selectedAvailable then return 'Selected '..selected..' is not active, so '..resolved..' is.' end
    return 'Selected '..selected..' is not configured, so '..resolved..' is active.'
end

-- Pure presentation for the LLM Model panel. `controls` is a snapshot already confirmed to describe
-- this panel's target and `pending` is the one slot the player is waiting on. Reading is all this
-- does: opening or redrawing the panel never selects a slot.
function M.modelSlotView(controls,pending)
    local slots=modelSlotRows(controls)
    local view={rows={},loaded=next(slots)~=nil,pending=modelSlotKey(pending),
        randomized=M.modelRandomizerEnabled(controls)}
    view.busy=view.pending~=nil or (type(controls)=='table' and controls.pending==true)
    view.selected=view.loaded and modelSlotKey(controls.selected_model_slot_key) or DEFAULT_MODEL_SLOT
    view.resolved=view.loaded and modelSlotKey(controls.resolved_model_slot_key) or nil
    view.refreshable=not view.busy
    for _,entry in ipairs(MODEL_SLOTS) do
        local slot=slots[entry.key]
        local available=slot~=nil and slot.available~=false
        local label=slot and trim(slot.label)~='' and trim(slot.label) or entry.label
        local detail
        if not view.loaded then detail=nil
        elseif not available then detail='not configured'
        else detail=modelSlotDetail(slot) end
        -- The selected slot and the slot the server actually resolved are annotated separately, so a
        -- fallback is visible on its own row without the panel growing one.
        local isSelected=view.loaded and entry.key==view.selected
        local isResolved=view.loaded and entry.key==view.resolved
        if isSelected then view.selectedAvailable=available end
        local mark,suffix
        if view.pending==entry.key then mark,suffix='selecting','  [selecting...]'
        elseif not view.loaded then mark,suffix='loading',''
        elseif isSelected and isResolved then mark,suffix='active','  [active]'
        elseif isSelected then mark,suffix='selected','  [selected]'
        elseif isResolved then mark,suffix='fallback','  [active fallback]'
        elseif not available then mark,suffix='unavailable',''
        else mark,suffix='ready','' end
        view.rows[#view.rows+1]={key=entry.key,label=label,mark=mark,detail=detail,
            clickable=view.loaded and available and not view.randomized and not view.busy,
            text=label..suffix..(detail and ('  |  '..detail) or '')}
    end
    view.message=modelSlotMessage(view)
    return view
end

function M.modelSlotBusy(state) return state.modelSlotPending~=nil end

-- One player-started selection at a time. The clicked slot stays marked until the snapshot it will
-- change stops being in flight, so a second click cannot queue a duplicate write.
function M.beginModelSlot(state,key)
    if state.modelSlotPending or not modelSlotKey(key) then return false end
    state.modelSlotPending=key
    return true
end

-- Settling on a lost or mismatched snapshot as well keeps a target change from stranding the panel
-- with every choice and the refresh row disabled.
function M.settleModelSlot(state,controls)
    if not state.modelSlotPending then return false end
    if type(controls)=='table' and controls.pending==true
        and controls.selected_model_slot_key~=state.modelSlotPending then return false end
    state.modelSlotPending=nil
    return true
end

-- Switch panels and record the menu the player came from. An unknown origin keeps the previous
-- one so an incidental panel change can never strand the player without a back route.
function M.setPanel(state,panel,origin)
    if origin and BACK_ROUTES[origin] then state.panelOrigin=origin end
    state.panel=panel
    return state.panel
end

function M.backRoute(state)
    return BACK_ROUTES[state.panelOrigin] or BACK_ROUTES[DEFAULT_ORIGIN]
end

function M.toggle(state) state.visible = not state.visible return state.visible end
function M.setStatus(state, status, diagnostics) state.status=status state.diagnostics=diagnostics end
function M.setTarget(state, target) state.target=util.copy(target) end
function M.setAudience(state, audience)
    state.audience={}
    for index,actor in ipairs(audience or {}) do state.audience[index]=util.copy(actor) end
end
function M.setNearby(state, actors)
    state.nearby={}
    local limit=state.policy.nearbyPickerRows
    for index,item in ipairs(actors or {}) do
        if limit==nil or index<=limit then state.nearby[index]=util.copy(item) end
    end
end
function M.delta(state, speaker, text) state.subtitle={speaker=util.copy(speaker), text=text, provisional=true} end
local function correlation(event)
    if type(event)~='table' then return {} end
    return {messageId=event.message_id,requestId=event.request_id,turnId=event.turn_id,
        sequence=event.sequence,createdAt=event.created_at}
end
local function appendTranscript(state,speaker,text,event,status)
    local ids=correlation(event)
    state.subtitle={speaker=util.copy(speaker), text=text, provisional=false}
    table.insert(state.transcript, {speaker=util.copy(speaker),text=text,status=status,
        messageId=ids.messageId,requestId=ids.requestId,turnId=ids.turnId,
        sequence=ids.sequence,createdAt=ids.createdAt})
    state.historyPage=1
    state.lastCorrelation=ids
    local limit=state.policy.transcriptRows
    while limit and #state.transcript > limit do table.remove(state.transcript, 1) end
end
function M.queued(state,speaker,text,event) appendTranscript(state,speaker,text,event,'queued') end
function M.final(state, speaker, text, event) appendTranscript(state,speaker,text,event,'responding') end
-- Keep every line for a request aligned with its terminal server state and latest correlation IDs.
function M.updateTurnState(state,event,status)
    local ids=correlation(event)
    state.lastCorrelation=ids
    for _,line in ipairs(state.transcript) do
        if (ids.requestId and line.requestId==ids.requestId) or (ids.turnId and line.turnId==ids.turnId) then
            line.status=status
            line.terminalSequence=ids.sequence
            line.terminalCreatedAt=ids.createdAt
        end
    end
end
function M.clearTransient(state)
    state.input='' state.subtitle=nil
    M.setTurnPreview(state,nil,nil)
end

return M
