local runner=(arg and arg[0] or ''):gsub('\\','/')
local root=runner:match('^(.*)/scripts/LORKHAN/tests/run%.lua$') or 'lorkhan/files'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..root..'/scripts/LORKHAN/tests/fake_openmw/?.lua;'..package.path

local failures,tests=0,0
local function test(name,fn)
    tests=tests+1 local ok,reason=pcall(fn)
    if ok then io.write('ok - '..name..'\n') else failures=failures+1 io.write('not ok - '..name..': '..tostring(reason)..'\n') end
end
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function truthy(v) assert(v) end

local identity=require('scripts.LORKHAN.identity')
local protocol=require('scripts.LORKHAN.protocol')
local playerInput=require('scripts.LORKHAN.player_input')
local conversation=require('scripts.LORKHAN.conversation')
local storage=require('scripts.LORKHAN.storage')
local context=require('scripts.LORKHAN.context')
local actions=require('scripts.LORKHAN.actions')
local actor=require('scripts.LORKHAN.actor_executor')
local agentRegistry=require('scripts.LORKHAN.agent_registry')
local orchestrator=require('scripts.LORKHAN.orchestrator')
local responseQueue=require('scripts.LORKHAN.response_queue')
local player=require('scripts.LORKHAN.player_state')
local openmwAdapter=require('scripts.LORKHAN.adapters.openmw')
local support=require('scripts.LORKHAN.util')
local fake=require('fake_openmw')
local npc=fake.identity('npc','fargoth',1)
local playerId=fake.identity('player','player',2)
local enemy=fake.identity('creature','mudcrab',3)
local UUID={message='00000000-0000-4000-8000-000000000001',request='00000000-0000-4000-8000-000000000002',turn='00000000-0000-4000-8000-000000000003',session='00000000-0000-4000-8000-000000000004'}
local function event(sequence,kind,generation,payload)
 return {message_id=UUID.message,request_id=UUID.request,turn_id=UUID.turn,session_id=UUID.session,generation=generation,
  sequence=sequence,created_at='2026-07-19T20:00:0'..tostring(sequence)..'Z',type=kind,payload=payload or {}}
end
test('menu dialogue splits into a bounded ordered sentence queue',function()
 local sentences=support.splitSentences('First line. Second line! Third line?',8)
 eq(#sentences,3);eq(sentences[1],'First line.');eq(sentences[2],'Second line!');eq(sentences[3],'Third line?')
 sentences=support.splitSentences('Wait... Still here. Final.',2)
 eq(#sentences,2);eq(sentences[1],'Wait...');eq(sentences[2],'Still here. Final.')
 sentences=support.splitSentences('One line without punctuation',8)
 eq(#sentences,1);eq(sentences[1],'One line without punctuation')
 local book=string.rep('Read this aloud ',40)..'End.'
 local chunks=support.speechChunks(book,240)
 truthy(#chunks>1);eq(table.concat(chunks,' '),book)
 for _,chunk in ipairs(chunks) do truthy(#chunk<=240) end
 local rpg=assert(protocol.rpgEvent({kind='levelup',player=playerId,game_time=120,text='The player reached level 2.'}))
 eq(rpg.kind,'levelup');eq(protocol.rpgEvent({kind='levelup',player=npc,game_time=120,text='not player'}),nil)
end)
test('RPG responder is typed and acknowledgements stay bounded and session owned',function()
 local args={kind='sleep',player=playerId,responder=npc,game_time=120,text='The player slept.'}
 local dto=assert(protocol.rpgEvent(args));truthy(identity.same(dto.responder,npc));truthy(dto.responder~=npc)
 args.responder=playerId;eq(protocol.rpgEvent(args),nil)
 args.responder=enemy;truthy(protocol.rpgEvent(args));args.kind='lockpick';eq(protocol.rpgEvent(args),nil)
 local s=player.new();local session={session_id=UUID.session,generation=7}
 local ack={request_id=UUID.request,session_id=UUID.session,generation=7}
 truthy(player.rememberRpgComment(s,UUID.request,npc,session,10))
 truthy(identity.same(player.takeRpgComment(s,ack,session,11),npc))
 eq(player.takeRpgComment(s,ack,session,11),nil)
 truthy(player.rememberRpgComment(s,UUID.request,npc,session,10))
 eq(player.takeRpgComment(s,ack,session,41),nil)
 truthy(player.rememberRpgComment(s,UUID.request,npc,session,10))
 eq(player.takeRpgComment(s,ack,{session_id=UUID.session,generation=8},11),nil)
 for i=1,32 do truthy(player.rememberRpgComment(s,tostring(i),npc,session,10)) end
 eq(player.rememberRpgComment(s,'overflow',npc,session,10),false)
 truthy(player.rememberRpgComment(s,'new',npc,{session_id='new-session',generation=7},11))
 local count=0;for _ in pairs(s.pendingRpgComments) do count=count+1 end;eq(count,1)
end)
test('RPG global handoff refuses changed responders, generations and busy turns',function()
 local function setup()
  local b=fake.bridge();local s=orchestrator.new(b,nil,nil,function()return true end)
  orchestrator.configureSession(s,UUID.session);orchestrator.activate(s,npc,{})
  truthy(orchestrator.selectTarget(s,{identity=npc,distance=100,maxDistance=1200,dead=false,hostile=false,available=true}))
  local request=b.nextTurnMetadata();request.text='[RPG:sleep] The player slept.';request.language='en-US'
  request.speaker=playerId;request.context={};request.capabilities={'dialogue.text'};request.recent_action_results={}
  request.ui_source='lorkhan_rpg_event';request.rpg_responder=npc;request.rpg_session_id=s.sessionId;request.rpg_generation=s.generation
  return b,s,request
 end
 local b,s,request=setup();request.rpg_responder=enemy
 local ok,reason=orchestrator.submitText(s,request);eq(ok,nil);eq(reason,'stale_rpg_responder');eq(#b.submitted,0)
 b,s,request=setup();request.rpg_generation=s.generation+1
 ok,reason=orchestrator.submitText(s,request);eq(ok,nil);eq(reason,'stale_rpg_responder')
 b,s,request=setup();s.conversation.turn={terminal=false}
 ok,reason=orchestrator.submitText(s,request);eq(ok,nil);eq(reason,'rpg_busy');eq(#b.submitted,0)
 b,s,request=setup();s.combatActors[identity.key(enemy)]=true
 ok,reason=orchestrator.submitText(s,request);eq(ok,nil);eq(reason,'rpg_busy')
 b,s,request=setup();truthy(orchestrator.submitText(s,request));truthy(identity.same(b.submitted[1].payload.target,npc))
 eq(s.autonomy.rpgCooldownSeconds,60)
 ok,reason=orchestrator.submitText(s,request);eq(ok,nil);eq(reason,'rpg_cooldown')
 for _=1,12 do orchestrator.runAutonomy(s,5) end;eq(s.autonomy.rpgCooldownSeconds,0)
 orchestrator.lifecycle(s,'load');eq(s.autonomy.rpgCooldownSeconds,0)
end)
local function uuid(value) return string.format('00000000-0000-4000-8000-%012x',value) end
local function dialogueLine(index,lineId,speaker,listener,text,final,speechEnabled)
 return {schema='lorkhan.response.line.v1',line_id=lineId,line_index=index,speaker=speaker.display_name,
  display_name=speaker.display_name,speaker_identity=speaker,action='say',text=text,subtitle=text,tts_text=text,
  request_id=UUID.request,utterance_id=uuid(100+index),listener=listener.display_name,listener_identity=listener,
  rechat_target=speaker.display_name,rechat_target_identity=speaker,final_response_line=final,
  metadata={rechat_depth=0,speech_enabled=speechEnabled~=false,source='provider'}}
end
local function actionLine(index,lineId,speaker,listener,name,args)
 return {schema='lorkhan.response.line.v1',line_id=lineId,line_index=index,speaker=speaker.display_name,
  display_name=speaker.display_name,speaker_identity=speaker,action='rolecommand',text='',subtitle='',tts_text='',
  request_id=UUID.request,utterance_id=uuid(100+index),listener=listener.display_name,listener_identity=listener,
  rechat_target=speaker.display_name,rechat_target_identity=speaker,command_name=name,command_args=args or {},
  final_response_line=false,metadata={rechat_depth=0,source='provider'}}
end
local function responseEvent(sequence,lines,generation,responseId)
 responseId=responseId or uuid(80+sequence)
 local response={schema='lorkhan.response.v1',response_id=responseId,installation_id=uuid(60),profile_id=uuid(61),
  playthrough_id=uuid(62),session_id=UUID.session,turn_id=UUID.turn,request_id=UUID.request,
  generation=generation,runtime_generation=generation,created_at='2026-07-19T20:00:00Z',ok=true,
  lines=lines,close=false,error=''}
 local result=event(sequence,'response.complete',generation,response);result.message_id=responseId return result
end

test('lifecycle invalidates generation and cancels native',function()
 local b=fake.bridge() local s=orchestrator.new(b) local before=s.generation orchestrator.lifecycle(s,'load')
 eq(s.generation,before+1) eq(b.cancelled[1],before)
 local loadedFlag
 b.finishLoadedSave=function() return true end
 b.cancelGeneration=function(_,loaded) loadedFlag=loaded end
 orchestrator.lifecycle(s,'load');eq(loadedFlag,true)
 orchestrator.lifecycle(s,'new_game');eq(loadedFlag,false)
end)
test('GLOBAL loaded-save handshake waits for the player and submits only calendar fields',function()
 local saved={} local modules={'scripts.LORKHAN.adapters.openmw','scripts.LORKHAN.orchestrator',
  'openmw.world','openmw.types','openmw.interfaces','openmw.util'}
 for _,name in ipairs(modules) do saved[name]=package.loaded[name] end
 local ok,err=pcall(function()
  local calls={} local fenced=false
  local world={players={},activeActors={},mwscript={}}
  local variables={year=427,month=7,day=16,gamehour=9.5,dayspassed=50}
  world.mwscript.getGlobalVariables=function() return variables end
  local native={finishLoadedSave=function(calendar)
   if not fenced then return false end
   fenced=false;calls[#calls+1]=calendar or 'unknown';return true
  end}
  package.loaded['scripts.LORKHAN.adapters.openmw']={bridge=function()return native end,
   event=function()return {} end,identity=function()return nil end}
  package.loaded['scripts.LORKHAN.orchestrator']={new=function()return {} end,
   load=function()fenced=true end,lifecycle=function()fenced=false end}
  package.loaded['openmw.world']=world
  for _,name in ipairs({'openmw.types','openmw.interfaces','openmw.util'}) do package.loaded[name]={} end
  local handlers=assert(loadfile(root..'/scripts/LORKHAN/global.lua'))().engineHandlers
  handlers.onLoad({});handlers.onPlayerAdded({});eq(#calls,0)
  world.players[1]={sendEvent=function()end}
  handlers.onPlayerAdded(world.players[1]);eq(#calls,1)
  eq(calls[1].year,427);eq(calls[1].month,7);eq(calls[1].day,16);eq(calls[1].hour,9.5)
  eq(calls[1].days_passed,nil);eq(calls[1].month_name,nil)
  handlers.onPlayerAdded(world.players[1]);eq(#calls,1)
  handlers.onNewGame();handlers.onPlayerAdded(world.players[1]);eq(#calls,1)
  world.mwscript=nil;handlers.onLoad({});handlers.onPlayerAdded(world.players[1]);eq(calls[2],'unknown')
 end)
 for _,name in ipairs(modules) do package.loaded[name]=saved[name] end
 assert(ok,err)
end)
test('browser speech queues a normal turn only for the current idle session before its deadline',function()
 local saved={} local modules={'scripts.LORKHAN.adapters.openmw','scripts.LORKHAN.orchestrator',
  'openmw.world','openmw.types','openmw.interfaces','openmw.util'}
 for _,name in ipairs(modules) do saved[name]=package.loaded[name] end
 local ok,err=pcall(function()
  local results={} local calls={} local current={sessionId='session',generation=4,conversation={target={kind='npc'}}}
  local native={nextTurnMetadata=function()return {request_id=UUID.message,turn_id=UUID.message,message_id=UUID.message,created_at='2026-09-12T00:00:00Z'} end}
  package.loaded['scripts.LORKHAN.adapters.openmw']={bridge=function()return native end,
   event=function()return {getRealTime=function()return 10 end} end}
  package.loaded['scripts.LORKHAN.orchestrator']={new=function()return current end,
   submitText=function(_,args) calls[#calls+1]=args;return args.request_id end}
  package.loaded['openmw.world']={players={{sendEvent=function(_,name,payload)results[#results+1]={name=name,payload=payload}end}}}
  for _,name in ipairs({'openmw.types','openmw.interfaces','openmw.util'}) do package.loaded[name]={} end
  local handler=assert(loadfile(root..'/scripts/LORKHAN/global.lua'))().eventHandlers.LORKHAN_DEBUG_COMMAND
  local function submit(overrides)
   local input={command={name='player.dialogue.submit',command_id=UUID.message,
    parameters={text='Where is Caius? *curious*',language='en-US'}},
    browser_args={text='ignored',context={}},session_id='session',generation=4,deadline=20}
   for key,value in pairs(overrides or {}) do input[key]=value end
   handler(input);return results[#results].payload
  end
  eq(submit({generation=3}).reason_code,'stale_session');eq(#calls,0)
  eq(submit({deadline=10}).reason_code,'command_expired');eq(#calls,0)
  current.pendingVoice={};eq(submit().reason_code,'player_input_busy');current.pendingVoice=nil
  current.conversation.turn={terminal=false};eq(submit().reason_code,'player_input_busy');current.conversation.turn=nil
  local result=submit();eq(result.status,'succeeded');eq(result.reason_code,'dialogue_queued');eq(#calls,1)
  eq(calls[1].text,'Where is Caius? *curious*');eq(calls[1].input_key,UUID.message)
  eq(calls[1].ui_source,'lorkhan_browser_speech');eq(result.observed.request_id,UUID.message)
 end)
 for _,name in ipairs(modules) do package.loaded[name]=saved[name] end
 assert(ok,err)
end)
test('wire validators reject uppercase UUID and zero-byte media',function()
 eq(protocol.isUuid('00000000-0000-4000-8000-000000000001'),true)
 eq(protocol.isUuid('00000000-0000-4000-8000-00000000000A'),false)
 local speech=event(1,'speech.ready',3,{media_id=UUID.message,dialogue_message_id=UUID.message,sha256=string.rep('a',64),bytes=0,codec='wav',duration_ms=1,expires_at='2026-07-19T00:00:00Z'})
 local ok,reason=protocol.validatePolledEvent(speech);eq(ok,nil);eq(reason,'invalid_speech_bytes')
 speech.payload.bytes=4;speech.payload.duration_ms=0;ok,reason=protocol.validatePolledEvent(speech);eq(ok,nil);eq(reason,'invalid_speech_duration')
end)
test('player input policy parses only safe one-turn prefixes and validates moods',function()
 local parsed=playerInput.parse('|| stay close');eq(parsed.text,'stay close');eq(parsed.mode,'Close');eq(parsed.prefix,'||')
 parsed=playerInput.parse('| whisper');eq(parsed.text,'whisper');eq(parsed.mode,'Whisper')
 parsed=playerInput.parse('!! everyone');eq(parsed.text,'everyone');eq(parsed.mode,'Shout')
 parsed=playerInput.parse('Normal text');eq(parsed.text,'Normal text');eq(parsed.mode,nil)
 local invalid,reason=playerInput.parse('|  ');eq(invalid,nil);eq(reason,'empty_input')
 parsed=playerInput.parse('** narrator');eq(parsed.text,'** narrator');eq(parsed.mode,nil)
 local mood; mood,reason=playerInput.validateMood({kind='angry'});eq(mood.kind,'angry');eq(reason,nil)
 mood=playerInput.validateMood({kind='custom',custom='  with quiet resolve  '});eq(mood.custom,'with quiet resolve')
 mood,reason=playerInput.validateMood({kind='custom',custom='two\nlines'});eq(mood,nil);eq(reason,'invalid_mood')
 mood,reason=playerInput.validateMood({kind='custom',custom=string.rep('x',81)});eq(mood,nil);eq(reason,'invalid_mood')
 mood,reason=playerInput.validateMood({kind='happy',custom='extra'});eq(mood,nil);eq(reason,'invalid_mood')
end)
test('event ordering dedup and cursor recovery',function()
 local c=protocol.CursoredEvents(UUID.session,3) truthy(c:accept(event(1,'turn.accepted',3)))
 local ok,reason=c:accept(event(1,'turn.accepted',3)); eq(ok,false);eq(reason,'duplicate_event')
 ok,reason=c:accept(event(3,'turn.complete',3));truthy(ok);eq(reason,'cursor_resynced');eq(c:cursor(),3)
end)
test('speaker-less streaming delta uses the selected target',function()
 local s=player.new();s.ui.target=npc
 player.event(s,event(1,'dialogue.delta',3,{text='Welcome.'}))
 eq(s.ui.subtitle.speaker.record_id,'fargoth');eq(s.ui.subtitle.text,'Welcome.')
end)
test('streamed sentence media queues before the final response without replay',function()
 local lineId=uuid(150);local mediaId=uuid(151);local q=responseQueue.new(3,3)
 local streamed=event(1,'dialogue.complete',3,{speaker=npc,addressee=playerId,text='Early sentence.'})
 streamed.message_id=lineId
 local queued,count=responseQueue.enqueueDialogueEvent(q,streamed,3);assert(queued,count);eq(count,1)
 local speech=event(2,'speech.ready',3,{media_id=mediaId,dialogue_message_id=lineId,sha256=string.rep('a',64),
  bytes=16,codec='wav',duration_ms=100,expires_at='2026-07-19T21:00:00Z'})
 local attached,attachReason=responseQueue.attachMedia(q,speech);assert(attached,attachReason);eq(q.items[1].media.media_id,mediaId)
 local final=dialogueLine(0,lineId,npc,playerId,'Early sentence.',true,true)
 local accepted,newLines=responseQueue.enqueue(q,responseEvent(3,{final},3).payload,3,3)
 assert(accepted,newLines);eq(newLines,0);eq(#q.items,1);eq(q.items[1].line.final_response_line,true)
 eq(q.counters.queued,1);eq(q.counters.deduplicated,1)
end)

test('final response advances rechat after its streamed sentence already played',function()
 local lineId=uuid(152);local mediaId=uuid(153);local q=responseQueue.new(3,3)
 local streamed=event(1,'dialogue.complete',3,{speaker=npc,addressee=playerId,text='Early final sentence.'})
 streamed.message_id=lineId
 assert(responseQueue.enqueueDialogueEvent(q,streamed,3))
 local speech=event(2,'speech.ready',3,{media_id=mediaId,dialogue_message_id=lineId,sha256=string.rep('b',64),
  bytes=16,codec='wav',duration_ms=100,expires_at='2026-07-19T21:00:00Z'})
 assert(responseQueue.attachMedia(q,speech));q.items[1].status='ready'
 assert(responseQueue.markDispatched(q,q.items[1]));assert(responseQueue.completeDialogue(q,mediaId,'played'))
 eq(#q.items,0);eq(responseQueue.consumeRechat(q),false)
 local final=dialogueLine(0,lineId,npc,playerId,'Early final sentence.',true,true)
 assert(responseQueue.enqueue(q,responseEvent(3,{final},3).payload,3,3))
 eq(responseQueue.consumeRechat(q),true);eq(responseQueue.consumeRechat(q),false)
end)

test('target settings preserve local presentation actions and target preferences',function()
 local function localSettings()
  return {autoActivate={addHostile=true,addCreatures=true},behavior={actionsEnabled=true},
   presentation={showStatusHud=false,transcriptRows=12,ttsVolumeBoost=4}}
 end
 local settings=localSettings();local presentation=settings.presentation
 local target={safety={actions_enabled=true,allow_hostile=true,allow_creatures=true},
  behavior={rechat=true,rechat_max_depth=1,rechat_probability_percent=0,rechat_mode='group',
   rechat_strict_targeting=false,open_rechat=false,end_conversation_cooldown_seconds=0,
   auto_greeting=true,boredom=true,combat_barks=true,rechat_allow_actions=true},
  presentation={show_status_hud=true,transcript_rows=2,tts_volume_boost=1},
  memory={recent_turn_limit=0,knowledge_limit=0},narrator={enabled=false}}
 player.applyTargetSettings(settings,target)
 eq(settings.presentation,presentation);eq(presentation.showStatusHud,false)
 eq(presentation.transcriptRows,12);eq(presentation.ttsVolumeBoost,4)
 eq(settings.autoActivate.addHostile,true);eq(settings.autoActivate.addCreatures,true)
 eq(settings.behavior.actionsEnabled,true);eq(settings.behavior.rechat,true)
 eq(settings.behavior.rechatMaxDepth,1);eq(settings.behavior.rechatProbabilityPercent,0)
 eq(settings.behavior.rechatMode,'group');eq(settings.behavior.openRechat,false)
 eq(settings.behavior.rechatStrictTargeting,false);eq(settings.behavior.endConversationCooldownSeconds,0)
 eq(settings.behavior.autoGreeting,true);eq(settings.behavior.boredom,true)
 eq(settings.behavior.boredomDelaySeconds,180);eq(settings.behavior.combatBarks,true)
 eq(settings.behavior.combatBarkPeriodSeconds,20);eq(settings.behavior.rechat_allow_actions,nil)
 eq(settings.memory.recent_turn_limit,0);eq(settings.narrator.enabled,false)
 settings=localSettings();settings.behavior.actionsEnabled=false
 settings.autoActivate.addHostile=false;settings.autoActivate.addCreatures=false
 player.applyTargetSettings(settings,target)
 eq(settings.behavior.actionsEnabled,false);eq(settings.autoActivate.addHostile,false)
 eq(settings.autoActivate.addCreatures,false)
 for _,safety in ipairs({{}, {actions_enabled=false,allow_hostile=false,allow_creatures=false}}) do
  settings=localSettings();player.applyTargetSettings(settings,{safety=safety})
  eq(settings.behavior.actionsEnabled,true);eq(settings.autoActivate.addHostile,true)
  eq(settings.autoActivate.addCreatures,true);eq(settings.behavior.rechat,false)
 end
end)
test('conversation history retains correlation metadata and terminal request state',function()
 local s=player.new();s.ui.policy.transcriptRows=2
 player.queued(s,playerId,'Hello.',event(1,'turn.accepted',3,{status='accepted'}))
 player.event(s,event(2,'dialogue.complete',3,{speaker=npc,text='Greetings.'}))
 eq(#s.ui.transcript,2);eq(s.ui.transcript[1].status,'queued');eq(s.ui.transcript[2].sequence,2)
 eq(s.ui.transcript[2].createdAt,'2026-07-19T20:00:02Z');eq(s.ui.lastCorrelation.messageId,UUID.message)
 player.event(s,event(3,'turn.complete',3,{status='complete'}))
 eq(s.ui.transcript[1].status,'complete');eq(s.ui.transcript[2].status,'complete')
 eq(s.ui.transcript[1].terminalSequence,3)
 player.event(s,event(4,'dialogue.complete',3,{speaker=npc,text='Another response.'}))
 eq(#s.ui.transcript,2);eq(s.ui.transcript[1].text,'Greetings.')
end)
test('OpenMW async callback retains its package identifier',function()
 local savedLoaded=package.loaded['openmw.async'];local savedPreload=package.preload['openmw.async']
 package.loaded['openmw.async']=nil
 local asyncPackage={}
 asyncPackage.callback=function(self,fn)eq(self,asyncPackage);eq(type(fn),'function');return fn end
 package.preload['openmw.async']=function()return asyncPackage end
 local fn=function()return true end;eq(openmwAdapter.callback(fn),fn)
 package.loaded['openmw.async']=savedLoaded;package.preload['openmw.async']=savedPreload
end)
test('quest commentary carries observed journal text without inventing stages',function()
 local args={responder=npc,game_time=120,entries={{quest_id='mq_test',stage=20,text='Actual journal line.'},{quest_id='unknown',text='No known stage.'}}}
 local q=assert(protocol.questEvent(args));eq(q.text,'Quest mq_test, stage 20: Actual journal line.\nQuest unknown: No known stage.')
 truthy(identity.same(q.responder,npc));args.responder=playerId;eq(protocol.questEvent(args),nil)
 args.responder=npc;args.entries={{quest_id='too_long',text=string.rep('x',8193)}};eq(protocol.questEvent(args),nil)
end)
test('journal deltas preserve entry content and fence initial snapshots and session changes',function()
 local s={} local session={session_id=UUID.session,generation=1}
 local first={id='a',quest_id='quest',stage=10,text='First objective.'}
 local second={id='b',quest_id='quest',stage=20,text='Second objective.'}
 eq(#player.journalChanges(s,{first,second},session),0)
 eq(#player.journalChanges(s,{second,first},session),0) -- ordering alone is not an update
 first.stage=11
 local changed=player.journalChanges(s,{first,second},session)
 eq(#changed,1);eq(changed[1].stage,11);eq(changed[1].text,'First objective.')
 changed[1].text='mutated';eq(#player.journalChanges(s,{first,second},session),0)
 second.text='New objective text.';eq(#player.journalChanges(s,{first,second},session),1)
 eq(#player.journalChanges(s,{second},session),0) -- truncated/removed rows are not new entries
 session.generation=2;eq(#player.journalChanges(s,{first,second},session),0)
 eq(#player.journalChanges(s,{},nil),0);eq(#player.journalChanges(s,{first,second},session),0)
end)
test('journal stages match record info IDs without guessing from entry IDs',function()
 local first='31540100981975929470';local second='1642660101856927121'
 local entries={{id=first,questId='test_quest',text='First.'},{id=second,questId='test_quest',text='Second.'},
  {id='10',questId='test_quest',text='Missing record.'},{id='orphan',text='No quest.'}}
 local modules={types={Player={journal=function()return{journalTextEntries=entries}end}},
  core={dialogue={journal={records={test_quest={infos={{id=first,questStage=10},{id=second,questStage=20}}}}}}}}
 local journal=openmwAdapter.journalEntries(modules)
 eq(#journal,4);eq(journal[1].id,first);eq(journal[1].stage,10);eq(journal[2].stage,20)
 eq(journal[3].stage,nil);eq(journal[4].stage,nil);eq(journal[1].text,'First.')
 modules.core={};eq(openmwAdapter.journalEntries(modules)[1].stage,nil)
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
 local over=context.snapshot({world={description=string.rep('x',context.limits.MAX_CONTEXT_BYTES)},targetState={inventory={items={{record_id='dagger',count=1}},total=1,truncated=false}}})
 truthy(over.budget.truncated);eq(#over.targetState.inventory.items,0);eq(over.targetState.inventory.total,1);truthy(over.targetState.inventory.truncated)
 local many={} for i=1,300 do many[i]={n=i} end
 local snap=context.snapshot({audience=many,actorActivities=many,inventory=many,nearbyObjects=many,activeEffects=many,journal=many,books=many,recentVanillaDialogue=many,contentFiles=many})
 eq(#snap.audience.items,12);eq(#snap.actorActivities.items,12);eq(#snap.inventory.items,48);eq(#snap.nearbyObjects.items,32);eq(#snap.activeEffects.items,32);eq(#snap.journal.items,32);eq(#snap.books.items,8);eq(#snap.recentVanillaDialogue.items,8);eq(#snap.contentFiles.items,256);truthy(snap.audience.truncated)
end)
test('vanilla dialogue is bounded and consumed by the next accepted turn',function()
 local b=fake.bridge() local s=orchestrator.new(b,nil,nil,function() return true end)
 orchestrator.configureSession(s,UUID.session)
 orchestrator.activate(s,npc,{})
 local selected,selectReason=orchestrator.selectTarget(s,{identity=npc,distance=100,maxDistance=2048,dead=false,available=true});assert(selected,selectReason)
 for i=1,10 do local recorded,recordReason=orchestrator.recordVanillaDialogue(s,{source='openmw.DialogueResponse',text='line '..i});assert(recorded,recordReason) end
 local request=b.nextTurnMetadata();request.text='What did you say?';request.input_key='vanilla-dialogue'
 request.language='en-US';request.speaker=playerId;request.context={};request.capabilities={'dialogue.text'}
 request.recent_action_results={};request.ui_source='lorkhan_text'
 local submitted,reason=orchestrator.submitText(s,request);assert(submitted,reason)
 local recent=b.submitted[1].payload.context.recentVanillaDialogue.items
 eq(#recent,8);eq(recent[1].text,'line 3');eq(recent[8].text,'line 10');eq(#s.recentVanillaDialogue,0)
end)
test('captured vanilla dialogue preserves CHIM background and menu classifications',function()
 local background,reason=protocol.capturedDialogue({source='background',speaker=npc,listener=playerId,
  audience={},text='Wealth beyond measure, outlander.',topic='voice',game_time=123.5})
 assert(background,reason);eq(background.source,'background');eq(background.game_time,123.5)
 local menu=assert(protocol.capturedDialogue({source='menu',speaker=npc,listener=playerId,
  audience={enemy},text='What can Fargoth do for you?',topic='greeting'}))
 eq(menu.source,'menu');eq(menu.audience[1].record_id,enemy.record_id)
 local invalid,invalidReason=protocol.capturedDialogue({source='journal',speaker=npc,listener=playerId,
  audience={},text='No.',topic=''})
 eq(invalid,nil);eq(invalidReason,'invalid_dialogue_source')
 invalid,invalidReason=protocol.capturedDialogue({source='background',speaker=npc,listener=playerId,
  audience={enemy,enemy},text='No.',topic=''})
 eq(invalid,nil);eq(invalidReason,'duplicate_dialogue_audience')
end)
test('auto-activated actor profile snapshots are bounded and closed',function()
 local snapshot,reason=protocol.actorProfile({actor=npc,race='Wood Elf',class='Commoner',gender='male',
  level=1,disposition=50,factions={'fighters guild'}})
 assert(snapshot,reason);eq(snapshot.actor.record_id,'fargoth');eq(snapshot.gender,'male');eq(snapshot.factions[1],'fighters guild')
 local creature,creatureReason=protocol.actorProfile({actor=enemy,race='Creature',class='',gender='none',
  level=1,disposition=0,factions={}})
 assert(creature,creatureReason);eq(creature.actor.kind,'creature');eq(creature.gender,'none')
 local invalid,invalidReason=protocol.actorProfile({actor=npc,race='Wood Elf',class='Commoner',gender='male',
  level=1,disposition=50,factions={'fighters guild','fighters guild'}})
 eq(invalid,nil);eq(invalidReason,'invalid_actor_profile')
end)
test('automatic diary candidates keep timer sleep and wait actors bounded',function()
 local payload,reason=protocol.automaticDiary({trigger='sleep',game_time=123.5,actors={npc,enemy}})
 assert(payload,reason);eq(payload.trigger,'sleep');eq(payload.game_time,123.5);eq(#payload.actors,2)
 local invalid,invalidReason=protocol.automaticDiary({trigger='rest',game_time=123.5,actors={}})
 eq(invalid,nil);eq(invalidReason,'invalid_automatic_diary')
 invalid,invalidReason=protocol.automaticDiary({trigger='wait',game_time=123.5,actors={npc,npc}})
 eq(invalid,nil);eq(invalidReason,'duplicate_automatic_diary_actor')
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
test('player event delivery failure cannot strand an active turn',function()
 local b=fake.bridge();local s=orchestrator.new(b,function()error('ui delivery failed')end)
 s.sessionId=UUID.session;s.events=protocol.CursoredEvents(UUID.session,1)
 truthy(conversation.setTarget(s.conversation,npc));truthy(conversation.begin(s.conversation,UUID.request,UUID.turn,'input'))
 b.results={event(1,'turn.accepted',1,{status='accepted'}),event(2,'turn.complete',1,{status='complete'})}
 eq(orchestrator.poll(s),2);truthy(s.conversation.turn.terminal);eq(s.conversation.turn.status,'complete')
end)
test('correlated transport failure releases the active turn',function()
 local b=fake.bridge();local emitted={};local s=orchestrator.new(b,function(name,payload)emitted[#emitted+1]={name,payload}end)
 s.sessionId=UUID.session;s.events=protocol.CursoredEvents(UUID.session,0)
 truthy(conversation.setTarget(s.conversation,npc));truthy(conversation.begin(s.conversation,UUID.request,UUID.turn,'first'))
 b.results={{type='transport.failure',request_id=UUID.request,turn_id=UUID.turn,reason='server returned a typed protocol error'}}
 eq(orchestrator.poll(s),1);truthy(s.conversation.turn.terminal);eq(s.conversation.turn.status,'failed')
 eq(emitted[1][1],'LORKHAN_EVENT');eq(emitted[1][2].type,'turn.failed')
 truthy(conversation.begin(s.conversation,uuid(901),uuid(902),'second'))
end)
test('action capability authority expiry exact parameters and limits',function()
 local state=actions.new({'action.ai.follow'}) local registry=identity.Registry();registry:activate(npc,{});registry:activate(playerId,{})
 local authority={generation=2,session_id='s',actor=npc,resolve=function(id)return registry:resolve(id)end,expired=function()return false end}
 local base={schema='lorkhan.action-intent.v1',action_id='a',request_id='r',turn_id='t',session_id='s',generation=2,name='ai.follow',tier=1,actor=npc,target=playerId,parameters={distance=191},expires_at='soon'}
 local ok,reason=actions.validate(state,base,authority);eq(ok,nil);eq(reason,'invalid_follow_distance')
 base.parameters.distance=193;ok,reason=actions.validate(state,base,authority);eq(ok,nil);eq(reason,'invalid_follow_distance')
 base.parameters.distance=192.5;ok,reason=actions.validate(state,base,authority);eq(ok,nil);eq(reason,'invalid_follow_distance')
 base.parameters.distance=192;base.display_name='Follow';base.confirmation_required=false;base.followup_enabled=true
 local mapped=actions.validate(state,base,authority);eq(mapped.display_name,'Follow');eq(mapped.confirmation_required,false);eq(mapped.followup_enabled,true)
 truthy(actions.result(state,'a','succeeded',nil,{}));eq(actions.result(state,'a','failed','x',{}),nil)
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
 local mapped=protocol.dialogueDeliveryResult(delivery);eq(mapped.schema,'lorkhan.dialogue-delivery-result.v1');eq(mapped.status,'played')
 delivery.reason_code='../../file';mapped,reason=protocol.dialogueDeliveryResult(delivery);eq(mapped,nil);eq(reason,'invalid_reason_code')
end)
test('tier zero inspect report is closed and capability gated',function()
 local state=actions.new({'action.inspect.report'}) local registry=identity.Registry();registry:activate(npc,{});registry:activate(playerId,{})
 local authority={generation=2,session_id='s',actor=npc,resolve=function(id)return registry:resolve(id)end,expired=function()return false end}
 local intent={schema='lorkhan.action-intent.v1',action_id='inspect',request_id='r',turn_id='inspect-turn',session_id='s',generation=2,name='inspect.report',tier=0,actor=npc,target=playerId,parameters={},expires_at='soon'}
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
 result=actions.canonicalResult(internal,correlation,'2026-07-19T00:00:00Z');eq(result.completed_at,'2026-07-19T00:00:00Z');eq(result.schema,'lorkhan.action-result.v1');eq(result.session_id,UUID.session)
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
 local descriptor={media_id='00000000-0000-4000-8000-000000000005',dialogue_message_id=UUID.message,sha256=string.rep('a',64),bytes=4,codec='ogg',duration_ms=100,expires_at='2026-07-19T21:00:00Z'}
 local complete=event(2,'dialogue.complete',1,{speaker=npc,addressee=playerId,text='Hello.'});complete.message_id=UUID.message
 b.results={responseEvent(1,{dialogueLine(0,UUID.message,npc,playerId,'Hello.',true,true)},1),complete,
  event(3,'speech.ready',1,descriptor)}
 eq(orchestrator.poll(s),3);eq(#b.prepared,1);eq(b.prepared[1].media_id,descriptor.media_id);eq(b.prepared[1].path,nil);eq(b.prepared[1].url,nil)
 b.media[descriptor.media_id]={state='ready'};orchestrator.poll(s)
 local speak=emitted[#emitted];eq(speak.name,'LORKHAN_ACTOR_SPEAK');eq(speak.payload.media_id,descriptor.media_id);eq(speak.payload.subtitle,'Hello.');eq(speak.payload.generation,1);eq(speak.payload.dialogue_message_id,UUID.message);eq(speak.payload.session_id,UUID.session);eq(speak.payload.tts_volume_boost,4)
  truthy(orchestrator.speechStatus(s,{media_id=descriptor.media_id,active=false,status='played'}));truthy(s.responseQueue.unfinished==false);eq(s.activeSpeechMediaId,nil)
  orchestrator.lifecycle(s,'load');truthy(s.responseQueue.unfinished==false)
 end)
test('Close rechat preserves its group through one correlated continuation',function()
 for _,freshItems in ipairs({{{record_id='new_dagger',count=2}}, {}}) do
 local contextRequest
 local busy=fake.identity('npc','busy_actor',4)
 local b=fake.bridge() local s
 s=orchestrator.new(b,function(name,payload)
  if name=='LORKHAN_RECHAT_CONTEXT_REQUEST' then contextRequest=payload end
 end,function(actorIdentity,name,payload)
  if name=='LORKHAN_ACTOR_CONVERSATION_STATE_REQUEST' then
   orchestrator.actorCombatStatus(s,{actor=actorIdentity,hostile_to_player=false,activity='idle',
    conversation_state=identity.same(actorIdentity,busy) and 'busy' or 'active',conversation_state_proven=true,
    probe_id=payload.probe_id})
  end
  return true
 end)
 s.settings={behavior={rechat=true,rechatMaxDepth=2},presentation={ttsVolumeBoost=3}}
 s.dialogueMode='Close'
 orchestrator.configureSession(s,UUID.session);orchestrator.activate(s,npc,{})
 orchestrator.activate(s,enemy,{});orchestrator.activate(s,busy,{})
 truthy(conversation.setTarget(s.conversation,npc))
 truthy(conversation.addAudience(s.conversation,enemy));truthy(conversation.addAudience(s.conversation,busy))
 truthy(orchestrator.submitText(s,{message_id=UUID.message,request_id=UUID.request,turn_id=UUID.turn,
  installation_id='00000000-0000-4000-8000-000000000060',profile_id='00000000-0000-4000-8000-000000000061',
  playthrough_id='00000000-0000-4000-8000-000000000062',created_at='2026-07-19T20:00:00Z',platform='windows',
  content_fingerprint='sha256:'..string.rep('a',64),text='Hello.',input_key='player:1',language='en-US',
  speaker=playerId,context={targetState={inventory={items={{record_id='old_dagger',count=1}},total=1,truncated=false}}},capabilities={'dialogue.text','speech.say'},recent_action_results={},ui_source='lorkhan_text'}))
 local dialogue=event(2,'dialogue.complete',1,{speaker=npc,addressee=playerId,text='Greetings.'});dialogue.message_id=UUID.message
 local descriptor={media_id='00000000-0000-4000-8000-000000000005',dialogue_message_id=UUID.message,
  sha256=string.rep('a',64),bytes=4,codec='ogg',duration_ms=100,expires_at='2026-07-19T21:00:00Z'}
 b.results={responseEvent(1,{dialogueLine(0,UUID.message,npc,playerId,'Greetings.',true,true)},1),dialogue,
  event(3,'speech.ready',1,descriptor),event(4,'turn.complete',1,{status='complete'})}
 eq(orchestrator.poll(s),4);eq(#b.submitted,1)
 b.media[descriptor.media_id]={state='ready'};orchestrator.poll(s);eq(#b.submitted,1)
 truthy(orchestrator.speechStatus(s,{media_id=descriptor.media_id,active=false,status='played'}))
 truthy(orchestrator.pollRechatEligibility(s,0))
 eq(#b.submitted,1);truthy(contextRequest);eq(s.rechat.depth,0)
 contextRequest.context={targetState={inventory={items=freshItems,total=#freshItems,truncated=false}}}
 local original=contextRequest.generation
 contextRequest.generation=original+1;eq(orchestrator.rechatContext(s,contextRequest),false)
 contextRequest.generation=original
 local session=contextRequest.session_id;contextRequest.session_id=UUID.request
 eq(orchestrator.rechatContext(s,contextRequest),false);contextRequest.session_id=session
 local chain=contextRequest.chain_id;contextRequest.chain_id=UUID.request
 eq(orchestrator.rechatContext(s,contextRequest),false);contextRequest.chain_id=chain
 contextRequest.depth=2;eq(orchestrator.rechatContext(s,contextRequest),false);contextRequest.depth=1
 contextRequest.target=enemy;eq(orchestrator.rechatContext(s,contextRequest),false);contextRequest.target=npc
 local target=s.conversation.target;s.conversation.target=enemy
 eq(orchestrator.rechatContext(s,contextRequest),false);s.conversation.target=target
 local origin=s.conversation.turn.turnId;s.conversation.turn.turnId=UUID.request
 eq(orchestrator.rechatContext(s,contextRequest),false);s.conversation.turn.turnId=origin
 truthy(orchestrator.rechatContext(s,contextRequest));eq(orchestrator.rechatContext(s,contextRequest),false)
 eq(#b.submitted[2].payload.context.targetState.inventory.items,#freshItems)
 if #freshItems>0 then eq(b.submitted[2].payload.context.targetState.inventory.items[1].record_id,'new_dagger') end
 eq(#b.submitted,2);eq(b.submitted[2].payload.ui_source,'lorkhan_rechat')
 eq(b.submitted[2].payload.context.rechat.rechat_depth,1);eq(b.submitted[2].payload.context.rechat.origin_turn_id,UUID.turn)
 eq(b.submitted[2].payload.context.rechat.origin_line,'Hello.')
 truthy(identity.same(b.submitted[2].payload.context.rechat.speaker,npc))
 truthy(identity.same(b.submitted[2].payload.context.rechat.listener_hint,playerId))
 truthy(identity.same(b.submitted[2].payload.context.rechat.rechat_target_hint,npc))
 eq(b.submitted[2].payload.context.dialogueMode,'Close');eq(#b.submitted[2].payload.audience,3)
 truthy(identity.same(b.submitted[2].payload.audience[1],npc))
 truthy(identity.same(b.submitted[2].payload.audience[2],enemy))
 truthy(identity.same(b.submitted[2].payload.audience[3],busy))
 local participantStates=b.submitted[2].payload.context.rechat.participant_states
 eq(#participantStates,3);eq(participantStates[1].state,'active')
 eq(participantStates[2].state,'active');eq(participantStates[3].state,'busy')
 eq(s.rechat.requestInFlight,true)
 eq(s.rechat.originTurnId,UUID.turn)
 end
end)
test('rechat cancels when the previous speaker is freshly busy',function()
 local b=fake.bridge() local s
 s=orchestrator.new(b,nil,function(actorIdentity,name,payload)
  if name=='LORKHAN_ACTOR_CONVERSATION_STATE_REQUEST' then
   orchestrator.actorCombatStatus(s,{actor=actorIdentity,hostile_to_player=false,activity='combat',
    conversation_state=identity.same(actorIdentity,npc) and 'busy' or 'active',conversation_state_proven=true,
    probe_id=payload.probe_id})
  end
  return true
 end)
 s.settings={behavior={rechat=true,rechatMaxDepth=2},presentation={ttsVolumeBoost=3}}
 orchestrator.configureSession(s,UUID.session);orchestrator.activate(s,npc,{});orchestrator.activate(s,enemy,{})
 truthy(conversation.setTarget(s.conversation,npc));truthy(conversation.addAudience(s.conversation,enemy))
 truthy(orchestrator.submitText(s,{message_id=UUID.message,request_id=UUID.request,turn_id=UUID.turn,
  installation_id=uuid(60),profile_id=uuid(61),playthrough_id=uuid(62),created_at='2026-07-19T20:00:00Z',
  platform='windows',content_fingerprint='sha256:'..string.rep('a',64),text='Hello.',input_key='player:busy',
  language='en-US',speaker=playerId,context={},capabilities={'dialogue.text','speech.say'},
  recent_action_results={},ui_source='lorkhan_text'}))
 local line=event(2,'dialogue.complete',1,{speaker=npc,addressee=playerId,text='Busy.'});line.message_id=UUID.message
 local media={media_id=uuid(5),dialogue_message_id=UUID.message,sha256=string.rep('a',64),bytes=4,
  codec='ogg',duration_ms=100,expires_at='2026-07-19T21:00:00Z'}
 b.results={responseEvent(1,{dialogueLine(0,UUID.message,npc,playerId,'Busy.',true,true)},1),line,
  event(3,'speech.ready',1,media),event(4,'turn.complete',1,{status='complete'})}
 eq(orchestrator.poll(s),4);b.media[media.media_id]={state='ready'};orchestrator.poll(s)
 truthy(orchestrator.speechStatus(s,{media_id=media.media_id,active=false,status='played'}))
 eq(orchestrator.pollRechatEligibility(s,0),false);eq(#b.submitted,1);truthy(s.rechat.cancelled)
end)
test('rechat probe ignores an unproven compatibility fallback',function()
 local s=orchestrator.new(fake.bridge()) local key=identity.key(npc)
 s.rechatEligibility={probeId=UUID.message,expected={[key]=true},states={}}
 orchestrator.actorCombatStatus(s,{actor=npc,hostile_to_player=false,activity='idle',conversation_state='active',
  conversation_state_proven=false,probe_id=UUID.message})
 eq(s.rechatEligibility.states[key],nil)
 s.rechat={chainId=UUID.message,cancelled=false}
 s.rechatEligibility={pendingArgs={},chainId=UUID.message,elapsed=0}
 eq(orchestrator.pollRechatEligibility(s,0.5),false);truthy(s.rechatEligibility)
 eq(orchestrator.pollRechatEligibility(s,0.5),false);eq(s.rechatEligibility,nil);truthy(s.rechat.cancelled)

end)
test('multi-speaker media plays in dialogue order without overlap',function()
 local b=fake.bridge() local sent={}
 local s=orchestrator.new(b,nil,function(_,name,payload)table.insert(sent,{name=name,payload=payload})return true end)
 orchestrator.configureSession(s,UUID.session);s.conversation.turn={requestId=UUID.request,turnId=UUID.turn,generation=1,status='accepted',terminal=false}
 local first=event(2,'dialogue.complete',1,{speaker=npc,addressee=playerId,text='First.'})
 first.message_id='00000000-0000-4000-8000-000000000041'
 local secondSpeaker=enemy
 local second=event(4,'dialogue.complete',1,{speaker=secondSpeaker,addressee=playerId,text='Second.'})
 second.message_id='00000000-0000-4000-8000-000000000042'
 local one={media_id='00000000-0000-4000-8000-000000000031',dialogue_message_id=first.message_id,sha256=string.rep('a',64),bytes=4,codec='ogg',duration_ms=100,expires_at='2026-07-19T21:00:00Z'}
 local two={media_id='00000000-0000-4000-8000-000000000032',dialogue_message_id=second.message_id,sha256=string.rep('b',64),bytes=4,codec='ogg',duration_ms=100,expires_at='2026-07-19T21:00:00Z'}
 b.results={responseEvent(1,{dialogueLine(0,first.message_id,npc,playerId,'First.',false,true),
  dialogueLine(1,second.message_id,secondSpeaker,playerId,'Second.',true,true)},1),first,
  event(3,'speech.ready',1,one),second,event(5,'speech.ready',1,two)}
 eq(orchestrator.poll(s),5)
 b.media[one.media_id]={state='ready'}
 orchestrator.poll(s);eq(#sent,1);eq(sent[1].payload.media_id,one.media_id)
 orchestrator.speechStatus(s,{media_id=one.media_id,active=false,status='played'})
 b.media[two.media_id]={state='ready'}
 orchestrator.poll(s);eq(#sent,2);eq(sent[2].payload.media_id,two.media_id)
 eq(#s.conversation.transcript,2);eq(s.conversation.transcript[1].text,'First.');eq(s.conversation.transcript[2].text,'Second.')
end)
test('canonical FIFO gates rolecommands behind terminal dialogue delivery',function()
 local b=fake.bridge() local sent={}
 local s=orchestrator.new(b,nil,function(_,name,payload)table.insert(sent,{name=name,payload=payload})return true end)
 orchestrator.configureSession(s,UUID.session);s.conversation.turn={requestId=UUID.request,turnId=UUID.turn,generation=1,status='accepted',terminal=false}
 local lineId=uuid(140);local actionLineId=uuid(141);local actionId=uuid(142)
 local dialogue=event(2,'dialogue.complete',1,{speaker=npc,addressee=playerId,text='Follow me.'});dialogue.message_id=lineId
 local intent={schema='lorkhan.action-intent.v1',action_id=actionId,request_id=UUID.request,turn_id=UUID.turn,
  session_id=UUID.session,generation=1,name='ai.follow',tier=1,actor=npc,target=playerId,
  parameters={distance=192},expires_at='2026-07-19T21:00:00Z'}
 local actionEvent=event(3,'action.intent',1,intent);actionEvent.message_id=actionLineId
 b.results={responseEvent(1,{dialogueLine(0,lineId,npc,playerId,'Follow me.',true,false),
  actionLine(1,actionLineId,npc,playerId,'ai.follow',{'distance=192'})},1),dialogue,actionEvent,
  event(4,'turn.complete',1,{status='complete'})}
 eq(orchestrator.poll(s),4);eq(#sent,1);eq(sent[1].name,'LORKHAN_ACTOR_SUBTITLE')
 truthy(orchestrator.speechStatus(s,{media_id=lineId,active=false,status='played'}))
 eq(#sent,2);eq(sent[2].name,'LORKHAN_ACTOR_ACTION');eq(sent[2].payload.action_id,actionId)
 truthy(orchestrator.actionResult(s,{result={action_id=actionId}}));truthy(s.responseQueue.unfinished==false)
 local snapshot=require('scripts.LORKHAN.response_queue').snapshot(s.responseQueue)
 eq(snapshot.dispatched,2);eq(snapshot.completed,2);eq(snapshot.pending_dialogue,0);eq(snapshot.pending_actions,0)
end)
test('policy confirmation override and one result follow-up cross the ordered lane',function()
 local b=fake.bridge() local sent={}
 local s=orchestrator.new(b,nil,function(_,name,payload)table.insert(sent,{name=name,payload=payload})return true end)
 orchestrator.configureSession(s,UUID.session);orchestrator.activate(s,npc,{})
 truthy(conversation.setTarget(s.conversation,npc))
 truthy(orchestrator.submitText(s,{message_id=UUID.message,request_id=UUID.request,turn_id=UUID.turn,
  installation_id=uuid(60),profile_id=uuid(61),playthrough_id=uuid(62),created_at='2026-07-19T20:00:00Z',
  platform='windows',content_fingerprint='sha256:'..string.rep('a',64),text='Start combat.',input_key='player:action',
  language='en-US',speaker=playerId,context={},capabilities={'dialogue.text','action.combat.start',
  'action.confirmation','action.result-followup'},recent_action_results={},ui_source='lorkhan_text'}))
 local lineId=uuid(170);local actionId=uuid(171)
 local intent={schema='lorkhan.action-intent.v1',action_id=actionId,request_id=UUID.request,turn_id=UUID.turn,
  session_id=UUID.session,generation=1,name='combat.start',display_name='Engage',tier=2,actor=npc,target=playerId,
  confirmation_required=false,followup_enabled=true,parameters={},expires_at='2026-07-19T21:00:00Z'}
 local actionEvent=event(2,'action.intent',1,intent);actionEvent.message_id=lineId
 b.results={responseEvent(1,{actionLine(0,lineId,npc,playerId,'combat.start',{})},1),actionEvent,
  event(3,'turn.complete',1,{status='complete'})}
 eq(orchestrator.poll(s),3);eq(#sent,1);eq(sent[1].name,'LORKHAN_ACTOR_ACTION')
 local result={schema='lorkhan.action-result.v1',message_id=uuid(172),request_id=UUID.request,action_id=actionId,
  turn_id=UUID.turn,session_id=UUID.session,generation=1,status='succeeded',reason_code='combat_started',
  observed={target='mudcrab'},completed_at='2026-07-19T20:00:04Z'}
 truthy(b.submitActionResult(result));truthy(orchestrator.actionResult(s,{result=result}))
 eq(#b.submitted,2);eq(b.submitted[2].payload.ui_source,'lorkhan_action_followup')
 local recent=b.submitted[2].payload.recent_action_results;eq(#recent,1);eq(recent[1].action_id,actionId)
 eq(#s.actionFollowups.pending,0);truthy(s.actionFollowups.seen[actionId])
end)
test('halt actions cancels queued rolecommands and reports terminal receipts',function()
 local b=fake.bridge() local sent={}
 local s=orchestrator.new(b,nil,function(_,name,payload)table.insert(sent,{name=name,payload=payload})return true end)
 orchestrator.configureSession(s,UUID.session);s.conversation.turn={requestId=UUID.request,turnId=UUID.turn,generation=1,status='accepted',terminal=false}
 orchestrator.activate(s,npc,{});s.attachments[identity.key(npc)]=npc
 local dialogueId=uuid(150);local firstLineId=uuid(151);local secondLineId=uuid(152)
 local firstActionId=uuid(153);local secondActionId=uuid(154)
 local dialogue=event(2,'dialogue.complete',1,{speaker=npc,addressee=playerId,text='Wait here.'});dialogue.message_id=dialogueId
 local first={schema='lorkhan.action-intent.v1',action_id=firstActionId,turn_id=UUID.turn,name='ai.follow',tier=1,
  actor=npc,target=playerId,parameters={distance=192},expires_at='2026-07-19T21:00:00Z'}
 local second={schema='lorkhan.action-intent.v1',action_id=secondActionId,turn_id=UUID.turn,name='ai.stop',tier=1,
  actor=npc,target=playerId,parameters={},expires_at='2026-07-19T21:00:00Z'}
 local firstEvent=event(3,'action.intent',1,first);firstEvent.message_id=firstLineId
 local secondEvent=event(4,'action.intent',1,second);secondEvent.message_id=secondLineId
 b.results={responseEvent(1,{dialogueLine(0,dialogueId,npc,playerId,'Wait here.',true,false),
  actionLine(1,firstLineId,npc,playerId,'ai.follow',{'distance=192'}),
  actionLine(2,secondLineId,npc,playerId,'ai.stop',{})},1),dialogue,firstEvent,secondEvent,
  event(5,'turn.complete',1,{status='complete'})}
 eq(orchestrator.poll(s),5);eq(sent[1].name,'LORKHAN_ACTOR_SUBTITLE')
 truthy(orchestrator.haltActions(s,'user_halt_actions'));eq(#b.actionResults,2)
 eq(b.actionResults[1].status,'cancelled');eq(b.actionResults[2].reason_code,'user_halt_actions')
 truthy(orchestrator.speechStatus(s,{media_id=dialogueId,active=false,status='played'}))
 eq(#sent,2);eq(sent[2].name,'LORKHAN_ACTOR_HALT_ACTIONS')
 local snapshot=require('scripts.LORKHAN.response_queue').snapshot(s.responseQueue)
 eq(snapshot.pending_actions,0);truthy(snapshot.unfinished==false)
end)
test('successful End Conversation suppresses Rechat and result followups',function()
 local b=fake.bridge() local sent={}
 local s=orchestrator.new(b,nil,function(_,name,payload)sent[#sent+1]={name=name,payload=payload};return true end)
 orchestrator.configureSession(s,UUID.session)
 s.conversation.turn={requestId=UUID.request,turnId=UUID.turn,generation=1,status='accepted',terminal=false}
 orchestrator.activate(s,npc,{});s.attachments[identity.key(npc)]=npc
 local lineId=uuid(185);local actionId=uuid(186)
 local intent={schema='lorkhan.action-intent.v1',action_id=actionId,request_id=UUID.request,turn_id=UUID.turn,
  session_id=UUID.session,generation=1,name='conversation.end',tier=1,actor=npc,target=playerId,
  followup_enabled=true,parameters={},expires_at='2026-07-19T21:00:00Z'}
 local actionEvent=event(2,'action.intent',1,intent);actionEvent.message_id=lineId
 b.results={responseEvent(1,{actionLine(0,lineId,npc,playerId,'conversation.end',{})},1),actionEvent,
  event(3,'turn.complete',1,{status='complete'})}
 eq(orchestrator.poll(s),3);eq(sent[1].name,'LORKHAN_ACTOR_ACTION')
 s.rechat={lastSpeaker=npc};s.rechatSeed={};s.rechatEligibility={}
 local result={action_id=actionId,status='succeeded',reason_code='conversation_ended'}
 truthy(orchestrator.actionResult(s,{result=result}));eq(s.rechat,nil);eq(s.rechatSeed,nil);eq(s.rechatEligibility,nil)
 eq(#s.actionFollowups.pending,0);eq(#b.submitted,0)
end)
test('narrator media uses the ordered player-local speech lane',function()
 local b=fake.bridge() local emitted={} local actorSends=0
 local s=orchestrator.new(b,function(name,payload)table.insert(emitted,{name=name,payload=payload})end,
  function()actorSends=actorSends+1 return true end)
 orchestrator.configureSession(s,UUID.session);s.conversation.turn={requestId=UUID.request,turnId=UUID.turn,generation=1,status='accepted',terminal=false}
 local narrator=fake.identity('narrator','lorkhan:narrator',0);narrator.display_name='The Narrator'
 local media={media_id='00000000-0000-4000-8000-000000000033',dialogue_message_id=UUID.message,sha256=string.rep('c',64),bytes=4,codec='ogg',duration_ms=100,expires_at='2026-07-19T21:00:00Z'}
 local dialogue=event(2,'dialogue.complete',1,{speaker=narrator,addressee=playerId,text='The fog gathers.'});dialogue.message_id=UUID.message
 b.results={responseEvent(1,{dialogueLine(0,UUID.message,narrator,playerId,'The fog gathers.',true,true)},1),
  dialogue,event(3,'speech.ready',1,media)};eq(orchestrator.poll(s),3)
 b.media[media.media_id]={state='ready'};orchestrator.poll(s)
 eq(actorSends,0);eq(emitted[#emitted].name,'LORKHAN_NARRATOR_SPEAK');eq(emitted[#emitted].payload.actor.kind,'narrator')
end)
test('actor is self-only and detach stops owned state',function()
 local st=actor.new(npc,2,{'action.ai.follow'}) local stopped=0 local playedBoost
 local adapter={followSelf=function()return true end,playSpeech=function(_,_,_,volumeBoost)playedBoost=volumeBoost return true end,stopSpeech=function()stopped=stopped+1 end,stopAi=function()stopped=stopped+1 return true end}
 local registry=identity.Registry();registry:activate(npc,{});registry:activate(playerId,{})
 local cmd={schema='lorkhan.action-intent.v1',action_id='a',request_id='r',turn_id='t',session_id='s',generation=2,name='ai.follow',tier=1,actor=npc,target=playerId,parameters={distance=192},expires_at='x'}
 local result=actor.execute(st,cmd,adapter,{session_id='s',resolve=function(id)return registry:resolve(id)end,expired=function()return false end});eq(result.status,'succeeded');eq(result.kind,'lorkhan.internal.action-terminal')
 actor.speak(st,{generation=2,actor=npc,media_id='opaque',request_id='r',turn_id='t',session_id='s',dialogue_message_id='d',expires_at='x',tts_volume_boost=4},adapter,{expired=function()return false end});eq(st.activeSpeech.mediaId,'opaque');eq(playedBoost,4);actor.detach(st,adapter);eq(st.attached,false);eq(stopped,2)
end)
test('ordinary halt interrupts owned work and keeps the bridge recoverable',function()
 local b=fake.bridge() local sent={}
 local s=orchestrator.new(b,nil,function(_,name)table.insert(sent,name)return true end)
 orchestrator.activate(s,npc,{}) s.attachments[identity.key(npc)]=npc truthy(conversation.setTarget(s.conversation,npc))
 orchestrator.halt(s);eq(b.halted,false);eq(b.cancelled[1],1);eq(s.conversation.target.record_id,npc.record_id)
 eq(sent[1],'LORKHAN_ACTOR_STOP_SPEECH');eq(sent[2],'LORKHAN_ACTOR_STOP');eq(s.hardHalted,false)
end)
test('travel and escort require player-captured bounded destinations and retain owned package identity',function()
 local registry=identity.Registry();registry:activate(npc,{});registry:activate(playerId,{})
 local authority={generation=2,session_id='s',actor=npc,resolve=function(id)return registry:resolve(id)end,
  expired=function()return false end}
 local parameters={destination_x=128.5,destination_y=-64,destination_z=12,destination_cell='exterior:0:0'}
 local state=actions.new({'action.ai.travel','action.ai.escort','action.ai.stop'})
 local intent={schema='lorkhan.action-intent.v1',action_id='travel',request_id='r',turn_id='movement',session_id='s',
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
 local stop={schema='lorkhan.action-intent.v1',action_id='travel-stop',request_id='r',turn_id='movement',session_id='s',
  generation=2,name='ai.stop',tier=1,actor=npc,target=playerId,parameters={},expires_at='soon'}
 result=actor.execute(actorState,stop,adapter,authority);eq(result.status,'succeeded')
 eq(stopped.destination.destination_x,128.5)
end)
test('face action reports only observed completion and cancels cleanly',function()
 local registry=identity.Registry();registry:activate(npc,{});registry:activate(playerId,{})
 local authority={generation=2,session_id='s',actor=npc,resolve=function(id)return registry:resolve(id)end,
  expired=function()return false end}
 local intent={schema='lorkhan.action-intent.v1',action_id='face',message_id=UUID.message,request_id=UUID.request,
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
test('ending conversation releases only owned packages and reports cleanup failures',function()
 local authority={generation=2,session_id='s',actor=npc,resolve=function()return {}end,expired=function()return false end}
 local intent={schema='lorkhan.action-intent.v1',action_id='end',request_id='r',turn_id='t',session_id='s',
  generation=2,name='conversation.end',tier=1,actor=npc,target=playerId,parameters={},expires_at='soon'}
 local state=actor.new(npc,2,{'action.conversation.end'});state.ownedAi={type='Follow'};state.ownedCombat={target=playerId}
 local stopped={}
 local result=actor.execute(state,intent,{stopAi=function(owned)stopped.ai=owned.type;return true end,
  stopCombat=function(target)stopped.combat=target;return true end},authority)
 eq(result.status,'succeeded');eq(result.reason,'conversation_ended');eq(stopped.ai,'Follow');eq(stopped.combat,playerId)
 eq(state.ownedAi,nil);eq(state.ownedCombat,nil)
 state=actor.new(npc,2,{'action.conversation.end'});state.ownedAi={type='Follow'}
 result=actor.execute(state,intent,{stopAi=function()return false,'cleanup_failed'end},authority)
 eq(result.status,'failed');eq(result.reason,'cleanup_failed');eq(state.ownedAi.type,'Follow')
 state=actor.new(npc,2,{'action.conversation.end'});intent.parameters={script='tgm'}
 result=actor.execute(state,intent,{},authority);eq(result.status,'rejected')
end)
test('typed player action request remains inside the strict turn envelope',function()
 local dto,reason=protocol.turn({message_id=UUID.message,request_id=UUID.request,turn_id=UUID.turn,
  installation_id='00000000-0000-4000-8000-000000000010',profile_id='00000000-0000-4000-8000-000000000011',
  playthrough_id='00000000-0000-4000-8000-000000000012',session_id=UUID.session,generation=1,runtime_generation=3,
  created_at='2026-08-01T00:00:00Z',platform='windows',content_fingerprint='sha256:'..string.rep('a',64),
  text='Attack the mudcrab',language='en-US',mood={kind='angry'},speaker=playerId,target=npc,audience={npc},context={},capabilities={'action.combat.start'},
  ui_source='lorkhan_action_menu',action_request={name='combat.start',tier=2,parameters={},target=enemy}})
 truthy(dto,reason);eq(dto.payload.action_request.name,'combat.start');eq(dto.payload.action_request.target.record_id,'mudcrab')
 eq(dto.payload.input.mood.kind,'angry')
 eq(dto.runtime_generation,3)
 dto,reason=protocol.turn({message_id=UUID.message,request_id=UUID.request,turn_id=UUID.turn,
  installation_id='00000000-0000-4000-8000-000000000010',profile_id='00000000-0000-4000-8000-000000000011',
  playthrough_id='00000000-0000-4000-8000-000000000012',session_id=UUID.session,generation=1,runtime_generation=3,
  created_at='2026-08-01T00:00:00Z',platform='windows',content_fingerprint='sha256:'..string.rep('a',64),
  text='Bad',language='en-US',speaker=playerId,target=npc,audience={npc},context={},capabilities={},
  ui_source='lorkhan_action_menu',action_request={name='../run',tier=1,parameters={}}})
 eq(dto,nil);eq(reason,'invalid_action_request')
end)
test('inventory observations are changed-only bounded and fenced from failed reads and sessions',function()
 local state={} local playerState=require('scripts.LORKHAN.player_state')
 local session={session_id=UUID.session,generation=1}
 local observation={session_id=UUID.session,generation=1,actor=npc}
 local signature='initial' local available=true local accepted=true local calls=0
 local function read()if available then return {owner=npc,items={}},signature end end
 local function submit()calls=calls+1;return accepted end
 truthy(playerState.observeInventory(state,observation,session,read,submit,10));eq(calls,1)
 eq(playerState.observeInventory(state,observation,session,read,submit,10),false);eq(calls,1)
 truthy(playerState.observeInventory(state,observation,session,read,submit,310));eq(calls,2)
 eq(playerState.observeInventory(state,observation,session,read,submit,311),false);eq(calls,2)
 available=false;eq(playerState.observeInventory(state,observation,session,read,submit,312),false);eq(calls,2)
 available=true;signature='';accepted=false
 eq(playerState.observeInventory(state,observation,session,read,submit,10),false)
 accepted=true;truthy(playerState.observeInventory(state,observation,session,read,submit,10))
 observation.generation=2;eq(playerState.observeInventory(state,observation,session,read,submit,10),false)
 session.generation=2;truthy(playerState.observeInventory(state,observation,session,read,submit,10))
 local emitted=0 local scheduler=orchestrator.new(fake.bridge(),function(name)if name=='LORKHAN_INVENTORY_OBSERVE' then emitted=emitted+1 end end)
 orchestrator.configureSession(scheduler,UUID.session);orchestrator.activate(scheduler,npc,{})
 require('scripts.LORKHAN.agent_registry').activate(scheduler.agents,npc,'auto',1)
 truthy(orchestrator.pollInventoryObservations(scheduler,0));eq(emitted,1)
 eq(orchestrator.pollInventoryObservations(scheduler,1),false);eq(emitted,1)
 truthy(orchestrator.pollInventoryObservations(scheduler,1));eq(emitted,2)
end)
test('managed agents activate in bounded batches and manual pins survive distance cleanup',function()
 local b=fake.bridge() local managed=0 local detached=0 local agentEvents=0 local profileEvents=0
 local s=orchestrator.new(b,function(name,payload)
   if name=='LORKHAN_AGENTS'then agentEvents=agentEvents+1
   elseif name=='LORKHAN_AUTO_ACTIVATED'then profileEvents=profileEvents+1;truthy(payload.actor.kind=='npc') end
  end,
  function(_,name)if name=='LORKHAN_ACTOR_DETACH'then detached=detached+1 end return true end,
  function()managed=managed+1 return true end)
 local candidates={}
 for i=1,8 do
  local actorId=fake.identity('npc','agent'..i,20+i)
  orchestrator.activate(s,actorId,{})
  candidates[i]={identity=actorId,distance=i*10,maxDistance=1200,dead=false,hostile=false,available=true}
 end
 eq(orchestrator.scanAgents(s,candidates),6);eq(#agentRegistry.snapshot(s.agents),6);eq(agentEvents,1);eq(profileEvents,6)
 eq(orchestrator.scanAgents(s,candidates),2);eq(managed,8);eq(agentEvents,2);eq(profileEvents,8)
 eq(orchestrator.scanAgents(s,candidates),0);eq(agentEvents,2);eq(profileEvents,8)
 local actor,status=orchestrator.manageCandidate(s,candidates[1],'manual');truthy(actor);eq(status,'upgraded')
 eq(agentEvents,3)
 for _=1,4 do orchestrator.scanAgents(s,{}) end
 eq(agentEvents,4)
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
 request.recent_action_results={};request.ui_source='lorkhan_text'
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
  request.capabilities={'dialogue.text'};request.recent_action_results={};request.ui_source='lorkhan_text'
  truthy(orchestrator.submitText(s,request))
  return b.submitted[1].payload
 end
 local standard=submit('Standard',false,300);eq(#standard.audience,2);eq(standard.context.dialogueMode,'Standard')
 local close=submit('Close',true,300);eq(#close.audience,2);eq(close.context.dialogueMode,'Close')
 local whisper=submit('Whisper',true,300);eq(#whisper.audience,1);eq(whisper.context.dialogueMode,'Whisper')
 local shout=submit('Shout',false,700);eq(#shout.audience,2);eq(shout.context.dialogueMode,'Shout')
end)
test('one-turn mode override strips its prefix and preserves the selected mode and rechat group',function()
 local b=fake.bridge() local s=orchestrator.new(b,nil,nil,function()return true end)
 local other=fake.identity('npc','one-shot-actor',92)
 s.settings={autoActivate={hearingDistance=500},behavior={rechat=true}}
 s.dialogueMode='Standard';orchestrator.configureSession(s,UUID.session)
 for _,actorId in ipairs({npc,other}) do orchestrator.activate(s,actorId,{}) end
 local function candidate(actorId,distance)
  return {identity=actorId,distance=distance,maxDistance=1200,dead=false,hostile=false,available=true}
 end
 truthy(orchestrator.selectTarget(s,candidate(npc,100)))
 truthy(orchestrator.manageCandidate(s,candidate(other,300),'auto'))
 truthy(orchestrator.addAudience(s,candidate(other,300)))
 local request=b.nextTurnMetadata();request.text='|| keep this between us';request.input_key='one-shot-close'
 request.language='en-US';request.speaker=playerId;request.context={};request.capabilities={'dialogue.text'}
 request.recent_action_results={};request.ui_source='lorkhan_text';request.mood={kind='suspicious'}
 truthy(orchestrator.submitText(s,request))
 local payload=b.submitted[1].payload
 eq(payload.input.text,'keep this between us');eq(payload.input.mood.kind,'suspicious')
 eq(payload.context.dialogueMode,'Close');eq(#payload.audience,2);eq(s.dialogueMode,'Standard')
 eq(s.rechatSeed.dialogueMode,'Close');eq(s.rechatSeed.mood,nil)
end)
test('spoken mood and selected mode survive transcription as typed protocol data',function()
 local b=fake.bridge() local s=orchestrator.new(b,nil,nil,function()return true end)
 orchestrator.configureSession(s,UUID.session);orchestrator.activate(s,npc,{})
 truthy(orchestrator.selectTarget(s,{identity=npc,distance=100,maxDistance=1200,dead=false,available=true}))
 truthy(orchestrator.startVoice(s,{speaker=playerId,context={},language='en-US',capabilities={'dialogue.text'},
  recent_action_results={},dialogueMode='Close',mood={kind='playful'}}))
 truthy(orchestrator.stopVoice(s));truthy(orchestrator.pollVoice(s))
 local transcript=event(1,'stt.transcript',1,{text='Tell me more.',language='en-US'})
 transcript.request_id='00000000-0000-4000-8000-000000000041'
 b.results={transcript};eq(orchestrator.poll(s),1)
 local payload=b.submitted[1].payload
 eq(payload.input.kind,'stt');eq(payload.input.text,'Tell me more.');eq(payload.input.mood.kind,'playful')
 eq(payload.context.dialogueMode,'Close')
end)
test('auto-managed actors attacking the player are removed unless explicitly allowed',function()
 local b=fake.bridge() local detached=0 local combatEvents={}
 local s=orchestrator.new(b,function(name,payload)
  if name=='LORKHAN_COMBAT_STATUS' then table.insert(combatEvents,payload) end
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
 removed,reason=orchestrator.actorCombatStatus(s,{actor=npc,hostile_to_player=false,
  activity='inactive',conversation_state='inactive'})
 truthy(removed);eq(reason,'inactive_removed');eq(#agentRegistry.snapshot(s.agents),0)
 orchestrator.lifecycle(s,'load');eq(combatEvents[#combatEvents].active,false);eq(combatEvents[#combatEvents].count,0)
end)
test('explicit hard halt clears queues and blocks submit',function()
 local b=fake.bridge() local s=orchestrator.new(b);orchestrator.hardHalt(s);truthy(b.halted);eq(s.conversation.target,nil)
 local ok,reason=orchestrator.submitText(s,{text='hi'});eq(ok,nil);eq(reason,'lorkhan_disabled')
end)
test('actor lifecycle stop and detach tolerate pre-init delivery',function()
 eq(actor.stop(nil,{}),nil);eq(actor.detach(nil,{}),nil);eq(actor.completeSpeech(nil),nil)
end)
test('player action does not consume vanilla activation',function()
 local s=player.new();eq(player.onAction(s,'Activate',function()end),false);truthy(player.onAction(s,'LORKHAN_Talk',function()end))
end)
test('text edit Enter becomes a single-line submit request',function()
 local value,submit=player.consumeTextEdit('Hello, Caius!\n');eq(value,'Hello, Caius! ');eq(submit,true)
 value,submit=player.consumeTextEdit('Still typing');eq(value,'Still typing');eq(submit,false)
 value,submit=player.consumeTextEdit('First\r\nSecond');eq(value,'First Second');eq(submit,true)
 value,submit=player.consumeTextEdit(nil);eq(value,'');eq(submit,false)
end)
test('player mood and typed prefixes stay separate from the saved dialogue mode',function()
 local uiState=require('scripts.LORKHAN.ui.state')
 local s=uiState.new()
 eq(s.mood,'None');eq(s.mode,'Standard');eq(uiState.moodSelection(s),nil);eq(uiState.effectiveMode(s),'Standard')
 eq(#uiState.MOODS,12);eq(uiState.MOODS[1],'None');eq(uiState.MOODS[#uiState.MOODS],'Custom')
 eq(#uiState.SHORTCUTS,3);eq(uiState.SHORTCUTS[1].prefix,'||')
 -- longest match wins and a prefix never rewrites the saved mode
 eq(uiState.refreshTurnPreview(s),false)
 s.input='|| stay close';truthy(uiState.refreshTurnPreview(s))
 eq(s.turnMode,'Close');eq(s.turnPrefix,'||');eq(s.mode,'Standard');eq(uiState.effectiveMode(s),'Close')
 eq(uiState.refreshTurnPreview(s),false)
 s.input='| just you';uiState.refreshTurnPreview(s);eq(s.turnMode,'Whisper');eq(s.turnPrefix,'|')
 s.input='!! everyone';uiState.refreshTurnPreview(s);eq(s.turnMode,'Shout');eq(s.mode,'Standard')
 s.input='?? nobody';uiState.refreshTurnPreview(s);eq(s.turnMode,nil);eq(uiState.effectiveMode(s),'Standard')
 s.input='!! everyone';uiState.refreshTurnPreview(s)
 uiState.clearTransient(s);eq(s.turnMode,nil);eq(s.turnPrefix,nil);eq(s.mode,'Standard')
 -- moods are shared by typed and spoken input and default to ordinary chat
 eq(uiState.setMood(s,'Narrator'),false);eq(s.mood,'None')
 truthy(uiState.setMood(s,'Angry'));eq(uiState.moodSelection(s).kind,'angry');eq(uiState.moodLabel(s),'Angry')
 truthy(uiState.setMood(s,'Custom'));eq(s.moodDirection,'');eq(uiState.moodSelection(s),nil)
 eq(uiState.moodLabel(s),'Custom (no direction set)')
 uiState.setMoodDirection(s,'  hushed and clipped\nsecond line')
 eq(s.moodDirection,'  hushed and clipped second line')
 eq(uiState.moodSelection(s).kind,'custom');eq(uiState.moodSelection(s).custom,'hushed and clipped second line')
 eq(#uiState.setMoodDirection(s,string.rep('x',200)),uiState.MOOD_DIRECTION_LIMIT)
 -- a capped direction stays valid UTF-8 instead of splitting a character in half
 local accent=string.char(0xC3,0xA9)
 eq(#uiState.setMoodDirection(s,string.rep('x',78)..accent),80)
 eq(#uiState.setMoodDirection(s,string.rep('x',79)..accent),81) -- 80 characters, kept whole
 eq(uiState.setMoodDirection(s,string.rep('x',79)..accent..'z'),string.rep('x',79)..accent)
 eq(#uiState.moodSummary(s),34) -- a long direction is shortened so it cannot crowd the chat status line
 -- the preview vocabulary and mood kinds stay identical to the parser that owns submitted turns
 local playerInput=require('scripts.LORKHAN.player_input')
 eq(uiState.SHORTCUTS,playerInput.SHORTCUTS);eq(uiState.MOOD_DIRECTION_LIMIT,playerInput.CUSTOM_LIMIT)
 local kinds={} for _,kind in ipairs(playerInput.MOODS) do kinds[kind]=true end
 for _,mood in ipairs(uiState.MOODS) do
  uiState.setMood(s,mood)
  if mood=='Custom' then uiState.setMoodDirection(s,'clipped') end
  local selection=uiState.moodSelection(s)
  if mood=='None' then eq(selection,nil) else truthy(kinds[selection.kind]) end
  for _,shortcut in ipairs(playerInput.SHORTCUTS) do
   local parsed=playerInput.parse(shortcut.prefix..' hello')
   eq(uiState.shortcutPreview(shortcut.prefix..' hello'),parsed.mode)
  end
 end
 truthy(uiState.setMood(s,'None'));eq(s.moodDirection,'');eq(uiState.moodSelection(s),nil)
 -- panels shared by Interact and Targeted NPC Tools return to whichever menu opened them
 eq(s.panelOrigin,'actor-tools');eq(uiState.backRoute(s).panel,'actor-tools')
 eq(uiState.backRoute(s).label,'Targeted NPC Tools')
 eq(uiState.setPanel(s,'diagnostics','conversation'),'diagnostics');eq(s.panelOrigin,'conversation')
 eq(uiState.backRoute(s).panel,'conversation');eq(uiState.backRoute(s).label,'Back to conversation')
 uiState.setPanel(s,'history') -- an origin-less panel change keeps the route the player arrived by
 eq(s.panel,'history');eq(uiState.backRoute(s).panel,'conversation')
 uiState.setPanel(s,'profile-menu','nowhere');eq(s.panelOrigin,'conversation')
 uiState.setPanel(s,'modes','actor-tools');eq(uiState.backRoute(s).panel,'actor-tools')
end)
test('focused UI builders keep chat selectors tools and notifications independent',function()
 local ui={TYPE={Text='text',Image='image',TextEdit='edit',Container='container'},content=function(value)return value end}
 local util={vector2=function(x,y)return{x=x,y=y}end,color={rgb=function(r,g,b)return{r=r,g=g,b=b}end}}
 local chatbox=require('scripts.LORKHAN.ui.chatbox')
 local uiState=require('scripts.LORKHAN.ui.state')
 -- every Interact entry gets its own callback so a mis-wired row cannot pass unnoticed
 local clicked
 local menuContext={ui=ui,util=util,target='Fargoth',text='',shortcuts=uiState.SHORTCUTS,
  onTextChanged=function()end,onKeyPress=function()end,onSend=function()end,onClose=function()end}
 for _,entry in ipairs(chatbox.MENU) do
  menuContext[entry.callback]=function() clicked=entry.key end
 end
 local chat=chatbox.build(menuContext)
 eq(chat[1].props.text,'Chat with Fargoth');eq(chat[#chat-1].props.text,'Send');eq(chat[#chat].props.text,'Close')
 eq(chat[2].props.text,'Mood: None  |  Mode: Standard')
 eq(chat[4].props.text,'One-turn prefixes: || Close, !! Shout, | Whisper.')
 -- the moved controls sit between the send hint and Send, in one compact clickable list
 local MENU_FIRST=6
 eq(#chatbox.MENU,9);eq(#chat,MENU_FIRST+#chatbox.MENU+1)
 local expected={'mood','autoChat','modes','model','profiles','settings','history','statusHud','diagnostics'}
 for index,entry in ipairs(chatbox.MENU) do
  eq(entry.key,expected[index])
  local row=chat[MENU_FIRST+index-1]
  eq(row.props.text,entry.key=='statusHud' and 'Status HUD: off'
   or entry.key=='autoChat' and 'Auto Chat: off' or entry.label)
  clicked=nil;row.events.mouseClick();eq(clicked,entry.key)
 end
 eq(chat[MENU_FIRST].props.text,'Mood')
 -- the status HUD entry reports the state it will leave behind, and toggles rather than navigates
 local hudShown=chatbox.build({ui=ui,util=util,target='Fargoth',text='',shortcuts=uiState.SHORTCUTS,
  statusHudVisible=true,onTextChanged=function()end,onKeyPress=function()end,
  onSend=function()end,onClose=function()end})
 eq(hudShown[MENU_FIRST+7].props.text,'Status HUD: on')
 eq(chatbox.statusHudLabel(true),'Status HUD: on');eq(chatbox.statusHudLabel(false),'Status HUD: off')
 eq(chatbox.autoChatLabel(true),'Auto Chat: on');eq(chatbox.autoChatLabel(false),'Auto Chat: off')
 -- the top-left HUD draws only while statusHudVisible is set, so no transient status leaks when it is off
 local hudSource=io.open(root..'/scripts/LORKHAN/player.lua')
 local hudBody=assert(hudSource:read('*a'):match('local function renderStatusHud%(%)(.-)\nend\n'));hudSource:close()
 truthy(hudBody:find('or not state.ui.statusHudVisible then',1,true))
 eq(hudBody:find('notification',1,true),nil)
 local prefixed=chatbox.build({ui=ui,util=util,target='Fargoth',text='|| stay close',
  mood='Custom: hushed',mode='Standard',turnMode='Close',turnPrefix='||',shortcuts=uiState.SHORTCUTS,
  onTextChanged=function()end,onKeyPress=function()end,onSend=function()end,onClose=function()end})
 eq(prefixed[2].props.text,'Mood: Custom: hushed  |  Mode: Close (this turn)')
 eq(prefixed[4].props.text,'Prefix "||" sends this turn as Close. Saved mode stays Standard.')
 eq(#prefixed,#chat) -- constant row structure keeps the live preview from rebuilding the text box
 local moodPanel=chatbox.buildMoodPanel({ui=ui,util=util,customVisible=true,customText='',customLimit=80,
  moods={{label='None',active=true,onSelect=function()end},{label='Custom',onSelect=function()end}},
  onCustomChanged=function()end,onCustomKeyPress=function()end,onBack=function()end,onClose=function()end})
 eq(moodPanel[1].props.text,'Player Mood');eq(moodPanel[3].props.text,'None  [active]')
 eq(moodPanel[4].props.text,'Custom');eq(moodPanel[5].props.text,'Custom delivery direction')
 eq(moodPanel[#moodPanel-1].props.text,'Back to conversation');eq(moodPanel[#moodPanel].props.text,'Close')
 local help=chatbox.buildShortcutHelp({ui=ui,util=util,shortcuts=uiState.SHORTCUTS})
 eq(help[1].props.text,'Typed one-turn shortcuts')
 eq(help[2].props.text,'|| before your message sends that one turn as Close.')
 eq(help[#help].props.text,'A prefix changes only the turn you submit. The mode selected above stays saved.')
 local choices=require('scripts.LORKHAN.ui.selector').build({ui=ui,util=util,title='Dialogue Mode',
  options={{label='Standard',active=true,onSelect=function()end}},onClose=function()end})
 eq(choices[1].props.text,'Dialogue Mode');eq(choices[2].props.text,'Standard  [active]')
 local tools=require('scripts.LORKHAN.ui.actor_tools').build({ui=ui,util=util,target='Fargoth',
  options={{label='Actor actions...',onSelect=function()end}},onClose=function()end})
 eq(tools[1].props.text,'Targeted NPC Tools');eq(tools[2].props.text,'Target: Fargoth')
 local saved,changed
 local settings=require('scripts.LORKHAN.ui.settings').build({ui=ui,util=util,wrap=function(callback)return callback end,
  editor={sections={}},field={kind='string',label='Personality'},value='Old text',
  save=function(value)saved=value end,changeValue=function(value)changed=value end,cancel=function()end,back=function()end})
 settings[3].events.textChanged('New text');settings[4].events.mouseClick()
 eq(changed,'New text');eq(saved,'New text') -- Save uses the edited widget value, not its initial snapshot.
 local notifications=require('scripts.LORKHAN.ui.notifications');local notice=notifications.new()
 truthy(notifications.show(notice,'queued',1));truthy(notifications.active(notice))
 eq(notifications.update(notice,0.5),false);eq(notifications.update(notice,0.5),true);eq(notifications.active(notice),false)
end)
test('LLM model panel keeps four semantic slots with async fallback and randomizer state',function()
 local ui={TYPE={Text='text',Image='image',TextEdit='edit',Container='container'},content=function(value)return value end}
 local util={vector2=function(x,y)return{x=x,y=y}end,color={rgb=function(r,g,b)return{r=r,g=g,b=b}end}}
 local uiState=require('scripts.LORKHAN.ui.state')
 local selector=require('scripts.LORKHAN.ui.selector')
 -- exactly the four fixed contract rows, in contract order
 local function slots(unavailable)
  local rows={}
  for _,entry in ipairs(uiState.MODEL_SLOTS) do
   local available=not (unavailable and unavailable[entry.key])
   rows[#rows+1]={key=entry.key,label=entry.label,available=available,
    configuration_id=available and uuid(200) or nil,configuration_name=available and 'Local' or nil,
    revision=available and 2 or nil,driver=available and 'configured' or nil,
    model=available and ('model-'..entry.key) or nil}
  end
  return rows
 end
 local function controls(selected,resolved,options)
  options=options or {}
  return {target=npc,selected_model_slot_key=selected,resolved_model_slot_key=resolved,
   pending=options.pending==true,model_slots=slots(options.unavailable),
   effective_settings={routing={llm_randomizer_enabled=options.randomized==true}}}
 end
 local function panel(view,select)
  return selector.buildModelSlots({ui=ui,util=util,view=view,select=select,
   onRefresh=function()end,backLabel='Back to conversation',onBack=function()end})
 end
 -- before any snapshot the panel is Standard-first, read-only, and already in its final shape
 local loading=uiState.modelSlotView(nil,nil)
 eq(loading.selected,'standard');eq(loading.loaded,false);eq(#loading.rows,4)
 local rows=panel(loading,{standard=function()end})
 eq(#rows,8);eq(rows[1].props.text,'LLM Model');eq(rows[2].props.text,'Loading server-owned choices...')
 eq(rows[3].props.text,'Standard');eq(rows[4].props.text,'Fast');eq(rows[5].props.text,'Powerful')
 eq(rows[6].props.text,'Experimental')
 for index=3,6 do eq(rows[index].events,nil) end -- opening the panel can never write a selection
 eq(rows[7].props.text,'Refresh choices');truthy(rows[7].events.mouseClick)
 eq(rows[8].props.text,'Back to conversation');truthy(rows[8].events.mouseClick)
 -- a loaded snapshot marks the active slot and carries one compact connector and model line per row
 local ready=uiState.modelSlotView(controls('standard','standard'),nil)
 eq(ready.rows[1].text,'Standard  [active]  |  Local / model-standard')
 eq(ready.rows[2].text,'Fast  |  Local / model-fast')
 eq(ready.message,'Active: Standard.');eq(ready.refreshable,true)
 local clicked
 local readyRows=panel(ready,{fast=function() clicked='fast' end})
 readyRows[4].events.mouseClick();eq(clicked,'fast')
 -- an unavailable slot reads as not configured, keeps no click event, and still shows the fallback
 local fallback=uiState.modelSlotView(controls('experimental','standard',{unavailable={experimental=true}}),nil)
 eq(fallback.rows[4].text,'Experimental  [selected]  |  not configured')
 eq(fallback.rows[4].clickable,false)
 eq(fallback.rows[1].text,'Standard  [active fallback]  |  Local / model-standard')
 eq(fallback.message,'Selected Experimental is not configured, so Standard is active.')
 local fallbackRows=panel(fallback,{experimental=function() clicked='experimental' end})
 eq(#fallbackRows,8);eq(fallbackRows[6].events,nil)
 -- one in-flight selection at a time, and every choice plus refresh stops accepting clicks
 local s=uiState.new({})
 truthy(uiState.beginModelSlot(s,'powerful'));eq(uiState.modelSlotBusy(s),true)
 eq(uiState.beginModelSlot(s,'fast'),false);eq(s.modelSlotPending,'powerful')
 local waiting=uiState.modelSlotView(controls('standard','standard',{pending=true}),s.modelSlotPending)
 eq(waiting.rows[3].text,'Powerful  [selecting...]  |  Local / model-powerful')
 eq(waiting.message,'Selecting Powerful...');eq(waiting.refreshable,false)
 local waitingRows=panel(waiting,{standard=function()end,fast=function()end,
  powerful=function()end,experimental=function()end})
 eq(#waitingRows,8)
 for index=3,7 do eq(waitingRows[index].events,nil) end
 truthy(waitingRows[8].events.mouseClick) -- back routing stays reachable while a write is in flight
 -- the wait settles only once the snapshot it will change stops being in flight
 eq(uiState.settleModelSlot(s,controls('standard','standard',{pending=true})),false)
 truthy(uiState.settleModelSlot(s,controls('powerful','powerful')));eq(s.modelSlotPending,nil)
 -- random routing disables all four choices and says why, without changing the row count
 local randomized=uiState.modelSlotView(controls('fast','fast',{randomized=true}),nil)
 eq(randomized.message,'Random LLM is on, so the server picks a model every turn and these choices are disabled.')
 for _,row in ipairs(randomized.rows) do eq(row.clickable,false) end
 local randomRows=panel(randomized,{fast=function() clicked='randomized' end})
 eq(#randomRows,8);eq(randomRows[4].events,nil);truthy(randomRows[7].events.mouseClick)
 -- a long connector name is clipped instead of widening the row
 local long=slots();long[2].configuration_name='A very long local connector configuration name'
 local clipped=uiState.modelSlotView({target=npc,selected_model_slot_key='standard',
  resolved_model_slot_key='standard',pending=false,model_slots=long,
  effective_settings={routing={llm_randomizer_enabled=false}}},nil)
 truthy(#clipped.rows[2].detail<=38);eq(clipped.rows[2].detail:sub(-3),'...')
 -- the Interact overlay pauses simulation, so the paused-frame pump is what settles a selection.
 -- It stays gated on a visible server-owned panel with a request in flight, and carries no gameplay,
 -- settings, or event-lane work that belongs to onUpdate.
 local playerSource=io.open(root..'/scripts/LORKHAN/player.lua')
 local playerBody=playerSource:read('*a');playerSource:close()
 local frameBody=assert(playerBody:match('\n        onFrame=function%(%)(.-)\n        end,\n'))
 truthy(frameBody:find('controlsRequestActive',1,true))
 truthy(frameBody:find('SERVER_CONTROL_PANELS[state.ui.panel]',1,true))
 truthy(frameBody:find('native.pumpSessionControls',1,true))
 truthy(frameBody:find('render()',1,true))
 for _,forbidden in ipairs({'settingsRefreshElapsed','aimScanElapsed','autoScanElapsed',
  'flushCapturedDialogue','pollResults','send('}) do
  eq(frameBody:find(forbidden,1,true),nil)
 end
end)
test('OpenMW settings page registers controls and seeds conflict-free defaults once',function()
 local data={OMWInputBindings={},LORKHANInputDefaults={}}
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
package.preload['openmw.lorkhan']=function() return {
  currentVoiceCaptureDeviceName=function()return 'Test microphone'end,
  voiceCaptureDevices=function()return {
   {id=-1,name='Windows default'},{id=0,name='Virtual microphone'},{id=1,name='Headset microphone'},
   {id=2,name='Razer microphone'},{id=3,name='Streaming microphone'},{id=4,name='Test microphone'},
  }end,
 } end
 package.loaded['openmw.input']=nil package.loaded['openmw.storage']=nil package.loaded['openmw.interfaces']=nil
 package.loaded['openmw.lorkhan']=nil
 package.loaded['scripts.LORKHAN.settings']=nil
 local settingsEntry=require('scripts.LORKHAN.settings')
 eq(next(settingsEntry),nil)
 eq(registered.pages[1].key,'LORKHAN');eq(#registered.groups,6);eq(registered.groups[1].page,'LORKHAN');eq(#registered.groups[1].settings,8)
 for _,setting in ipairs(registered.groups[1].settings) do truthy(setting.name);truthy(setting.description) end
 truthy(registered.triggers.LORKHAN_Talk);truthy(registered.triggers.LORKHAN_Halt)
 truthy(registered.triggers.LORKHAN_StopDialogue);truthy(registered.triggers.LORKHAN_ManualActivate)
 truthy(registered.triggers.LORKHAN_ActionsMenu);truthy(registered.triggers.LORKHAN_MasterMenu)
 truthy(registered.triggers.LORKHAN_ToggleMode);truthy(registered.triggers.LORKHAN_StatusHud)
 truthy(registered.triggers.LORKHAN_ModelMenu);truthy(registered.triggers.LORKHAN_ProfileMenu)
 truthy(registered.triggers.LORKHAN_History);truthy(registered.triggers.LORKHAN_Diagnostics)
 truthy(registered.triggers.LORKHAN_OpenMic);truthy(registered.triggers.LORKHAN_OpenMicMute)
 truthy(registered.actions.LORKHAN_PushToTalk)
 local function setting(group,key)
  for _,candidate in ipairs(group.settings) do if candidate.key==key then return candidate end end
 end
 truthy(setting(registered.groups[1],'StopDialogueBinding'));truthy(setting(registered.groups[1],'TalkBinding'))
 truthy(setting(registered.groups[1],'HaltBinding'));truthy(setting(registered.groups[1],'ManualActivateBinding'))
 truthy(setting(registered.groups[1],'ActorToolsBinding'))
 truthy(setting(registered.groups[1],'PushToTalkBinding'));truthy(setting(registered.groups[1],'OpenMicBinding'))
 truthy(setting(registered.groups[1],'OpenMicMuteBinding'))
 -- the six moved controls leave the visible Hotkeys list so Interact is the one discoverable entry
 for _,key in ipairs({'ModeMenuBinding','ModelMenuBinding','ProfileMenuBinding','StatusHudBinding',
  'HistoryBinding','DiagnosticsBinding'}) do eq(setting(registered.groups[1],key),nil) end
 -- their triggers stay registered so bindings users already saved keep working
 for _,key in ipairs({'LORKHAN_ToggleMode','LORKHAN_ModelMenu','LORKHAN_ProfileMenu','LORKHAN_StatusHud',
  'LORKHAN_History','LORKHAN_Diagnostics'}) do truthy(registered.triggers[key]) end
 eq(registered.groups[2].key,'SettingsLORKHANAutoActivate');eq(setting(registered.groups[2],'enabled').default,true)
 eq(setting(registered.groups[2],'interiorDistance').default,1200);eq(setting(registered.groups[2],'exteriorDistance').default,2400)
 eq(setting(registered.groups[2],'interiorHearingDistance').default,500)
 eq(setting(registered.groups[2],'exteriorHearingDistance').default,1000)
 eq(registered.groups[3].key,'SettingsLORKHANBehavior');eq(#registered.groups[3].settings,5)
 eq(setting(registered.groups[3],'cancelDialogueOnCombat').default,true)
 eq(setting(registered.groups[3],'openMicSensitivity').default,700)
 eq(setting(registered.groups[3],'openMicEndDelayMs').default,900)
 eq(setting(registered.groups[3],'recordingDevice').default,-1)
 eq(setting(registered.groups[3],'recordingDevice').renderer,'number')
 eq(setting(registered.groups[3],'recordingDevice').argument.min,-1)
 eq(setting(registered.groups[3],'recordingDevice').argument.max,4)
 eq(setting(registered.groups[3],'recordingDeviceName').default,'Test microphone')
 eq(setting(registered.groups[3],'recordingDeviceName').renderer,'textLine')
 eq(setting(registered.groups[3],'recordingDeviceName').argument.disabled,true)
 eq(data.SettingsLORKHANBehavior.recordingDeviceName,'Test microphone')
 eq(setting(registered.groups[3],'rechat'),nil);eq(setting(registered.groups[3],'boredom'),nil)
 eq(setting(registered.groups[3],'combatBarks'),nil);eq(setting(registered.groups[3],'autoGreeting'),nil)
 eq(registered.groups[4].key,'SettingsLORKHANSound');eq(setting(registered.groups[4],'ttsVolumeBoost').default,3)
 eq(registered.groups[5].key,'SettingsLORKHANAgents');eq(setting(registered.groups[5],'actionsEnabled').default,true)
 eq(registered.groups[6].key,'SettingsLORKHANPresentation');eq(setting(registered.groups[6],'showStatusHud').default,false)
 local talk=data.OMWInputBindings.LORKHAN_Talk_Binding
 local halt=data.OMWInputBindings.LORKHAN_Halt_Binding
 eq(talk.device,'keyboard');eq(talk.button,6);eq(talk.type,'trigger');eq(talk.key,'LORKHAN_Talk')
 eq(halt.button,7);eq(data.OMWInputBindings.LORKHAN_ActionsMenu_Binding,nil)
 eq(data.OMWInputBindings.LORKHAN_MasterMenu_Binding,nil)
 eq(data.LORKHANInputDefaults.version,7)
 data.OMWInputBindings.LORKHAN_Talk_Binding=nil
 package.loaded['scripts.LORKHAN.settings']=nil
 require('scripts.LORKHAN.settings')
 eq(data.OMWInputBindings.LORKHAN_Talk_Binding,nil)
 package.preload['openmw.input']=nil package.preload['openmw.storage']=nil package.preload['openmw.interfaces']=nil
 package.preload['openmw.lorkhan']=nil
 package.loaded['openmw.input']=nil package.loaded['openmw.storage']=nil package.loaded['openmw.interfaces']=nil
 package.loaded['openmw.lorkhan']=nil
 package.loaded['scripts.LORKHAN.settings']=nil
end)
test('STT voice controls and the bounded automatic dialogue scheduler are exposed',function()
 for _,name in ipairs({'startVoice','stopVoice','pollVoice','enableOpenMic','disableOpenMic','muteOpenMic','pollOpenMic','runOpenMicContext'}) do
  truthy(type(orchestrator[name])=='function')
 end
 truthy(type(orchestrator.runAutonomy)=='function')
 for _,name in ipairs({'requestLocalAutonomy','pollAutonomy'}) do
  eq(orchestrator[name],nil)
 end
end)
test('agent scanning schedules one verified automatic greeting without submitting directly',function()
 local b=fake.bridge() local emitted={}
 local s=orchestrator.new(b,function(name,payload)table.insert(emitted,{name=name,payload=payload})end,nil,function()return true end)
 s.settings={autoActivate={enabled=true},behavior={autoGreeting=true,boredom=true,combatBarks=true}}
 orchestrator.configureSession(s,UUID.session);orchestrator.activate(s,npc,{})
 local candidate={identity=npc,distance=100,maxDistance=1200,dead=false,hostile=false,available=true}
 eq(orchestrator.scanAgents(s,{candidate}),1)
 orchestrator.actorCombatStatus(s,{actor=npc,hostile_to_player=false,activity='idle',conversation_state='active'})
 truthy(orchestrator.runAutonomy(s,0.05));eq(#b.submitted,0)
 local request=emitted[#emitted];eq(request.name,'LORKHAN_AUTONOMY_CONTEXT_REQUEST')
 eq(request.payload.kind,'greeting');truthy(identity.same(request.payload.actor,npc))
 eq(orchestrator.runAutonomy(s,0.05),false)
end)
test('dynamic profile timer resubmits a bounded nearby batch after the CHIM cadence',function()
 local b=fake.bridge() local emitted={}
 local s=orchestrator.new(b,function(name,payload)table.insert(emitted,{name=name,payload=payload})end,nil,function()return true end)
 s.settings={autoActivate={enabled=true},behavior={}}
 orchestrator.configureSession(s,UUID.session);orchestrator.activate(s,npc,{})
 local candidate={identity=npc,distance=100,maxDistance=1200,dead=false,hostile=false,available=true}
 eq(orchestrator.scanAgents(s,{candidate}),1)
 for _=1,239 do eq(orchestrator.runAutonomy(s,5),false) end
 truthy(orchestrator.runAutonomy(s,5))
 local request=emitted[#emitted];eq(request.name,'LORKHAN_PROFILE_EVOLUTION_REQUEST')
 eq(#request.payload.actors,1);truthy(identity.same(request.payload.actors[1],npc))
end)
test('boredom and combat barks share idle and period fences',function()
 local b=fake.bridge() local emitted={}
 local s=orchestrator.new(b,function(name,payload)table.insert(emitted,{name=name,payload=payload})end,nil,function()return true end)
 s.settings={autoActivate={enabled=true},behavior={autoGreeting=false,boredom=true,boredomDelaySeconds=30,
  combatBarks=true,combatBarkPeriodSeconds=5}}
 orchestrator.configureSession(s,UUID.session);orchestrator.activate(s,npc,{})
 local candidate={identity=npc,distance=100,maxDistance=1200,dead=false,hostile=false,available=true}
 eq(orchestrator.scanAgents(s,{candidate}),1)
 orchestrator.actorCombatStatus(s,{actor=npc,hostile_to_player=false,activity='idle',conversation_state='active'})
 for _=1,5 do eq(orchestrator.runAutonomy(s,5),false) end
 eq(orchestrator.runAutonomy(s,4),false);truthy(orchestrator.runAutonomy(s,1))
 eq(emitted[#emitted].name,'LORKHAN_BORED_POLICY_REQUEST')
 truthy(orchestrator.bindBoredRequest(s,{opportunity=s.autonomy.boredPending.opportunity,actor=npc,session_id=s.sessionId,generation=s.generation,request_id=UUID.request}))
 local count=#emitted
 b.pollResults=function()return {{type='bored.decision',request_id=UUID.request,session_id=s.sessionId,generation=s.generation,comment_requested=false}} end
 orchestrator.poll(s);eq(#emitted,count);eq(s.autonomy.boredPending,nil)
 for _=1,5 do eq(orchestrator.runAutonomy(s,5),false) end
 truthy(orchestrator.runAutonomy(s,5));eq(emitted[#emitted].name,'LORKHAN_BORED_POLICY_REQUEST')
 truthy(orchestrator.bindBoredRequest(s,{opportunity=s.autonomy.boredPending.opportunity,actor=npc,session_id=s.sessionId,generation=s.generation,request_id=UUID.request}))
 b.pollResults=function()return {{type='bored.decision',request_id=UUID.request,session_id=s.sessionId,generation=s.generation,comment_requested=true}} end
 orchestrator.poll(s);eq(emitted[#emitted].payload.kind,'boredom')
 count=#emitted;orchestrator.poll(s);eq(#emitted,count)
 s.autonomy.pending=nil;s.conversation.turn=nil
 orchestrator.actorCombatStatus(s,{actor=npc,hostile_to_player=false,activity='combat',conversation_state='busy'})
 eq(orchestrator.runAutonomy(s,4),false);truthy(orchestrator.runAutonomy(s,1))
 eq(emitted[#emitted].payload.kind,'combat_bark')
 eq(orchestrator.runAutonomy(s,4),false) -- pending context request fences duplicate work
 eq(orchestrator.runAutonomy(s,1),false)
 truthy(orchestrator.runAutonomy(s,4)) -- a lost player event is retried only after the watchdog expires
end)
test('combat cooldown accepts the full profile range without a 300 second clamp',function()
 local b=fake.bridge() local emitted={}
 local s=orchestrator.new(b,function(name,payload)table.insert(emitted,{name=name,payload=payload})end,nil,function()return true end)
 s.settings={autoActivate={enabled=true},behavior={combatBarks=true,combatBarkPeriodSeconds=600}}
 orchestrator.configureSession(s,UUID.session);orchestrator.activate(s,npc,{})
 orchestrator.scanAgents(s,{{identity=npc,distance=100,maxDistance=1200,dead=false,hostile=false,available=true}})
 orchestrator.actorCombatStatus(s,{actor=npc,hostile_to_player=false,activity='combat',conversation_state='busy'})
 for _=1,119 do eq(orchestrator.runAutonomy(s,5),false) end
 eq(orchestrator.runAutonomy(s,4),false);truthy(orchestrator.runAutonomy(s,1))
 eq(emitted[#emitted].payload.kind,'combat_bark')
end)

test('narrator events use welcome, round, quest, and bored fences',function()
 local b=fake.bridge() local emitted={}
 local s=orchestrator.new(b,function(name,payload)table.insert(emitted,{name=name,payload=payload})end,nil,function()return true end)
 s.randomPercent=function()return 1 end
 s.settings={autoActivate={enabled=true},behavior={boredom=true,boredomDelaySeconds=30},narrator={enabled=true,
  name='The Narrator',welcome_events=true,welcomeReady=true,random_events=true,random_chance_percent=100,
  random_cooldown_rounds=2,bored_events=true,bored_chance_percent=100,quest_events=true,quest_chance_percent=100}}
 orchestrator.configureSession(s,UUID.session)
 truthy(orchestrator.runAutonomy(s,0.05));eq(emitted[#emitted].payload.kind,'narrator_welcome')
 eq(emitted[#emitted].payload.actor.kind,'narrator')
 orchestrator.runAutonomy(s,5);eq(s.conversation.target,nil)
 s.conversation.turn=nil
 s.autonomy.narratorRounds=1;s.autonomy.narratorRandomPending=true
 eq(orchestrator.runAutonomy(s,0.05),false)
 s.autonomy.narratorRounds=2;s.autonomy.narratorRandomPending=true
 truthy(orchestrator.runAutonomy(s,0.05));eq(emitted[#emitted].payload.kind,'narrator_random')
 orchestrator.runAutonomy(s,5);eq(s.conversation.target,nil)
 s.conversation.turn=nil
 truthy(orchestrator.queueNarratorEvent(s,'quest',nil,true,'Quest test, stage 20: Observed objective.'));truthy(orchestrator.runAutonomy(s,0.05))
 eq(emitted[#emitted].payload.kind,'narrator_quest')
 eq(emitted[#emitted].payload.observed_text,'Quest test, stage 20: Observed objective.')
 eq(orchestrator.queueNarratorEvent(s,'quest',nil,true,string.rep('x',8193)),false)
 orchestrator.runAutonomy(s,5);eq(s.conversation.target,nil)
 s.conversation.turn=nil
 orchestrator.activate(s,npc,{})
 local candidate={identity=npc,distance=100,maxDistance=1200,dead=false,hostile=false,available=true}
 orchestrator.scanAgents(s,{candidate})
 orchestrator.actorCombatStatus(s,{actor=npc,hostile_to_player=false,activity='idle',conversation_state='active'})
 for _=1,6 do orchestrator.runAutonomy(s,5) end
 eq(emitted[#emitted].name,'LORKHAN_BORED_POLICY_REQUEST')
 truthy(orchestrator.bindBoredRequest(s,{opportunity=s.autonomy.boredPending.opportunity,actor=npc,session_id=s.sessionId,generation=s.generation,request_id=UUID.request}))
 b.pollResults=function()return {{type='bored.decision',request_id=UUID.request,session_id=s.sessionId,generation=s.generation,comment_requested=true}} end
 orchestrator.poll(s)
 eq(emitted[#emitted].payload.kind,'narrator_boredom');truthy(identity.same(emitted[#emitted].payload.context_actor,npc))
end)
test('safe movement and combat actions enforce tiers and bounds',function()
 local registry=identity.Registry();registry:activate(npc,{});registry:activate(playerId,{})
 local authority={generation=2,session_id='s',actor=npc,resolve=function(id)return registry:resolve(id)end,expired=function()return false end}
 local state=actions.new({'action.ai.stop','action.ai.wander','action.combat.start','action.combat.stop'})
 local intent={schema='lorkhan.action-intent.v1',action_id='wander',request_id='r',turn_id='t',session_id='s',generation=2,
  name='ai.wander',tier=1,actor=npc,target=playerId,parameters={distance=512,duration_seconds=3600},expires_at='soon'}
 local mapped=actions.validate(state,intent,authority);eq(mapped.parameters.distance,512);eq(mapped.parameters.duration_seconds,3600)
 intent.action_id='bad-wander';intent.parameters.distance=2049;local ok,reason=actions.validate(state,intent,authority);eq(ok,nil);eq(reason,'invalid_wander_distance')
 intent.parameters={};intent.name='combat.start';intent.tier=1;intent.action_id='combat';ok,reason=actions.validate(state,intent,authority);eq(ok,nil);eq(reason,'invalid_action_tier')
 intent.tier=2;mapped=actions.validate(state,intent,authority);eq(mapped.name,'combat.start')
end)
test('inventory inspect, approach, and bounded wait use owned API-129 actions',function()
 local registry=identity.Registry();registry:activate(npc,{});registry:activate(playerId,{})
 local authority={generation=2,session_id='s',actor=npc,resolve=function(id)return registry:resolve(id)end,expired=function()return false end}
 local capabilities={'action.inventory.inspect','action.ai.approach','action.ai.wait'}
 local state=actor.new(npc,2,capabilities)
 local stopped
 local adapter={
  inventoryReport=function()return true,'inventory_inspected',{items={{record_id='iron_dagger',count=1}},total_record_types=1,truncated=false} end,
  approachSelf=function()return true,'approach_started',{destination_x=1,destination_y=2,destination_z=3,destination_cell='exterior:0:0'} end,
  waitSelf=function(_,parameters)return true,'wait_started',{distance=0,duration_seconds=parameters.duration_seconds} end,
  stopAi=function(owned)stopped=owned return true,'ai_packages_stopped' end}
 local intent={schema='lorkhan.action-intent.v1',action_id='inventory',request_id='r',turn_id='safe-actions',session_id='s',
  generation=2,name='inventory.inspect',tier=0,actor=npc,target=playerId,parameters={},expires_at='soon'}
 local result=actor.execute(state,intent,adapter,authority);eq(result.status,'succeeded');eq(result.observed.items[1].record_id,'iron_dagger')
 intent.action_id='approach';intent.name='ai.approach';intent.tier=1
 result=actor.execute(state,intent,adapter,authority);eq(result.status,'succeeded');eq(state.ownedAi.type,'Travel')
 eq(state.ownedAi.destination.destination_cell,'exterior:0:0')
 intent.action_id='wait';intent.name='ai.wait';intent.parameters={duration_seconds=3600}
 result=actor.execute(state,intent,adapter,authority);eq(result.status,'succeeded');eq(stopped.type,'Travel')
 eq(state.ownedAi.type,'Wander');eq(state.ownedAi.distance,0);eq(state.ownedAi.duration,1)
 intent.action_id='bad-wait';intent.parameters={duration_seconds=3599}
 local ok,reason=actions.validate(state.actions,intent,authority);eq(ok,nil);eq(reason,'invalid_wait_duration')
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
 local intent={schema='lorkhan.action-intent.v1',action_id='anim',request_id='r',turn_id='t',session_id='s',generation=2,
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
 local creatureObject={id='0x01000071',recordId='dagoth_ur_1',contentFile='morrowind.esm',enabled=true,
  position=vector(0,320,0),cell={isExterior=true,gridX=-2,gridY=-9}}
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
 local modules={core={contentFiles={list={'Morrowind.esm','Test.esp'}},getGameTime=function()return 1234 end,
  dialogue={topic={records={vivec={infos={{id='vivec-info',text='I am %Name, %Class.'}}}}}},
  getFormId=function(_,index)if index==playerId.refnum.index then return 0x00000014 end
   if index==113 then return 0x01000071 end return 0x01000070 end},self=selfObject,
  interfaces={FollowerDetectionUtil={version=2,getFollowerList=function()return{
    follower={actor=object,leader=playerTarget,superLeader=nil,followsPlayer=true}}
  end},AI={getActivePackage=function()return activePackage end,isFleeing=function()return false end,
   startPackage=function(package)started=package end,filterPackages=function(filter)packageFilter=filter end}},
    types={Player={objectIsInstance=function(o)return o==playerTarget end},NPC={objectIsInstance=function(o)return o==object or o==playerTarget end,
     record=function(o)return{name=o==playerTarget and 'RANGROO' or 'Fargoth',race=o==object and 'wood elf' or 'dark elf',
      class='commoner',isMale=true,isEssential=false,primaryFaction=o==object and 'hlaalu' or ''}end,
     isWerewolf=function()return false end,getDisposition=function()return 67 end,
     getFactions=function()return{'hlaalu'}end,getFactionRank=function()return 2 end,
     getFactionReputation=function()return 4 end},Creature={objectIsInstance=function(o)return o==creatureObject end,
     record=function()return{name='Dagoth Ur'}end},Actor={
     stats={level=function()return{current=5}end},
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
       players={playerTarget},items={ownedItem},doors={lockedDoor},getObjectByFormId=function(formId)
        if formId==0x01000071 then return creatureObject end return object end}}
 local mapped=openmwAdapter.identity(object,modules);eq(mapped.kind,'npc');eq(mapped.refnum.index,112)
 eq(mapped.refnum.content_file,1);eq(mapped.content_file,'Test.esp');eq(mapped.display_name,'Fargoth')
 local actorProfile=openmwAdapter.actorProfile(mapped,modules);eq(actorProfile.race,'wood elf');eq(actorProfile.class,'commoner')
 eq(actorProfile.gender,'male');eq(actorProfile.level,5);eq(actorProfile.disposition,67);eq(actorProfile.factions[1],'hlaalu')
 local creatureIdentity=openmwAdapter.identity(creatureObject,modules);eq(creatureIdentity.kind,'creature')
 local creatureProfile=openmwAdapter.actorProfile(creatureIdentity,modules);eq(creatureProfile.race,'Creature')
 eq(creatureProfile.gender,'none');eq(creatureProfile.level,5);eq(creatureProfile.disposition,0);eq(#creatureProfile.factions,0)
 local mappedPlayer=openmwAdapter.identity(playerTarget,modules);eq(mappedPlayer.kind,'player');eq(mappedPlayer.refnum.index,0)
 eq(mappedPlayer.refnum.content_file,0);eq(mappedPlayer.content_file,'Morrowind.esm');eq(mappedPlayer.display_name,'RANGROO')
 local response=openmwAdapter.dialogueResponse({actor=object,type='topic',recordId='vivec',infoId='vivec-info',
   text='I am Fargoth, commoner.'},modules)
 eq(response.text,'I am Fargoth, commoner.');eq(response.actor.record_id,'fargoth');eq(response.captured_game_time,1234)
 local rawResponse=openmwAdapter.dialogueResponse({actor=object,type='topic',recordId='vivec',infoId='vivec-info'},modules)
 eq(rawResponse.text,'I am %Name, %Class.')
 eq(openmwAdapter.resolve(mappedPlayer,modules),playerTarget)
 local aimed=openmwAdapter.resolveActorRay(512,modules);eq(aimed.identity.record_id,'fargoth');eq(aimed.distance,300)
 local candidate=openmwAdapter.resolveCameraTarget(512,modules);eq(candidate.identity.record_id,'fargoth');eq(candidate.distance,300)
 eq(openmwAdapter.actorDistance(mapped,modules),300)
 local combatStatus=openmwAdapter.combatStatus(modules);truthy(combatStatus.hostile_to_player);eq(combatStatus.target.kind,'player')
 eq(combatStatus.activity,'combat');eq(combatStatus.conversation_state,'unconscious')
 eq(combatStatus.conversation_state_proven,true)
 local destination=openmwAdapter.resolveCameraPoint(512,modules);eq(destination.destination_y,256);eq(destination.destination_cell,'exterior:-2:-9')
 truthy(openmwAdapter.travel(destination,modules));eq(started.type,'Travel');eq(started.destPosition.y,256)
 truthy(openmwAdapter.stopAi({type='Travel',destination=destination},modules))
 eq(packageFilter({type='Travel',destPosition=vector(0,256,8)}),false)
 eq(packageFilter({type='Travel',destPosition=vector(0,257,8)}),true)
 truthy(openmwAdapter.escort(playerId,destination,modules));eq(started.type,'Escort');eq(started.target,playerTarget)
 truthy(openmwAdapter.approach(mapped,modules));eq(started.type,'Travel');eq(started.destPosition.y,300)
 local waitOk,_,waitObserved=openmwAdapter.wait({duration_seconds=3600},modules);truthy(waitOk);eq(started.type,'Wander')
 eq(started.distance,0);eq(started.duration,3600);eq(waitObserved.duration_seconds,3600)
 truthy(openmwAdapter.stopAi({type='Wander',distance=0,duration=1},modules))
 eq(packageFilter({type='Wander',distance=0,duration=1}),false)
 eq(packageFilter({type='Wander',distance=0,duration=2}),true)
 activePackage=nil
 local faceOk,_,controller=openmwAdapter.beginFace(mapped,{},modules);truthy(faceOk)
 local completed=openmwAdapter.updateFace(controller,0.1,modules);eq(completed,nil);truthy(selfObject.controls.yawChange<0)
 yaw=0;completed=openmwAdapter.updateFace(controller,0.1,modules);eq(completed,true);eq(selfObject.controls.yawChange,0)
 local inventoryRows=openmwAdapter.targetInventory(mapped,modules);eq(inventoryRows[1].record_id,'iron_dagger');eq(#inventoryRows,2)
 local inventoryOk,_,inventoryObserved=openmwAdapter.inventoryReport(modules);truthy(inventoryOk)
 eq(inventoryObserved.items[1].record_id,'iron_dagger');eq(inventoryObserved.total_record_types,2);eq(inventoryObserved.truncated,false)
 local equipmentRows=openmwAdapter.targetEquipment(mapped,modules);eq(equipmentRows[1].slot,'carried_right');eq(equipmentRows[1].record_id,'iron_dagger')
 local followers,provider=openmwAdapter.followerContext(modules);eq(#followers,1);eq(followers[1].actor.record_id,'fargoth')
 eq(followers[1].leader.kind,'player');eq(followers[1].follows_player,true);eq(provider.provider,'FollowerDetectionUtil');eq(provider.version,2)
  local context=openmwAdapter.playerContext(mapped,modules);eq(context.followers[1].actor.record_id,'fargoth')
  eq(context.targetState.identity.race,'wood elf');eq(context.targetState.identity.gender,'Male')
  eq(context.targetState.identity.primary_faction,'hlaalu');eq(context.targetState.identity.is_werewolf,false)
 eq(context.capabilities.follower_detection,'FollowerDetectionUtil');eq(context.capabilities.follower_detection_version,2)
 eq(context.playerState.held_items[1].display_name,'Iron Dagger')
 eq(context.nearbyObjects[1].ownership.record_id,'fargoth');eq(context.nearbyObjects[2].lock.locked,true)
 eq(context.nearbyObjects[2].lock.level,35);eq(context.nearbyObjects[2].lock.key_record_id,'warehouse_key')
 local npcItems={}
 for index=1,49 do npcItems[index]={recordId=string.format('npc_item_%02d',index),count=index,
  type={record=function(item)return{name='NPC '..item.recordId}end}} end
 modules.types.Actor.inventory=function(owner)
  if owner==object then return {getAll=function()return npcItems end} end
  return inventorySource
 end
 local captured=openmwAdapter.playerContext(mapped,modules)
 eq(#captured.inventory,2);eq(captured.inventory[1].record_id,'iron_dagger')
 eq(#captured.targetState.inventory.items,48);eq(captured.targetState.inventory.total,49)
 eq(captured.targetState.inventory.truncated,true)
 eq(captured.targetState.inventory.items[1].display_name,'NPC npc_item_01')
 eq(captured.targetState.inventory.items[48].count,48)
 npcItems={};captured=openmwAdapter.playerContext(mapped,modules)
 eq(captured.targetState.inventory.total,0);eq(#captured.targetState.inventory.items,0)
 local sword={recordId='iron_dagger',id='sword',count=2,contentFile='Morrowind.esm',
  type={record=function()return{name='Iron Dagger',value=10,health=100}end}}
 local robe={recordId='robe',id='robe',count=1,type={record=function()return{name='Robe',value=20}end}}
 modules.types.Actor.inventory=function()return {getAll=function()return{sword,robe}end}end
 modules.types.Actor.getEquipment=function()return{[1]=sword}end
 modules.types.Item={itemData=function(item)if item==sword then return{condition=50}end return{}end}
 local payload,signature=openmwAdapter.inventoryObservation(mapped,modules)
 eq(#payload.items,2);eq(payload.items[1].condition,0.5);eq(payload.items[1].equipped,true)
 eq(payload.items[1].content_file,nil)
 eq(payload.items[2].condition,nil);eq(payload.items[2].content_file,nil)
 modules.types.Actor.inventory=function()return {getAll=function()return{robe,sword}end}end
 local _,reordered=openmwAdapter.inventoryObservation(mapped,modules);eq(signature,reordered)
 robe.type.record=function()return{name='Robe'}end
 eq(openmwAdapter.inventoryObservation(mapped,modules),nil)
 modules.types.Actor.inventory=function()return {getAll=function()return{}end}end
 payload,signature=openmwAdapter.inventoryObservation(mapped,modules);eq(#payload.items,0);eq(signature,'')
 modules.types.Actor.inventory=function()return nil end
 eq(openmwAdapter.playerContext(mapped,modules).targetState.inventory,nil)
 eq(openmwAdapter.inventoryObservation(mapped,modules),nil)
end)

io.write(string.format('%d tests, %d failures\n',tests,failures))
if failures>0 then os.exit(1) end
