#pragma once

#include "almsivi/types.hpp"

#include <cstdint>
#include <mutex>
#include <string>
#include <unordered_map>

namespace almsivi {

enum class ActionTerminalStatus { succeeded, failed, rejected, timed_out, cancelled };

struct ActionTerminalResult {
    ActionId action;
    ActionTerminalStatus status{ActionTerminalStatus::failed};
    std::string reasonCode;
};

struct FollowParameters {
    double distance{};
    std::uint32_t durationSeconds{};
};

[[nodiscard]] Result<FollowParameters> validateAiFollow(double distance, std::uint32_t durationSeconds);

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

} // namespace almsivi
