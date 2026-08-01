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
local orchestrator=require('scripts.ALMSIVI.orchestrator')
local player=require('scripts.ALMSIVI.player_state')
local openmwAdapter=require('scripts.ALMSIVI.adapters.openmw')
local fake=require('fake_openmw')
local npc=fake.identity('npc','fargoth',1)
local playerId=fake.identity('player','player',2)
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
 local snap=context.snapshot({audience=many,inventory=many,nearbyObjects=many,activeEffects=many,journal=many,contentFiles=many})
 eq(#snap.audience.items,12);eq(#snap.inventory.items,48);eq(#snap.nearbyObjects.items,32);eq(#snap.activeEffects.items,32);eq(#snap.journal.items,32);eq(#snap.contentFiles.items,256);truthy(snap.audience.truncated)
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
 orchestrator.configureSession(s,UUID.session);s.conversation.turn={requestId=UUID.request,turnId=UUID.turn,generation=1,status='accepted',terminal=false}
 truthy(s.events:accept(event(1,'dialogue.complete',1,{speaker=npc,addressee=playerId,text='Hello.'})))
 truthy(conversation.apply(s.conversation,event(1,'dialogue.complete',1,{speaker=npc,addressee=playerId,text='Hello.'})))
 local descriptor={media_id='00000000-0000-4000-8000-000000000005',sha256=string.rep('a',64),bytes=4,codec='ogg',duration_ms=100,expires_at='2026-07-19T21:00:00Z'}
 b.results={event(2,'speech.ready',1,descriptor)};eq(orchestrator.poll(s),1);eq(#b.prepared,1);eq(b.prepared[1].media_id,descriptor.media_id);eq(b.prepared[1].path,nil);eq(b.prepared[1].url,nil)
 b.media[descriptor.media_id]={state='ready'};orchestrator.poll(s)
 local speak=emitted[#emitted];eq(speak.name,'ALMSIVI_ACTOR_SPEAK');eq(speak.payload.media_id,descriptor.media_id);eq(speak.payload.subtitle,'Hello.');eq(speak.payload.generation,1);eq(speak.payload.dialogue_message_id,UUID.message);eq(speak.payload.session_id,UUID.session)
 orchestrator.lifecycle(s,'load');eq(next(s.conversation.pendingMedia),nil)
end)
test('actor is self-only and detach stops owned state',function()
 local st=actor.new(npc,2,{'action.ai.follow'}) local stopped=0
 local adapter={followSelf=function()return true end,playSpeech=function()return true end,stopSpeech=function()stopped=stopped+1 end,stopAi=function()stopped=stopped+1 return true end}
 local registry=identity.Registry();registry:activate(npc,{});registry:activate(playerId,{})
 local cmd={schema='almsivi.action-intent.v1',action_id='a',request_id='r',turn_id='t',session_id='s',generation=2,name='ai.follow',tier=1,actor=npc,target=playerId,parameters={distance=192},expires_at='x'}
 local result=actor.execute(st,cmd,adapter,{session_id='s',resolve=function(id)return registry:resolve(id)end,expired=function()return false end});eq(result.status,'succeeded');eq(result.kind,'almsivi.internal.action-terminal')
 actor.speak(st,{generation=2,actor=npc,media_id='opaque',request_id='r',turn_id='t',session_id='s',dialogue_message_id='d',expires_at='x'},adapter,{expired=function()return false end});eq(st.activeSpeech.mediaId,'opaque');actor.detach(st,adapter);eq(st.attached,false);eq(stopped,2)
end)
test('hard halt clears queues and blocks submit',function()
 local b=fake.bridge() local s=orchestrator.new(b);orchestrator.halt(s);truthy(b.halted);eq(s.conversation.target,nil)
 local ok,reason=orchestrator.submitText(s,{text='hi'});eq(ok,nil);eq(reason,'almsivi_disabled')
end)
test('player action does not consume vanilla activation',function()
 local s=player.new();eq(player.onAction(s,'Activate',function()end),false);truthy(player.onAction(s,'ALMSIVI_Talk',function()end))
end)
test('OpenMW settings page registers controls and seeds conflict-free defaults once',function()
 local data={OMWInputBindings={},ALMSIVIInputDefaults={}}
 local function section(name)
  data[name]=data[name] or {}
  return {get=function(_,key)return data[name][key]end,set=function(_,key,value)data[name][key]=value end}
 end
 local registered={triggers={},actions={},pages={},groups={}}
 package.preload['openmw.input']=function() return {
  KEY={F6=6,F7=7},ACTION_TYPE={Boolean='boolean'},
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
 require('scripts.ALMSIVI.settings')
 eq(registered.pages[1].key,'ALMSIVI');eq(registered.groups[1].page,'ALMSIVI');eq(#registered.groups[1].settings,4)
 for _,setting in ipairs(registered.groups[1].settings) do truthy(setting.name);truthy(setting.description) end
 truthy(registered.triggers.ALMSIVI_Talk);truthy(registered.triggers.ALMSIVI_Halt)
 truthy(registered.triggers.ALMSIVI_OpenMic);truthy(registered.actions.ALMSIVI_PushToTalk)
 local talk=data.OMWInputBindings.ALMSIVI_Talk_Binding
 local halt=data.OMWInputBindings.ALMSIVI_Halt_Binding
 eq(talk.device,'keyboard');eq(talk.button,6);eq(talk.type,'trigger');eq(talk.key,'ALMSIVI_Talk')
 eq(halt.button,7);eq(data.ALMSIVIInputDefaults.version,1)
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
test('opt-in open microphone uses VAD and rearms only after the turn',function()
 local b=fake.bridge() local emitted={}
 local s=orchestrator.new(b,function(name,payload)table.insert(emitted,{name=name,payload=payload})end)
 orchestrator.configureSession(s,UUID.session);orchestrator.activate(s,npc,{});truthy(conversation.setTarget(s.conversation,npc))
 s.conversation.turn={terminal=false}
 truthy(orchestrator.enableOpenMic(s,{speaker=playerId,target=npc,context={inventory={}},language='en-US',
  capabilities={'dialogue.text','speech.listen'}}));truthy(s.openMic);eq(b.voiceState,'idle');eq(emitted[#emitted].payload.status,'waiting')
 s.conversation.turn.terminal=true;truthy(orchestrator.pollOpenMic(s));eq(emitted[#emitted].name,'ALMSIVI_OPEN_MIC_CONTEXT_REQUEST')
 truthy(orchestrator.runOpenMicContext(s,{speaker=playerId,target=npc,context={inventory={}},language='en-US',
  capabilities={'dialogue.text','speech.listen'}}));truthy(b.voiceAutomatic);eq(b.voiceState,'recording')
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
 local selfObject={position=vector(0,0,0)}
 local modules={core={contentFiles={list={'Morrowind.esm','Test.esp'}}},self=selfObject,
  types={Player={objectIsInstance=function()return false end},NPC={objectIsInstance=function(o)return o==object end,
   record=function()return{name='Fargoth'}end},Creature={objectIsInstance=function()return false end},Actor={isDead=function()return false end}},
  util={vector2=function()return {}end},camera={getPosition=function()return vector(0,0,0)end,
   viewportToWorldVector=function()return vector(0,1,0)end},nearby={castRenderingRay=function()return{hit=true,hitObject=object}end}}
 local mapped=openmwAdapter.identity(object,modules);eq(mapped.kind,'npc');eq(mapped.refnum.index,112)
 eq(mapped.refnum.content_file,1);eq(mapped.content_file,'Test.esp');eq(mapped.display_name,'Fargoth')
 local candidate=openmwAdapter.resolveCameraTarget(512,modules);eq(candidate.identity.record_id,'fargoth');eq(candidate.distance,300)
end)

io.write(string.format('%d tests, %d failures\n',tests,failures))
if failures>0 then os.exit(1) end
