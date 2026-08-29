local state={submitted={},results={},cancelled={},halted=false}
local M={version='fake-v1'}
function M.capabilities() return {'dialogue.text','action.ai.follow'} end
function M.status() return state.halted and 'halted' or 'ready' end
function M.configureProfile(profileId) assert(type(profileId)=='string' and profileId~='') return true end
function M.submitInit(dto) assert(type(dto)=='table') return dto.request_id end
function M.submitTurn(dto) assert(type(dto)=='table' and dto.schema=='almsivi.turn.v1');table.insert(state.submitted,dto);return dto.request_id end
function M.pollResults(maxItems) assert(type(maxItems)=='number' and maxItems>=0 and maxItems<=128);local out={} for _=1,math.min(maxItems,#state.results) do table.insert(out,table.remove(state.results,1)) end return out end
function M.actorConversationState() return {state='unconscious'} end
function M.cancel(requestId) assert(type(requestId)=='string') return true end
function M.cancelGeneration(generation) assert(type(generation)=='number');table.insert(state.cancelled,generation);return true end
function M.halt() state.halted=true;state.results={};state.submitted={} end
function M._state() return state end
-- Intentionally no request, URL, token, path, file, process, socket, or dynamic-code primitive.
return M
