local constants = require('scripts.ALMSIVI.constants')
local identity = require('scripts.ALMSIVI.identity')
local util = require('scripts.ALMSIVI.util')

local M = {}
local knownInternalEvents = {['turn.accepted']=true, ['turn.status']=true, ['dialogue.delta']=true,
    ['dialogue.complete']=true, ['speech.ready']=true, ['action.intent']=true, ['turn.complete']=true,
    ['turn.failed']=true, ['turn.cancelled']=true, ['session.config_changed']=true, ['server.notice']=true}

function M.isUuid(value)
    if type(value)~='string' then return false end
    local a,b,c,d,e=value:match('^([0-9a-fA-F]+)%-([0-9a-fA-F]+)%-([0-9a-fA-F]+)%-([0-9a-fA-F]+)%-([0-9a-fA-F]+)$')
    return a and #a==8 and #b==4 and #c==4 and #d==4 and #e==12 or false
end

function M.runtime(platform, capabilities)
    return {game='tes3', variant='openmw', openmw_version=constants.OPENMW_VERSION,
        openmw_commit=constants.OPENMW_COMMIT, lua_api_revision=constants.LUA_API_REVISION,
        client_version=constants.CLIENT_VERSION, platform=platform, capabilities=util.arrayCopy(capabilities or {})}
end

function M.turn(args)
    local required = {'message_id','request_id','turn_id','installation_id','profile_id','playthrough_id',
        'session_id','generation','created_at','platform','content_fingerprint','text','speaker','target','audience','context','ui_source'}
    for _, key in ipairs(required) do if args[key] == nil then return nil, 'missing_' .. key end end
    for _, key in ipairs({'message_id','request_id','turn_id','installation_id','profile_id','playthrough_id','session_id'}) do
        if not M.isUuid(args[key]) then return nil,'invalid_'..key end
    end
    if type(args.text) ~= 'string' or args.text:match('^%s*$') then return nil, 'empty_input' end
    if not identity.validate(args.target) or not identity.validate(args.speaker) then return nil, 'invalid_identity' end
    if #args.audience > constants.MAX_AUDIENCE then return nil, 'audience_too_large' end
    return {
        schema='almsivi.turn.v1', message_id=args.message_id, request_id=args.request_id, turn_id=args.turn_id,
        installation_id=args.installation_id, profile_id=args.profile_id, playthrough_id=args.playthrough_id,
        session_id=args.session_id, generation=args.generation, created_at=args.created_at,
        runtime=M.runtime(args.platform, args.capabilities), content_fingerprint=args.content_fingerprint,
        payload={input={kind='text', text=args.text, language=args.language}, speaker=util.copy(args.speaker),
            target=util.copy(args.target), audience=util.arrayCopy(args.audience), context=util.copy(args.context),
            recent_action_results=util.arrayCopy(args.recent_action_results or {}), ui_source=args.ui_source}
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
    if event.type=='speech.ready' then
        for _,key in ipairs({'media_id','sha256','codec','expires_at'}) do if type(event.payload[key])~='string' then return nil,'invalid_speech_'..key end end
        if type(event.payload.bytes)~='number' or event.payload.bytes%1~=0 or event.payload.bytes<0 then return nil,'invalid_speech_bytes' end
    end
    if event.type=='action.intent' and type(event.payload.intent)~='table' then return nil,'invalid_action_intent' end
    return true
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
