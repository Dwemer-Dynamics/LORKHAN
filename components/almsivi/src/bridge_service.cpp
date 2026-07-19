#include "almsivi/bridge_service.hpp"

#include "almsivi/validation.hpp"

#include <algorithm>

namespace almsivi {

BridgeService::BridgeService(std::unique_ptr<ITransport> transport, std::shared_ptr<IClock> clock)
    : m_transport(std::move(transport)), m_clock(std::move(clock))
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
    if (request.id.empty())
        return Result<void>::failure(makeError(ErrorCode::invalid_argument, "request ID is empty"));
    if (request.generation != m_generation.current())
        return Result<void>::failure(makeError(ErrorCode::stale_generation, "request generation is stale"));
    if (request.kind != RequestKind::health && request.session.empty())
        return Result<void>::failure(makeError(ErrorCode::invalid_argument, "session ID is required"));
    const auto validatePayload = [](std::string_view value, std::size_t limit) -> Result<void> {
        auto valid = requireValidUtf8(value, limit);
        return valid ? Result<void>::success() : Result<void>::failure(valid.error());
    };
    if (const auto* turn = std::get_if<TurnRequest>(&request.payload))
        return validatePayload(turn->serializedPayload, kMaxJsonBytes);
    if (const auto* action = std::get_if<ActionResultRequest>(&request.payload))
        return validatePayload(action->serializedPayload, kMaxJsonBytes);
    if (const auto* stt = std::get_if<SttRequest>(&request.payload)) {
        if (stt->audio.empty() || stt->audio.size() > kMaxSttBytes)
            return Result<void>::failure(makeError(ErrorCode::invalid_argument, "STT body is outside size limit"));
        if (stt->codec != "wav" && stt->codec != "ogg" && stt->codec != "webm")
            return Result<void>::failure(makeError(ErrorCode::invalid_argument, "STT codec is not allowed"));
    }
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
    maximumItems = std::min(maximumItems, kMaxPollItems);
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
    if (cancelled)
        publishCancelled(*cancelled);
    m_transport->interrupt();
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
    m_transport->interrupt();
    return Result<Generation>::success(m_generation.invalidate());
}

void BridgeService::halt() noexcept
{
    if (m_halted.exchange(true, std::memory_order_acq_rel))
        return;
    m_generation.invalidate();
    m_cancellations.cancelAll();
    m_transport->interrupt();
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
        else if (!cancelled && response && m_generation.isCurrent(response.value().generation))
            static_cast<void>(m_inbound.tryPush(std::move(response).value()));
        else if (!cancelled && !response && m_generation.isCurrent(request->generation)) {
            InboundResult failure{request->id, request->session, request->generation, ResponseKind::failure, {}, response.error()};
            static_cast<void>(m_inbound.tryPush(std::move(failure)));
        }
        m_cancellations.complete(request->id);
    }
}

} // namespace almsivi
