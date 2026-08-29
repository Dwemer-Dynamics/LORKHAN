#pragma once

#include "lorkhan/actions.hpp"
#include "lorkhan/events.hpp"
#include "lorkhan/lifecycle.hpp"
#include "lorkhan/queues.hpp"
#include "lorkhan/transport.hpp"

#include <atomic>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace lorkhan {

struct BridgeDiagnostics {
    std::size_t outbound{};
    std::size_t inbound{};
    std::size_t active{};
    std::size_t cancellations{};
};

// Thread ownership contract:
// - OpenMW's engine/main thread validates and copies DTOs before calling enqueue/poll/control.
// - The sole worker owns ITransport. It never receives or retains engine, sol, VFS, or UI objects.
// - poll returns immutable native DTOs; the caller re-resolves engine identity behind its main-thread gate.
class BridgeService {
public:
    BridgeService(std::unique_ptr<ITransport> transport, std::shared_ptr<IClock> clock,
        Generation initialGeneration = Generation());
    ~BridgeService();
    BridgeService(const BridgeService&) = delete;
    BridgeService& operator=(const BridgeService&) = delete;

    [[nodiscard]] Generation generation() const noexcept { return m_generation.current(); }
    [[nodiscard]] Result<RequestId> enqueue(OutboundRequest request);
    [[nodiscard]] std::vector<InboundResult> poll(std::size_t maximumItems);
    [[nodiscard]] Result<void> cancel(const RequestId& request);
    [[nodiscard]] Result<Generation> cancelGeneration(Generation generation);
    [[nodiscard]] BridgeDiagnostics diagnostics() const;
    void halt() noexcept;
    [[nodiscard]] bool halted() const noexcept { return m_halted.load(std::memory_order_acquire); }

private:
    void workerLoop();
    void publishCancelled(const OutboundRequest& request);
    [[nodiscard]] Result<void> validateRequest(const OutboundRequest& request) const;

    std::unique_ptr<ITransport> m_transport;
    std::shared_ptr<IClock> m_clock;
    BoundedQueue<OutboundRequest> m_outbound{kOutboundCapacity, kReservedControlCapacity};
    BoundedQueue<InboundResult> m_inbound{kInboundCapacity, kReservedControlCapacity};
    GenerationState m_generation;
    CancellationRegistry m_cancellations;
    std::jthread m_worker;
    std::atomic<bool> m_halted{false};
    mutable std::mutex m_stateMutex;
    std::unordered_set<RequestId> m_knownRequests;
    std::unordered_map<RequestId, OutboundRequest> m_activeRequests;
    std::unordered_set<RequestId> m_cancelledPublished;
};

} // namespace lorkhan
