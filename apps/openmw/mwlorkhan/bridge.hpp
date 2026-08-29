#pragma once

#include "lorkhan/bridge_service.hpp"

#include <memory>

namespace MWLorkhan {

// OpenMW integration adapter only. This file is intentionally excluded from lorkhan_core.
// Every method is called behind an OpenMW main-thread gate and copies native DTOs.
class Bridge final {
public:
    explicit Bridge(std::shared_ptr<lorkhan::BridgeService> service);
    lorkhan::Result<lorkhan::RequestId> submit(lorkhan::OutboundRequest request);
    std::vector<lorkhan::InboundResult> poll(std::size_t maximumItems);
    void onEngineLifecycleInvalidation();
    void shutdown() noexcept;

private:
    std::shared_ptr<lorkhan::BridgeService> m_service;
};

} // namespace MWLorkhan
