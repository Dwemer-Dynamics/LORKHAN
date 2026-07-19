#pragma once

#include "almsivi/bridge_service.hpp"

#include <memory>

namespace MWAlmsivi {

// OpenMW integration adapter only. This file is intentionally excluded from almsivi_core.
// Every method is called behind an OpenMW main-thread gate and copies native DTOs.
class Bridge final {
public:
    explicit Bridge(std::shared_ptr<almsivi::BridgeService> service);
    almsivi::Result<almsivi::RequestId> submit(almsivi::OutboundRequest request);
    std::vector<almsivi::InboundResult> poll(std::size_t maximumItems);
    void onEngineLifecycleInvalidation();
    void shutdown() noexcept;

private:
    std::shared_ptr<almsivi::BridgeService> m_service;
};

} // namespace MWAlmsivi
