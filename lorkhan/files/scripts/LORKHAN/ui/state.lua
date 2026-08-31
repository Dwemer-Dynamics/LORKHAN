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

-- Panels that Interact and Targeted NPC Tools both reach remember which menu opened them, so the
-- back row returns to the menu the player actually used instead of a fixed destination.
local BACK_ROUTES={
    conversation={panel='conversation',label='Back to conversation'},
    ['actor-tools']={panel='actor-tools',label='Targeted NPC Tools'},
}
local DEFAULT_ORIGIN='actor-tools'

M.MODES=MODES
M.SHORTCUTS=SHORTCUTS
M.MOODS=MOODS
M.MOOD_DIRECTION_LIMIT=MOOD_DIRECTION_LIMIT
M.BACK_ROUTES=BACK_ROUTES

function M.new(policy)
    return {visible=false, status='offline', target=nil, audience={}, nearby={}, agents={}, input='', transcript={}, subtitle=nil,
        diagnostics=nil, lastCorrelation=nil, mode='Standard',panel='conversation',actionView='root',actionPage=1,actionSlot=nil,
        historyPage=1,panelOrigin=DEFAULT_ORIGIN,
        mood='None',moodDirection='',
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
