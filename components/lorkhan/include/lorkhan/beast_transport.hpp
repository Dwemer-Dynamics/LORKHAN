#pragma once

#include "lorkhan/transport.hpp"
#include "lorkhan/validation.hpp"

#include <chrono>
#include <filesystem>
#include <memory>

namespace lorkhan {

// Compile-optional literal-loopback HTTP/1.1 transport. It accepts only a prevalidated
// BaseUrl and exposes no generic method, URL, header, or response-following surface.
class BeastTransport final : public ITransport {
public:
    struct Deadlines {
        std::chrono::milliseconds connect{2000};
        std::chrono::milliseconds write{5000};
        std::chrono::milliseconds firstByte{5000};
        std::chrono::milliseconds read{20000};
        std::chrono::milliseconds total{30000};
    };

    BeastTransport(BaseUrl baseUrl, InstallationId installation, PairingToken token,
        std::filesystem::path mediaCacheRoot);
    BeastTransport(BaseUrl baseUrl, InstallationId installation, PairingToken token,
        std::filesystem::path mediaCacheRoot, Deadlines deadlines);
    ~BeastTransport() override;
    Result<InboundResult> execute(const OutboundRequest& request, std::stop_token cancellation) override;
    void interrupt(const RequestId& request) noexcept override;

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace lorkhan
