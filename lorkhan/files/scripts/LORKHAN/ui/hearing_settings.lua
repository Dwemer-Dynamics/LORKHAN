-- CHIM Hearing & Awareness presets; activation distances deliberately stay independent.
local M = {}
local presets = {
    Realistic = {4, 600, 1000},
    Recommended = {10, 1000, 1800},
    Extended = {15, 1600, 2400},
}
local keys = {'autoHearingRadiusMeters', 'interiorHearingDistance', 'exteriorHearingDistance'}

function M.preset(section)
    for name, values in pairs(presets) do
        if section:get(keys[1]) == values[1] and section:get(keys[2]) == values[2]
            and section:get(keys[3]) == values[3] then return name end
    end
    return 'Custom'
end

function M.apply(section, name)
    local values = presets[name]
    if not values then return end
    for i, key in ipairs(keys) do
        if section:get(key) ~= values[i] then section:set(key, values[i]) end
    end
end

-- Move old controls once, retaining custom distances and the old Wide multiplier.
function M.migrate(section, legacy)
    if section:get('layoutVersion') then return end
    local inside = tonumber(legacy:get('interiorHearingDistance')) or 500
    local outside = tonumber(legacy:get('exteriorHearingDistance')) or 1000
    local oldPreset = legacy:get('hearingPreset')
    if oldPreset == 'Wide' then inside, outside = inside * 2, outside * 2
    elseif inside == 500 and outside == 1000 then inside, outside = 1000, 1800 end
    local values = {
        autoHearingRadiusMeters = 10,
        interiorHearingDistance = inside,
        exteriorHearingDistance = outside,
        interiorDistance = tonumber(legacy:get('interiorDistance')) or 1200,
        exteriorDistance = tonumber(legacy:get('exteriorDistance')) or 2400,
    }
    for key, value in pairs(values) do
        if section:get(key) == nil then section:set(key, value) end
    end
    section:set('hearingPreset', M.preset(section))
    section:set('layoutVersion', 1)
end

-- OpenMW callbacks are queued: compare the final range values rather than using a re-entry flag.
function M.changed(section, key)
    if key == 'hearingPreset' then
        M.apply(section, section:get(key))
    elseif key == nil or key == keys[1] or key == keys[2] or key == keys[3] then
        local name = M.preset(section)
        if section:get('hearingPreset') ~= name then section:set('hearingPreset', name) end
    end
end

return M
