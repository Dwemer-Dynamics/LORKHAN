local M={}
function M.create(spec) assert(type(spec)=='table');return {spec=spec,destroyed=false,destroy=function(self)self.destroyed=true end} end
return M
