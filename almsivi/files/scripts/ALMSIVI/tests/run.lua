local root=(arg and arg[0] or ''):match('^(.*)/scripts/ALMSIVI/tests/run%.lua$') or 'almsivi/files'
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
 local s=conversation.new(1);truthy(conversation.setTarget(s,npc));truthy(conversation.begin(s,'r','t','input'))
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
test('canonical action result requires completion timestamp',function()
 local state=actions.new({}) local internal=actions.result(state,'a','succeeded',nil,{})
 local result,reason=actions.canonicalResult(internal,nil);eq(result,nil);eq(reason,'completed_at_required')
 result=actions.canonicalResult(internal,'2026-07-19T00:00:00Z');eq(result.completed_at,'2026-07-19T00:00:00Z');eq(result.schema,'almsivi.action-result.v1')
end)
test('submit requires caller supplied UUID correlation',function()
 local b=fake.bridge() local s=orchestrator.new(b) local ok,reason=orchestrator.submitText(s,{text='hi'})
 eq(ok,nil);eq(reason,'invalid_request_id')
end)
test('actor is self-only and detach stops owned state',function()
 local st=actor.new(npc,2,{'action.ai.follow'}) local stopped=0
 local adapter={followSelf=function()return true end,sayOpaque=function()return true end,stopSpeech=function()stopped=stopped+1 end,stopOwnedFollow=function()stopped=stopped+1 end}
 local registry=identity.Registry();registry:activate(npc,{});registry:activate(playerId,{})
 local cmd={schema='almsivi.action-intent.v1',action_id='a',request_id='r',turn_id='t',session_id='s',generation=2,name='ai.follow',tier=1,actor=npc,target=playerId,parameters={distance=192},expires_at='x'}
 local result=actor.execute(st,cmd,adapter,{session_id='s',resolve=function(id)return registry:resolve(id)end,expired=function()return false end});eq(result.status,'succeeded');eq(result.kind,'almsivi.internal.action-terminal')
 actor.speak(st,{generation=2,actor=npc,media_id='opaque',request_id='r',turn_id='t',expires_at='x'},adapter,{expired=function()return false end});actor.detach(st,adapter);eq(st.attached,false);eq(stopped,2)
end)
test('hard halt clears queues and blocks submit',function()
 local b=fake.bridge() local s=orchestrator.new(b);orchestrator.halt(s);truthy(b.halted);eq(s.conversation.target,nil)
 local ok,reason=orchestrator.submitText(s,{text='hi'});eq(ok,nil);eq(reason,'almsivi_disabled')
end)
test('player action does not consume vanilla activation',function()
 local s=player.new();eq(player.onAction(s,'Activate',function()end),false);truthy(player.onAction(s,'ALMSIVI_Talk',function()end))
end)

io.write(string.format('%d tests, %d failures\n',tests,failures))
if failures>0 then os.exit(1) end
