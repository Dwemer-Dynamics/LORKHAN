local runner=(arg and arg[0] or ''):gsub('\\','/')
local root=runner:match('^(.*)/scripts/ALMSIVI/tests/run%.lua$') or 'almsivi/files'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..root..'/scripts/ALMSIVI/tests/fake_openmw/?.lua;'..package.path

local failures,tests=0,0
local function test(name,fn)
    tests=tests+1 local ok,reason=pcall(fn)
    if ok then io.write('ok - '..name..'\n') else failures=failures+1 io.write('not ok - '..name..': '..tostring(reason)..'\n') end
end
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function truthy(v) assert(v) end

local identity=require('scripts.ALMSIVI.identity')
local protocol=require('scripts.ALMSIVI.protocol')
local conversation=require('scripts.ALMSIVI.conversation')
local storage=require('scripts.ALMSIVI.storage')
local context=require('scripts.ALMSIVI.context')
local actions=require('scripts.ALMSIVI.actions')
local actor=require('scripts.ALMSIVI.actor_executor')
local agentRegistry=require('scripts.ALMSIVI.agent_registry')
local orchestrator=require('scripts.ALMSIVI.orchestrator')
local player=require('scripts.ALMSIVI.player_state')
local openmwAdapter=require('scripts.ALMSIVI.adapters.openmw')
local fake=require('fake_openmw')
local npc=fake.identity('npc','fargoth',1)
local playerId=fake.identity('player','player',2)
local enemy=fake.identity('creature','mudcrab',3)
local UUID={message='00000000-0000-4000-8000-000000000001',request='00000000-0000-4000-8000-000000000002',turn='00000000-0000-4000-8000-000000000003',session='00000000-0000-4000-8000-000000000004'}
local function event(sequence,kind,generation,payload)
 return {message_id=UUID.message,request_id=UUID.request,turn_id=UUID.turn,session_id=UUID.session,generation=generation,sequence=sequence,type=kind,payload=payload or {}}
end

test('lifecycle invalidates generation and cancels native',function()
 local b=fake.bridge() local s=orchestrator.new(b) local before=s.generation orchestrator.lifecycle(s,'load')
 eq(s.generation,before+1) eq(b.cancelled[1],before)
end)
test('wire validators reject uppercase UUID and zero-byte media',function()
 eq(protocol.isUuid('00000000-0000-4000-8000-000000000001'),true)
 eq(protocol.isUuid('00000000-0000-4000-8000-00000000000A'),false)
 local speech=event(1,'speech.ready',3,{media_id=UUID.message,sha256=string.rep('a',64),bytes=0,codec='wav',duration_ms=1,expires_at='2026-07-19T00:00:00Z'})
 local ok,reason=protocol.validatePolledEvent(speech);eq(ok,nil);eq(reason,'invalid_speech_bytes')
 speech.payload.bytes=4;speech.payload.duration_ms=0;ok,reason=protocol.validatePolledEvent(speech);eq(ok,nil);eq(reason,'invalid_speech_duration')
end)
test('event ordering dedup and cursor gaps',function()
 local c=protocol.CursoredEvents(UUID.session,3) truthy(c:accept(event(1,'turn.accepted',3)))
 local ok,reason=c:accept(event(1,'turn.accepted',3)); eq(ok,false);eq(reason,'duplicate_event')
 ok,reason=c:accept(event(3,'turn.complete',3));eq(ok,nil);eq(reason,'cursor_gap');eq(c:cursor(),1)
end)
test('future save disables and cannot overwrite',function()
 local raw={schemaVersion=99,secret='do-not-touch'} local loaded,meta=storage.load(raw,4)
 truthy(loaded.disabled) truthy(meta.preserve) local saved,reason=storage.save(loaded);eq(saved,nil);eq(reason,'future_schema_preserved')
end)
test('old save migrates and drops inflight',function()
 local loaded,meta=storage.load({schemaVersion=1,generationSeed=2,preferences={},conversationUi={},actorStateHints={}},5)
 truthy(meta.migrated) eq(loaded.schemaVersion,2) eq(loaded.generationSeed,6) eq(loaded.inFlight,nil)
end)
test('context applies all bounded constants',function()
 local many={} for i=1,300 do many[i]={n=i} end
 local snap=context.snapshot({audience=many,actorActivities=many,inventory=many,nearbyObjects=many,activeEffects=many,journal=many,books=many,contentFiles=many})
 eq(#snap.audience.items,12);eq(#snap.actorActivities.items,12);eq(#snap.inventory.items,48);eq(#snap.nearbyObjects.items,32);eq(#snap.activeEffects.items,32);eq(#snap.journal.items,32);eq(#snap.books.items,8);eq(#snap.contentFiles.items,256);truthy(snap.audience.truncated)
end)
test('identity registry refuses substitution and ambiguity',function()
 local r=identity.Registry() local one={} truthy(r:activate(npc,one)); eq(r:activate(npc,{}),nil)
 local clone=fake.identity('npc','fargoth',9);eq(r:resolve(clone),nil);eq(r:resolve(npc),one)
end)
test('conversation stale generation and exact terminal',function()
 local s=conversation.new(1);truthy(conversation.setTarget(s,npc));truthy(conversation.begin(s,UUID.request,UUID.turn,'input'))
 local ok,reason=conversation.apply(s,event(1,'turn.complete',0));eq(ok,false);eq(reason,'stale_generation')
 truthy(conversation.apply(s,event(1,'turn.complete',1)));ok,reason=conversation.apply(s,event(2,'turn.complete',1));eq(ok,false);eq(reason,'duplicate_terminal')
end)
test('action capability authority expiry exact parameters and limits',function()
 local state=actions.new({'action.ai.follow'}) local registry=identity.Registry();registry:activate(npc,{});registry:activate(playerId,{})
 local authority={generation=2,session_id='s',actor=npc,resolve=function(id)return registry:resolve(id)end,expired=function()return false end}
 local base={schema='almsivi.action-intent.v1',action_id='a',request_id='r',turn_id='t',session_id='s',generation=2,name='ai.follow',tier=1,actor=npc,target=playerId,parameters={distance=191},expires_at='soon'}
 local ok,reason=actions.validate(state,base,authority);eq(ok,nil);eq(reason,'invalid_follow_distance')
 base.parameters.distance=193;ok,reason=actions.validate(state,base,authority);eq(ok,nil);eq(reason,'invalid_follow_distance')
 base.parameters.distance=192.5;ok,reason=actions.validate(state,base,authority);eq(ok,nil);eq(reason,'invalid_follow_distance')
 base.parameters.distance=192;truthy(actions.validate(state,base,authority));truthy(actions.result(state,'a','succeeded',nil,{}));eq(actions.result(state,'a','failed','x',{}),nil)
 truthy(actions.claimContinuation(state,'a'));eq(actions.claimContinuation(state,'a'),nil)
 for i=2,4 do base.action_id='a'..i truthy(actions.validate(state,base,authority)) end
 base.action_id='a5';ok,reason=actions.validate(state,base,authority);eq(ok,nil);eq(reason,'turn_action_limit')
end)
test('stt events and dialogue delivery mapping are strict',function()
 local transcript=event(1,'stt.transcript',3,{text='Hello there.',language='en-US'});truthy(protocol.validatePolledEvent(transcript))
 transcript.payload.text='';local ok,reason=protocol.validatePolledEvent(transcript);eq(ok,nil);eq(reason,'invalid_stt_text')
 local failed=event(1,'stt.failed',3,{code='provider_timeout',retriable=true,retry_after_ms=1000});truthy(protocol.validatePolledEvent(failed))
 failed.payload.code='arbitrary';ok,reason=protocol.validatePolledEvent(failed);eq(ok,nil);eq(reason,'invalid_stt_failure_code')
 local delivery={message_id=UUID.message,request_id=UUID.request,dialogue_message_id='00000000-0000-4000-8000-000000000005',turn_id=UUID.turn,session_id=UUID.session,generation=3,speaker=npc,status='played',reason_code='playback_completed',completed_at='2026-07-19T20:00:02Z'}
 local mapped=protocol.dialogueDeliveryResult(delivery);eq(mapped.schema,'almsivi.dialogue-delivery-result.v1');eq(mapped.status,'played')
 delivery.reason_code='../../file';mapped,reason=protocol.dialogueDeliveryResult(delivery);eq(mapped,nil);eq(reason,'invalid_reason_code')
end)
test('tier zero inspect report is closed and capability gated',function()
 local state=actions.new({'action.inspect.report'}) local registry=identity.Registry();registry:activate(npc,{});registry:activate(playerId,{})
 local authority={generation=2,session_id='s',actor=npc,resolve=function(id)return registry:resolve(id)end,expired=function()return false end}
 local intent={schema='almsivi.action-intent.v1',action_id='inspect',request_id='r',turn_id='inspect-turn',session_id='s',generation=2,name='inspect.report',tier=0,actor=npc,target=playerId,parameters={},expires_at='soon'}
 local mapped=actions.validate(state,intent,authority);eq(mapped.name,'inspect.report');eq(next(mapped.parameters),nil)
 intent.parameters.path='inventory';local ok,reason=actions.validate(state,intent,authority);eq(ok,nil);eq(reason,'unknown_inspect_parameter')
 intent.parameters={};intent.tier=1;ok,reason=actions.validate(state,intent,authority);eq(ok,nil);eq(reason,'invalid_action_tier')
 intent.tier=0;local actorState=actor.new(npc,2,{'action.inspect.report'});local followed=false
 local adapter={followSelf=function()followed=true return true end,inspectReport=function()return true,'inspection_completed',{record_id='fargoth'} end}
 local result=actor.execute(actorState,intent,adapter,authority);eq(result.status,'succeeded');eq(result.observed.record_id,'fargoth');eq(followed,false)
end)
test('canonical action result requires completion timestamp',function()
 local state=actions.new({}) local internal=actions.result(state,'00000000-0000-4000-8000-000000000020','succeeded',nil,{})
 local result,reason=actions.canonicalResult(internal,nil,nil);eq(result,nil);eq(reason,'correlation_required')
 local correlation={message_id=UUID.message,request_id=UUID.request,turn_id=UUID.turn,session_id=UUID.session,generation=7}
 result,reason=actions.canonicalResult(internal,correlation,nil);eq(result,nil);eq(reason,'completed_at_required')
 correlation.message_id='00000000-0000-4000-8000-00000000000A';result,reason=actions.canonicalResult(internal,correlation,'2026-07-19T00:00:00Z');eq(result,nil);eq(reason,'invalid_message_id');correlation.message_id=UUID.message
 result=actions.canonicalResult(internal,correlation,'2026-07-19T00:00:00Z');eq(result.completed_at,'2026-07-19T00:00:00Z');eq(result.schema,'almsivi.action-result.v1');eq(result.session_id,UUID.session)
end)
test('submit requires caller supplied UUID correlation',function()
 local b=fake.bridge() local s=orchestrator.new(b) local ok,reason=orchestrator.submitText(s,{text='hi'})
 eq(ok,nil);eq(reason,'invalid_request_id')
end)
test('media prepare handoff is opaque generation-bound and fake-adapter tested',function()
 local b=fake.bridge() local emitted={} local capture=function(name,payload)table.insert(emitted,{name=name,payload=payload})end
 local s=orchestrator.new(b,capture,function(actor,name,payload) capture(name,payload) return true end)
 s.settings={presentation={ttsVolumeBoost=4}}
 orchestrator.configureSession(s,UUID.session);s.conversation.turn={requestId=UUID.request,turnId=UUID.turn,generation=1,status='accepted',terminal=false}
 truthy(s.events:accept(event(1,'dialogue.complete',1,{speaker=npc,addressee=playerId,text='Hello.'})))
 truthy(conversation.apply(s.conversation,event(1,'dialogue.complete',1,{speaker=npc,addressee=playerId,text='Hello.'})))
 local descriptor={media_id='00000000-0000-4000-8000-000000000005',sha256=string.rep('a',64),bytes=4,codec='ogg',duration_ms=100,expires_at='2026-07-19T21:00:00Z'}
 b.results={event(2,'speech.ready',1,descriptor)};eq(orchestrator.poll(s),1);eq(#b.prepared,1);eq(b.prepared[1].media_id,descriptor.media_id);eq(b.prepared[1].path,nil);eq(b.prepared[1].url,nil)
 b.media[descriptor.media_id]={state='ready'};orchestrator.poll(s)
  local speak=emitted[#emitted];eq(speak.name,'ALMSIVI_ACTOR_SPEAK');eq(speak.payload.media_id,descriptor.media_id);eq(speak.payload.subtitle,'Hello.');eq(speak.payload.generation,1);eq(speak.payload.dialogue_message_id,UUID.message);eq(speak.payload.session_id,UUID.session);eq(speak.payload.tts_volume_boost,4)
  truthy(orchestrator.speechStatus(s,{media_id=descriptor.media_id,active=false,status='played'}));eq(next(s.conversation.pendingMedia),nil);eq(s.activeSpeechMediaId,nil)
  orchestrator.lifecycle(s,'load');eq(next(s.conversation.pendingMedia),nil)
 end)
test('multi-speaker media plays in dialogue order without overlap',function()
 local b=fake.bridge() local sent={}
 local s=orchestrator.new(b,nil,function(_,name,payload)table.insert(sent,{name=name,payload=payload})return true end)
 orchestrator.configureSession(s,UUID.session);s.conversation.turn={requestId=UUID.request,turnId=UUID.turn,generation=1,status='accepted',terminal=false}
 local first=event(1,'dialogue.complete',1,{speaker=npc,addressee=playerId,text='First.'})
 local secondSpeaker=enemy
 local second=event(3,'dialogue.complete',1,{speaker=secondSpeaker,addressee=playerId,text='Second.'})
 truthy(conversation.apply(s.conversation,first))
 local one={media_id='00000000-0000-4000-8000-000000000031',sha256=string.rep('a',64),bytes=4,codec='ogg',duration_ms=100,expires_at='2026-07-19T21:00:00Z'}
 truthy(conversation.apply(s.conversation,event(2,'speech.ready',1,one)))
 truthy(conversation.apply(s.conversation,second))
 local two={media_id='00000000-0000-4000-8000-000000000032',sha256=string.rep('b',64),bytes=4,codec='ogg',duration_ms=100,expires_at='2026-07-19T21:00:00Z'}
 truthy(conversation.apply(s.conversation,event(4,'speech.ready',1,two)))
 orchestrator.poll(s)
 b.media[one.media_id]={state='ready'} b.media[two.media_id]={state='ready'}
 orchestrator.poll(s);eq(#sent,1);eq(sent[1].payload.media_id,one.media_id)
 orchestrator.speechStatus(s,{media_id=one.media_id,active=false,status='played'})
 orchestrator.poll(s);eq(#sent,2);eq(sent[2].payload.media_id,two.media_id)
 eq(#s.conversation.transcript,2);eq(s.conversation.transcript[1].text,'First.');eq(s.conversation.transcript[2].text,'Second.')
end)
test('narrator media uses the ordered player-local speech lane',function()
 local b=fake.bridge() local emitted={} local actorSends=0
 local s=orchestrator.new(b,function(name,payload)table.insert(emitted,{name=name,payload=payload})end,
  function()actorSends=actorSends+1 return true end)
 orchestrator.configureSession(s,UUID.session);s.conversation.turn={requestId=UUID.request,turnId=UUID.turn,generation=1,status='accepted',terminal=false}
 local narrator=fake.identity('narrator','almsivi:narrator',0);narrator.display_name='The Narrator'
 truthy(conversation.apply(s.conversation,event(1,'dialogue.complete',1,{speaker=narrator,addressee=playerId,text='The fog gathers.'})))
 local media={media_id='00000000-0000-4000-8000-000000000033',sha256=string.rep('c',64),bytes=4,codec='ogg',duration_ms=100,expires_at='2026-07-19T21:00:00Z'}
 truthy(conversation.apply(s.conversation,event(2,'speech.ready',1,media)));orchestrator.poll(s)
 b.media[media.media_id]={state='ready'};orchestrator.poll(s)
 eq(actorSends,0);eq(emitted[#emitted].name,'ALMSIVI_NARRATOR_SPEAK');eq(emitted[#emitted].payload.actor.kind,'narrator')
end)
test('actor is self-only and detach stops owned state',function()
 local st=actor.new(npc,2,{'action.ai.follow'}) local stopped=0 local playedBoost
 local adapter={followSelf=function()return true end,playSpeech=function(_,_,_,volumeBoost)playedBoost=volumeBoost return true end,stopSpeech=function()stopped=stopped+1 end,stopAi=function()stopped=stopped+1 return true end}
 local registry=identity.Registry();registry:activate(npc,{});registry:activate(playerId,{})
 local cmd={schema='almsivi.action-intent.v1',action_id='a',request_id='r',turn_id='t',session_id='s',generation=2,name='ai.follow',tier=1,actor=npc,target=playerId,parameters={distance=192},expires_at='x'}
 local result=actor.execute(st,cmd,adapter,{session_id='s',resolve=function(id)return registry:resolve(id)end,expired=function()return false end});eq(result.status,'succeeded');eq(result.kind,'almsivi.internal.action-terminal')
 actor.speak(st,{generation=2,actor=npc,media_id='opaque',request_id='r',turn_id='t',session_id='s',dialogue_message_id='d',expires_at='x',tts_volume_boost=4},adapter,{expired=function()return false end});eq(st.activeSpeech.mediaId,'opaque');eq(playedBoost,4);actor.detach(st,adapter);eq(st.attached,false);eq(stopped,2)
end)
test('ordinary halt interrupts owned work and keeps the bridge recoverable',function()
 local b=fake.bridge() local sent={}
 local s=orchestrator.new(b,nil,function(_,name)table.insert(sent,name)return true end)
 orchestrator.activate(s,npc,{}) s.attachments[identity.key(npc)]=npc truthy(conversation.setTarget(s.conversation,npc))
 orchestrator.halt(s);eq(b.halted,false);eq(b.cancelled[1],1);eq(s.conversation.target.record_id,npc.record_id)
 eq(sent[1],'ALMSIVI_ACTOR_STOP');eq(s.hardHalted,false)
end)
test('travel and escort require player-captured bounded destinations and retain owned package identity',function()
 local registry=identity.Registry();registry:activate(npc,{});registry:activate(playerId,{})
 local authority={generation=2,session_id='s',actor=npc,resolve=function(id)return registry:resolve(id)end,
  expired=function()return false end}
 local parameters={destination_x=128.5,destination_y=-64,destination_z=12,destination_cell='exterior:0:0'}
 local state=actions.new({'action.ai.travel','action.ai.escort','action.ai.stop'})
 local intent={schema='almsivi.action-intent.v1',action_id='travel',request_id='r',turn_id='movement',session_id='s',
  generation=2,name='ai.travel',tier=1,actor=npc,target=playerId,parameters=parameters,expires_at='soon'}
 local mapped=actions.validate(state,intent,authority);eq(mapped.parameters.destination_x,128.5)
 intent.action_id='bad-coordinate';intent.parameters.destination_x=100000001
 local ok,reason=actions.validate(state,intent,authority);eq(ok,nil);eq(reason,'invalid_destination_coordinate')
 intent.action_id='bad-cell';intent.parameters.destination_x=128.5;intent.parameters.destination_cell='../Balmora'
 ok,reason=actions.validate(state,intent,authority);eq(ok,nil);eq(reason,'invalid_destination_cell')
 intent.action_id='travel-execute';intent.parameters.destination_cell='exterior:0:0'
 local stopped
 local adapter={travelSelf=function()return true,'travel_started',parameters end,
  stopAi=function(owned)stopped=owned return true,'ai_packages_stopped' end}
 local actorState=actor.new(npc,2,{'action.ai.travel','action.ai.stop'})
 local result=actor.execute(actorState,intent,adapter,authority);eq(result.status,'succeeded')
 eq(result.observed.destination_cell,'exterior:0:0');eq(actorState.ownedAi.type,'Travel')
 local stop={schema='almsivi.action-intent.v1',action_id='travel-stop',request_id='r',turn_id='movement',session_id='s',
  generation=2,name='ai.stop',tier=1,actor=npc,target=playerId,parameters={},expires_at='soon'}
 result=actor.execute(actorState,stop,adapter,authority);eq(result.status,'succeeded')
 eq(stopped.destination.destination_x,128.5)
end)
test('face action reports only observed completion and cancels cleanly',function()
 local registry=identity.Registry();registry:activate(npc,{});registry:activate(playerId,{})
 local authority={generation=2,session_id='s',actor=npc,resolve=function(id)return registry:resolve(id)end,
  expired=function()return false end}
 local intent={schema='almsivi.action-intent.v1',action_id='face',message_id=UUID.message,request_id=UUID.request,
  turn_id=UUID.turn,session_id='s',generation=2,name='ai.face',tier=1,actor=npc,target=playerId,
  parameters={},expires_at='soon'}
 local updates,stopped=0,false
 local adapter={faceSelf=function()return true,'face_started',{target=playerId} end,
  updateFace=function()updates=updates+1;if updates==1 then return nil,'face_turning' end
   return true,'face_completed',{final_yaw_error=0.01} end,
  stopFace=function()stopped=true end}
 local state=actor.new(npc,2,{'action.ai.face'})
 local result,reason=actor.execute(state,intent,adapter,authority);eq(result,nil);eq(reason,'action_pending');truthy(state.activeFace)
 result=actor.updateFace(state,adapter,0.016);eq(result,nil)
 local command;result,command=actor.updateFace(state,adapter,0.016);eq(result.status,'succeeded')
 eq(result.observed.final_yaw_error,0.01);eq(command.action_id,'face');eq(state.activeFace,nil)
 intent.action_id='face-cancel';intent.turn_id='face-cancel-turn';state=actor.new(npc,2,{'action.ai.face'})
 actor.execute(state,intent,adapter,authority);result,command=actor.cancelFace(state,adapter,'client_interrupted')
 eq(result.status,'cancelled');eq(command.action_id,'face-cancel');truthy(stopped)
 intent.action_id='face-combat';intent.turn_id='face-combat-turn';state=actor.new(npc,2,{'action.ai.face'})
 adapter.updateFace=function()return false,'face_interrupted_by_combat',{},'cancelled' end
 actor.execute(state,intent,adapter,authority);result=actor.updateFace(state,adapter,0.016)
 eq(result.status,'cancelled');eq(result.reason,'face_interrupted_by_combat')
end)
test('typed player action request remains inside the strict turn envelope',function()
 local dto,reason=protocol.turn({message_id=UUID.message,request_id=UUID.request,turn_id=UUID.turn,
  installation_id='00000000-0000-4000-8000-000000000010',profile_id='00000000-0000-4000-8000-000000000011',
  playthrough_id='00000000-0000-4000-8000-000000000012',session_id=UUID.session,generation=1,
  created_at='2026-08-01T00:00:00Z',platform='windows',content_fingerprint='sha256:'..string.rep('a',64),
  text='Attack the mudcrab',language='en-US',speaker=playerId,target=npc,audience={npc},context={},capabilities={'action.combat.start'},
  ui_source='almsivi_action_menu',action_request={name='combat.start',tier=2,parameters={},target=enemy}})
 truthy(dto,reason);eq(dto.payload.action_request.name,'combat.start');eq(dto.payload.action_request.target.record_id,'mudcrab')
 dto,reason=protocol.turn({message_id=UUID.message,request_id=UUID.request,turn_id=UUID.turn,
  installation_id='00000000-0000-4000-8000-000000000010',profile_id='00000000-0000-4000-8000-000000000011',
  playthrough_id='00000000-0000-4000-8000-000000000012',session_id=UUID.session,generation=1,
  created_at='2026-08-01T00:00:00Z',platform='windows',content_fingerprint='sha256:'..string.rep('a',64),
  text='Bad',language='en-US',speaker=playerId,target=npc,audience={npc},context={},capabilities={},
  ui_source='almsivi_action_menu',action_request={name='../run',tier=1,parameters={}}})
 eq(dto,nil);eq(reason,'invalid_action_request')
end)
test('managed agents activate in bounded batches and manual pins survive distance cleanup',function()
 local b=fake.bridge() local managed=0 local detached=0
 local s=orchestrator.new(b,nil,function(_,name)if name=='ALMSIVI_ACTOR_DETACH'then detached=detached+1 end return true end,
  function()managed=managed+1 return true end)
 local candidates={}
 for i=1,8 do
  local actorId=fake.identity('npc','agent'..i,20+i)
  orchestrator.activate(s,actorId,{})
  candidates[i]={identity=actorId,distance=i*10,maxDistance=1200,dead=false,hostile=false,available=true}
 end
 eq(orchestrator.scanAgents(s,candidates),6);eq(#agentRegistry.snapshot(s.agents),6)
 eq(orchestrator.scanAgents(s,candidates),2);eq(managed,8)
 local actor,status=orchestrator.manageCandidate(s,candidates[1],'manual');truthy(actor);eq(status,'upgraded')
 for _=1,4 do orchestrator.scanAgents(s,{}) end
 local snapshot=agentRegistry.snapshot(s.agents);eq(#snapshot,1);eq(snapshot[1].source,'manual')
 actor,status=orchestrator.manageCandidate(s,candidates[1],'manual');truthy(actor);eq(status,'deactivated');eq(detached,8)
end)
test('manual nearby activation pins a bounded group without toggling existing pins off',function()
 local b=fake.bridge() local s=orchestrator.new(b,nil,nil,function()return true end)
 local candidates={}
 for i=1,14 do
  local actorId=fake.identity('npc','manual'..i,300+i)
  orchestrator.activate(s,actorId,{})
  candidates[i]={identity=actorId,distance=i*10,maxDistance=1200,dead=false,hostile=false,available=true}
 end
 local added,retained=orchestrator.manageNearby(s,candidates)
 eq(added,12);eq(retained,0);eq(#agentRegistry.snapshot(s.agents),12)
 added,retained=orchestrator.manageNearby(s,candidates)
 eq(added,0);eq(retained,12);eq(#agentRegistry.snapshot(s.agents),12)
end)
test('configured hearing distance adds nearby managed agents to the turn audience',function()
 local b=fake.bridge() local s=orchestrator.new(b,nil,nil,function()return true end)
 local near=fake.identity('npc','ajira',31) local far=fake.identity('npc','caius',32)
 s.settings={autoActivate={hearingDistance=500}}
 orchestrator.configureSession(s,UUID.session)
 for _,actorId in ipairs({npc,near,far}) do orchestrator.activate(s,actorId,{}) end
 local function candidate(actorId,distance)
  return {identity=actorId,distance=distance,maxDistance=1200,dead=false,hostile=false,available=true}
 end
 truthy(orchestrator.selectTarget(s,candidate(npc,100)))
 truthy(orchestrator.manageCandidate(s,candidate(near,300),'auto'))
 truthy(orchestrator.manageCandidate(s,candidate(far,700),'auto'))
 local request=b.nextTurnMetadata();request.text='What do you both think?';request.input_key='hearing-test'
 request.language='en-US';request.speaker=playerId;request.context={};request.capabilities={'dialogue.text'}
 request.recent_action_results={};request.ui_source='almsivi_text'
 truthy(orchestrator.submitText(s,request));eq(#b.submitted[1].payload.audience,2)
 eq(b.submitted[1].payload.audience[1].record_id,npc.record_id)
 eq(b.submitted[1].payload.audience[2].record_id,near.record_id)
 eq(b.submitted[1].payload.context.dialogueMode,'Standard')
end)
test('dialogue modes apply explicit bounded audience policies',function()
 local function submit(mode,explicitGroup,distance)
  local b=fake.bridge() local s=orchestrator.new(b,nil,nil,function()return true end)
  local other=fake.identity('npc','mode-actor',91)
  s.settings={autoActivate={hearingDistance=500}}
  s.dialogueMode=mode
  orchestrator.configureSession(s,UUID.session)
  for _,actorId in ipairs({npc,other}) do orchestrator.activate(s,actorId,{}) end
  local function candidate(actorId,actorDistance)
   return {identity=actorId,distance=actorDistance,maxDistance=1200,dead=false,hostile=false,available=true}
  end
  truthy(orchestrator.selectTarget(s,candidate(npc,100)))
  truthy(orchestrator.manageCandidate(s,candidate(other,distance),'auto'))
  if explicitGroup then truthy(orchestrator.addAudience(s,candidate(other,distance))) end
  local request=b.nextTurnMetadata();request.text='Mode test';request.input_key='mode-'..mode
  request.language='en-US';request.speaker=playerId;request.context={dialogueMode='forged'}
  request.capabilities={'dialogue.text'};request.recent_action_results={};request.ui_source='almsivi_text'
  truthy(orchestrator.submitText(s,request))
  return b.submitted[1].payload
 end
 local standard=submit('Standard',false,300);eq(#standard.audience,2);eq(standard.context.dialogueMode,'Standard')
 local close=submit('Close',true,300);eq(#close.audience,2);eq(close.context.dialogueMode,'Close')
 local whisper=submit('Whisper',true,300);eq(#whisper.audience,1);eq(whisper.context.dialogueMode,'Whisper')
 local shout=submit('Shout',false,700);eq(#shout.audience,2);eq(shout.context.dialogueMode,'Shout')
end)
test('auto-managed actors attacking the player are removed unless explicitly allowed',function()
 local b=fake.bridge() local detached=0 local combatEvents={}
 local s=orchestrator.new(b,function(name,payload)
  if name=='ALMSIVI_COMBAT_STATUS' then table.insert(combatEvents,payload) end
 end,nil,function() return true end)
 s.sendActor=function() detached=detached+1 return true end
 s.settings={autoActivate={enabled=true,addHostile=false}}
 orchestrator.activate(s,npc,{})
 local candidate={identity=npc,distance=100,maxDistance=1200,dead=false,hostile=false,available=true}
 truthy(orchestrator.manageCandidate(s,candidate,'auto'))
 local removed,reason=orchestrator.actorCombatStatus(s,{actor=npc,hostile_to_player=true,target=playerId})
 truthy(removed);eq(reason,'hostile_removed');eq(#agentRegistry.snapshot(s.agents),0);eq(detached,1)
 eq(combatEvents[#combatEvents].active,false);eq(combatEvents[#combatEvents].count,0)
 s.settings.autoActivate.addHostile=true
 truthy(orchestrator.manageCandidate(s,candidate,'auto'))
 removed,reason=orchestrator.actorCombatStatus(s,{actor=npc,hostile_to_player=true,target=playerId})
 eq(removed,false);eq(reason,'hostile_allowed');eq(#agentRegistry.snapshot(s.agents),1)
 eq(combatEvents[#combatEvents].active,true);eq(#combatEvents[#combatEvents].threats,1)
 removed,reason=orchestrator.actorCombatStatus(s,{actor=npc,hostile_to_player=false})
 eq(removed,false);eq(reason,'agent_retained');eq(combatEvents[#combatEvents].active,false)
 orchestrator.lifecycle(s,'load');eq(combatEvents[#combatEvents].active,false);eq(combatEvents[#combatEvents].count,0)
end)
test('explicit hard halt clears queues and blocks submit',function()
 local b=fake.bridge() local s=orchestrator.new(b);orchestrator.hardHalt(s);truthy(b.halted);eq(s.conversation.target,nil)
 local ok,reason=orchestrator.submitText(s,{text='hi'});eq(ok,nil);eq(reason,'almsivi_disabled')
end)
test('actor lifecycle stop and detach tolerate pre-init delivery',function()
 eq(actor.stop(nil,{}),nil);eq(actor.detach(nil,{}),nil);eq(actor.completeSpeech(nil),nil)
end)
test('player action does not consume vanilla activation',function()
 local s=player.new();eq(player.onAction(s,'Activate',function()end),false);truthy(player.onAction(s,'ALMSIVI_Talk',function()end))
end)
test('text edit Enter becomes a single-line submit request',function()
 local value,submit=player.consumeTextEdit('Hello, Caius!\n');eq(value,'Hello, Caius! ');eq(submit,true)
 value,submit=player.consumeTextEdit('Still typing');eq(value,'Still typing');eq(submit,false)
 value,submit=player.consumeTextEdit('First\r\nSecond');eq(value,'First Second');eq(submit,true)
 value,submit=player.consumeTextEdit(nil);eq(value,'');eq(submit,false)
end)
test('focused UI builders keep chat selectors tools and notifications independent',function()
 local ui={TYPE={Text='text',Image='image',TextEdit='edit',Container='container'},content=function(value)return value end}
 local util={vector2=function(x,y)return{x=x,y=y}end,color={rgb=function(r,g,b)return{r=r,g=g,b=b}end}}
 local chat=require('scripts.ALMSIVI.ui.chatbox').build({ui=ui,util=util,target='Fargoth',text='',
  onTextChanged=function()end,onKeyPress=function()end,onSend=function()end,onClose=function()end})
 eq(chat[1].props.text,'Chat with Fargoth');eq(chat[#chat-1].props.text,'Send');eq(chat[#chat].props.text,'Close')
 local choices=require('scripts.ALMSIVI.ui.selector').build({ui=ui,util=util,title='Dialogue Mode',
  options={{label='Standard',active=true,onSelect=function()end}},onClose=function()end})
 eq(choices[1].props.text,'Dialogue Mode');eq(choices[2].props.text,'Standard  [active]')
 local tools=require('scripts.ALMSIVI.ui.actor_tools').build({ui=ui,util=util,target='Fargoth',
  options={{label='Actor actions...',onSelect=function()end}},onClose=function()end})
 eq(tools[1].props.text,'Targeted NPC Tools');eq(tools[2].props.text,'Target: Fargoth')
 local notifications=require('scripts.ALMSIVI.ui.notifications');local notice=notifications.new()
 truthy(notifications.show(notice,'queued',1));truthy(notifications.active(notice))
 eq(notifications.update(notice,0.5),false);eq(notifications.update(notice,0.5),true);eq(notifications.active(notice),false)
end)
test('OpenMW settings page registers controls and seeds conflict-free defaults once',function()
 local data={OMWInputBindings={},ALMSIVIInputDefaults={}}
 local function section(name)
  data[name]=data[name] or {}
  return {get=function(_,key)return data[name][key]end,set=function(_,key,value)data[name][key]=value end}
 end
 local registered={triggers={},actions={},pages={},groups={}}
 package.preload['openmw.input']=function() return {
  KEY={F6=6,F7=7,F8=8,F9=9},ACTION_TYPE={Boolean='boolean'},
  registerTrigger=function(value)registered.triggers[value.key]=value end,
  registerAction=function(value)registered.actions[value.key]=value end,
 } end
 package.preload['openmw.storage']=function() return {playerSection=section} end
 package.preload['openmw.interfaces']=function() return {Settings={
  registerPage=function(value)table.insert(registered.pages,value)end,
  registerGroup=function(value)table.insert(registered.groups,value)end,
 }} end
 package.loaded['openmw.input']=nil package.loaded['openmw.storage']=nil package.loaded['openmw.interfaces']=nil
 package.loaded['scripts.ALMSIVI.settings']=nil
 local settingsEntry=require('scripts.ALMSIVI.settings')
 eq(next(settingsEntry),nil)
 eq(registered.pages[1].key,'ALMSIVI');eq(#registered.groups,6);eq(registered.groups[1].page,'ALMSIVI');eq(#registered.groups[1].settings,7)
 for _,setting in ipairs(registered.groups[1].settings) do truthy(setting.name);truthy(setting.description) end
 truthy(registered.triggers.ALMSIVI_Talk);truthy(registered.triggers.ALMSIVI_Halt)
 truthy(registered.triggers.ALMSIVI_StopDialogue);truthy(registered.triggers.ALMSIVI_ManualActivate)
 truthy(registered.triggers.ALMSIVI_ActionsMenu);truthy(registered.triggers.ALMSIVI_MasterMenu)
 truthy(registered.triggers.ALMSIVI_ToggleMode);truthy(registered.triggers.ALMSIVI_StatusHud)
 truthy(registered.triggers.ALMSIVI_ModelMenu);truthy(registered.triggers.ALMSIVI_ProfileMenu)
 truthy(registered.triggers.ALMSIVI_History);truthy(registered.triggers.ALMSIVI_Diagnostics)
 truthy(registered.triggers.ALMSIVI_OpenMic);truthy(registered.triggers.ALMSIVI_OpenMicMute)
 truthy(registered.actions.ALMSIVI_PushToTalk)
 local function setting(group,key)
  for _,candidate in ipairs(group.settings) do if candidate.key==key then return candidate end end
 end
 eq(registered.groups[2].key,'SettingsALMSIVIAutoActivate');eq(setting(registered.groups[2],'enabled').default,true)
 eq(setting(registered.groups[2],'interiorDistance').default,1200);eq(setting(registered.groups[2],'exteriorDistance').default,2400)
 eq(setting(registered.groups[2],'interiorHearingDistance').default,500)
 eq(setting(registered.groups[2],'exteriorHearingDistance').default,1000)
 eq(registered.groups[3].key,'SettingsALMSIVIBehavior');eq(setting(registered.groups[3],'rechatDelaySeconds').default,45)
 eq(setting(registered.groups[3],'rechatMaxDepth').default,10);eq(setting(registered.groups[3],'boredomDelaySeconds').default,180)
 eq(setting(registered.groups[3],'avoidAutonomyInMenus').default,true)
 eq(setting(registered.groups[3],'avoidAutonomyInCombat').default,true)
 eq(setting(registered.groups[3],'avoidAutonomyWhenSneaking').default,true)
 eq(setting(registered.groups[3],'cancelDialogueOnCombat').default,true)
 eq(setting(registered.groups[3],'combatBarks').default,true)
 eq(setting(registered.groups[3],'combatBarkPeriodSeconds').default,30)
 eq(registered.groups[4].key,'SettingsALMSIVISound');eq(setting(registered.groups[4],'ttsVolumeBoost').default,3)
 eq(registered.groups[5].key,'SettingsALMSIVIAgents');eq(setting(registered.groups[5],'actionsEnabled').default,true)
 eq(registered.groups[6].key,'SettingsALMSIVIPresentation');eq(setting(registered.groups[6],'showStatusHud').default,false)
 local talk=data.OMWInputBindings.ALMSIVI_Talk_Binding
 local halt=data.OMWInputBindings.ALMSIVI_Halt_Binding
 eq(talk.device,'keyboard');eq(talk.button,6);eq(talk.type,'trigger');eq(talk.key,'ALMSIVI_Talk')
 eq(halt.button,7);eq(data.OMWInputBindings.ALMSIVI_ActionsMenu_Binding,nil)
 eq(data.OMWInputBindings.ALMSIVI_MasterMenu_Binding,nil)
 eq(data.ALMSIVIInputDefaults.version,4)
 data.OMWInputBindings.ALMSIVI_Talk_Binding=nil
 package.loaded['scripts.ALMSIVI.settings']=nil
 require('scripts.ALMSIVI.settings')
 eq(data.OMWInputBindings.ALMSIVI_Talk_Binding,nil)
 package.preload['openmw.input']=nil package.preload['openmw.storage']=nil package.preload['openmw.interfaces']=nil
 package.loaded['openmw.input']=nil package.loaded['openmw.storage']=nil package.loaded['openmw.interfaces']=nil
 package.loaded['scripts.ALMSIVI.settings']=nil
end)
test('push to talk capture submits STT and transcript becomes a normal turn',function()
 local b=fake.bridge() local emitted={}
 local s=orchestrator.new(b,function(name,payload)table.insert(emitted,{name=name,payload=payload})end)
 orchestrator.configureSession(s,UUID.session);orchestrator.activate(s,npc,{})
 truthy(conversation.setTarget(s.conversation,npc))
 truthy(orchestrator.startVoice(s,{speaker=playerId,target=npc,context={inventory={}},language='en-US',
  capabilities={'dialogue.text','speech.listen'},ui_source='almsivi_voice'}))
 eq(b.voiceState,'recording');truthy(orchestrator.stopVoice(s));eq(b.voiceState,'ready')
 truthy(orchestrator.pollVoice(s));eq(#b.voiceSubmissions,1)
 b.results={{message_id='00000000-0000-4000-8000-000000000043',request_id='00000000-0000-4000-8000-000000000041',
  turn_id='00000000-0000-4000-8000-000000000042',session_id=UUID.session,generation=1,sequence=1,
  type='stt.transcript',payload={text='Where is Caius Cosades?',language='en-US'}}}
 eq(orchestrator.poll(s),1);eq(#b.submitted,1);eq(b.submitted[1].payload.input.text,'Where is Caius Cosades?')
 eq(b.submitted[1].payload.input.kind,'text');eq(b.submitted[1].payload.ui_source,'almsivi_voice')
end)
test('auto greeting selects one newly managed NPC once per session',function()
 local b=fake.bridge() local emitted={}
 local s=orchestrator.new(b,function(name,payload)table.insert(emitted,{name=name,payload=payload})end,nil,function()return true end)
 s.settings={autoActivate={enabled=true},behavior={autoGreeting=true}}
 orchestrator.configureSession(s,UUID.session);orchestrator.activate(s,npc,{})
 local candidate={identity=npc,distance=100,maxDistance=1200,dead=false,hostile=false,available=true}
 eq(orchestrator.scanAgents(s,{candidate},true),1);eq(s.conversation.target,nil)
 orchestrator.actorCombatStatus(s,{actor=npc,hostile_to_player=false})
 eq(orchestrator.scanAgents(s,{candidate},true),0);eq(s.conversation.target.record_id,npc.record_id)
 eq(emitted[#emitted].name,'ALMSIVI_AUTONOMY_CONTEXT_REQUEST')
 local directive=emitted[#emitted].payload.directive
 truthy(orchestrator.runAutonomy(s,{directive=directive,speaker=playerId,context={},language='en-US',
  capabilities={'dialogue.text'},recent_action_results={}}))
 eq(#b.submitted,1);truthy(b.submitted[1].payload.input.text:match('natural, context%-aware greeting'))
 s.conversation.turn.terminal=true;conversation.clearTarget(s.conversation)
 orchestrator.scanAgents(s,{candidate},true);eq(#b.submitted,1);eq(#s.pendingAutonomy,0)
end)
test('opt-in open microphone uses VAD and rearms only after the turn',function()
 local b=fake.bridge() local emitted={}
 local s=orchestrator.new(b,function(name,payload)table.insert(emitted,{name=name,payload=payload})end)
 orchestrator.configureSession(s,UUID.session);orchestrator.activate(s,npc,{});truthy(conversation.setTarget(s.conversation,npc))
 s.conversation.turn={terminal=false}
 truthy(orchestrator.enableOpenMic(s,{speaker=playerId,target=npc,context={inventory={}},language='en-US',
  capabilities={'dialogue.text','speech.listen'}}));truthy(s.openMic);eq(b.voiceState,'idle');eq(emitted[#emitted].payload.status,'waiting')
 s.conversation.turn.terminal=true;truthy(orchestrator.pollOpenMic(s));eq(emitted[#emitted].name,'ALMSIVI_OPEN_MIC_CONTEXT_REQUEST')
 truthy(orchestrator.runOpenMicContext(s,{speaker=playerId,target=npc,context={inventory={}},language='en-US',
  capabilities={'dialogue.text','speech.listen'},vad_sensitivity=1200,end_delay_ms=1500}));truthy(b.voiceAutomatic);eq(b.voiceState,'recording')
 eq(b.voiceSensitivity,1200);eq(b.voiceEndDelay,1500)
 b.voiceState='ready';truthy(orchestrator.pollVoice(s));eq(#b.voiceSubmissions,1)
 b.results={{message_id='00000000-0000-4000-8000-000000000043',request_id='00000000-0000-4000-8000-000000000041',
  turn_id='00000000-0000-4000-8000-000000000042',session_id=UUID.session,generation=1,sequence=1,
  type='stt.transcript',payload={text='Tell me about Balmora.',language='en-US'}}}
 eq(orchestrator.poll(s),1);eq(#b.submitted,1);eq(b.submitted[1].payload.ui_source,'almsivi_open_mic')
 eq(orchestrator.pollOpenMic(s),false)
 s.conversation.turn.terminal=true;truthy(orchestrator.pollOpenMic(s));eq(emitted[#emitted].name,'ALMSIVI_OPEN_MIC_CONTEXT_REQUEST')
 truthy(orchestrator.runOpenMicContext(s,{speaker=playerId,target=npc,context={journal={}},language='en-US',
  capabilities={'dialogue.text','speech.listen'}}));eq(b.voiceState,'recording');truthy(b.voiceAutomatic)
 truthy(orchestrator.disableOpenMic(s));eq(b.voiceState,'idle');eq(s.openMic,false)
end)
test('server autonomy directive becomes a fresh context-aware dialogue turn',function()
 local b=fake.bridge() local emitted={}
 local s=orchestrator.new(b,function(name,payload)table.insert(emitted,{name=name,payload=payload})end)
 s.settings={behavior={rechat=true}}
 orchestrator.configureSession(s,UUID.session);orchestrator.activate(s,npc,{})
 truthy(conversation.setTarget(s.conversation,npc))
 local directive={schema='almsivi.autonomy-directive.v1',schedule_id='00000000-0000-4000-8000-000000000070',
  kind='rechat',issued_at='2026-07-19T20:00:00Z'}
 b.autonomy={directive};eq(orchestrator.pollAutonomy(s),1)
 eq(emitted[#emitted].name,'ALMSIVI_AUTONOMY_CONTEXT_REQUEST')
 truthy(orchestrator.runAutonomy(s,{directive=directive,speaker=playerId,context={journal={}},language='en-US',
  capabilities={'dialogue.text'},recent_action_results={}}))
 eq(#b.submitted,1);eq(b.submitted[1].payload.ui_source,'almsivi_autonomy')
 truthy(b.submitted[1].payload.input.text:match('Continue the recent conversation'))
end)
test('local rechat and boredom controls create bounded autonomy turns',function()
 local b=fake.bridge() local emitted={}
 local s=orchestrator.new(b,function(name,payload)table.insert(emitted,{name=name,payload=payload})end,nil,function()return true end)
 s.settings={behavior={rechat=true,boredom=true,combatBarks=true}}
 orchestrator.configureSession(s,UUID.session);orchestrator.activate(s,npc,{})
 truthy(conversation.setTarget(s.conversation,npc))
 local directive=orchestrator.requestLocalAutonomy(s,'rechat');eq(directive.kind,'rechat')
 eq(emitted[#emitted].name,'ALMSIVI_AUTONOMY_CONTEXT_REQUEST')
 truthy(orchestrator.runAutonomy(s,{directive=directive,speaker=playerId,context={},language='en-US',
  capabilities={'dialogue.text'},recent_action_results={}}));eq(#b.submitted,1)
 s.conversation.turn.terminal=true;conversation.clearTarget(s.conversation)
 local candidate={identity=npc,distance=100,maxDistance=1200,dead=false,hostile=false,available=true}
 truthy(orchestrator.manageCandidate(s,candidate,'manual'))
 directive=orchestrator.requestLocalAutonomy(s,'boredom');eq(directive.kind,'boredom')
 eq(s.conversation.target.record_id,npc.record_id)
 s.pendingAutonomy={} s.autonomyRequested=false
 directive=orchestrator.requestLocalAutonomy(s,'combat_bark',npc);eq(directive.kind,'combat_bark')
end)
test('idle conversation rotates across managed agents before repeating',function()
 local b=fake.bridge() local s=orchestrator.new(b,nil,nil,function()return true end)
 local other=fake.identity('npc','ajira',88)
 s.settings={behavior={boredom=true}}
 for _,actorId in ipairs({npc,other}) do orchestrator.activate(s,actorId,{}) end
 truthy(orchestrator.manageCandidate(s,{identity=npc,distance=100,maxDistance=1200,dead=false,hostile=false,available=true},'auto'))
 truthy(orchestrator.manageCandidate(s,{identity=other,distance=200,maxDistance=1200,dead=false,hostile=false,available=true},'auto'))
 truthy(orchestrator.requestLocalAutonomy(s,'boredom'));eq(s.conversation.target.record_id,npc.record_id)
 s.pendingAutonomy={} s.autonomyRequested=false conversation.clearTarget(s.conversation)
 truthy(orchestrator.requestLocalAutonomy(s,'boredom'));eq(s.conversation.target.record_id,other.record_id)
end)
test('safe movement and combat actions enforce tiers and bounds',function()
 local registry=identity.Registry();registry:activate(npc,{});registry:activate(playerId,{})
 local authority={generation=2,session_id='s',actor=npc,resolve=function(id)return registry:resolve(id)end,expired=function()return false end}
 local state=actions.new({'action.ai.stop','action.ai.wander','action.combat.start','action.combat.stop'})
 local intent={schema='almsivi.action-intent.v1',action_id='wander',request_id='r',turn_id='t',session_id='s',generation=2,
  name='ai.wander',tier=1,actor=npc,target=playerId,parameters={distance=512,duration_seconds=60},expires_at='soon'}
 local mapped=actions.validate(state,intent,authority);eq(mapped.parameters.distance,512);eq(mapped.parameters.duration_seconds,60)
 intent.action_id='bad-wander';intent.parameters.distance=2049;local ok,reason=actions.validate(state,intent,authority);eq(ok,nil);eq(reason,'invalid_wander_distance')
 intent.parameters={};intent.name='combat.start';intent.tier=1;intent.action_id='combat';ok,reason=actions.validate(state,intent,authority);eq(ok,nil);eq(reason,'invalid_action_tier')
 intent.tier=2;mapped=actions.validate(state,intent,authority);eq(mapped.name,'combat.start')
end)
test('group audience preserves target and deduplicates actors',function()
 local c=conversation.new(1);truthy(conversation.setTarget(c,npc));truthy(conversation.addAudience(c,npc));eq(#c.audience,1)
 local other=fake.identity('npc','ajira',3);truthy(conversation.addAudience(c,other));eq(#c.audience,2)
 truthy(conversation.removeAudience(c,other));eq(#c.audience,1);eq(c.target.record_id,npc.record_id)
end)
test('animation and item actions are closed and tier gated',function()
 local registry=identity.Registry();registry:activate(npc,{});registry:activate(playerId,{})
 local authority={generation=2,session_id='s',actor=npc,resolve=function(id)return registry:resolve(id)end,expired=function()return false end}
 local state=actions.new({'action.animation.play','action.item.use','action.item.equip','action.item.unequip'})
 local intent={schema='almsivi.action-intent.v1',action_id='anim',request_id='r',turn_id='t',session_id='s',generation=2,
  name='animation.play',tier=1,actor=npc,target=playerId,parameters={group='idle2'},expires_at='soon'}
 truthy(actions.validate(state,intent,authority));intent.action_id='bad-anim';intent.parameters.group='death1'
 local ok,reason=actions.validate(state,intent,authority);eq(ok,nil);eq(reason,'invalid_animation_group')
 intent.action_id='item';intent.name='item.use';intent.tier=2;intent.parameters={record_id='p_restore_health_s'}
  truthy(actions.validate(state,intent,authority));intent.action_id='bad-item';intent.parameters.record_id='../unsafe'
  ok,reason=actions.validate(state,intent,authority);eq(ok,nil);eq(reason,'invalid_item_record_id')
 intent.action_id='bad-equip';intent.name='item.equip';intent.parameters={record_id='iron dagger',slot='weapon'}
 ok,reason=actions.validate(state,intent,authority);eq(ok,nil);eq(reason,'invalid_equipment_slot')
 intent.action_id='equip';intent.parameters.slot='carried_right';truthy(actions.validate(state,intent,authority))
 intent.action_id='unequip';intent.name='item.unequip';intent.parameters={slot='carried_left'}
 truthy(actions.validate(state,intent,authority))
end)
test('OpenMW adapter maps API-129 actor identity and camera target',function()
 local vectorMeta
 vectorMeta={__sub=function(a,b)return setmetatable({x=a.x-b.x,y=a.y-b.y,z=a.z-b.z},vectorMeta)end,
  __add=function(a,b)return setmetatable({x=a.x+b.x,y=a.y+b.y,z=a.z+b.z},vectorMeta)end,
  __mul=function(a,b)if type(a)=='number'then a,b=b,a end return setmetatable({x=a.x*b,y=a.y*b,z=a.z*b},vectorMeta)end}
 vectorMeta.__index={length=function(v)return math.sqrt(v.x*v.x+v.y*v.y+v.z*v.z)end,normalize=function(v)local n=v:length();return v*(1/n)end}
 local function vector(x,y,z)return setmetatable({x=x,y=y,z=z},vectorMeta)end
 local object={id='0x01000070',recordId='fargoth',contentFile='morrowind.esm',enabled=true,
  position=vector(0,300,0),cell={isExterior=true,gridX=-2,gridY=-9}}
 local yaw=1
 local selfObject={position=vector(0,0,0),cell={isExterior=true,gridX=-2,gridY=-9},controls={yawChange=0},
  rotation={getYaw=function()return yaw end}}
 local playerTarget={id='@0x1',recordId='player',
   position=vector(0,0,0),cell={isExterior=true,gridX=-2,gridY=-9}}
 local inventorySource={getAll=function()return{{recordId='iron_dagger',count=1},{recordId='p_restore_health_s',count=2}}end}
 local itemType={record=function()return{name='Iron Dagger'}end}
 local doorType={record=function()return{name='Warehouse Door'}end}
 local ownedItem={recordId='iron_dagger',contentFile='Morrowind.esm',type=itemType,count=1,
  owner={recordId='fargoth',factionId='hlaalu',factionRank=1},position=vector(0,64,0)}
 local lockedDoor={recordId='warehouse_door',contentFile='Morrowind.esm',type=doorType,
  owner={factionId='hlaalu'},position=vector(0,96,0)}
 local started,packageFilter
 local activePackage={type='Combat',target=playerTarget}
 local modules={core={contentFiles={list={'Morrowind.esm','Test.esp'}},
  getFormId=function(_,index)if index==playerId.refnum.index then return 0x00000014 end return 0x01000070 end},self=selfObject,
  interfaces={FollowerDetectionUtil={version=2,getFollowerList=function()return{
    follower={actor=object,leader=playerTarget,superLeader=nil,followsPlayer=true}}
  end},AI={getActivePackage=function()return activePackage end,isFleeing=function()return false end,
   startPackage=function(package)started=package end,filterPackages=function(filter)packageFilter=filter end}},
    types={Player={objectIsInstance=function(o)return o==playerTarget end},NPC={objectIsInstance=function(o)return o==object or o==playerTarget end,
     record=function(o)return{name=o==playerTarget and 'RANGROO' or 'Fargoth'}end},Creature={objectIsInstance=function()return false end},Actor={
     isDead=function()return false end,inventory=function()return inventorySource end,EQUIPMENT_SLOT={CarriedRight=1},
     getEquipment=function()return{[1]={recordId='iron_dagger',type=itemType,count=1}}end},Lockable={
     objectIsInstance=function(o)return o==lockedDoor end,isLocked=function()return true end,getLockLevel=function()return 35 end,
     getKeyRecord=function()return{id='warehouse_key'}end,getTrapSpell=function()return{id='fire damage'}end}},
   util={vector2=function()return {}end,vector3=vector},camera={getPosition=function()return vector(0,0,0)end,
    viewportToWorldVector=function()return vector(0,1,0)end},nearby={castRenderingRay=function()return{hit=true,hitObject=object,hitPos=vector(0,256,8)}end,
     COLLISION_TYPE={Actor=4},castRay=function(_,target,options)
      if options and options.collisionType==4 then return{hit=true,hitObject=object,hitPos=vector(0,256,8)}end
      return{hit=true,hitObject=object,hitPos=target}
     end,
       players={playerTarget},items={ownedItem},doors={lockedDoor},getObjectByFormId=function()return object end}}
 local mapped=openmwAdapter.identity(object,modules);eq(mapped.kind,'npc');eq(mapped.refnum.index,112)
 eq(mapped.refnum.content_file,1);eq(mapped.content_file,'Test.esp');eq(mapped.display_name,'Fargoth')
 local mappedPlayer=openmwAdapter.identity(playerTarget,modules);eq(mappedPlayer.kind,'player');eq(mappedPlayer.refnum.index,0)
 eq(mappedPlayer.refnum.content_file,0);eq(mappedPlayer.content_file,'Morrowind.esm');eq(mappedPlayer.display_name,'RANGROO')
 eq(openmwAdapter.resolve(mappedPlayer,modules),playerTarget)
 local aimed=openmwAdapter.resolveActorRay(512,modules);eq(aimed.identity.record_id,'fargoth');eq(aimed.distance,300)
 local candidate=openmwAdapter.resolveCameraTarget(512,modules);eq(candidate.identity.record_id,'fargoth');eq(candidate.distance,300)
 eq(openmwAdapter.actorDistance(mapped,modules),300)
 local combatStatus=openmwAdapter.combatStatus(modules);truthy(combatStatus.hostile_to_player);eq(combatStatus.target.kind,'player')
 eq(combatStatus.activity,'combat')
 local destination=openmwAdapter.resolveCameraPoint(512,modules);eq(destination.destination_y,256);eq(destination.destination_cell,'exterior:-2:-9')
 truthy(openmwAdapter.travel(destination,modules));eq(started.type,'Travel');eq(started.destPosition.y,256)
 truthy(openmwAdapter.stopAi({type='Travel',destination=destination},modules))
 eq(packageFilter({type='Travel',destPosition=vector(0,256,8)}),false)
 eq(packageFilter({type='Travel',destPosition=vector(0,257,8)}),true)
 truthy(openmwAdapter.escort(playerId,destination,modules));eq(started.type,'Escort');eq(started.target,playerTarget)
 activePackage=nil
 local faceOk,_,controller=openmwAdapter.beginFace(mapped,{},modules);truthy(faceOk)
 local completed=openmwAdapter.updateFace(controller,0.1,modules);eq(completed,nil);truthy(selfObject.controls.yawChange<0)
 yaw=0;completed=openmwAdapter.updateFace(controller,0.1,modules);eq(completed,true);eq(selfObject.controls.yawChange,0)
 local inventoryRows=openmwAdapter.targetInventory(mapped,modules);eq(inventoryRows[1].record_id,'iron_dagger');eq(#inventoryRows,2)
 local equipmentRows=openmwAdapter.targetEquipment(mapped,modules);eq(equipmentRows[1].slot,'carried_right');eq(equipmentRows[1].record_id,'iron_dagger')
 local followers,provider=openmwAdapter.followerContext(modules);eq(#followers,1);eq(followers[1].actor.record_id,'fargoth')
 eq(followers[1].leader.kind,'player');eq(followers[1].follows_player,true);eq(provider.provider,'FollowerDetectionUtil');eq(provider.version,2)
 local context=openmwAdapter.playerContext(mapped,modules);eq(context.followers[1].actor.record_id,'fargoth')
 eq(context.capabilities.follower_detection,'FollowerDetectionUtil');eq(context.capabilities.follower_detection_version,2)
 eq(context.playerState.held_items[1].display_name,'Iron Dagger')
 eq(context.nearbyObjects[1].ownership.record_id,'fargoth');eq(context.nearbyObjects[2].lock.locked,true)
 eq(context.nearbyObjects[2].lock.level,35);eq(context.nearbyObjects[2].lock.key_record_id,'warehouse_key')
end)

io.write(string.format('%d tests, %d failures\n',tests,failures))
if failures>0 then os.exit(1) end
