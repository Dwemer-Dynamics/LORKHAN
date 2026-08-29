#include "lorkhan/actions.hpp"

#include "lorkhan/validation.hpp"

namespace lorkhan {

Result<FollowParameters> validateAiFollow(std::uint32_t distance)
{
    if (distance != 192)
        return Result<FollowParameters>::failure(makeError(ErrorCode::invalid_action, "ai.follow distance must equal 192"));
    return Result<FollowParameters>::success(FollowParameters{distance});
}

Result<void> ActionResultRegistry::registerAction(const ActionId& action, Generation generation)
{
    if (!isCanonicalUuid(action.value()))
        return Result<void>::failure(makeError(ErrorCode::invalid_action, "action ID must be a canonical lowercase UUID"));
    std::lock_guard lock(m_mutex);
    if (!m_entries.emplace(action, Entry{generation, false, {}}).second)
        return Result<void>::failure(makeError(ErrorCode::duplicate_conflict, "action ID already exists"));
    return Result<void>::success();
}

Result<void> ActionResultRegistry::finish(ActionTerminalResult result)
{
    if (!isCanonicalUuid(result.action.value()))
        return Result<void>::failure(makeError(ErrorCode::invalid_action, "action ID must be a canonical lowercase UUID"));
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

} // namespace lorkhan
