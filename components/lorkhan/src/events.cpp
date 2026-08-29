#include "lorkhan/events.hpp"

#include "lorkhan/validation.hpp"

namespace lorkhan {

EventDecision EventTracker::observe(const EventIdentity& event)
{
    if (!isCanonicalUuid(event.session.value()) || !isCanonicalUuid(event.message.value()) || event.sequence == 0)
        return {EventDisposition::invalid, 0};
    std::lock_guard lock(m_mutex);
    auto& state = m_sessions[event.session];
    const std::uint64_t expected = state.cursor + 1;
    if (event.sequence <= state.cursor || state.messages.contains(event.message))
        return {EventDisposition::duplicate, expected};
    if (event.sequence != expected)
        return {EventDisposition::gap, expected};
    state.cursor = event.sequence;
    state.messages.insert(event.message);
    return {EventDisposition::accepted, state.cursor + 1};
}

std::uint64_t EventTracker::cursor(const SessionId& session) const
{
    std::lock_guard lock(m_mutex);
    const auto found = m_sessions.find(session);
    return found == m_sessions.end() ? 0 : found->second.cursor;
}

void EventTracker::reset(const SessionId& session)
{
    std::lock_guard lock(m_mutex);
    m_sessions.erase(session);
}

void EventTracker::resetAll()
{
    std::lock_guard lock(m_mutex);
    m_sessions.clear();
}

} // namespace lorkhan
