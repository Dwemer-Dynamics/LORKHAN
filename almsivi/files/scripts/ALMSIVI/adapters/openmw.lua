local M = {}

function M.bridge()
    local ok, bridge = pcall(require, 'openmw.almsivi')
    if not ok then return nil, 'native_bridge_unavailable' end
    return bridge
end

function M.event()
    local ok, core = pcall(require, 'openmw.core')
    if not ok then return nil end
    return core
end

function M.ui()
    local ok, ui = pcall(require, 'openmw.ui')
    if not ok then return nil end
    return ui
end

-- Real OpenMW widget construction, camera rays, semantic action registration, object-to-identity
-- reads, and dynamic CUSTOM attachment stay confined here until verified against API revision 129.
return M
