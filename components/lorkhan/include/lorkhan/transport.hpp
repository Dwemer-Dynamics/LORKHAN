#pragma once

#include "lorkhan/media.hpp"
#include "lorkhan/types.hpp"

#include <chrono>
#include <stop_token>

namespace lorkhan {

class IClock {
public:
    virtual ~IClock() = default;
    [[nodiscard]] virtual std::chrono::steady_clock::time_point steadyNow() const noexcept = 0;
    [[nodiscard]] virtual std::chrono::system_clock::time_point systemNow() const noexcept = 0;
};

class SystemClock final : public IClock {
public:
    [[nodiscard]] std::chrono::steady_clock::time_point steadyNow() const noexcept override
    {
        return std::chrono::steady_clock::now();
    }
    [[nodiscard]] std::chrono::system_clock::time_point systemNow() const noexcept override
    {
        return std::chrono::system_clock::now();
    }
};

class ITransport {
public:
    virtual ~ITransport() = default;
    virtual Result<InboundResult> execute(const OutboundRequest& request, std::stop_token cancellation) = 0;
    // Interrupt only the operation currently owned by request. Implementations must ignore a
    // late interrupt after that request has completed and must not mutate a socket from another thread.
    virtual void interrupt(const RequestId& request) noexcept = 0;
};

} // namespace lorkhan
