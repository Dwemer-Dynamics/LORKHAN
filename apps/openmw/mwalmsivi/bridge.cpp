#include "bridge.hpp"

#include <stdexcept>

namespace MWAlmsivi {

Bridge::Bridge(std::shared_ptr<almsivi::BridgeService> service) : m_service(std::move(service))
{
    if (!m_service)
        throw std::invalid_argument("MWAlmsivi::Bridge requires a service");
}

almsivi::Result<almsivi::RequestId> Bridge::submit(almsivi::OutboundRequest request)
{
    // OpenMW patch registration must assert the engine main thread before entering here.
    return m_service->enqueue(std::move(request));
}

std::vector<almsivi::InboundResult> Bridge::poll(std::size_t maximumItems)
{
    // Engine identities are deliberately absent. Lua bindings re-resolve them after poll.
    return m_service->poll(maximumItems);
}

void Bridge::onEngineLifecycleInvalidation()
{
    static_cast<void>(m_service->cancelGeneration(m_service->generation()));
}

void Bridge::shutdown() noexcept
{
    m_service->halt();
}

} // namespace MWAlmsivi
