local M={}

M.SHORTCUTS={{prefix='||',mode='Close'},{prefix='!!',mode='Shout'},{prefix='|',mode='Whisper'}}
M.MOODS={'happy','sad','angry','annoyed','scared','surprised','confused','suspicious','playful','flirty','custom'}
M.CUSTOM_LIMIT=80

local moodKinds={}
for _,kind in ipairs(M.MOODS) do moodKinds[kind]=true end

-- Parse only the safe dialogue delivery prefixes, longest first, without changing the saved mode.
function M.parse(text)
    if type(text)~='string' then return nil,'invalid_text' end
    for _,shortcut in ipairs(M.SHORTCUTS) do
        if text:sub(1,#shortcut.prefix)==shortcut.prefix then
            local authored=text:sub(#shortcut.prefix+1):gsub('^%s+','')
            if authored:match('^%s*$') then return nil,'empty_input' end
            return {text=authored,mode=shortcut.mode,prefix=shortcut.prefix}
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
