local M={}
function M.identity(kind,record,index)
 return {kind=kind,record_id=record,refnum={index=index,content_file=0},content_file='Test.esm',cell={kind='interior',name='Test'},display_name=record}
end
function M.bridge()
 local bridge={submitted={},results={},cancelled={},halted=false}
 function bridge.submitTurn(dto) table.insert(bridge.submitted,dto) return dto.request_id end
 function bridge.pollResults(max) local out={} for _=1,math.min(max,#bridge.results) do table.insert(out,table.remove(bridge.results,1)) end return out end
 function bridge.cancelGeneration(generation) table.insert(bridge.cancelled,generation) end
 function bridge.halt() bridge.halted=true bridge.results={} bridge.submitted={} end
 return bridge
end
return M
