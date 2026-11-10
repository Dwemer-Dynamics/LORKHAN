local constants = require('scripts.LORKHAN.constants')
local identity = require('scripts.LORKHAN.identity')
local util = require('scripts.LORKHAN.util')

-- Versioned lorkhan.plugin.*.v1 addon contract. Addons declare bounded typed actions, events and
-- prompt slots; the server may only name a registered action with declared enum/number/boolean/actor
-- parameters. No code, console command, path or URL crosses this boundary.
local M = {}
M.CAPABILITY = 'plugin.contract.v1'
M.API_VERSION = 1
M.MANIFEST = 'lorkhan.plugin.manifest.v1'
M.REGISTRATION = 'lorkhan.plugin.registration.v1'
M.ACTION_INTENT = 'lorkhan.plugin.action-intent.v1'
M.EVENT = 'lorkhan.plugin.event.v1'
M.INTENT_EVENT_TYPE = 'plugin.action.intent'
M.MAX_PLUGINS = 16
local SLOTS = {actor_state=true, player_state=true, scene_notes=true, world_state=true}
local RESERVED = {builtin=true, core=true, lorkhan=true, morrowind=true, openmw=true, tes3=true}
local EXECUTORS = {creature=true, npc=true}
local ACTORS = {creature=true, npc=true, player=true}

local function isList(value, maximum)
    if type(value) ~= 'table' or #value > maximum then return false end
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    return count == #value
end

local function exactKeys(value, required, optional)
    if type(value) ~= 'table' then return false end
    local allowed = {}
    for _, key in ipairs(required) do
        if value[key] == nil then return false end
        allowed[key] = true
    end
    for _, key in ipairs(optional or {}) do allowed[key] = true end
    for key in pairs(value) do if not allowed[key] then return false end end
    return true
end

local function uuid(value)
    return type(value) == 'string'
        and value:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') ~= nil
        and value:lower() == value
end

local function timestamp(value)
    return type(value) == 'string' and #value <= 32
        and value:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[.%d]*Z$') ~= nil
end

local function integer(value, minimum, maximum)
    return type(value) == 'number' and value % 1 == 0 and value >= minimum and value <= maximum
end

local function finite(value, limit)
    return type(value) == 'number' and value == value and value >= -limit and value <= limit
end

local function text(value, maximum)
    return type(value) == 'string' and #value > 0 and #value <= maximum * 4
        and (utf8 == nil or (utf8.len(value) or maximum + 1) <= maximum) and not value:find('%c')
end

function M.isPluginId(value)
    if type(value) ~= 'string' then return false end
    local author, name = value:match('^([a-z][a-z0-9_]*)%.([a-z][a-z0-9_]*)$')
    return author ~= nil and #author >= 2 and #author <= 32 and #name >= 2 and #name <= 48 and not RESERVED[author]
end

function M.isVersion(value)
    if type(value) ~= 'string' then return false end
    local parts = {value:match('^(%d+)%.(%d+)%.(%d+)$')}
    if #parts ~= 3 then return false end
    for _, part in ipairs(parts) do
        if #part > 5 or (#part > 1 and part:sub(1, 1) == '0') then return false end
    end
    return true
end

function M.isName(value)
    return type(value) == 'string' and #value <= 32 and value:match('^[a-z][a-z0-9_]*$') ~= nil
end

function M.isToken(value)
    return type(value) == 'string' and #value <= 64 and value:match('^[a-z0-9][a-z0-9_.%-]*$') ~= nil
end

function M.compareVersions(left, right)
    local a, b = {left:match('^(%d+)%.(%d+)%.(%d+)$')}, {right:match('^(%d+)%.(%d+)%.(%d+)$')}
    for index = 1, 3 do
        local x, y = tonumber(a[index]), tonumber(b[index])
        if x ~= y then return x < y and -1 or 1 end
    end
    return 0
end

local function kinds(value, allowed, minimum, maximum)
    if not isList(value, maximum) or #value < minimum then return false end
    local seen = {}
    for _, kind in ipairs(value) do
        if not allowed[kind] or seen[kind] then return false end
        seen[kind] = true
    end
    return true
end

local function uniqueNames(list, maximum, check)
    if not isList(list, maximum) then return false end
    local seen = {}
    for _, item in ipairs(list) do
        local name = check(item)
        if not name or seen[name] then return false end
        seen[name] = true
    end
    return true
end

local function tierConfirmation(tier, confirmation)
    return integer(tier, 0, 2) and (confirmation == 'none' or confirmation == 'optional' or confirmation == 'required')
        and (tier ~= 2 or confirmation == 'required')
end

-- Validate one declarative specification; free text exists only for client-observed event fields.
local function spec(value, field)
    if type(value) ~= 'table' or not M.isName(value.name) or type(value.required) ~= 'boolean' then return nil end
    local kind = value.type
    if kind == 'integer' or kind == 'number' then
        if not exactKeys(value, {'name', 'type', 'required', 'minimum', 'maximum'}) then return nil end
        local valid = kind == 'integer' and integer(value.minimum, -2147483647, 2147483647)
            and integer(value.maximum, -2147483647, 2147483647)
            or kind == 'number' and finite(value.minimum, 1000000000) and finite(value.maximum, 1000000000)
        if not valid or value.minimum > value.maximum then return nil end
    elseif kind == 'boolean' then
        if not exactKeys(value, {'name', 'type', 'required'}) then return nil end
    elseif kind == 'enum' then
        if not exactKeys(value, {'name', 'type', 'required', 'values'}) or not isList(value.values, 32) or #value.values < 1 then return nil end
        local seen = {}
        for _, token in ipairs(value.values) do
            if not M.isToken(token) or seen[token] then return nil end
            seen[token] = true
        end
    elseif kind == 'actor' then
        if not exactKeys(value, {'name', 'type', 'required', 'actor_kinds'}) or not kinds(value.actor_kinds, ACTORS, 1, 3) then return nil end
    elseif kind == 'text' and field then
        if not exactKeys(value, {'name', 'type', 'required', 'max_length'}) or not integer(value.max_length, 1, 512) then return nil end
    else
        return nil
    end
    return value.name
end

local function value(declared, supplied)
    local kind = declared.type
    if kind == 'integer' then return integer(supplied, declared.minimum, declared.maximum) end
    if kind == 'number' then return finite(supplied, math.huge) and supplied >= declared.minimum and supplied <= declared.maximum end
    if kind == 'boolean' then return type(supplied) == 'boolean' end
    if kind == 'enum' then
        for _, token in ipairs(declared.values) do if supplied == token then return true end end
        return false
    end
    if kind == 'actor' then
        if not identity.validate(supplied) then return false end
        for _, allowed in ipairs(declared.actor_kinds) do if supplied.kind == allowed then return true end end
        return false
    end
    return kind == 'text' and text(supplied, declared.max_length)
end

-- Check supplied parameters or fields against declared specifications.
function M.values(specs, supplied)
    if type(supplied) ~= 'table' then return nil, 'plugin_values_invalid' end
    local declared, count = {}, 0
    for _, item in ipairs(specs) do declared[item.name] = item end
    for name, item in pairs(supplied) do
        count = count + 1
        if count > 8 or not declared[name] or not value(declared[name], item) then return nil, 'plugin_values_invalid' end
    end
    for name, item in pairs(declared) do
        if item.required and supplied[name] == nil then return nil, 'plugin_values_invalid' end
    end
    return true
end

local function actionSpec(action)
    if not exactKeys(action, {'name', 'display_name', 'description', 'tier', 'confirmation', 'executor_kinds', 'target',
        'target_kinds', 'timeout_seconds', 'cancellable', 'parameters'}) then return nil end
    if not M.isName(action.name) or not text(action.display_name, 64) or not text(action.description, 256)
        or not tierConfirmation(action.tier, action.confirmation) or not kinds(action.executor_kinds, EXECUTORS, 1, 2)
        or not kinds(action.target_kinds, ACTORS, 0, 3) or not integer(action.timeout_seconds, 1, 300)
        or type(action.cancellable) ~= 'boolean' then return nil end
    if action.target ~= 'none' and action.target ~= 'optional' and action.target ~= 'required' then return nil end
    if (action.target == 'none') ~= (#action.target_kinds == 0) then return nil end
    if not uniqueNames(action.parameters, 8, function(item) return spec(item, false) end) then return nil end
    return action.name
end

function M.validateManifest(manifest)
    if not exactKeys(manifest, {'schema', 'plugin_id', 'version', 'api_version', 'display_name', 'description', 'author',
        'compatibility', 'dependencies', 'default_enabled', 'actions', 'events', 'prompt_contributions'})
        or manifest.schema ~= M.MANIFEST or manifest.api_version ~= M.API_VERSION then return nil, 'invalid_plugin_manifest' end
    if not M.isPluginId(manifest.plugin_id) then return nil, 'invalid_plugin_id' end
    if not M.isVersion(manifest.version) or not text(manifest.display_name, 64) or not text(manifest.description, 256)
        or not text(manifest.author, 64) or type(manifest.default_enabled) ~= 'boolean' then return nil, 'invalid_plugin_manifest' end
    local compatibility = manifest.compatibility
    if not exactKeys(compatibility, {'product', 'game', 'min_client_version', 'min_server_version', 'lua_api_revision'})
        or compatibility.product ~= 'lorkhan' or compatibility.game ~= 'tes3' or not M.isVersion(compatibility.min_client_version)
        or not M.isVersion(compatibility.min_server_version) or not integer(compatibility.lua_api_revision, 129, 1000000) then
        return nil, 'invalid_plugin_compatibility'
    end
    local dependenciesValid = uniqueNames(manifest.dependencies, 8, function(dependency)
        if not exactKeys(dependency, {'plugin_id', 'min_version'}, {'max_version_exclusive'})
            or not M.isPluginId(dependency.plugin_id) or dependency.plugin_id == manifest.plugin_id
            or not M.isVersion(dependency.min_version) then return nil end
        if dependency.max_version_exclusive ~= nil and (not M.isVersion(dependency.max_version_exclusive)
            or M.compareVersions(dependency.max_version_exclusive, dependency.min_version) <= 0) then return nil end
        return dependency.plugin_id
    end)
    if not dependenciesValid then return nil, 'invalid_plugin_dependencies' end
    if not uniqueNames(manifest.actions, 16, actionSpec) then return nil, 'invalid_plugin_actions' end
    local eventsValid = uniqueNames(manifest.events, 16, function(event)
        if not exactKeys(event, {'name', 'description', 'max_per_minute', 'fields'}) or not M.isName(event.name)
            or not text(event.description, 256) or not integer(event.max_per_minute, 1, 120)
            or not uniqueNames(event.fields, 8, function(item) return spec(item, true) end) then return nil end
        return event.name
    end)
    if not eventsValid then return nil, 'invalid_plugin_events' end
    local slotsValid = uniqueNames(manifest.prompt_contributions, 4, function(slot)
        if not exactKeys(slot, {'slot', 'max_chars'}) or not SLOTS[slot.slot] or not integer(slot.max_chars, 1, 1024) then return nil end
        return slot.slot
    end)
    if not slotsValid then return nil, 'invalid_plugin_prompt_slots' end
    return true
end

-- Build the client-owned registration entry for one installed, locally active addon.
-- actorScopes optionally binds named actions to exact TES3 actor identities.
function M.registrationEntry(manifest, manifestSha256, actorScopes)
    local ok, reason = M.validateManifest(manifest)
    if not ok then return nil, reason end
    if type(manifestSha256) ~= 'string' or not manifestSha256:match('^' .. string.rep('[0-9a-f]', 64) .. '$') then
        return nil, 'invalid_plugin_manifest_hash'
    end
    local actions, events, slots = {}, {}, {}
    for _, action in ipairs(manifest.actions) do
        local entry = {name=action.name, tier=action.tier, confirmation=action.confirmation,
            executor_kinds=util.arrayCopy(action.executor_kinds)}
        local scope = actorScopes and actorScopes[action.name]
        if scope ~= nil then
            if not isList(scope, 12) or #scope < 1 then return nil, 'invalid_plugin_actor_scope' end
            local seen = {}
            for _, actor in ipairs(scope) do
                local key = identity.key(actor)
                if not key or not EXECUTORS[actor.kind] or seen[key] then return nil, 'invalid_plugin_actor_scope' end
                seen[key] = true
            end
            entry.actors = util.copy(scope)
        end
        actions[#actions + 1] = entry
    end
    for _, event in ipairs(manifest.events) do events[#events + 1] = event.name end
    for _, slot in ipairs(manifest.prompt_contributions) do slots[#slots + 1] = slot.slot end
    return {plugin_id=manifest.plugin_id, version=manifest.version, manifest_sha256=manifestSha256,
        actions=actions, events=events, prompt_slots=slots}
end

-- Session-owned plugin state; a new generation always starts empty and must re-register.
function M.new(session)
    local enabled = false
    for _, capability in ipairs(session.capabilities or {}) do
        if capability == M.CAPABILITY then enabled = true end
    end
    return {enabled=enabled, session_id=session.session_id, generation=session.generation, plugins={}}
end

-- Record a locally registered addon only after the server reported it active.
function M.activate(state, manifest, entry, serverState)
    if not state.enabled then return nil, 'plugin_contract_unsupported' end
    if serverState ~= 'active' then return nil, 'plugin_not_active' end
    if entry.plugin_id ~= manifest.plugin_id or entry.version ~= manifest.version then return nil, 'plugin_version_mismatch' end
    -- Mirror server limits: pinned Lua API until native negotiation proves another, and 16 active plugins.
    local revision = type(manifest.compatibility) == 'table' and manifest.compatibility.lua_api_revision
    if type(revision) ~= 'number' or revision > constants.LUA_API_REVISION then return nil, 'plugin_incompatible' end
    if not state.plugins[entry.plugin_id] then
        local count = 0
        for _ in pairs(state.plugins) do count = count + 1 end
        if count >= M.MAX_PLUGINS then return nil, 'plugin_limit_exceeded' end
    end
    state.plugins[entry.plugin_id] = {manifest=manifest, registration=entry}
    return true
end

function M.deactivate(state, pluginId)
    state.plugins[pluginId] = nil
end

local function find(list, name)
    for _, item in ipairs(list) do if item.name == name then return item end end
end

-- Validate one server plugin intent against the local registration before any addon handler runs.
function M.validateIntent(state, intent, authority)
    if type(intent) ~= 'table' or intent.schema ~= M.ACTION_INTENT then return nil, 'invalid_plugin_intent_schema' end
    if not exactKeys(intent, {'schema', 'action_id', 'turn_id', 'session_id', 'generation', 'plugin_id', 'plugin_version',
        'action', 'tier', 'confirmation_required', 'cancellable', 'actor', 'parameters', 'expires_at'}, {'target'}) then
        return nil, 'invalid_plugin_intent_fields'
    end
    if not uuid(intent.action_id) or not uuid(intent.turn_id) or not timestamp(intent.expires_at) then
        return nil, 'invalid_plugin_intent_fields'
    end
    if not state.enabled then return nil, 'plugin_contract_unsupported' end
    if intent.session_id ~= state.session_id or intent.generation ~= state.generation
        or intent.session_id ~= authority.session_id or intent.generation ~= authority.generation then return nil, 'stale_action' end
    local plugin = state.plugins[intent.plugin_id]
    if not plugin or plugin.manifest.version ~= intent.plugin_version then return nil, 'plugin_not_active' end
    local registered = find(plugin.registration.actions, intent.action)
    local declared = find(plugin.manifest.actions, intent.action)
    if not registered or not declared then return nil, 'plugin_action_unregistered' end
    if intent.tier ~= declared.tier or intent.confirmation_required ~= (declared.confirmation == 'required')
        or intent.cancellable ~= declared.cancellable then return nil, 'plugin_action_policy_mismatch' end
    if not identity.validate(intent.actor) or not EXECUTORS[intent.actor.kind] then return nil, 'wrong_actor' end
    local executor = false
    for _, kind in ipairs(registered.executor_kinds) do executor = executor or kind == intent.actor.kind end
    local scoped = registered.actors == nil
    for _, actor in ipairs(registered.actors or {}) do scoped = scoped or identity.same(actor, intent.actor) end
    if not executor or not scoped then return nil, 'wrong_actor' end
    if not authority.resolve(intent.actor) then return nil, 'actor_inactive' end
    local target = intent.target
    if (declared.target == 'none' and target ~= nil) or (declared.target == 'required' and target == nil) then
        return nil, 'invalid_plugin_target'
    end
    if target ~= nil then
        local allowed = false
        for _, kind in ipairs(declared.target_kinds) do allowed = allowed or kind == target.kind end
        if not identity.validate(target) or not allowed then return nil, 'invalid_plugin_target' end
        if not authority.resolve(target) then return nil, 'target_inactive' end
    end
    local ok = M.values(declared.parameters, intent.parameters)
    if not ok then return nil, 'invalid_plugin_parameters' end
    if type(authority.expired) ~= 'function' or authority.expired(intent.expires_at) then return nil, 'action_expired' end
    return {plugin_id=intent.plugin_id, action=intent.action, action_id=intent.action_id, turn_id=intent.turn_id,
        actor=util.copy(intent.actor), target=util.copy(target), parameters=util.copy(intent.parameters),
        confirmation_required=intent.confirmation_required, cancellable=intent.cancellable}
end

-- Build one bounded plugin event for an active addon's registered event.
function M.event(state, args)
    if not state.enabled then return nil, 'plugin_contract_unsupported' end
    if not uuid(args.message_id) or not uuid(args.request_id) or not timestamp(args.observed_at) then
        return nil, 'invalid_plugin_event_envelope'
    end
    local plugin = state.plugins[args.plugin_id]
    if not plugin then return nil, 'plugin_not_active' end
    local declared = find(plugin.manifest.events, args.event)
    local registered = false
    for _, name in ipairs(plugin.registration.events) do registered = registered or name == args.event end
    if not declared or not registered then return nil, 'plugin_event_unregistered' end
    local ok = M.values(declared.fields, args.fields)
    if not ok then return nil, 'invalid_plugin_event_fields' end
    return {schema=M.EVENT, message_id=args.message_id, request_id=args.request_id, session_id=state.session_id,
        generation=state.generation, observed_at=args.observed_at, plugin_id=args.plugin_id,
        plugin_version=plugin.manifest.version, event=args.event, fields=util.copy(args.fields)}
end

return M
