#pragma once

#include "lorkhan/result.hpp"

#include <array>
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

namespace lorkhan {

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

// Native scheduling correlation is separate from schema-owned action-result JSON fields.
struct RequestCorrelation {
    RequestId request;
    SessionId session;
    Generation generation;
};

struct HealthRequest {};
struct InitRequest {
    EnvelopeIds ids;
    RuntimeInfo runtime;
    std::string contentFingerprint;
    std::string createdAt;
};
struct TurnRequest {
    EnvelopeIds ids;
    Generation runtimeGeneration;
    RuntimeInfo runtime;
    std::string contentFingerprint;
    std::string createdAt;
    // A JSON object containing only the schema-owned `payload` member. The transport
    // constructs the envelope and never accepts a caller-selected method, route, or header.
    std::string serializedPayload;
};
struct EventPollRequest {
    SessionId session;
    Generation generation;
    std::uint64_t after{};
    std::uint32_t waitMs{};
};
struct InterruptionRequest {
    MessageId message;
    RequestId request;
    TurnId turn;
    SessionId session;
    Generation generation;
    std::string createdAt;
    std::string reason;
};
enum class ActionTerminalStatus { succeeded, failed, rejected, timed_out, cancelled };

struct ActionResultRequest {
    MessageId message;
    RequestCorrelation correlation;
    ActionId action;
    TurnId turn;
    ActionTerminalStatus status{ActionTerminalStatus::failed};
    std::string reasonCode;
    // A bounded JSON object containing schema-owned observations only.
    std::string serializedObserved;
    std::string completedAt;
};
struct SessionEndRequest {
    RequestId request;
    SessionId session;
    Generation generation;
};
struct SttRequest {
    EnvelopeIds ids;
    std::string createdAt;
    std::string codec;
    std::string language;
    std::string sha256;
    std::vector<std::byte> audio;
};
enum class DialogueDeliveryStatus { played, failed, expired, interrupted };
struct DialogueDeliveryResultRequest {
    MessageId message;
    RequestCorrelation correlation;
    MessageId dialogueMessage;
    TurnId turn;
    std::string serializedSpeaker;
    DialogueDeliveryStatus status{DialogueDeliveryStatus::failed};
    std::string reasonCode;
    std::string completedAt;
};

struct ControlsQueryRequest {
    MessageId message;
    RequestCorrelation correlation;
    std::string serializedTarget;
};

struct DebugCommandQueryRequest {
    MessageId message;
    RequestCorrelation correlation;
};

enum class DebugCommandResultStatus { succeeded, failed, rejected };
struct DebugCommandResultRequest {
    MessageId message;
    RequestCorrelation correlation;
    MessageId command;
    DebugCommandResultStatus status{DebugCommandResultStatus::failed};
    std::string reasonCode;
    std::string serializedObserved;
    std::string completedAt;
};

enum class SessionControlKind { model_slot, actor_profile, profile_generate, narrator_profile_generate };
struct ControlsSelectRequest {
    MessageId message;
    RequestCorrelation correlation;
    std::string createdAt;
    SessionControlKind kind{SessionControlKind::model_slot};
    std::optional<std::string> selectionId;
    std::optional<std::string> selectionKey;
    std::string serializedTarget;
};

struct MenuDialogueTtsRequest {
    MessageId message;
    RequestCorrelation correlation;
    std::string createdAt;
    std::string serializedActor;
    std::string text;
};

struct GameDataRequest {
    InstallationId installation;
    PlaythroughId playthrough;
    RequestId request;
    Generation runtimeGeneration;
    std::string observedAt;
    // A strict schema-owned captured_dialogue JSON object.
    std::string serializedPayload;
};

enum class MediaCodec { wav, ogg, mp3 };

struct MediaDescriptor {
    MediaId id;
    std::array<std::byte, 32> sha256{};
    std::size_t bytes{};
    MediaCodec codec{MediaCodec::wav};
    std::chrono::system_clock::time_point expiresAt;
};

struct MediaPrepareRequest {
    RequestCorrelation correlation;
    MediaDescriptor descriptor;
};

struct PreparedMedia {
    MediaId id;
    std::size_t bytes{};
    MediaCodec codec{MediaCodec::wav};
};

using RequestPayload = std::variant<HealthRequest, InitRequest, TurnRequest, EventPollRequest,
    InterruptionRequest, ActionResultRequest, SessionEndRequest, SttRequest,
    DialogueDeliveryResultRequest, ControlsQueryRequest, ControlsSelectRequest, DebugCommandQueryRequest,
    DebugCommandResultRequest, MenuDialogueTtsRequest, GameDataRequest,
    MediaPrepareRequest>;

enum class RequestKind {
    health,
    init,
    turn,
    event_poll,
    interruption,
    action_result,
    dialogue_delivery_result,
    session_end,
    stt,
    controls_query,
    controls_select,
    debug_command_query,
    debug_command_result,
    menu_dialogue_tts,
    gamedata,
    media,
};

enum class ResponseKind { accepted, event, completed, failure, cancelled, media_ready, menu_dialogue_ready, status, controls, debug_command };

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

class BeastTransport;

class PairingToken {
public:
    using Secret = std::array<std::byte, 32>;

    PairingToken() = default;
    explicit PairingToken(Secret secret) noexcept : m_secret(secret), m_present(true) {}
    PairingToken(const PairingToken&) = delete;
    PairingToken& operator=(const PairingToken&) = delete;
    PairingToken(PairingToken&& other) noexcept : m_secret(other.m_secret), m_present(other.m_present) { other.clear(); }
    PairingToken& operator=(PairingToken&& other) noexcept
    {
        if (this != &other) {
            clear();
            m_secret = other.m_secret;
            m_present = other.m_present;
            other.clear();
        }
        return *this;
    }
    ~PairingToken() { clear(); }

    [[nodiscard]] bool empty() const noexcept { return !m_present; }
    [[nodiscard]] std::string redacted() const { return m_present ? "<redacted>" : "<unset>"; }

private:
    friend class BeastTransport;
    [[nodiscard]] std::string authorizationToken() const;
    [[nodiscard]] const Secret& macKey() const noexcept { return m_secret; }

    void clear() noexcept
    {
        volatile std::byte* memory = m_secret.data();
        for (std::size_t i = 0; i < m_secret.size(); ++i)
            memory[i] = std::byte{0};
        m_present = false;
    }

    Secret m_secret{};
    bool m_present{false};
};

} // namespace lorkhan

namespace std {
template <class Tag>
struct hash<lorkhan::StrongId<Tag>> {
    std::size_t operator()(const lorkhan::StrongId<Tag>& id) const noexcept
    {
        return std::hash<std::string>{}(id.value());
    }
};
} // namespace std
