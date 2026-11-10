#pragma once

#include "lorkhan/transport.hpp"
#include "lorkhan/validation.hpp"

#include <chrono>
#include <filesystem>
#include <memory>
#include <optional>

namespace lorkhan {

// Bounded, unauthenticated endpoint lookup; pairing material is never sent to discovery.
std::optional<BaseUrl> discoverLocalServer(std::stop_token cancellation,
    std::uint16_t port = 7135);

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
        // A loaded-save init may capture the previous timeline before accepting the session.
        std::chrono::milliseconds loadedSaveFirstByte{20000};
    };

    BeastTransport(BaseUrl baseUrl, InstallationId installation, PairingToken token,
        std::filesystem::path mediaCacheRoot);
    BeastTransport(BaseUrl baseUrl, InstallationId installation, PairingToken token,
        std::filesystem::path mediaCacheRoot, Deadlines deadlines);
    ~BeastTransport() override;
    Result<InboundResult> execute(const OutboundRequest& request, std::stop_token cancellation) override;
    Result<InboundResult> executeBackground(const OutboundRequest& request, std::stop_token cancellation,
        const std::function<void()>& yield) override;
    void interrupt(const RequestId& request) noexcept override;
    void setConnectionTimeout(int seconds);
    void enableDiscovery();

private:
    // Paired request-MAC headers for one exact method, target, content type and body.
    [[nodiscard]] Headers authorizationHeaders(std::string_view method, std::string_view target,
        std::string_view contentType, std::string_view body) const;
    // Probe, chunked upload, install/update and operation polling, each as its own signed exchange.
    [[nodiscard]] Result<InboundResult> executePackageSync(const OutboundRequest& request,
        const PluginPackageSyncRequest& sync, std::stop_token cancellation, const std::function<void()>& yield = {});

    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace lorkhan
