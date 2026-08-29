#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <utility>

namespace lorkhan {

enum class ErrorCode {
    invalid_argument,
    invalid_utf8,
    invalid_url,
    invalid_header,
    invalid_content_type,
    invalid_json,
    invalid_schema,
    payload_too_large,
    timeout,
    unauthorized,
    forbidden,
    rate_limited,
    unknown_session,
    cursor_expired,
    provider_unavailable,
    action_disabled,
    internal_error,
    redirect_rejected,
    queue_full,
    stopped,
    cancelled,
    stale_generation,
    duplicate_conflict,
    cursor_gap,
    invalid_action,
    media_rejected,
    transport_failure,
};

struct Error {
    ErrorCode code{ErrorCode::invalid_argument};
    std::string message;
    bool retriable{false};
    std::optional<std::uint64_t> retryAfterMs;
    std::optional<std::string> correlationId;

    friend bool operator==(const Error&, const Error&) = default;
};

template <class T>
class Result {
public:
    static Result success(T value) { return Result(std::move(value)); }
    static Result failure(Error error) { return Result(std::move(error)); }

    [[nodiscard]] bool hasValue() const noexcept { return m_value.has_value(); }
    [[nodiscard]] explicit operator bool() const noexcept { return hasValue(); }
    [[nodiscard]] const T& value() const& { return m_value.value(); }
    [[nodiscard]] T&& value() && { return std::move(m_value).value(); }
    [[nodiscard]] const Error& error() const& { return m_error.value(); }

private:
    explicit Result(T value) : m_value(std::move(value)) {}
    explicit Result(Error error) : m_error(std::move(error)) {}

    std::optional<T> m_value;
    std::optional<Error> m_error;
};

template <>
class Result<void> {
public:
    static Result success() { return Result(); }
    static Result failure(Error error) { return Result(std::move(error)); }

    [[nodiscard]] bool hasValue() const noexcept { return !m_error.has_value(); }
    [[nodiscard]] explicit operator bool() const noexcept { return hasValue(); }
    [[nodiscard]] const Error& error() const& { return m_error.value(); }

private:
    Result() = default;
    explicit Result(Error error) : m_error(std::move(error)) {}

    std::optional<Error> m_error;
};

inline Error makeError(ErrorCode code, std::string message, bool retriable = false,
    std::optional<std::uint64_t> retryAfterMs = std::nullopt,
    std::optional<std::string> correlationId = std::nullopt)
{
    return Error{code, std::move(message), retriable, retryAfterMs, std::move(correlationId)};
}

} // namespace lorkhan
