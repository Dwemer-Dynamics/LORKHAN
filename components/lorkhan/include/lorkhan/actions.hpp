#pragma once

#include "lorkhan/types.hpp"

#include <cstdint>
#include <mutex>
#include <string>
#include <unordered_map>

namespace lorkhan {

struct ActionTerminalResult {
    ActionId action;
    ActionTerminalStatus status{ActionTerminalStatus::failed};
    std::string reasonCode;
};

struct FollowParameters {
    std::uint32_t distance{};
};

// Protocol v1 currently defines exactly {"distance": 192}; no duration or additional
// wire-visible parameter is accepted by this typed validator.
[[nodiscard]] Result<FollowParameters> validateAiFollow(std::uint32_t distance);

// A queued engine mutation may begin once; cancellation cannot rewrite a committed outcome.
class ActionCommitGate {
public:
    bool queue() { if (m_state != State::fresh) return false; m_state = State::pending; return true; }
    bool begin() { if (m_state != State::pending) return false; m_state = State::executing; return true; }
    bool cancel() { if (m_state != State::fresh && m_state != State::pending) return false; m_state = State::terminal; return true; }
    void finish() { if (m_state == State::executing) m_state = State::terminal; }
private:
    enum class State { fresh, pending, executing, terminal };
    State m_state{State::fresh};
};

class ActionResultRegistry {
public:
    Result<void> registerAction(const ActionId& action, Generation generation);
    Result<void> finish(ActionTerminalResult result);
    std::size_t cancelGeneration(Generation generation);
    [[nodiscard]] bool terminal(const ActionId& action) const;
    void clear();

private:
    struct Entry { Generation generation; bool terminal{}; ActionTerminalStatus status{ActionTerminalStatus::failed}; };
    mutable std::mutex m_mutex;
    std::unordered_map<ActionId, Entry> m_entries;
};

} // namespace lorkhan
