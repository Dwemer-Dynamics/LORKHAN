local M={}

M.MODES={{key='standard',label='Standard',hearing='Standard'},
    {key='whisper',label='Whisper',prefix='%',hearing='Whisper'},
    {key='close',label='Close',prefix='%%',hearing='Close'},
    {key='shout',label='Shout',prefix='!!',hearing='Shout'},
    {key='narrator',label='Narrator',prefix='@',execution='narrator'},
    {key='director',label='Director',prefix='>',execution='director'},
    {key='cheat',label='Cheat',prefix='#',execution='cheat'},
    {key='autochat',label='Auto Chat',prefix='**',autoChat=true},
    {key='injection_log',label='Inject Event',prefix='((...))',execution='injection_log'},
    {key='injection_chat',label='Inject & Chat',prefix='(...)',execution='injection_chat'}}
M.SHORTCUTS={{prefix='%%',mode='Close'},{prefix='||',mode='Close'},{prefix='!!',mode='Shout'},
    {prefix='**',label='Auto Chat',autoChat=true},{prefix='%',mode='Whisper'},{prefix='|',mode='Whisper'},
    {prefix='@',label='Narrator',execution='narrator'},{prefix='>',label='Director',execution='director'},
    {prefix='#',label='Cheat',execution='cheat'}}
M.MOODS={'happy','sad','angry','annoyed','scared','surprised','confused','suspicious','playful','flirty','custom'}
M.CUSTOM_LIMIT=80

local moodKinds={}
for _,kind in ipairs(M.MOODS) do moodKinds[kind]=true end

-- Longest prefixes and balanced outer event wrappers affect this turn only.
function M.parse(text)
    if type(text)~='string' then return nil,'invalid_text' end
    text=text:gsub('^%s+',''):gsub('%s+$','')
    local wrapped,execution,prefix
    if text:sub(1,2)=='((' and text:sub(-2)=='))' then
        wrapped=text:sub(3,-3);execution='injection_log';prefix='((...))'
    elseif text:sub(1,1)=='(' and text:sub(-1)==')' then
        wrapped=text:sub(2,-2);execution='injection_chat';prefix='(...)'
    end
    if wrapped then
        wrapped=wrapped:gsub('^%s+',''):gsub('%s+$','')
        if wrapped=='' then return nil,'empty_input' end
        return {text=wrapped,execution=execution,prefix=prefix,label=execution=='injection_log' and 'Inject Event' or 'Inject & Chat'}
    end
    for _,shortcut in ipairs(M.SHORTCUTS) do
        if text:sub(1,#shortcut.prefix)==shortcut.prefix then
            local authored=text:sub(#shortcut.prefix+1):gsub('^%s+','')
            if authored:match('^%s*$') then return nil,'empty_input' end
            return {text=authored,mode=shortcut.mode,prefix=shortcut.prefix,label=shortcut.label or shortcut.mode,
                execution=shortcut.execution,autoChat=shortcut.autoChat}
        end
    end
    if text:match('^%s*$') then return nil,'empty_input' end
    return {text=text}
end

local function utf8Length(value)
    local _,count=value:gsub('[^\128-\193]','')
    return count
end

function M.validateMood(mood)
    if mood==nil then return nil end
    if type(mood)~='table' or type(mood.kind)~='string' or not moodKinds[mood.kind] then return nil,'invalid_mood' end
    local count=0 for _ in pairs(mood) do count=count+1 end
    if mood.kind~='custom' then
        if count~=1 then return nil,'invalid_mood' end
        return {kind=mood.kind}
    end
    if count~=2 or type(mood.custom)~='string' then return nil,'invalid_mood' end
    local custom=mood.custom:gsub('^%s+',''):gsub('%s+$','')
    if custom=='' or custom:find('[\r\n%z\1-\31\127]') or utf8Length(custom)>M.CUSTOM_LIMIT then
        return nil,'invalid_mood'
    end
    return {kind='custom',custom=custom}
end

return M
