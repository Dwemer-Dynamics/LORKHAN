#pragma once

#include "almsivi/types.hpp"

#include <cstdint>
#include <mutex>
#include <unordered_map>
#include <unordered_set>

namespace almsivi {

struct EventIdentity {
    SessionId session;
    std::uint64_t sequence{};
    MessageId message;
};

enum class EventDisposition { accepted, duplicate, gap };

struct EventDecision {
    EventDisposition disposition{EventDisposition::accepted};
    std::uint64_t expectedSequence{};
};

class EventTracker {
public:
    EventDecision observe(const EventIdentity& event);
    [[nodiscard]] std::uint64_t cursor(const SessionId& session) const;
    void reset(const SessionId& session);
    void resetAll();

private:
    struct SessionState {
        std::uint64_t cursor{};
        std::unordered_set<MessageId> messages;
    };
    mutable std::mutex m_mutex;
    std::unordered_map<SessionId, SessionState> m_sessions;
};

} // namespace almsivi
