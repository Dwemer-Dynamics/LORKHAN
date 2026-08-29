local M={events={}}
function M.sendGlobalEvent(name,payload) assert(type(name)=='string' and type(payload)=='table');table.insert(M.events,{name=name,payload=payload}) end
return M
