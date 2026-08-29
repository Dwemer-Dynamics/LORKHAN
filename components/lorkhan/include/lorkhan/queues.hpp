#pragma once

#include "lorkhan/result.hpp"

#include <condition_variable>
#include <cstddef>
#include <algorithm>
#include <deque>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <utility>
#include <vector>

namespace lorkhan {

template <class T>
class BoundedQueue {
public:
    explicit BoundedQueue(std::size_t capacity, std::size_t reservedControl = 0)
        : m_capacity(capacity), m_reservedControl(reservedControl)
    {
        if (capacity == 0 || reservedControl >= capacity)
            throw std::invalid_argument("invalid queue capacity");
    }

    Result<void> tryPush(T item, bool control = false)
    {
        std::lock_guard lock(m_mutex);
        if (m_closed)
            return Result<void>::failure(makeError(ErrorCode::stopped, "queue is closed"));
        const std::size_t normalLimit = m_capacity - m_reservedControl;
        if (m_items.size() >= m_capacity || (!control && m_items.size() >= normalLimit))
            return Result<void>::failure(makeError(ErrorCode::queue_full, "queue is full", true));
        if (control)
            m_items.emplace_front(std::move(item));
        else
            m_items.emplace_back(std::move(item));
        m_ready.notify_one();
        return Result<void>::success();
    }

    [[nodiscard]] std::optional<T> tryPop()
    {
        std::lock_guard lock(m_mutex);
        if (m_items.empty())
            return std::nullopt;
        T item = std::move(m_items.front());
        m_items.pop_front();
        return item;
    }

    [[nodiscard]] std::optional<T> waitPop()
    {
        std::unique_lock lock(m_mutex);
        m_ready.wait(lock, [this] { return m_closed || !m_items.empty(); });
        if (m_items.empty())
            return std::nullopt;
        T item = std::move(m_items.front());
        m_items.pop_front();
        return item;
    }

    [[nodiscard]] std::vector<T> drain(std::size_t maximum)
    {
        std::lock_guard lock(m_mutex);
        std::vector<T> output;
        output.reserve(std::min(maximum, m_items.size()));
        while (!m_items.empty() && output.size() < maximum) {
            output.emplace_back(std::move(m_items.front()));
            m_items.pop_front();
        }
        return output;
    }

    void close()
    {
        std::lock_guard lock(m_mutex);
        m_closed = true;
        m_ready.notify_all();
    }

    void clear()
    {
        std::lock_guard lock(m_mutex);
        m_items.clear();
    }

    template <class Predicate>
    std::size_t eraseIf(Predicate predicate)
    {
        std::lock_guard lock(m_mutex);
        const std::size_t before = m_items.size();
        std::erase_if(m_items, predicate);
        return before - m_items.size();
    }

    [[nodiscard]] std::size_t size() const
    {
        std::lock_guard lock(m_mutex);
        return m_items.size();
    }

    [[nodiscard]] bool closed() const
    {
        std::lock_guard lock(m_mutex);
        return m_closed;
    }

private:
    const std::size_t m_capacity;
    const std::size_t m_reservedControl;
    mutable std::mutex m_mutex;
    std::condition_variable m_ready;
    std::deque<T> m_items;
    bool m_closed{false};
};

} // namespace lorkhan
