local M={}
function M.identity(kind,record,index)
 return {kind=kind,record_id=record,refnum={index=index,content_file=0},content_file='Test.esm',cell={kind='interior',name='Test'},display_name=record}
end
function M.bridge()
 local bridge={submitted={},results={},cancelled={},prepared={},media={},played={},stopped=0,halted=false,
  voiceState='idle',voiceSubmissions={},autonomy={}}
 function bridge.submitTurn(dto) table.insert(bridge.submitted,dto) return dto.request_id end
 function bridge.pollResults(max) local out={} for _=1,math.min(max,#bridge.results) do table.insert(out,table.remove(bridge.results,1)) end return out end
 function bridge.pollAutonomy(max) local out={} for _=1,math.min(max,#bridge.autonomy) do table.insert(out,table.remove(bridge.autonomy,1)) end return out end
 function bridge.prepareMedia(descriptor) table.insert(bridge.prepared,descriptor);bridge.media[descriptor.media_id]={state='preparing'};return 'prepare-'..descriptor.media_id end
 function bridge.mediaStatus(mediaId) return bridge.media[mediaId] end
 function bridge.playSpeech(mediaId,actor,subtitle,volumeBoost) table.insert(bridge.played,{media_id=mediaId,actor=actor,subtitle=subtitle,tts_volume_boost=volumeBoost});return true end
 function bridge.stopSpeech() bridge.stopped=bridge.stopped+1 end
 function bridge.startVoiceCapture(automatic,sensitivity,endDelay)
  bridge.voiceState='recording' bridge.voiceAutomatic=automatic==true
  bridge.voiceSensitivity=sensitivity bridge.voiceEndDelay=endDelay return 'recording'
 end
 function bridge.stopVoiceCapture() if bridge.voiceState=='recording' then bridge.voiceState='ready' end end
 function bridge.cancelVoiceCapture() bridge.voiceState='idle' bridge.voiceAutomatic=false end
 function bridge.voiceCaptureStatus() return {state=bridge.voiceState,bytes=3200,duration_ms=100,
  automatic=bridge.voiceAutomatic==true,voice_detected=bridge.voiceState=='ready'} end
 function bridge.submitCapturedStt(language)
  local metadata={message_id='00000000-0000-4000-8000-000000000040',request_id='00000000-0000-4000-8000-000000000041',
   turn_id='00000000-0000-4000-8000-000000000042',session_id='00000000-0000-4000-8000-000000000004',generation=1,
   created_at='2026-07-19T20:00:00Z'}
  bridge.voiceState='idle';table.insert(bridge.voiceSubmissions,{language=language,metadata=metadata});return metadata
 end
 function bridge.nextTurnMetadata() return {message_id='00000000-0000-4000-8000-000000000050',
  request_id='00000000-0000-4000-8000-000000000051',turn_id='00000000-0000-4000-8000-000000000052',
  session_id='00000000-0000-4000-8000-000000000004',generation=1,installation_id='00000000-0000-4000-8000-000000000060',
  profile_id='00000000-0000-4000-8000-000000000061',playthrough_id='00000000-0000-4000-8000-000000000062',
  created_at='2026-07-19T20:00:00Z',platform='windows',content_fingerprint='sha256:'..string.rep('a',64)} end
 function bridge.newMessageId() return '00000000-0000-4000-8000-000000000071' end
 function bridge.utcNow() return '2026-07-19T20:00:00Z' end
 function bridge.cancelGeneration(generation) table.insert(bridge.cancelled,generation) end
 function bridge.halt() bridge.halted=true bridge.results={} bridge.submitted={} bridge.media={} end
 return bridge
end
return M
