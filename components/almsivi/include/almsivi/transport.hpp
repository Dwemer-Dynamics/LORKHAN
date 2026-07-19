#pragma once

#include "almsivi/media.hpp"
#include "almsivi/types.hpp"

#include <chrono>
#include <stop_token>

namespace almsivi {

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
    virtual void interrupt() noexcept = 0;
};

} // namespace almsivi
