#pragma once

#include "almsivi/result.hpp"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

namespace almsivi {

inline constexpr std::string_view kClientVersion = "0.1.0";
inline constexpr std::string_view kOpenMwVersion = "0.51.0";
inline constexpr std::string_view kOpenMwCommit = "f4bec41444214a7903bebd178389ca22ca13f646";
inline constexpr std::uint32_t kLuaApiRevision = 129;
inline constexpr std::size_t kMaxJsonBytes = 2U * 1024U * 1024U;
inline constexpr std::size_t kMaxSttBytes = 16U * 1024U * 1024U;
inline constexpr std::size_t kMaxMediaBytes = 32U * 1024U * 1024U;
inline constexpr std::size_t kMaxContextBytes = 128U * 1024U;
inline constexpr std::size_t kOutboundCapacity = 32U;
inline constexpr std::size_t kInboundCapacity = 128U;
inline constexpr std::size_t kReservedControlCapacity = 4U;
inline constexpr std::uint32_t kMaxAudienceActors = 12U;
inline constexpr std::uint32_t kMaxActionsPerTurn = 4U;
inline constexpr std::uint32_t kMaxActionContinuations = 1U;

template <class Tag>
class StrongId {
public:
    StrongId() = default;
    explicit StrongId(std::string value) : m_value(std::move(value)) {}

    [[nodiscard]] const std::string& value() const noexcept { return m_value; }
    [[nodiscard]] bool empty() const noexcept { return m_value.empty(); }

    friend bool operator==(const StrongId&, const StrongId&) = default;
    friend auto operator<=>(const StrongId&, const StrongId&) = default;

private:
    std::string m_value;
};

struct InstallationIdTag;
struct ProfileIdTag;
struct PlaythroughIdTag;
struct SessionIdTag;
struct RequestIdTag;
struct TurnIdTag;
struct MessageIdTag;
struct ActionIdTag;
struct MediaIdTag;

using InstallationId = StrongId<InstallationIdTag>;
using ProfileId = StrongId<ProfileIdTag>;
using PlaythroughId = StrongId<PlaythroughIdTag>;
using SessionId = StrongId<SessionIdTag>;
using RequestId = StrongId<RequestIdTag>;
using TurnId = StrongId<TurnIdTag>;
using MessageId = StrongId<MessageIdTag>;
using ActionId = StrongId<ActionIdTag>;
using MediaId = StrongId<MediaIdTag>;

class Generation {
public:
    constexpr explicit Generation(std::uint64_t value = 0) : m_value(value) {}
    [[nodiscard]] constexpr std::uint64_t value() const noexcept { return m_value; }
    friend constexpr bool operator==(Generation, Generation) = default;
    friend constexpr auto operator<=>(Generation, Generation) = default;

private:
    std::uint64_t m_value;
};

struct RuntimeInfo {
    std::string game{"tes3"};
    std::string variant{"openmw"};
    std::string openmwVersion{std::string(kOpenMwVersion)};
    std::string openmwCommit{std::string(kOpenMwCommit)};
    std::uint32_t luaApiRevision{kLuaApiRevision};
    std::string clientVersion{std::string(kClientVersion)};
    std::string platform;
    std::vector<std::string> capabilities;
};

struct EnvelopeIds {
    InstallationId installation;
    ProfileId profile;
    PlaythroughId playthrough;
    SessionId session;
    RequestId request;
    TurnId turn;
    MessageId message;
    Generation generation;
};

struct HealthRequest {};
struct InitRequest { EnvelopeIds ids; RuntimeInfo runtime; std::string contentFingerprint; };
struct TurnRequest { EnvelopeIds ids; std::string serializedPayload; };
struct ActionResultRequest { EnvelopeIds ids; ActionId action; std::string serializedPayload; };
struct SttRequest { EnvelopeIds ids; std::string codec; std::vector<std::byte> audio; };

using RequestPayload = std::variant<HealthRequest, InitRequest, TurnRequest, ActionResultRequest, SttRequest>;

enum class RequestKind { health, init, turn, action_result, stt, event_poll, media };

enum class ResponseKind { accepted, event, completed, failure, cancelled, media_ready, status };

struct OutboundRequest {
    RequestId id;
    SessionId session;
    Generation generation;
    RequestKind kind{RequestKind::health};
    RequestPayload payload{HealthRequest{}};
};

struct InboundResult {
    RequestId request;
    SessionId session;
    Generation generation;
    ResponseKind kind{ResponseKind::status};
    std::string payload;
    std::optional<Error> failure;
};

class PairingToken {
public:
    PairingToken() = default;
    explicit PairingToken(std::string token) : m_token(std::move(token)) {}
    PairingToken(const PairingToken&) = delete;
    PairingToken& operator=(const PairingToken&) = delete;
    PairingToken(PairingToken&& other) noexcept : m_token(std::move(other.m_token)) { other.clear(); }
    PairingToken& operator=(PairingToken&& other) noexcept
    {
        if (this != &other) {
            clear();
            m_token = std::move(other.m_token);
            other.clear();
        }
        return *this;
    }
    ~PairingToken() { clear(); }

    [[nodiscard]] bool empty() const noexcept { return m_token.empty(); }
    [[nodiscard]] std::string redacted() const { return m_token.empty() ? "<unset>" : "<redacted>"; }

private:
    void clear() noexcept
    {
        volatile char* memory = m_token.empty() ? nullptr : m_token.data();
        for (std::size_t i = 0; i < m_token.size(); ++i)
            memory[i] = 0;
        m_token.clear();
    }

    std::string m_token;
};

} // namespace almsivi

namespace std {
template <class Tag>
struct hash<almsivi::StrongId<Tag>> {
    std::size_t operator()(const almsivi::StrongId<Tag>& id) const noexcept
    {
        return std::hash<std::string>{}(id.value());
    }
};
} // namespace std
