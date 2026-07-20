#include "almsivi/lifecycle.hpp"

namespace almsivi {

Result<std::stop_token> CancellationRegistry::registerRequest(const RequestId& request, Generation generation)
{
    if (request.empty())
        return Result<std::stop_token>::failure(makeError(ErrorCode::invalid_argument, "request ID is empty"));
    std::lock_guard lock(m_mutex);
    const auto [iterator, inserted] = m_entries.emplace(request, Entry{generation, {}});
    if (!inserted)
        return Result<std::stop_token>::failure(makeError(ErrorCode::duplicate_conflict, "request ID already registered"));
    return Result<std::stop_token>::success(iterator->second.source.get_token());
}

bool CancellationRegistry::cancel(const RequestId& request)
{
    std::lock_guard lock(m_mutex);
    const auto found = m_entries.find(request);
    return found != m_entries.end() && found->second.source.request_stop();
}

std::optional<std::stop_token> CancellationRegistry::token(const RequestId& request) const
{
    std::lock_guard lock(m_mutex);
    const auto found = m_entries.find(request);
    if (found == m_entries.end())
        return std::nullopt;
    return found->second.source.get_token();
}

std::size_t CancellationRegistry::cancelGeneration(Generation generation)
{
    std::lock_guard lock(m_mutex);
    std::size_t cancelled = 0;
    for (auto& [request, entry] : m_entries) {
        static_cast<void>(request);
        if (entry.generation == generation && entry.source.request_stop())
            ++cancelled;
    }
    return cancelled;
}

std::size_t CancellationRegistry::cancelAll()
{
    std::lock_guard lock(m_mutex);
    std::size_t cancelled = 0;
    for (auto& [request, entry] : m_entries) {
        static_cast<void>(request);
        if (entry.source.request_stop())
            ++cancelled;
    }
    return cancelled;
}

void CancellationRegistry::complete(const RequestId& request)
{
    std::lock_guard lock(m_mutex);
    m_entries.erase(request);
}

std::size_t CancellationRegistry::size() const
{
    std::lock_guard lock(m_mutex);
    return m_entries.size();
}

} // namespace almsivi
