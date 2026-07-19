#pragma once

#include "almsivi/transport.hpp"
#include "almsivi/validation.hpp"

namespace almsivi {

// Compile-optional transport seam. The production implementation is enabled only when
// ALMSIVI_WITH_BOOST_BEAST is set and Boost.System is available. Tests never open sockets.
#ifdef ALMSIVI_WITH_BOOST_BEAST
class BeastTransport final : public ITransport {
public:
    BeastTransport(BaseUrl baseUrl, PairingToken token);
    ~BeastTransport() override;
    Result<InboundResult> execute(const OutboundRequest& request, std::stop_token cancellation) override;
    void interrupt() noexcept override;

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};
#endif

} // namespace almsivi
