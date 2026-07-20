local M={}
function M.identity(kind,record,index)
 return {kind=kind,record_id=record,refnum={index=index,content_file=0},content_file='Test.esm',cell={kind='interior',name='Test'},display_name=record}
end
function M.bridge()
 local bridge={submitted={},results={},cancelled={},prepared={},media={},played={},stopped=0,halted=false}
 function bridge.submitTurn(dto) table.insert(bridge.submitted,dto) return dto.request_id end
 function bridge.pollResults(max) local out={} for _=1,math.min(max,#bridge.results) do table.insert(out,table.remove(bridge.results,1)) end return out end
 function bridge.prepareMedia(descriptor) table.insert(bridge.prepared,descriptor);bridge.media[descriptor.media_id]={state='preparing'};return 'prepare-'..descriptor.media_id end
 function bridge.mediaStatus(mediaId) return bridge.media[mediaId] end
 function bridge.playSpeech(mediaId,actor,subtitle) table.insert(bridge.played,{media_id=mediaId,actor=actor,subtitle=subtitle});return true end
 function bridge.stopSpeech() bridge.stopped=bridge.stopped+1 end
 function bridge.cancelGeneration(generation) table.insert(bridge.cancelled,generation) end
 function bridge.halt() bridge.halted=true bridge.results={} bridge.submitted={} bridge.media={} end
 return bridge
end
return M
