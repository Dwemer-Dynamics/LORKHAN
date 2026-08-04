#pragma once

#include "almsivi/actions.hpp"
#include "almsivi/json.hpp"
#include "almsivi/media.hpp"
#include "almsivi/types.hpp"
#include "almsivi/validation.hpp"

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

namespace almsivi {

struct ProtocolError {
    ErrorCode code{ErrorCode::invalid_schema};
    std::string correlationId;
    bool retriable{};
    std::optional<std::uint64_t> retryAfterMs;
};

struct ClientBehaviorSettings {
    bool autoGreeting{};
    bool rechat{};
    std::uint64_t rechatDelaySeconds{45};
    std::uint64_t rechatMaxDepth{10};
    bool boredom{};
    std::uint64_t boredomDelaySeconds{180};
    bool combatBarks{};
    std::uint64_t combatBarkPeriodSeconds{20};
};

struct ClientMemorySettings {
    std::uint64_t recentTurnLimit{20};
    std::uint64_t knowledgeLimit{5};
};

struct ClientNarratorSettings {
    bool enabled{};
    std::string name{"The Narrator"};
    bool contextVisibility{true};
    std::string inlineMode{"Disabled"};
    bool welcomeEvents{};
    bool randomEvents{};
    bool questEvents{};
    bool bookEvents{};
};

struct ClientPresentationSettings {
    bool showStatusHud{true};
    std::uint64_t transcriptRows{8};
    std::uint64_t ttsVolumeBoost{3};
};

struct ClientSafetySettings {
    bool actionsEnabled{true};
    bool allowHostile{};
    bool allowCreatures{};
};

struct ClientSettings {
    ClientBehaviorSettings behavior;
    ClientMemorySettings memory;
    ClientNarratorSettings narrator;
    ClientPresentationSettings presentation;
    ClientSafetySettings safety;
};

struct SessionAcceptedResponse {
    MessageId message;
    SessionId session;
    Generation generation;
    std::vector<std::string> capabilities;
    std::string configRevision;
    ClientSettings clientSettings;
    std::uint64_t eventCursor{};
};

struct ResponseCorrelation {
    MessageId message;
    RequestId request;
    TurnId turn;
    SessionId session;
    Generation generation;
};

struct TurnAcceptedResponse {
    ResponseCorrelation correlation;
    std::uint64_t eventCursor{};
};

struct ProtocolCell {
    enum class Kind { interior, exterior };
    Kind kind{Kind::interior};
    std::string name;
    std::int64_t gridX{};
    std::int64_t gridY{};
};

struct ProtocolIdentity {
    std::string kind;
    std::string recordId;
    std::uint64_t refnumIndex{};
    std::uint64_t refnumContentFile{};
    std::string contentFile;
    ProtocolCell cell;
    std::string displayName;
};

enum class ActionIntentKind { ai_follow, ai_stop, ai_travel, ai_escort, ai_face, ai_wander, animation_play, combat_start, combat_stop,
    inspect_report, item_equip, item_unequip, item_use };
struct ActionIntent {
    ActionId action;
    TurnId turn;
    ProtocolIdentity actor;
    ProtocolIdentity target;
    ActionIntentKind kind{ActionIntentKind::ai_follow};
    std::uint32_t followDistance{};
    std::uint32_t wanderDistance{};
    std::uint32_t wanderDurationSeconds{};
    std::string stringParameter;
    std::string secondaryStringParameter;
    double destinationX{};
    double destinationY{};
    double destinationZ{};
    std::string destinationCell;
    std::string expiresAt;
};

struct TurnAcceptedEventPayload {};
struct DialogueDeltaEventPayload { std::string text; };
struct DialogueCompleteEventPayload {
    ProtocolIdentity speaker;
    ProtocolIdentity addressee;
    std::string text;
};
struct ActionIntentEventPayload { ActionIntent intent; };
struct TurnCompleteEventPayload {};
struct TurnCancelledEventPayload { std::string reason; };
struct TurnFailedEventPayload {
    ErrorCode code{ErrorCode::provider_unavailable};
    bool retriable{};
    std::optional<std::uint64_t> retryAfterMs;
};
struct SttTranscriptEventPayload { std::string text; std::string language; };
struct SttFailedEventPayload {
    std::string code;
    bool retriable{};
    std::optional<std::uint64_t> retryAfterMs;
};
struct SpeechReadyEventPayload {
    MediaId media;
    MessageId dialogueMessage;
    std::string sha256;
    std::uint64_t bytes{};
    MediaCodec codec{MediaCodec::wav};
    std::uint64_t durationMs{};
    std::string expiresAt;
};

using ProtocolEventPayload = std::variant<TurnAcceptedEventPayload, DialogueDeltaEventPayload, DialogueCompleteEventPayload,
    ActionIntentEventPayload, TurnCompleteEventPayload, TurnCancelledEventPayload,
    TurnFailedEventPayload, SttTranscriptEventPayload, SttFailedEventPayload,
    SpeechReadyEventPayload>;

enum class ProtocolEventType {
    turn_accepted,
    dialogue_delta,
    dialogue_complete,
    action_intent,
    turn_complete,
    turn_cancelled,
    turn_failed,
    stt_transcript,
    stt_failed,
    speech_ready,
};

struct ProtocolEvent {
    ResponseCorrelation correlation;
    std::uint64_t sequence{};
    std::string createdAt;
    ProtocolEventType type{ProtocolEventType::turn_accepted};
    ProtocolEventPayload payload{TurnAcceptedEventPayload{}};
};

struct EventsResponse {
    struct AutonomyDirective {
        std::string scheduleId;
        std::string kind;
        std::string issuedAt;
    };
    SessionId session;
    Generation generation;
    std::uint64_t nextAfter{};
    std::vector<ProtocolEvent> events;
    std::vector<AutonomyDirective> autonomy;
};

struct InterruptionAcceptedResponse {
    ResponseCorrelation correlation;
    std::uint64_t eventCursor{};
    bool duplicate{};
};

struct ActionResultAcceptedResponse {
    ResponseCorrelation correlation;
    ActionId action;
    ActionTerminalStatus status{ActionTerminalStatus::failed};
    bool duplicate{};
};

struct SttAcceptedResponse {
    ResponseCorrelation correlation;
    std::uint64_t eventCursor{};
    bool duplicate{};
};
struct DialogueDeliveryResultAcceptedResponse {
    ResponseCorrelation correlation;
    MessageId dialogueMessage;
    DialogueDeliveryStatus status{DialogueDeliveryStatus::failed};
    bool duplicate{};
};

[[nodiscard]] Result<ProtocolIdentity> parseProtocolIdentity(std::string_view body,
    json::ParseLimits limits = {});

struct SessionEndedResponse {
    RequestId request;
    SessionId session;
    Generation generation;
    bool ended{};
};

struct ControlsResponse {
    struct ModelSlot {
        std::string configurationId;
        std::string name;
        std::uint64_t revision{};
        std::string driver;
        std::string model;
    };
    struct Profile {
        std::string profileId;
        std::string name;
        std::uint64_t revision{};
    };
    MessageId message;
    RequestId request;
    SessionId session;
    Generation generation;
    ProtocolIdentity target;
    std::optional<std::string> selectedModelSlotId;
    std::optional<std::string> selectedProfileId;
    std::optional<std::string> narratorProfileId;
    std::vector<ModelSlot> modelSlots;
    std::vector<Profile> profiles;
};

[[nodiscard]] Result<void> parseHealthResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits = {});
[[nodiscard]] Result<ProtocolError> parseProtocolErrorResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits = {});
[[nodiscard]] Result<SessionAcceptedResponse> parseSessionAcceptedResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits = {});
[[nodiscard]] Result<TurnAcceptedResponse> parseTurnAcceptedResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits = {});
[[nodiscard]] Result<EventsResponse> parseEventsResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits = {});
[[nodiscard]] Result<InterruptionAcceptedResponse> parseInterruptionAcceptedResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits = {});
[[nodiscard]] Result<ActionResultAcceptedResponse> parseActionResultAcceptedResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits = {});
[[nodiscard]] Result<SttAcceptedResponse> parseSttAcceptedResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits = {});
[[nodiscard]] Result<DialogueDeliveryResultAcceptedResponse> parseDialogueDeliveryResultAcceptedResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits = {});
[[nodiscard]] Result<SessionEndedResponse> parseSessionEndedResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits = {});
[[nodiscard]] Result<ControlsResponse> parseControlsResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits = {});
[[nodiscard]] Result<void> validateHealthHttpResponse(
    unsigned status, std::string_view body, const Headers& headers, json::ParseLimits limits = {});

} // namespace almsivi
