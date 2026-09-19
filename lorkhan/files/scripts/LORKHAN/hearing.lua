local M={}

-- CHIM PlayerConversationRouter/SpatialAwareness constants; presets set the actual ranges.
function M.ranges(settings,mode,sneaking)
    settings=settings or {}
    local modifier=(mode=='Whisper' and 0.35 or mode=='Shout' and 2 or 1)*(sneaking and 0.5 or 1)
    local radius=mode=='Close' and (sneaking and 100 or 200) or (tonumber(settings.hearingDistance) or 1800)*modifier
    local automatic=mode=='Close' and 0 or math.min(radius,
        math.max(1,math.min(20,tonumber(settings.autoHearingRadiusMeters) or 10))*70*modifier)
    return radius,automatic
end

-- OpenMW supplies ray visibility, not Skyrim's door-corridor/navmesh fallback evaluator.
function M.audible(distance,radius,automatic,observation,interior)
    if type(distance)~='number' or distance~=distance or distance<0 or distance>radius then return false end
    if observation and observation.available==false then return false end
    if automatic>0 and distance<=automatic then return true end
    if not observation or observation.visible~=true then return false end
    local factor=math.max(interior and 0.2 or 0.1,1-distance/radius)
    return factor*(interior and 1 or 0.7)>=0.15
end

return M
