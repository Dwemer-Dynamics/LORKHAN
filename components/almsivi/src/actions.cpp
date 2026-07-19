#include "almsivi/actions.hpp"

#include <cmath>

namespace almsivi {

Result<FollowParameters> validateAiFollow(double distance, std::uint32_t durationSeconds)
{
    if (!std::isfinite(distance) || distance < 0.0 || distance > 2048.0)
        return Result<FollowParameters>::failure(makeError(ErrorCode::invalid_action, "ai.follow distance must be within 0..2048"));
    if (durationSeconds == 0 || durationSeconds > 3600)
        return Result<FollowParameters>::failure(makeError(ErrorCode::invalid_action, "ai.follow duration must be within 1..3600 seconds"));
    return Result<FollowParameters>::success(FollowParameters{distance, durationSeconds});
}

Result<void> ActionResultRegistry::registerAction(const ActionId& action, Generation generation)
{
    if (action.empty())
        return Result<void>::failure(makeError(ErrorCode::invalid_action, "action ID is empty"));
    std::lock_guard lock(m_mutex);
    if (!m_entries.emplace(action, Entry{generation, false, {}}).second)
        return Result<void>::failure(makeError(ErrorCode::duplicate_conflict, "action ID already exists"));
    return Result<void>::success();
}

Result<void> ActionResultRegistry::finish(ActionTerminalResult result)
{
    std::lock_guard lock(m_mutex);
    const auto found = m_entries.find(result.action);
    if (found == m_entries.end())
        return Result<void>::failure(makeError(ErrorCode::invalid_action, "unknown action ID"));
    if (found->second.terminal)
        return Result<void>::failure(makeError(ErrorCode::duplicate_conflict, "terminal action result already recorded"));
    found->second.terminal = true;
    found->second.status = result.status;
    return Result<void>::success();
}

std::size_t ActionResultRegistry::cancelGeneration(Generation generation)
{
    std::lock_guard lock(m_mutex);
    std::size_t count = 0;
    for (auto& [action, entry] : m_entries) {
        static_cast<void>(action);
        if (entry.generation == generation && !entry.terminal) {
            entry.terminal = true;
            entry.status = ActionTerminalStatus::cancelled;
            ++count;
        }
    }
    return count;
}

bool ActionResultRegistry::terminal(const ActionId& action) const
{
    std::lock_guard lock(m_mutex);
    const auto found = m_entries.find(action);
    return found != m_entries.end() && found->second.terminal;
}

void ActionResultRegistry::clear()
{
    std::lock_guard lock(m_mutex);
    m_entries.clear();
}

} // namespace almsivi
