local constants = require('scripts.LORKHAN.constants')
local identity = require('scripts.LORKHAN.identity')
local playerInput = require('scripts.LORKHAN.player_input')
local util = require('scripts.LORKHAN.util')

local M = {}
local knownInternalEvents = {['turn.accepted']=true, ['dialogue.delta']=true, ['dialogue.complete']=true,
    ['speech.ready']=true, ['action.intent']=true, ['response.complete']=true, ['turn.complete']=true,
    ['turn.failed']=true, ['turn.cancelled']=true, ['stt.transcript']=true,
    ['stt.failed']=true}

function M.isUuid(value)
    if type(value)~='string' then return false end
    local a,b,c,d,e=value:match('^([0-9a-f]+)%-([0-9a-f]+)%-([0-9a-f]+)%-([0-9a-f]+)%-([0-9a-f]+)$')
    return a and #a==8 and #b==4 and #c==4 and #d==4 and #e==12 or false
end

local function validInteger(value,minimum,maximum)
    return type(value)=='number' and value%1==0 and value>=(minimum or 0) and value<=(maximum or 9007199254740991)
end

local function validBoundedString(value,minimum,maximum)
    return type(value)=='string' and #value>=(minimum or 0) and #value<=(maximum or math.huge)
end

local function validateCanonicalMedia(media,lineId)
    if type(media)~='table' or not M.isUuid(media.media_id) or media.dialogue_message_id~=lineId
        or not M.isUuid(media.dialogue_message_id) then return nil,'invalid_response_media_identity' end
    if not validBoundedString(media.sha256,64,64) or media.sha256:match('[^0-9a-f]') then return nil,'invalid_response_media_sha256' end
    if not validInteger(media.bytes,1,33554432) or not validInteger(media.duration_ms,1) then return nil,'invalid_response_media_bounds' end
    if media.codec~='wav' and media.codec~='ogg' and media.codec~='mp3' then return nil,'invalid_response_media_codec' end
    if not validBoundedString(media.expires_at,20,32) then return nil,'invalid_response_media_expiry' end
    return true
end

function M.validateCanonicalResponse(response,event)
    if type(response)~='table' or response.schema~='lorkhan.response.v1' then return nil,'invalid_response_schema' end
    for _,key in ipairs({'response_id','installation_id','profile_id','playthrough_id','session_id','turn_id','request_id'}) do
        if not M.isUuid(response[key]) then return nil,'invalid_response_'..key end
    end
    if event and (response.response_id~=event.message_id or response.request_id~=event.request_id
        or response.turn_id~=event.turn_id or response.session_id~=event.session_id
        or response.generation~=event.generation) then return nil,'response_event_correlation_mismatch' end
    if not validInteger(response.generation,1) or not validInteger(response.runtime_generation,1) then
        return nil,'invalid_response_generation'
    end
    if not validBoundedString(response.created_at,20,32) or type(response.ok)~='boolean'
        or type(response.close)~='boolean' or not validBoundedString(response.error,0,256)
        or (response.ok and response.error~='') or (not response.ok and response.error=='') then
        return nil,'invalid_response_outcome'
    end
    if type(response.lines)~='table' or #response.lines>64 then return nil,'invalid_response_lines' end
    local seenLine,seenUtterance,seenMedia={},{},{}
    local sawAction=false
    local lastDialogue
    for index,line in ipairs(response.lines) do
        if type(line)~='table' or line.schema~='lorkhan.response.line.v1' or line.line_index~=index-1
            or not M.isUuid(line.line_id) or not M.isUuid(line.utterance_id) or line.request_id~=response.request_id then
            return nil,'invalid_response_line'
        end
        if seenLine[line.line_id] or seenUtterance[line.utterance_id] then return nil,'duplicate_response_line' end
        seenLine[line.line_id]=true seenUtterance[line.utterance_id]=true
        if not validBoundedString(line.speaker,1,256) or not validBoundedString(line.display_name,1,256)
            or not identity.validate(line.speaker_identity) or not validBoundedString(line.listener,1,256)
            or not identity.validate(line.listener_identity) or not validBoundedString(line.rechat_target,1,256)
            or not identity.validate(line.rechat_target_identity) or type(line.final_response_line)~='boolean'
            or type(line.metadata)~='table' then return nil,'invalid_response_line_identity' end
        if not validBoundedString(line.text,0,4096) or not validBoundedString(line.subtitle,0,4096)
            or not validBoundedString(line.tts_text,0,4096) then return nil,'invalid_response_line_text' end
        if line.action=='say' then
            if sawAction or line.text=='' or line.subtitle=='' or line.tts_text=='' or line.command_name~=nil
                or line.command_args~=nil then return nil,'invalid_response_say_line' end
            lastDialogue=index
        elseif line.action=='rolecommand' then
            sawAction=true
            if not validBoundedString(line.command_name,1,64) or not line.command_name:match('^[a-z][a-z0-9_.]*$')
                or type(line.command_args)~='table' or #line.command_args>16 or line.media~=nil
                or line.final_response_line then return nil,'invalid_response_command_line' end
            for _,argument in ipairs(line.command_args) do
                if not validBoundedString(argument,0,512) then return nil,'invalid_response_command_argument' end
            end
        else return nil,'invalid_response_line_action' end
        if line.media then
            local mediaOk,mediaReason=validateCanonicalMedia(line.media,line.line_id)
            if not mediaOk then return nil,mediaReason end
            if seenMedia[line.media.media_id] then return nil,'duplicate_response_media' end
            seenMedia[line.media.media_id]=true
        end
    end
    for index,line in ipairs(response.lines) do
        if line.final_response_line~=(lastDialogue~=nil and index==lastDialogue) then return nil,'invalid_final_response_line' end
    end
    return true
end

local function isLanguageTag(value)
    if type(value)~='string' or #value<2 or #value>35 then return false end
    local first=true
    for part in value:gmatch('[^-]+') do
        if (first and (#part<2 or #part>3 or part:match('[^A-Za-z]')))
            or (not first and (#part<1 or #part>8 or part:match('[^A-Za-z0-9]'))) then return false end
        first=false
    end
    return not first and not value:match('^%-') and not value:match('%-$') and not value:match('%-%-')
end

function M.runtime(platform, capabilities)
    return {game='tes3', variant='openmw', openmw_version=constants.OPENMW_VERSION,
        openmw_commit=constants.OPENMW_COMMIT, lua_api_revision=constants.LUA_API_REVISION,
        client_version=constants.CLIENT_VERSION, platform=platform, capabilities=util.arrayCopy(capabilities or {})}
end

function M.turn(args)
    local required = {'message_id','request_id','turn_id','installation_id','profile_id','playthrough_id',
        'session_id','generation','runtime_generation','created_at','platform','content_fingerprint','text','language','speaker','target','audience','context','ui_source'}
    for _, key in ipairs(required) do if args[key] == nil then return nil, 'missing_' .. key end end
    for _, key in ipairs({'message_id','request_id','turn_id','installation_id','profile_id','playthrough_id','session_id'}) do
        if not M.isUuid(args[key]) then return nil,'invalid_'..key end
    end
    for _,key in ipairs({'generation','runtime_generation'}) do
        if type(args[key])~='number' or args[key]%1~=0 or args[key]<1 or args[key]>9007199254740991 then
            return nil,'invalid_'..key
        end
    end
    if type(args.text) ~= 'string' or args.text:match('^%s*$') then return nil, 'empty_input' end
    if not isLanguageTag(args.language) then return nil,'invalid_language' end
    if not identity.validate(args.target) or not identity.validate(args.speaker) then return nil, 'invalid_identity' end
    if #args.audience > constants.MAX_AUDIENCE then return nil, 'audience_too_large' end
    local inputKind=args.input_kind or 'text'
    if inputKind~='text' and inputKind~='stt' then return nil,'invalid_input_kind' end
    local mood,moodReason=playerInput.validateMood(args.mood)
    if moodReason then return nil,moodReason end
    local input={kind=inputKind, text=args.text, language=args.language}
    if mood~=nil then input.mood=mood end
    local payload={input=input, speaker=util.copy(args.speaker),
        target=util.copy(args.target), audience=util.arrayCopy(args.audience), context=util.copy(args.context),
        recent_action_results=util.arrayCopy(args.recent_action_results or {}), ui_source=args.ui_source}
    if args.execution_mode~=nil then
        if args.execution_mode~='standard' and args.execution_mode~='narrator' and args.execution_mode~='injection_log' and args.execution_mode~='injection_chat'
            and args.execution_mode~='director' and args.execution_mode~='cheat' then return nil,'invalid_execution_mode' end
        payload.execution_mode=args.execution_mode
        if (args.execution_mode=='injection_log' or args.execution_mode=='injection_chat')
            and (inputKind~='text' or args.ui_source~='lorkhan_text' or args.speaker.kind~='player') then
            return nil,'injection_requires_typed_text'
        end
    end
    if args.director_instruction_id~=nil then
        if not M.isUuid(args.director_instruction_id) or (args.execution_mode or 'standard')~='standard' then
            return nil,'invalid_director_instruction'
        end
        payload.director_instruction_id=args.director_instruction_id
    end
    if args.action_request~=nil then
        local request=args.action_request
        if type(request)~='table' or type(request.name)~='string' or not request.name:match('^[a-z][a-z0-9_.]*$')
            or #request.name>64 or type(request.tier)~='number' or request.tier%1~=0 or request.tier<0 or request.tier>3
            or type(request.parameters)~='table' then return nil,'invalid_action_request' end
        payload.action_request={name=request.name,tier=request.tier,parameters=util.copy(request.parameters)}
        if request.target~=nil then
            if not identity.validate(request.target) then return nil,'invalid_action_target' end
            payload.action_request.target=util.copy(request.target)
        end
    end
    return {
        schema='lorkhan.turn.v1', message_id=args.message_id, request_id=args.request_id, turn_id=args.turn_id,
        installation_id=args.installation_id, profile_id=args.profile_id, playthrough_id=args.playthrough_id,
        session_id=args.session_id, generation=args.generation, runtime_generation=args.runtime_generation, created_at=args.created_at,
        runtime=M.runtime(args.platform, args.capabilities), content_fingerprint=args.content_fingerprint,
        payload=payload
    }
end

-- Validate the only game-data payload that the native bridge currently exposes.
function M.capturedDialogue(args)
    if type(args)~='table' then return nil,'invalid_captured_dialogue' end
    if args.source~='background' and args.source~='menu' then return nil,'invalid_dialogue_source' end
    if not identity.validate(args.speaker) or not identity.validate(args.listener) then
        return nil,'invalid_dialogue_identity'
    end
    if type(args.text)~='string' or #args.text<1 or #args.text>4096 then return nil,'invalid_dialogue_text' end
    if type(args.topic)~='string' or #args.topic>256 then return nil,'invalid_dialogue_topic' end
    if type(args.audience)~='table' or #args.audience>constants.MAX_AUDIENCE then return nil,'invalid_dialogue_audience' end
    local seen={}
    for _,actor in ipairs(args.audience) do
        if not identity.validate(actor) then return nil,'invalid_dialogue_audience' end
        local key=identity.key(actor)
        if seen[key] then return nil,'duplicate_dialogue_audience' end
        seen[key]=true
    end
    if args.game_time~=nil and (type(args.game_time)~='number' or args.game_time<0) then
        return nil,'invalid_dialogue_game_time'
    end
    return {source=args.source,speaker=util.copy(args.speaker),listener=util.copy(args.listener),
        audience=util.arrayCopy(args.audience),text=args.text,topic=args.topic,game_time=args.game_time}
end

-- Preserve capture-time calendar facts; never derive them from delayed delivery time.
local function validObservationCalendar(calendar)
    if calendar==nil then return true end
    if type(calendar)~='table' then return false end
    for key in pairs(calendar) do
        if key~='year' and key~='month' and key~='day' and key~='hour' then return false end
    end
    for _,field in ipairs({'year','month','day'}) do
        if type(calendar[field])~='number' or calendar[field]%1~=0 then return false end
    end
    local days={31,28,31,30,31,30,31,31,30,31,30,31}
    return calendar.year>=1 and calendar.year<=9999 and calendar.month>=0 and calendar.month<=11
        and calendar.day>=1 and calendar.day<=days[calendar.month+1]
        and type(calendar.hour)=='number' and calendar.hour==calendar.hour and calendar.hour>=0 and calendar.hour<24
end

-- A successful cast is an observation; an optional target is not a confirmed spell impact.
function M.actorResurrected(args)
    if type(args)~='table' or not identity.validate(args.actor) or args.actor.kind=='narrator'
        or not validObservationCalendar(args.calendar) then return nil,'invalid_resurrection_actor' end
    if type(args.game_time)~='number' or args.game_time~=args.game_time or args.game_time<0
        or args.game_time>9007199254740991 then return nil,'invalid_resurrection_time' end
    local audience={};local seen={[identity.key(args.actor)]=true}
    if type(args.audience or {})~='table' or #(args.audience or {})>12 then return nil,'invalid_resurrection_audience' end
    for _,actor in ipairs(args.audience or {}) do
        if not identity.validate(actor) or (actor.kind~='npc' and actor.kind~='creature')
            or seen[identity.key(actor)] then return nil,'invalid_resurrection_audience' end
        seen[identity.key(actor)]=true;audience[#audience+1]=util.copy(actor)
    end
    return {actor=util.copy(args.actor),audience=audience,game_time=args.game_time,
        calendar=args.calendar and util.copy(args.calendar) or nil}
end

function M.spellCast(args)
    if type(args)=='table' and not validObservationCalendar(args.calendar) then return nil,'invalid_spell_calendar' end
    if type(args)~='table' or not identity.validate(args.caster)
        or not ({player=true,npc=true,creature=true})[args.caster.kind]
        or (args.target~=nil and (not identity.validate(args.target) or args.target.kind=='narrator')) then
        return nil,'invalid_spell_actor'
    end
    if type(args.spell_id)~='string' or #args.spell_id<1 or #args.spell_id>256
        or type(args.spell_name)~='string' or #args.spell_name<1 or #args.spell_name>256
        or type(args.game_time)~='number' or args.game_time~=args.game_time
        or args.game_time<0 or args.game_time>9007199254740991 then return nil,'invalid_spell_observation' end
    local audience
    if args.audience~=nil then
        if type(args.audience)~='table' or #args.audience>12 then return nil,'invalid_spell_audience' end
        local seen={[identity.key(args.caster)]=true}
        if args.target then seen[identity.key(args.target)]=true end
        audience={}
        for _,actor in ipairs(args.audience) do
            if not identity.validate(actor) or (actor.kind~='npc' and actor.kind~='creature') then return nil,'invalid_spell_audience' end
            local key=identity.key(actor)
            if seen[key] then return nil,'duplicate_spell_audience' end
            seen[key]=true;audience[#audience+1]=util.copy(actor)
        end
    end
    return {caster=util.copy(args.caster),target=args.target and util.copy(args.target) or nil,audience=audience,
        spell_id=args.spell_id,spell_name=args.spell_name,game_time=args.game_time,
        calendar=args.calendar and util.copy(args.calendar) or nil}
end

-- Only a completed native pickup supplies these values; inventory differences are not acquisition evidence.
function M.itemPickup(args)
    if type(args)=='table' and not validObservationCalendar(args.calendar) then return nil,'invalid_pickup_calendar' end
    if type(args)~='table' or not identity.validate(args.player) or args.player.kind~='player' then
        return nil,'invalid_pickup_player'
    end
    for _,field in ipairs({'item_record_id','item_name'}) do
        if type(args[field])~='string' or #args[field]<1 or #args[field]>256 then return nil,'invalid_pickup_item' end
    end
    if type(args.count)~='number' or args.count%1~=0 or args.count<1 or args.count>2147483647
        or type(args.unit_value)~='number' or args.unit_value%1~=0 or args.unit_value<0 or args.unit_value>2147483647
        or type(args.game_time)~='number' or args.game_time~=args.game_time or args.game_time<0 or args.game_time>9007199254740991
        or not ({world=true,container=true,actor=true})[args.source_kind] then return nil,'invalid_pickup_observation' end
    local source
    if args.source~=nil then
        if type(args.source)~='table' then return nil,'invalid_pickup_source' end
        for _,field in ipairs({'record_id','display_name'}) do
            if type(args.source[field])~='string' or #args.source[field]<1 or #args.source[field]>256 then return nil,'invalid_pickup_source' end
        end
        source={record_id=args.source.record_id,display_name=args.source.display_name}
    end
    local audience
    if args.audience~=nil then
        if type(args.audience)~='table' or #args.audience>12 then return nil,'invalid_pickup_audience' end
        audience={};local seen={[identity.key(args.player)]=true}
        for _,actor in ipairs(args.audience) do
            if not identity.validate(actor) or (actor.kind~='npc' and actor.kind~='creature') then return nil,'invalid_pickup_audience' end
            local key=identity.key(actor)
            if seen[key] then return nil,'duplicate_pickup_audience' end
            seen[key]=true;audience[#audience+1]=util.copy(actor)
        end
    end
    return {player=util.copy(args.player),item_record_id=args.item_record_id,item_name=args.item_name,
        count=args.count,unit_value=args.unit_value,game_time=args.game_time,source_kind=args.source_kind,
        source=source,audience=audience,calendar=args.calendar and util.copy(args.calendar) or nil}
end

-- Validate the actor snapshot that materializes a profile after successful automatic activation.
function M.actorProfile(args)
    if type(args)~='table' or not identity.validate(args.actor)
        or (args.actor.kind~='npc' and args.actor.kind~='creature') then
        return nil,'invalid_actor_profile'
    end
    if type(args.race)~='string' or #args.race<1 or #args.race>128
        or type(args.class)~='string' or #args.class>128
        or not ({female=true,male=true,none=true,unknown=true})[args.gender]
        or type(args.level)~='number' or args.level%1~=0 or args.level<1 or args.level>255
        or type(args.disposition)~='number' or args.disposition%1~=0
        or args.disposition<0 or args.disposition>100
        or type(args.factions)~='table' or #args.factions>32 then
        return nil,'invalid_actor_profile'
    end
    local factions,seen={},{}
    for _,faction in ipairs(args.factions) do
        if type(faction)~='string' or #faction<1 or #faction>256 or seen[faction] then
            return nil,'invalid_actor_profile'
        end
        seen[faction]=true factions[#factions+1]=faction
    end
    return {actor=util.copy(args.actor),race=args.race,class=args.class,gender=args.gender,
        level=args.level,disposition=args.disposition,factions=factions}
end

-- Real RPG observations stay separate from spoken dialogue and model-authored event text.
function M.rpgEvent(args)
    if type(args)~='table' or not ({levelup=true,combat_end=true,sleep=true,wait=true})[args.kind] then
        return nil,'invalid_rpg_event'
    end
    if not identity.validate(args.player) or args.player.kind~='player' then return nil,'invalid_rpg_player' end
    if type(args.game_time)~='number' or args.game_time~=args.game_time or args.game_time<0 or args.game_time>9007199254740991 then return nil,'invalid_game_time' end
    if type(args.text)~='string' or #args.text<1 or #args.text>1024 then return nil,'invalid_rpg_text' end
    local payload={kind=args.kind,player=util.copy(args.player),game_time=args.game_time,text=args.text}
    if args.responder~=nil then
        if not identity.validate(args.responder) or (args.responder.kind~='npc' and args.responder.kind~='creature') then
            return nil,'invalid_rpg_responder'
        end
        payload.responder=util.copy(args.responder)
    end
    return payload
end

-- Send complete observed quest lines within the wire limit; never invent an unknown journal stage.
function M.questText(entries)
    if type(entries)~='table' then return nil,'invalid_quest_event' end
    local lines,bytes={},0
    for _,entry in ipairs(entries) do
        if type(entry)=='table' and type(entry.quest_id)=='string' and type(entry.text)=='string' and entry.text~='' then
            local heading='Quest '..entry.quest_id
            if type(entry.stage)=='number' and entry.stage>=0 and entry.stage%1==0 then heading=heading..', stage '..tostring(entry.stage) end
            local line=heading..': '..entry.text
            if bytes+#line+1<=8192 then lines[#lines+1]=line;bytes=bytes+#line+1 end
        end
        if #lines>=32 then break end
    end
    if #lines==0 then return nil,'quest_text_unavailable' end
    return table.concat(lines,'\n')
end

-- Bind the formatted observation to an eligible NPC for the server policy decision.
function M.questEvent(args)
    if type(args)~='table' or not identity.validate(args.responder) or args.responder.kind~='npc'
        or type(args.game_time)~='number' or args.game_time~=args.game_time or args.game_time<0
        or args.game_time>9007199254740991 then return nil,'invalid_quest_event' end
    local text,reason=M.questText(args.entries)
    if not text then return nil,reason end
    return {responder=util.copy(args.responder),game_time=args.game_time,text=text}
end

-- Validate one bounded automatic diary candidate before it reaches the native bridge.
function M.automaticDiary(args)
    if type(args)~='table' or not ({timer=true,sleep=true,wait=true})[args.trigger]
        or type(args.game_time)~='number' or args.game_time<0
        or type(args.actors)~='table' or #args.actors>constants.MAX_AUDIENCE then
        return nil,'invalid_automatic_diary'
    end
    local actors,seen={},{}
    for _,actor in ipairs(args.actors) do
        if not identity.validate(actor) or (actor.kind~='npc' and actor.kind~='creature') then
            return nil,'invalid_automatic_diary'
        end
        local key=identity.key(actor)
        if seen[key] then return nil,'duplicate_automatic_diary_actor' end
        seen[key]=true actors[#actors+1]=util.copy(actor)
    end
    return {trigger=args.trigger,game_time=args.game_time,actors=actors}
end

-- pollResults returns native-validated internal DTOs, not canonical wire envelopes.
function M.validatePolledEvent(event)
    if type(event)~='table' then return nil,'event_not_table' end
    if not knownInternalEvents[event.type] then return nil,'unknown_event_type' end
    for _,key in ipairs({'message_id','request_id','turn_id','session_id'}) do
        if not M.isUuid(event[key]) then return nil,'invalid_'..key end
    end
    if type(event.generation)~='number' or event.generation%1~=0 or event.generation<0 then return nil,'invalid_generation' end
    if type(event.sequence)~='number' or event.sequence%1~=0 or event.sequence<1 then return nil,'invalid_event_cursor' end
    if type(event.payload)~='table' then return nil,'invalid_event_payload' end
    if (event.type=='dialogue.delta' or event.type=='dialogue.complete') and type(event.payload.text)~='string' then
        return nil,'invalid_dialogue_text'
    end
    if event.type=='stt.transcript' then
        if type(event.payload.text)~='string' or #event.payload.text<1 or #event.payload.text>16384 then return nil,'invalid_stt_text' end
        if not isLanguageTag(event.payload.language) then return nil,'invalid_stt_language' end
    end
    if event.type=='stt.failed' then
        local code=event.payload.code
        if code~='invalid_audio' and code~='provider_invalid_output' and code~='provider_timeout' and code~='provider_unavailable' then return nil,'invalid_stt_failure_code' end
        if type(event.payload.retriable)~='boolean' then return nil,'invalid_stt_retriable' end
        if event.payload.retry_after_ms~=nil and (type(event.payload.retry_after_ms)~='number' or event.payload.retry_after_ms%1~=0 or event.payload.retry_after_ms<0) then return nil,'invalid_stt_retry_after' end
    end
    if event.type=='speech.ready' then
        if not M.isUuid(event.payload.media_id) then return nil,'invalid_speech_media_id' end
        if not M.isUuid(event.payload.dialogue_message_id) then return nil,'invalid_speech_dialogue_message_id' end
        if type(event.payload.sha256)~='string' or #event.payload.sha256~=64 or event.payload.sha256:match('[^0-9a-f]') then return nil,'invalid_speech_sha256' end
        if event.payload.codec~='wav' and event.payload.codec~='ogg' and event.payload.codec~='mp3' then return nil,'invalid_speech_codec' end
        if type(event.payload.bytes)~='number' or event.payload.bytes%1~=0 or event.payload.bytes<1 or event.payload.bytes>33554432 then return nil,'invalid_speech_bytes' end
        if type(event.payload.duration_ms)~='number' or event.payload.duration_ms%1~=0 or event.payload.duration_ms<1 then return nil,'invalid_speech_duration' end
        if type(event.payload.expires_at)~='string' or not event.payload.expires_at:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$') then return nil,'invalid_speech_expires_at' end
    end
    if event.type=='response.complete' then
        local responseOk,responseReason=M.validateCanonicalResponse(event.payload,event)
        if not responseOk then return nil,responseReason end
    end
    if event.type=='action.intent' and event.payload.schema~='lorkhan.action-intent.v1' then return nil,'invalid_action_intent' end
    return true
end

function M.dialogueDeliveryResult(args)
    local required={'message_id','request_id','dialogue_message_id','turn_id','session_id','generation','speaker','status','reason_code','completed_at'}
    for _,key in ipairs(required) do if args[key]==nil then return nil,'missing_'..key end end
    for _,key in ipairs({'message_id','request_id','dialogue_message_id','turn_id','session_id'}) do
        if not M.isUuid(args[key]) then return nil,'invalid_'..key end
    end
    if type(args.generation)~='number' or args.generation%1~=0 or args.generation<0 then return nil,'invalid_generation' end
    if not identity.validate(args.speaker) then return nil,'invalid_speaker' end
    if args.status~='played' and args.status~='failed' and args.status~='expired' and args.status~='interrupted' then return nil,'invalid_delivery_status' end
    if type(args.reason_code)~='string' or #args.reason_code<1 or #args.reason_code>128 or not args.reason_code:match('^[a-z][a-z0-9_]*$') then return nil,'invalid_reason_code' end
    if type(args.completed_at)~='string' or not args.completed_at:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$') then return nil,'invalid_completed_at' end
    return {schema='lorkhan.dialogue-delivery-result.v1',message_id=args.message_id,request_id=args.request_id,
        dialogue_message_id=args.dialogue_message_id,turn_id=args.turn_id,session_id=args.session_id,
        generation=args.generation,speaker=util.copy(args.speaker),status=args.status,
        reason_code=args.reason_code,completed_at=args.completed_at}
end

function M.CursoredEvents(sessionId, generation)
    local cursor, seen = 0, {}
    return {
        reset = function(_, nextSession, nextGeneration) sessionId=nextSession generation=nextGeneration cursor=0 seen={} end,
        accept = function(_, event)
            local ok, reason = M.validatePolledEvent(event)
            if not ok then return nil, reason end
            if event.session_id ~= sessionId then return nil, 'stale_session' end
            if event.generation ~= generation then return nil, 'stale_generation' end
            local key = event.session_id .. '|' .. tostring(event.sequence) .. '|' .. event.message_id
            if seen[key] or event.sequence <= cursor then return false, 'duplicate_event' end
            -- The native transport has already authenticated and advanced the server cursor; let
            -- the Lua mirror recover forward when one native-to-Lua dispatch was missed.
            local recovered = event.sequence ~= cursor + 1
            seen[key], cursor = true, event.sequence
            return true, recovered and 'cursor_resynced' or nil
        end,
        cursor = function() return cursor end,
    }
end

return M
