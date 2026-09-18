#include "lorkhan/bridge_service.hpp"

#include "lorkhan/media.hpp"
#include "lorkhan/protocol_response.hpp"
#include "lorkhan/validation.hpp"

#include <algorithm>

namespace lorkhan {

BridgeService::BridgeService(std::unique_ptr<ITransport> transport, std::shared_ptr<IClock> clock,
    Generation initialGeneration)
    : m_transport(std::move(transport)), m_clock(std::move(clock)), m_generation(initialGeneration)
{
    if (!m_transport || !m_clock)
        throw std::invalid_argument("BridgeService requires transport and clock");
    m_worker = std::jthread([this] { workerLoop(); });
}

BridgeService::~BridgeService()
{
    halt();
}

Result<void> BridgeService::validateRequest(const OutboundRequest& request) const
{
    const auto validId = [](const auto& id) { return isCanonicalUuid(id.value()); };
    const auto validEnvelope = [&validId](const EnvelopeIds& ids, bool sessionRequired) {
        return validId(ids.installation) && isProfileId(ids.profile.value()) && validId(ids.playthrough)
            && (!sessionRequired || validId(ids.session)) && (sessionRequired || ids.session.empty() || validId(ids.session))
            && validId(ids.request) && validId(ids.turn) && validId(ids.message);
    };
    if (!validId(request.id))
        return Result<void>::failure(makeError(ErrorCode::invalid_argument, "request ID must be a canonical lowercase UUID"));
    if (request.generation != m_generation.current())
        return Result<void>::failure(makeError(ErrorCode::stale_generation, "request generation is stale"));
    const bool sessionRequired = request.kind != RequestKind::health && request.kind != RequestKind::init;
    if ((sessionRequired && !validId(request.session))
        || (!sessionRequired && !request.session.empty() && !validId(request.session)))
        return Result<void>::failure(makeError(ErrorCode::invalid_argument, "session ID is missing or malformed"));
    const auto envelopeMatches = [&request](const EnvelopeIds& ids) {
        return ids.request == request.id && ids.generation == request.generation
            && (request.session.empty() || ids.session == request.session);
    };
    if ((request.kind == RequestKind::health) != std::holds_alternative<HealthRequest>(request.payload)
        || (request.kind == RequestKind::init) != std::holds_alternative<InitRequest>(request.payload)
        || (request.kind == RequestKind::turn) != std::holds_alternative<TurnRequest>(request.payload)
        || (request.kind == RequestKind::event_poll) != std::holds_alternative<EventPollRequest>(request.payload)
        || (request.kind == RequestKind::interruption) != std::holds_alternative<InterruptionRequest>(request.payload)
        || (request.kind == RequestKind::action_result) != std::holds_alternative<ActionResultRequest>(request.payload)
        || (request.kind == RequestKind::dialogue_delivery_result) != std::holds_alternative<DialogueDeliveryResultRequest>(request.payload)
        || (request.kind == RequestKind::session_end) != std::holds_alternative<SessionEndRequest>(request.payload)
        || (request.kind == RequestKind::stt) != std::holds_alternative<SttRequest>(request.payload)
        || (request.kind == RequestKind::controls_query) != std::holds_alternative<ControlsQueryRequest>(request.payload)
        || (request.kind == RequestKind::controls_select) != std::holds_alternative<ControlsSelectRequest>(request.payload)
        || (request.kind == RequestKind::diary_book_query) != std::holds_alternative<DiaryBookQueryRequest>(request.payload)
        || (request.kind == RequestKind::diary_book_result) != std::holds_alternative<DiaryBookResultRequest>(request.payload)
        || (request.kind == RequestKind::debug_command_query) != std::holds_alternative<DebugCommandQueryRequest>(request.payload)
        || (request.kind == RequestKind::debug_command_result) != std::holds_alternative<DebugCommandResultRequest>(request.payload)
        || (request.kind == RequestKind::menu_dialogue_tts) != std::holds_alternative<MenuDialogueTtsRequest>(request.payload)
        || (request.kind == RequestKind::book_read_aloud) != std::holds_alternative<BookReadAloudRequest>(request.payload)
        || (request.kind == RequestKind::player_autochat) != std::holds_alternative<PlayerAutochatRequest>(request.payload)
        || (request.kind == RequestKind::gamedata) != std::holds_alternative<GameDataRequest>(request.payload)
        || (request.kind == RequestKind::media) != std::holds_alternative<MediaPrepareRequest>(request.payload))
        return Result<void>::failure(makeError(ErrorCode::invalid_argument, "request kind does not match typed payload"));
    if (const auto* init = std::get_if<InitRequest>(&request.payload)) {
        if(init->characterId.has_value()!=init->characterBinding.has_value()
            ||(init->characterId&&(!isCanonicalUuid(*init->characterId)
                ||(*init->characterBinding!="new"&&*init->characterBinding!="existing"))))
            return Result<void>::failure(makeError(ErrorCode::invalid_argument,"invalid saved character binding"));
        if (init->loadedCalendar && (!init->loadedSave || !init->loadedCalendar->valid()))
            return Result<void>::failure(makeError(ErrorCode::invalid_argument, "invalid loaded-save calendar"));
        if (!validId(init->ids.profile) || !validEnvelope(init->ids, false) || !envelopeMatches(init->ids))
            return Result<void>::failure(makeError(ErrorCode::invalid_argument, "init envelope contains malformed or inconsistent IDs"));
    }
    if (const auto* turn = std::get_if<TurnRequest>(&request.payload)) {
        if (!validEnvelope(turn->ids, true) || !envelopeMatches(turn->ids))
            return Result<void>::failure(makeError(ErrorCode::invalid_argument, "turn envelope contains malformed or inconsistent IDs"));
    }
    if (const auto* stt = std::get_if<SttRequest>(&request.payload)) {
        if (!validEnvelope(stt->ids, true) || !envelopeMatches(stt->ids))
            return Result<void>::failure(makeError(ErrorCode::invalid_argument, "STT envelope contains malformed or inconsistent IDs"));
    }
    if (const auto* media = std::get_if<MediaPrepareRequest>(&request.payload)) {
        if (!validId(media->correlation.request) || !validId(media->correlation.session)
            || media->correlation.request != request.id || media->correlation.session != request.session
            || media->correlation.generation != request.generation)
            return Result<void>::failure(makeError(ErrorCode::invalid_argument, "media correlation contains malformed or inconsistent IDs"));
        auto valid = validateMediaDescriptor(media->descriptor, {}, m_clock->systemNow());
        if (!valid)
            return valid;
    }
    if (const auto* poll = std::get_if<EventPollRequest>(&request.payload)) {
        if (!validId(poll->session) || poll->session != request.session || poll->generation != request.generation
            || poll->waitMs > 15000)
            return Result<void>::failure(makeError(ErrorCode::invalid_argument, "event-poll correlation or wait is invalid"));
    }
    if (const auto* interruption = std::get_if<InterruptionRequest>(&request.payload)) {
        if (!validId(interruption->message) || !validId(interruption->request) || !validId(interruption->turn)
            || !validId(interruption->session) || interruption->request != request.id
            || interruption->session != request.session || interruption->generation != request.generation)
            return Result<void>::failure(makeError(ErrorCode::invalid_argument, "interruption correlation contains malformed or inconsistent IDs"));
    }
    if (const auto* action = std::get_if<ActionResultRequest>(&request.payload)) {
        if (!validId(action->message) || !validId(action->correlation.request)
            || !validId(action->correlation.session) || !validId(action->action) || !validId(action->turn)
            || action->correlation.session != request.session
            || action->correlation.generation != request.generation)
            return Result<void>::failure(makeError(ErrorCode::invalid_argument, "action-result correlation contains malformed or inconsistent IDs"));
    }
    if (const auto* delivery = std::get_if<DialogueDeliveryResultRequest>(&request.payload)) {
        if (!validId(delivery->message) || !validId(delivery->correlation.request)
            || !validId(delivery->correlation.session) || !validId(delivery->dialogueMessage)
            || !validId(delivery->turn) || delivery->correlation.session != request.session
            || delivery->correlation.generation != request.generation)
            return Result<void>::failure(makeError(ErrorCode::invalid_argument,
                "dialogue-delivery correlation contains malformed or inconsistent IDs"));
        auto speaker = parseProtocolIdentity(delivery->serializedSpeaker);
        if (!speaker)
            return Result<void>::failure(speaker.error());
        if (delivery->reasonCode.empty() || delivery->reasonCode.size() > 128
            || delivery->reasonCode.front() < 'a' || delivery->reasonCode.front() > 'z'
            || !std::all_of(delivery->reasonCode.begin() + 1, delivery->reasonCode.end(), [](char character) {
                return (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9')
                    || character == '_';
            }))
            return Result<void>::failure(makeError(ErrorCode::invalid_argument,
                "dialogue-delivery reason code is outside the closed contract"));
        if (!isCanonicalUtcTimestamp(delivery->completedAt))
            return Result<void>::failure(makeError(ErrorCode::invalid_argument,
                "dialogue-delivery completion time is not a canonical UTC timestamp"));
    }
    if (const auto* end = std::get_if<SessionEndRequest>(&request.payload)) {
        if (!validId(end->request) || !validId(end->session) || end->request != request.id
            || end->session != request.session || end->generation != request.generation)
            return Result<void>::failure(makeError(ErrorCode::invalid_argument, "session-end correlation contains malformed or inconsistent IDs"));
    }
    if (const auto* controls = std::get_if<ControlsQueryRequest>(&request.payload)) {
        if (!validId(controls->message) || !validId(controls->correlation.request)
            || !validId(controls->correlation.session) || controls->correlation.request != request.id
            || controls->correlation.session != request.session || controls->correlation.generation != request.generation)
            return Result<void>::failure(makeError(ErrorCode::invalid_argument,
                "controls-query correlation contains malformed or inconsistent IDs"));
        auto target = parseProtocolIdentity(controls->serializedTarget);
        if (!target) return Result<void>::failure(target.error());
    }
    if (const auto* controls = std::get_if<ControlsSelectRequest>(&request.payload)) {
        if(controls->kind==SessionControlKind::setting){
            if(!controls->setting||controls->selectionId||controls->selectionKey)
                return Result<void>::failure(makeError(ErrorCode::invalid_argument,"setting selection is invalid"));
            const auto& setting=*controls->setting;
            if((setting.scope!="global"&&setting.scope!="core_profile"&&setting.scope!="npc")
                ||setting.key.empty()||setting.key.size()>128||setting.changeToken.size()!=64
                ||!std::all_of(setting.changeToken.begin(),setting.changeToken.end(),[](char c){return(c>='0'&&c<='9')||(c>='a'&&c<='f');})
                ||!std::all_of(setting.key.begin(),setting.key.end(),[](char c){return(c>='a'&&c<='z')||(c>='0'&&c<='9')||c=='_'||c=='.';})
                ||!requireValidUtf8(setting.value,512))
                return Result<void>::failure(makeError(ErrorCode::invalid_argument,"setting is outside the closed contract"));
        }else if(controls->setting)return Result<void>::failure(makeError(ErrorCode::invalid_argument,"unexpected setting"));
        const bool modelSlot = controls->kind == SessionControlKind::model_slot;
        const bool validModelKey = controls->selectionKey && (*controls->selectionKey == "standard"
            || *controls->selectionKey == "fast" || *controls->selectionKey == "powerful"
            || *controls->selectionKey == "experimental");
        if (!validId(controls->message) || !validId(controls->correlation.request)
            || !validId(controls->correlation.session) || controls->correlation.request != request.id
            || controls->correlation.session != request.session || controls->correlation.generation != request.generation
            || (modelSlot ? (controls->selectionId || !validModelKey)
                          : (controls->selectionKey || (controls->selectionId && !(controls->kind==SessionControlKind::narrator_profile_generate
                              ? isCanonicalUuid(*controls->selectionId) : isProfileId(*controls->selectionId)))))
            || !isCanonicalUtcTimestamp(controls->createdAt))
            return Result<void>::failure(makeError(ErrorCode::invalid_argument,
                "controls-select correlation or selection is invalid"));
        auto target = parseProtocolIdentity(controls->serializedTarget);
        if (!target) return Result<void>::failure(target.error());
    }
    if(const auto* debug=std::get_if<DiaryBookQueryRequest>(&request.payload)){
        if(!validId(debug->message)||!validId(debug->correlation.request)||!validId(debug->correlation.session)
            ||debug->correlation.request!=request.id||debug->correlation.session!=request.session
            ||debug->correlation.generation!=request.generation)
            return Result<void>::failure(makeError(ErrorCode::invalid_argument,"diary-book query correlation is invalid"));
    }
    if(const auto* debug=std::get_if<DiaryBookResultRequest>(&request.payload)){
        if(!validId(debug->message)||!validId(debug->correlation.request)||!validId(debug->correlation.session)
            ||!validId(debug->delivery)||debug->correlation.request!=request.id
            ||debug->correlation.session!=request.session||debug->correlation.generation!=request.generation
            ||!isCanonicalUtcTimestamp(debug->completedAt)||debug->reasonCode.size()>128)
            return Result<void>::failure(makeError(ErrorCode::invalid_argument,"diary-book result correlation is invalid"));
        if(!validId(debug->book)||debug->contentHash.size()!=64
            ||!std::all_of(debug->contentHash.begin(),debug->contentHash.end(),[](char c){return (c>='0'&&c<='9')||(c>='a'&&c<='f');})
            ||debug->status==DebugCommandResultStatus::rejected
            ||(debug->status==DebugCommandResultStatus::failed&&debug->reasonCode!="target_unavailable"
                &&debug->reasonCode!="target_mismatch"&&debug->reasonCode!="book_unavailable"
                &&debug->reasonCode!="record_creation_failed"&&debug->reasonCode!="inventory_update_failed"
                &&debug->reasonCode!="invalid_payload")
            ||(debug->status==DebugCommandResultStatus::succeeded&&!debug->reasonCode.empty()))
            return Result<void>::failure(makeError(ErrorCode::invalid_argument,"invalid diary receipt"));
    }
    if(const auto* debug=std::get_if<DebugCommandQueryRequest>(&request.payload)){
        if(!validId(debug->message)||!validId(debug->correlation.request)||!validId(debug->correlation.session)
            ||debug->correlation.request!=request.id||debug->correlation.session!=request.session
            ||debug->correlation.generation!=request.generation)
            return Result<void>::failure(makeError(ErrorCode::invalid_argument,"debug-command query correlation is invalid"));
    }
    if(const auto* debug=std::get_if<DebugCommandResultRequest>(&request.payload)){
        if(!validId(debug->message)||!validId(debug->correlation.request)||!validId(debug->correlation.session)
            ||!validId(debug->command)||debug->correlation.request!=request.id
            ||debug->correlation.session!=request.session||debug->correlation.generation!=request.generation
            ||!isCanonicalUtcTimestamp(debug->completedAt)||debug->reasonCode.empty()||debug->reasonCode.size()>128)
            return Result<void>::failure(makeError(ErrorCode::invalid_argument,"debug-command result correlation is invalid"));
        if(debug->reasonCode.front()<'a'||debug->reasonCode.front()>'z'
            ||!std::all_of(debug->reasonCode.begin()+1,debug->reasonCode.end(),[](char character){
                return(character>='a'&&character<='z')||(character>='0'&&character<='9')||character=='_';}))
            return Result<void>::failure(makeError(ErrorCode::invalid_argument,"debug-command reason code is invalid"));
    }
    if(const auto* menu=std::get_if<MenuDialogueTtsRequest>(&request.payload)){
        if(!validId(menu->message)||!validId(menu->correlation.request)||!validId(menu->correlation.session)
            ||menu->correlation.request!=request.id||menu->correlation.session!=request.session
            ||menu->correlation.generation!=request.generation||!isCanonicalUtcTimestamp(menu->createdAt))
            return Result<void>::failure(makeError(ErrorCode::invalid_argument,
                "menu dialogue TTS correlation is invalid"));
        auto actor=parseProtocolIdentity(menu->serializedActor);if(!actor)return Result<void>::failure(actor.error());
        auto text=requireValidUtf8(menu->text,16U*1024U);
        if(!text||menu->text.empty())return Result<void>::failure(makeError(ErrorCode::invalid_argument,
            "menu dialogue TTS text is outside the closed contract"));
    }
    if(const auto* book=std::get_if<BookReadAloudRequest>(&request.payload)){
        if(!validId(book->message)||!validId(book->correlation.request)||!validId(book->correlation.session)
            ||book->correlation.request!=request.id||book->correlation.session!=request.session
            ||book->correlation.generation!=request.generation||!isCanonicalUtcTimestamp(book->createdAt)
            ||book->bookId.empty()||book->text.empty()||!requireValidUtf8(book->bookId,512)
            ||!requireValidUtf8(book->title,512)||!requireValidUtf8(book->text,4096))
            return Result<void>::failure(makeError(ErrorCode::invalid_argument,"book read-aloud is outside the closed contract"));
    }
    if(const auto* autochat=std::get_if<PlayerAutochatRequest>(&request.payload)){
        if(!validId(autochat->message)||!validId(autochat->correlation.request)
            ||!validId(autochat->correlation.session)||autochat->correlation.request!=request.id
            ||autochat->correlation.session!=request.session
            ||autochat->correlation.generation!=request.generation||!isCanonicalUtcTimestamp(autochat->createdAt))
            return Result<void>::failure(makeError(ErrorCode::invalid_argument,
                "player autochat correlation is invalid"));
        auto player=parseProtocolIdentity(autochat->serializedPlayer);
        auto target=parseProtocolIdentity(autochat->serializedTarget);
        if(!player||player.value().kind!="player"||!target||target.value().kind=="player")
            return Result<void>::failure(makeError(ErrorCode::invalid_argument,
                "player autochat identities are invalid"));
        auto intent=requireValidUtf8(autochat->intent,16U*1024U);
        if(!intent||autochat->intent.empty())return Result<void>::failure(makeError(ErrorCode::invalid_argument,
            "player autochat intent is outside the closed contract"));
    }
    if (const auto* gamedata = std::get_if<GameDataRequest>(&request.payload)) {
        if (!validId(gamedata->installation) || !validId(gamedata->playthrough) || !validId(gamedata->request)
            || gamedata->request != request.id || gamedata->runtimeGeneration != request.generation
            || !isCanonicalUtcTimestamp(gamedata->observedAt))
            return Result<void>::failure(makeError(ErrorCode::invalid_argument,
                "game-data correlation is invalid"));
        if (gamedata->type == GameDataType::disposition)
            return validateDispositionPayload(gamedata->serializedPayload);
        if (gamedata->type == GameDataType::item_pickup)
            return validateItemPickupPayload(gamedata->serializedPayload);
        if (gamedata->type == GameDataType::actor_resurrected)
            return validateActorResurrectedPayload(gamedata->serializedPayload);
        if (gamedata->type == GameDataType::spell_cast)
            return validateSpellCastPayload(gamedata->serializedPayload);
        if (gamedata->type == GameDataType::inventory)
            return validateInventoryPayload(gamedata->serializedPayload);
    }
    const auto validatePayload = [](std::string_view value, std::size_t limit) -> Result<void> {
        auto valid = requireValidUtf8(value, limit);
        return valid ? Result<void>::success() : Result<void>::failure(valid.error());
    };
    if (const auto* turn = std::get_if<TurnRequest>(&request.payload))
        return validatePayload(turn->serializedPayload, kMaxJsonBytes);
    if (const auto* interruption = std::get_if<InterruptionRequest>(&request.payload)) {
        if (interruption->reason.empty() || interruption->reason.size() > 128)
            return Result<void>::failure(makeError(ErrorCode::invalid_argument, "interruption reason is outside size limit"));
        return validatePayload(interruption->reason, 128);
    }
    if (const auto* action = std::get_if<ActionResultRequest>(&request.payload)) {
        if (action->reasonCode.empty() || action->reasonCode.size() > 128)
            return Result<void>::failure(makeError(ErrorCode::invalid_argument, "action-result reason code is outside size limit"));
        auto reason = validatePayload(action->reasonCode, 128);
        if (!reason)
            return reason;
        return validatePayload(action->serializedObserved, kMaxJsonBytes);
    }
    if(const auto* debug=std::get_if<DebugCommandResultRequest>(&request.payload))
        return validatePayload(debug->serializedObserved,16U*1024U);
    if (const auto* stt = std::get_if<SttRequest>(&request.payload)) {
        if (stt->audio.empty() || stt->audio.size() > kMaxSttBytes)
            return Result<void>::failure(makeError(ErrorCode::invalid_argument, "STT body is outside size limit"));
        if (stt->codec != "wav")
            return Result<void>::failure(makeError(ErrorCode::invalid_argument, "STT codec must be wav"));
    }
    if (const auto* gamedata = std::get_if<GameDataRequest>(&request.payload))
        return validatePayload(gamedata->serializedPayload, kMaxJsonBytes);
    return Result<void>::success();
}

Result<RequestId> BridgeService::enqueue(OutboundRequest request)
{
    if (m_halted.load(std::memory_order_acquire))
        return Result<RequestId>::failure(makeError(ErrorCode::stopped, "bridge is halted"));
    auto valid = validateRequest(request);
    if (!valid)
        return Result<RequestId>::failure(valid.error());
    {
        std::lock_guard lock(m_stateMutex);
        if (!m_knownRequests.insert(request.id).second)
            return Result<RequestId>::failure(makeError(ErrorCode::duplicate_conflict, "request ID already used"));
    }
    auto registration = m_cancellations.registerRequest(request.id, request.generation);
    if (!registration) {
        std::lock_guard lock(m_stateMutex);
        m_knownRequests.erase(request.id);
        return Result<RequestId>::failure(registration.error());
    }
    const RequestId id = request.id;
    auto queued = m_outbound.tryPush(std::move(request));
    if (!queued) {
        m_cancellations.complete(id);
        std::lock_guard lock(m_stateMutex);
        m_knownRequests.erase(id);
        return Result<RequestId>::failure(queued.error());
    }
    return Result<RequestId>::success(id);
}

std::vector<InboundResult> BridgeService::poll(std::size_t maximumItems)
{
    // This is an implementation safety bound from queue storage, not a protocol compatibility limit.
    maximumItems = std::min(maximumItems, kInboundCapacity);
    auto items = m_inbound.drain(maximumItems);
    const Generation current = m_generation.current();
    std::erase_if(items, [current](const InboundResult& result) { return result.generation != current; });
    return items;
}

Result<void> BridgeService::cancel(const RequestId& request)
{
    if (m_halted.load(std::memory_order_acquire))
        return Result<void>::failure(makeError(ErrorCode::stopped, "bridge is halted"));
    if (!m_cancellations.cancel(request))
        return Result<void>::failure(makeError(ErrorCode::invalid_argument, "request is unknown or already cancelled"));
    std::optional<OutboundRequest> cancelled;
    {
        std::lock_guard lock(m_stateMutex);
        const auto active = m_activeRequests.find(request);
        if (active != m_activeRequests.end() && m_cancelledPublished.insert(request).second)
            cancelled = active->second;
    }
    if (cancelled) {
        publishCancelled(*cancelled);
        m_transport->interrupt(request);
    }
    return Result<void>::success();
}

Result<Generation> BridgeService::cancelGeneration(Generation generation)
{
    if (m_halted.load(std::memory_order_acquire))
        return Result<Generation>::failure(makeError(ErrorCode::stopped, "bridge is halted"));
    if (generation != m_generation.current())
        return Result<Generation>::failure(makeError(ErrorCode::stale_generation, "generation is not current"));
    m_cancellations.cancelGeneration(generation);
    m_outbound.eraseIf([generation](const OutboundRequest& request) { return request.generation == generation; });
    m_inbound.eraseIf([generation](const InboundResult& result) { return result.generation == generation; });
    std::vector<RequestId> active;
    {
        std::lock_guard lock(m_stateMutex);
        for (const auto& [id, request] : m_activeRequests) {
            if (request.generation == generation)
                active.push_back(id);
        }
    }
    for (const auto& id : active)
        m_transport->interrupt(id);
    return Result<Generation>::success(m_generation.invalidate());
}

BridgeDiagnostics BridgeService::diagnostics() const
{
    BridgeDiagnostics result{m_outbound.size(), m_inbound.size(), 0, m_cancellations.size()};
    std::lock_guard lock(m_stateMutex);
    result.active = m_activeRequests.size();
    return result;
}

void BridgeService::halt() noexcept
{
    if (m_halted.exchange(true, std::memory_order_acq_rel))
        return;
    m_generation.invalidate();
    m_cancellations.cancelAll();
    std::vector<RequestId> active;
    {
        std::lock_guard lock(m_stateMutex);
        for (const auto& [id, request] : m_activeRequests) {
            static_cast<void>(request);
            active.push_back(id);
        }
    }
    for (const auto& id : active)
        m_transport->interrupt(id);
    m_outbound.close();
    m_worker.request_stop();
    if (m_worker.joinable())
        m_worker.join();
    m_inbound.clear();
    m_inbound.close();
    std::lock_guard lock(m_stateMutex);
    m_knownRequests.clear();
    m_activeRequests.clear();
    m_cancelledPublished.clear();
}

void BridgeService::publishCancelled(const OutboundRequest& request)
{
    InboundResult result{request.id, request.session, request.generation, ResponseKind::cancelled, {},
        makeError(ErrorCode::cancelled, "request cancelled")};
    static_cast<void>(m_inbound.tryPush(std::move(result), true));
}

void BridgeService::workerLoop()
{
    while (auto request = m_outbound.waitPop()) {
        if (m_halted.load(std::memory_order_acquire))
            break;
        const auto cancellation = m_cancellations.token(request->id);
        if (!cancellation || cancellation->stop_requested()) {
            bool publish = false;
            {
                std::lock_guard lock(m_stateMutex);
                publish = m_cancelledPublished.insert(request->id).second;
            }
            if (publish)
                publishCancelled(*request);
            m_cancellations.complete(request->id);
            continue;
        }
        if (!m_generation.isCurrent(request->generation)) {
            m_cancellations.complete(request->id);
            continue;
        }
        {
            std::lock_guard lock(m_stateMutex);
            m_activeRequests.emplace(request->id, *request);
        }
        auto response = m_transport->execute(*request, *cancellation);
        const bool cancelled = cancellation->stop_requested();
        bool cancellationAlreadyPublished = false;
        {
            std::lock_guard lock(m_stateMutex);
            m_activeRequests.erase(request->id);
            cancellationAlreadyPublished = m_cancelledPublished.contains(request->id);
        }
        if (cancelled && !cancellationAlreadyPublished)
            publishCancelled(*request);
        else if (!cancelled && response && response.value().request == request->id
            && (response.value().session == request->session
                || (request->kind == RequestKind::init && request->session.empty()
                    && isCanonicalUuid(response.value().session.value())))
            && response.value().generation == request->generation
            && isCanonicalUuid(response.value().request.value())
            && (request->session.empty() || isCanonicalUuid(response.value().session.value()))
            && m_generation.isCurrent(response.value().generation))
            static_cast<void>(m_inbound.tryPush(std::move(response).value()));
        else if (!cancelled && response && m_generation.isCurrent(request->generation)) {
            InboundResult failure{request->id, request->session, request->generation, ResponseKind::failure, {},
                makeError(ErrorCode::transport_failure, "transport returned inconsistent correlation IDs")};
            static_cast<void>(m_inbound.tryPush(std::move(failure)));
        } else if (!cancelled && !response && m_generation.isCurrent(request->generation)) {
            InboundResult failure{request->id, request->session, request->generation, ResponseKind::failure, {}, response.error()};
            static_cast<void>(m_inbound.tryPush(std::move(failure)));
        }
        m_cancellations.complete(request->id);
    }
}

} // namespace lorkhan
