#pragma once

#include "lorkhan/types.hpp"

#include <atomic>
#include <mutex>
#include <stop_token>
#include <unordered_map>

namespace lorkhan {

class GenerationState {
public:
    explicit GenerationState(Generation initial = Generation()) noexcept : m_generation(initial.value()) {}
    [[nodiscard]] Generation current() const noexcept { return Generation(m_generation.load(std::memory_order_acquire)); }
    [[nodiscard]] bool isCurrent(Generation generation) const noexcept { return current() == generation; }
    Generation invalidate() noexcept { return Generation(m_generation.fetch_add(1, std::memory_order_acq_rel) + 1); }

private:
    std::atomic<std::uint64_t> m_generation;
};

class CancellationRegistry {
public:
    Result<std::stop_token> registerRequest(const RequestId& request, Generation generation);
    bool cancel(const RequestId& request);
    [[nodiscard]] std::optional<std::stop_token> token(const RequestId& request) const;
    std::size_t cancelGeneration(Generation generation);
    std::size_t cancelAll();
    void complete(const RequestId& request);
    [[nodiscard]] std::size_t size() const;

private:
    struct Entry { Generation generation; std::stop_source source; };
    mutable std::mutex m_mutex;
    std::unordered_map<RequestId, Entry> m_entries;
};

} // namespace lorkhan
