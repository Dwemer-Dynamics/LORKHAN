local constants = require('scripts.ALMSIVI.constants')
local identity = require('scripts.ALMSIVI.identity')
local util = require('scripts.ALMSIVI.util')

local M = {}
local knownInternalEvents = {['turn.accepted']=true, ['dialogue.complete']=true,
    ['speech.ready']=true, ['action.intent']=true, ['turn.complete']=true,
    ['turn.failed']=true, ['turn.cancelled']=true, ['stt.transcript']=true,
    ['stt.failed']=true}

function M.isUuid(value)
    if type(value)~='string' then return false end
    local a,b,c,d,e=value:match('^([0-9a-f]+)%-([0-9a-f]+)%-([0-9a-f]+)%-([0-9a-f]+)%-([0-9a-f]+)$')
    return a and #a==8 and #b==4 and #c==4 and #d==4 and #e==12 or false
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
        'session_id','generation','created_at','platform','content_fingerprint','text','language','speaker','target','audience','context','ui_source'}
    for _, key in ipairs(required) do if args[key] == nil then return nil, 'missing_' .. key end end
    for _, key in ipairs({'message_id','request_id','turn_id','installation_id','profile_id','playthrough_id','session_id'}) do
        if not M.isUuid(args[key]) then return nil,'invalid_'..key end
    end
    if type(args.text) ~= 'string' or args.text:match('^%s*$') then return nil, 'empty_input' end
    if not isLanguageTag(args.language) then return nil,'invalid_language' end
    if not identity.validate(args.target) or not identity.validate(args.speaker) then return nil, 'invalid_identity' end
    if #args.audience > constants.MAX_AUDIENCE then return nil, 'audience_too_large' end
    local payload={input={kind='text', text=args.text, language=args.language}, speaker=util.copy(args.speaker),
        target=util.copy(args.target), audience=util.arrayCopy(args.audience), context=util.copy(args.context),
        recent_action_results=util.arrayCopy(args.recent_action_results or {}), ui_source=args.ui_source}
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
        schema='almsivi.turn.v1', message_id=args.message_id, request_id=args.request_id, turn_id=args.turn_id,
        installation_id=args.installation_id, profile_id=args.profile_id, playthrough_id=args.playthrough_id,
        session_id=args.session_id, generation=args.generation, created_at=args.created_at,
        runtime=M.runtime(args.platform, args.capabilities), content_fingerprint=args.content_fingerprint,
        payload=payload
    }
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
        if type(event.payload.sha256)~='string' or #event.payload.sha256~=64 or event.payload.sha256:match('[^0-9a-f]') then return nil,'invalid_speech_sha256' end
        if event.payload.codec~='wav' and event.payload.codec~='ogg' and event.payload.codec~='mp3' then return nil,'invalid_speech_codec' end
        if type(event.payload.bytes)~='number' or event.payload.bytes%1~=0 or event.payload.bytes<1 or event.payload.bytes>33554432 then return nil,'invalid_speech_bytes' end
        if type(event.payload.duration_ms)~='number' or event.payload.duration_ms%1~=0 or event.payload.duration_ms<1 then return nil,'invalid_speech_duration' end
        if type(event.payload.expires_at)~='string' or not event.payload.expires_at:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$') then return nil,'invalid_speech_expires_at' end
    end
    if event.type=='action.intent' and event.payload.schema~='almsivi.action-intent.v1' then return nil,'invalid_action_intent' end
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
    return {schema='almsivi.dialogue-delivery-result.v1',message_id=args.message_id,request_id=args.request_id,
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
            if event.sequence ~= cursor + 1 then return nil, 'cursor_gap' end
            seen[key], cursor = true, event.sequence
            return true
        end,
        cursor = function() return cursor end,
    }
end

return M
