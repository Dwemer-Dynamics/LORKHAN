#include "almsivi/protocol_response.hpp"

#include <array>
#include <initializer_list>
#include <limits>
#include <set>
#include <utility>

namespace almsivi {
namespace {

constexpr std::uint64_t kMaximumProtocolInteger = 9007199254740991ULL;
constexpr std::size_t kMaximumEvents = 100;
constexpr std::size_t kMaximumCapabilityBytes = 128;
constexpr std::size_t kMaximumCapabilities = 64;
constexpr std::size_t kMaximumIdentityTextBytes = 256;

Result<void> invalidSchema(std::string message)
{
    return Result<void>::failure(makeError(ErrorCode::invalid_schema, std::move(message)));
}

template <class T>
Result<T> invalidSchemaValue(std::string message)
{
    return Result<T>::failure(makeError(ErrorCode::invalid_schema, std::move(message)));
}

Result<void> validateJsonBody(std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto contentType = validateJsonContentType(headers);
    if (!contentType)
        return contentType;
    if (body.size() > limits.maximumBytes)
        return Result<void>::failure(makeError(ErrorCode::payload_too_large, "response body exceeds JSON byte limit"));
    return Result<void>::success();
}

bool hasExactly(const json::Object& object, std::initializer_list<std::string_view> required,
    std::initializer_list<std::string_view> optional = {})
{
    if (object.size() < required.size() || object.size() > required.size() + optional.size())
        return false;
    for (const auto key : required) {
        if (!json::find(object, key))
            return false;
    }
    for (const auto& [key, value] : object) {
        static_cast<void>(value);
        bool known = false;
        for (const auto candidate : required)
            known = known || key == candidate;
        for (const auto candidate : optional)
            known = known || key == candidate;
        if (!known)
            return false;
    }
    return true;
}

Result<json::Object> parseObject(std::string_view body, const Headers& headers,
    std::string_view schema, json::ParseLimits limits)
{
    auto bodyValidation = validateJsonBody(body, headers, limits);
    if (!bodyValidation)
        return Result<json::Object>::failure(bodyValidation.error());
    return json::requireObjectWithSchema(body, schema, limits);
}

Result<std::string> requireString(const json::Object& object, std::string_view key,
    std::size_t minimumBytes = 0, std::size_t maximumBytes = std::numeric_limits<std::size_t>::max())
{
    const auto* value = json::find(object, key);
    if (!value || !value->string() || value->string()->size() < minimumBytes
        || value->string()->size() > maximumBytes)
        return invalidSchemaValue<std::string>(std::string(key) + " must be a bounded string");
    return Result<std::string>::success(*value->string());
}

Result<std::string> requireUuid(const json::Object& object, std::string_view key)
{
    auto value = requireString(object, key);
    if (!value)
        return value;
    if (!isCanonicalUuid(value.value()))
        return invalidSchemaValue<std::string>(std::string(key) + " must be a canonical UUID");
    return value;
}

Result<std::uint64_t> requireUnsigned(const json::Object& object, std::string_view key,
    std::uint64_t maximum = kMaximumProtocolInteger, std::uint64_t minimum = 0)
{
    const auto* value = json::find(object, key);
    if (!value || !value->integer() || *value->integer() < 0)
        return invalidSchemaValue<std::uint64_t>(std::string(key) + " must be a nonnegative integer");
    const auto parsed = static_cast<std::uint64_t>(*value->integer());
    if (parsed < minimum || parsed > maximum)
        return invalidSchemaValue<std::uint64_t>(std::string(key) + " is outside the allowed range");
    return Result<std::uint64_t>::success(parsed);
}

Result<bool> requireBoolean(const json::Object& object, std::string_view key)
{
    const auto* value = json::find(object, key);
    if (!value || !value->boolean())
        return invalidSchemaValue<bool>(std::string(key) + " must be boolean");
    return Result<bool>::success(*value->boolean());
}

Result<std::string> requireTimestamp(const json::Object& object, std::string_view key)
{
    auto value = requireString(object, key);
    if (!value)
        return value;
    if (!isCanonicalUtcTimestamp(value.value()))
        return invalidSchemaValue<std::string>(std::string(key) + " must be a canonical UTC timestamp");
    return value;
}

Result<ResponseCorrelation> parseCorrelation(const json::Object& object)
{
    auto message = requireUuid(object, "message_id");
    auto request = requireUuid(object, "request_id");
    auto turn = requireUuid(object, "turn_id");
    auto session = requireUuid(object, "session_id");
    auto generation = requireUnsigned(object, "generation");
    if (!message) return invalidSchemaValue<ResponseCorrelation>(message.error().message);
    if (!request) return invalidSchemaValue<ResponseCorrelation>(request.error().message);
    if (!turn) return invalidSchemaValue<ResponseCorrelation>(turn.error().message);
    if (!session) return invalidSchemaValue<ResponseCorrelation>(session.error().message);
    if (!generation) return invalidSchemaValue<ResponseCorrelation>(generation.error().message);
    return Result<ResponseCorrelation>::success({MessageId(std::move(message).value()),
        RequestId(std::move(request).value()), TurnId(std::move(turn).value()),
        SessionId(std::move(session).value()), Generation(generation.value())});
}

Result<ProtocolCell> parseCell(const json::Value& value)
{
    const auto* object = value.object();
    if (!object)
        return invalidSchemaValue<ProtocolCell>("identity cell must be an object");
    auto kind = requireString(*object, "kind");
    if (!kind)
        return invalidSchemaValue<ProtocolCell>(kind.error().message);
    if (kind.value() == "interior") {
        if (!hasExactly(*object, {"kind", "name"}))
            return invalidSchemaValue<ProtocolCell>("interior cell fields mismatch");
        auto name = requireString(*object, "name", 1, kMaximumIdentityTextBytes);
        if (!name) return invalidSchemaValue<ProtocolCell>(name.error().message);
        return Result<ProtocolCell>::success(
            {ProtocolCell::Kind::interior, std::move(name).value(), 0, 0});
    }
    if (kind.value() == "exterior") {
        if (!hasExactly(*object, {"kind", "grid_x", "grid_y"}))
            return invalidSchemaValue<ProtocolCell>("exterior cell fields mismatch");
        const auto* gridX = json::find(*object, "grid_x");
        const auto* gridY = json::find(*object, "grid_y");
        if (!gridX->integer() || !gridY->integer())
            return invalidSchemaValue<ProtocolCell>("exterior cell grid must use integers");
        return Result<ProtocolCell>::success(
            {ProtocolCell::Kind::exterior, {}, *gridX->integer(), *gridY->integer()});
    }
    return invalidSchemaValue<ProtocolCell>("unknown identity cell kind");
}

Result<ProtocolIdentity> parseIdentity(const json::Value& value)
{
    const auto* object = value.object();
    if (!object || !hasExactly(*object,
            {"kind", "record_id", "refnum", "content_file", "cell", "display_name"}))
        return invalidSchemaValue<ProtocolIdentity>("identity fields mismatch");
    auto kind = requireString(*object, "kind", 1, 64);
    auto record = requireString(*object, "record_id", 1, kMaximumIdentityTextBytes);
    auto content = requireString(*object, "content_file", 1, kMaximumIdentityTextBytes);
    auto display = requireString(*object, "display_name", 1, kMaximumIdentityTextBytes);
    if (!kind) return invalidSchemaValue<ProtocolIdentity>(kind.error().message);
    if (!record) return invalidSchemaValue<ProtocolIdentity>(record.error().message);
    if (!content) return invalidSchemaValue<ProtocolIdentity>(content.error().message);
    if (!display) return invalidSchemaValue<ProtocolIdentity>(display.error().message);

    const auto* refnumValue = json::find(*object, "refnum");
    const auto* refnum = refnumValue ? refnumValue->object() : nullptr;
    if (!refnum || !hasExactly(*refnum, {"index", "content_file"}))
        return invalidSchemaValue<ProtocolIdentity>("identity refnum fields mismatch");
    auto index = requireUnsigned(*refnum, "index", static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()));
    auto refContent = requireUnsigned(*refnum, "content_file", static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()));
    if (!index) return invalidSchemaValue<ProtocolIdentity>(index.error().message);
    if (!refContent) return invalidSchemaValue<ProtocolIdentity>(refContent.error().message);
    const auto* cellValue = json::find(*object, "cell");
    auto cell = parseCell(*cellValue);
    if (!cell) return invalidSchemaValue<ProtocolIdentity>(cell.error().message);
    return Result<ProtocolIdentity>::success({std::move(kind).value(), std::move(record).value(),
        index.value(), refContent.value(), std::move(content).value(), std::move(cell).value(),
        std::move(display).value()});
}

Result<ActionIntent> parseActionIntent(const json::Value& value, const TurnId& envelopeTurn)
{
    const auto* object = value.object();
    if (!object || !hasExactly(*object,
            {"schema", "action_id", "turn_id", "name", "tier", "actor", "target", "parameters", "expires_at"}))
        return invalidSchemaValue<ActionIntent>("action intent fields mismatch");
    auto schema = requireString(*object, "schema");
    auto action = requireUuid(*object, "action_id");
    auto turn = requireUuid(*object, "turn_id");
    auto name = requireString(*object, "name");
    auto tier = requireUnsigned(*object, "tier", 1, 0);
    auto expiresAt = requireTimestamp(*object, "expires_at");
    if (!schema || schema.value() != "almsivi.action-intent.v1")
        return invalidSchemaValue<ActionIntent>("action intent schema mismatch");
    if (!action) return invalidSchemaValue<ActionIntent>(action.error().message);
    if (!turn) return invalidSchemaValue<ActionIntent>(turn.error().message);
    if (turn.value() != envelopeTurn.value())
        return invalidSchemaValue<ActionIntent>("action intent turn does not match event envelope");
    if (!name || (name.value() != "ai.follow" && name.value() != "inspect.report"))
        return invalidSchemaValue<ActionIntent>("unknown action intent name");
    if (!tier) return invalidSchemaValue<ActionIntent>(tier.error().message);
    if ((name.value() == "ai.follow" && tier.value() != 1)
        || (name.value() == "inspect.report" && tier.value() != 0))
        return invalidSchemaValue<ActionIntent>("action intent tier mismatch");
    if (!expiresAt) return invalidSchemaValue<ActionIntent>(expiresAt.error().message);

    const auto* actorValue = json::find(*object, "actor");
    const auto* targetValue = json::find(*object, "target");
    auto actor = parseIdentity(*actorValue);
    auto target = parseIdentity(*targetValue);
    if (!actor) return invalidSchemaValue<ActionIntent>(actor.error().message);
    if (!target) return invalidSchemaValue<ActionIntent>(target.error().message);

    const auto* parametersValue = json::find(*object, "parameters");
    const auto* parameters = parametersValue ? parametersValue->object() : nullptr;
    if (!parameters)
        return invalidSchemaValue<ActionIntent>("action intent parameters mismatch");
    ActionIntentKind intentKind = ActionIntentKind::inspect_report;
    std::uint32_t followDistance = 0;
    if (name.value() == "ai.follow") {
        if (!hasExactly(*parameters, {"distance"}))
            return invalidSchemaValue<ActionIntent>("action intent parameters mismatch");
        auto distance = requireUnsigned(*parameters, "distance", 192, 192);
        if (!distance) return invalidSchemaValue<ActionIntent>(distance.error().message);
        auto validatedDistance = validateAiFollow(static_cast<std::uint32_t>(distance.value()));
        if (!validatedDistance)
            return invalidSchemaValue<ActionIntent>(validatedDistance.error().message);
        intentKind = ActionIntentKind::ai_follow;
        followDistance = validatedDistance.value().distance;
    } else if (!hasExactly(*parameters, {})) {
        return invalidSchemaValue<ActionIntent>("inspect.report parameters must be empty");
    }

    return Result<ActionIntent>::success({ActionId(std::move(action).value()),
        TurnId(std::move(turn).value()), std::move(actor).value(), std::move(target).value(),
        intentKind, followDistance, std::move(expiresAt).value()});
}

Result<ActionTerminalStatus> parseTerminalStatus(const json::Object& object)
{
    auto status = requireString(object, "status");
    if (!status) return invalidSchemaValue<ActionTerminalStatus>(status.error().message);
    if (status.value() == "succeeded") return Result<ActionTerminalStatus>::success(ActionTerminalStatus::succeeded);
    if (status.value() == "failed") return Result<ActionTerminalStatus>::success(ActionTerminalStatus::failed);
    if (status.value() == "rejected") return Result<ActionTerminalStatus>::success(ActionTerminalStatus::rejected);
    if (status.value() == "timed_out") return Result<ActionTerminalStatus>::success(ActionTerminalStatus::timed_out);
    if (status.value() == "cancelled") return Result<ActionTerminalStatus>::success(ActionTerminalStatus::cancelled);
    return invalidSchemaValue<ActionTerminalStatus>("unknown action terminal status");
}

Result<DialogueDeliveryStatus> parseDialogueDeliveryStatus(const json::Object& object)
{
    auto status = requireString(object, "status");
    if (!status) return invalidSchemaValue<DialogueDeliveryStatus>(status.error().message);
    if (status.value() == "played") return Result<DialogueDeliveryStatus>::success(DialogueDeliveryStatus::played);
    if (status.value() == "failed") return Result<DialogueDeliveryStatus>::success(DialogueDeliveryStatus::failed);
    if (status.value() == "expired") return Result<DialogueDeliveryStatus>::success(DialogueDeliveryStatus::expired);
    if (status.value() == "interrupted") return Result<DialogueDeliveryStatus>::success(DialogueDeliveryStatus::interrupted);
    return invalidSchemaValue<DialogueDeliveryStatus>("unknown dialogue delivery status");
}

std::optional<ErrorCode> protocolCode(std::string_view code)
{
    struct Mapping { std::string_view name; ErrorCode code; };
    static constexpr std::array mappings{
        Mapping{"action_disabled", ErrorCode::action_disabled},
        Mapping{"action_result_expired", ErrorCode::invalid_action},
        Mapping{"action_result_mismatch", ErrorCode::invalid_action},
        Mapping{"cursor_expired", ErrorCode::cursor_expired},
        Mapping{"duplicate_conflict", ErrorCode::duplicate_conflict},
        Mapping{"forbidden", ErrorCode::forbidden},
        Mapping{"internal_error", ErrorCode::internal_error},
        Mapping{"invalid_idempotency_key", ErrorCode::duplicate_conflict},
        Mapping{"invalid_schema", ErrorCode::invalid_schema},
        Mapping{"media_unavailable", ErrorCode::media_rejected},
        Mapping{"not_found", ErrorCode::transport_failure},
        Mapping{"payload_too_large", ErrorCode::payload_too_large},
        Mapping{"provider_action_not_allowed", ErrorCode::action_disabled},
        Mapping{"provider_invalid_action", ErrorCode::provider_unavailable},
        Mapping{"provider_invalid_output", ErrorCode::provider_unavailable},
        Mapping{"provider_timeout", ErrorCode::timeout},
        Mapping{"provider_unavailable", ErrorCode::provider_unavailable},
        Mapping{"rate_limited", ErrorCode::rate_limited},
        Mapping{"request_mismatch", ErrorCode::duplicate_conflict},
        Mapping{"service_unavailable", ErrorCode::provider_unavailable},
        Mapping{"stale_generation", ErrorCode::stale_generation},
        Mapping{"terminal_turn", ErrorCode::cancelled},
        Mapping{"turn_terminal", ErrorCode::cancelled},
        Mapping{"unauthorized", ErrorCode::unauthorized},
        Mapping{"unknown_action", ErrorCode::invalid_action},
        Mapping{"unknown_session", ErrorCode::unknown_session},
        Mapping{"unknown_turn", ErrorCode::unknown_session},
    };
    for (const auto& mapping : mappings) {
        if (mapping.name == code)
            return mapping.code;
    }
    return std::nullopt;
}

Result<ProtocolEvent> parseEvent(const json::Value& value, const SessionId& responseSession,
    Generation responseGeneration)
{
    const auto* object = value.object();
    if (!object || !hasExactly(*object,
            {"message_id", "request_id", "turn_id", "session_id", "generation", "sequence", "created_at", "type", "payload"}))
        return invalidSchemaValue<ProtocolEvent>("event envelope fields mismatch");
    auto correlation = parseCorrelation(*object);
    auto sequence = requireUnsigned(*object, "sequence");
    auto createdAt = requireTimestamp(*object, "created_at");
    auto type = requireString(*object, "type");
    if (!correlation) return invalidSchemaValue<ProtocolEvent>(correlation.error().message);
    if (!sequence) return invalidSchemaValue<ProtocolEvent>(sequence.error().message);
    if (!createdAt) return invalidSchemaValue<ProtocolEvent>(createdAt.error().message);
    if (!type) return invalidSchemaValue<ProtocolEvent>(type.error().message);
    if (correlation.value().session != responseSession || correlation.value().generation != responseGeneration)
        return invalidSchemaValue<ProtocolEvent>("event identity does not match events response");
    const auto* payloadValue = json::find(*object, "payload");
    const auto* payload = payloadValue ? payloadValue->object() : nullptr;
    if (!payload)
        return invalidSchemaValue<ProtocolEvent>("event payload must be an object");

    ProtocolEvent event{correlation.value(), sequence.value(), std::move(createdAt).value()};
    if (type.value() == "turn.accepted") {
        if (!hasExactly(*payload, {"status"})) return invalidSchemaValue<ProtocolEvent>("turn accepted payload fields mismatch");
        auto status = requireString(*payload, "status");
        if (!status || status.value() != "accepted") return invalidSchemaValue<ProtocolEvent>("turn accepted status mismatch");
        event.type = ProtocolEventType::turn_accepted;
        event.payload = TurnAcceptedEventPayload{};
    } else if (type.value() == "dialogue.complete") {
        if (!hasExactly(*payload, {"speaker", "addressee", "text"})) return invalidSchemaValue<ProtocolEvent>("dialogue payload fields mismatch");
        auto speaker = parseIdentity(*json::find(*payload, "speaker"));
        auto addressee = parseIdentity(*json::find(*payload, "addressee"));
        auto text = requireString(*payload, "text", 0, 4096);
        if (!speaker) return invalidSchemaValue<ProtocolEvent>(speaker.error().message);
        if (!addressee) return invalidSchemaValue<ProtocolEvent>(addressee.error().message);
        if (!text) return invalidSchemaValue<ProtocolEvent>(text.error().message);
        event.type = ProtocolEventType::dialogue_complete;
        event.payload = DialogueCompleteEventPayload{
            std::move(speaker).value(), std::move(addressee).value(), std::move(text).value()};
    } else if (type.value() == "action.intent") {
        auto intent = parseActionIntent(*payloadValue, correlation.value().turn);
        if (!intent) return invalidSchemaValue<ProtocolEvent>(intent.error().message);
        event.type = ProtocolEventType::action_intent;
        event.payload = ActionIntentEventPayload{std::move(intent).value()};
    } else if (type.value() == "turn.complete") {
        if (!hasExactly(*payload, {"status"})) return invalidSchemaValue<ProtocolEvent>("turn complete payload fields mismatch");
        auto status = requireString(*payload, "status");
        if (!status || status.value() != "complete") return invalidSchemaValue<ProtocolEvent>("turn complete status mismatch");
        event.type = ProtocolEventType::turn_complete;
        event.payload = TurnCompleteEventPayload{};
    } else if (type.value() == "turn.cancelled") {
        if (!hasExactly(*payload, {"reason"})) return invalidSchemaValue<ProtocolEvent>("turn cancelled payload fields mismatch");
        auto reason = requireString(*payload, "reason", 1, 128);
        if (!reason) return invalidSchemaValue<ProtocolEvent>(reason.error().message);
        event.type = ProtocolEventType::turn_cancelled;
        event.payload = TurnCancelledEventPayload{std::move(reason).value()};
    } else if (type.value() == "turn.failed") {
        if (!hasExactly(*payload, {"code", "retriable"}, {"retry_after_ms"}))
            return invalidSchemaValue<ProtocolEvent>("turn failed payload fields mismatch");
        auto code = requireString(*payload, "code");
        auto retriable = requireBoolean(*payload, "retriable");
        if (!code || (code.value() != "provider_timeout" && code.value() != "provider_unavailable"))
            return invalidSchemaValue<ProtocolEvent>("turn failed provider code mismatch");
        if (!retriable) return invalidSchemaValue<ProtocolEvent>(retriable.error().message);
        TurnFailedEventPayload failure{code.value() == "provider_timeout" ? ErrorCode::timeout : ErrorCode::provider_unavailable,
            retriable.value(), std::nullopt};
        if (json::find(*payload, "retry_after_ms")) {
            auto retry = requireUnsigned(*payload, "retry_after_ms", static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()));
            if (!retry) return invalidSchemaValue<ProtocolEvent>(retry.error().message);
            failure.retryAfterMs = retry.value();
        }
        event.type = ProtocolEventType::turn_failed;
        event.payload = failure;
    } else if (type.value() == "stt.transcript") {
        if (!hasExactly(*payload, {"text", "language"}))
            return invalidSchemaValue<ProtocolEvent>("STT transcript payload fields mismatch");
        auto text = requireString(*payload, "text", 1, 16384);
        auto language = requireString(*payload, "language", 2, 35);
        if (!text) return invalidSchemaValue<ProtocolEvent>(text.error().message);
        if (!language) return invalidSchemaValue<ProtocolEvent>(language.error().message);
        event.type = ProtocolEventType::stt_transcript;
        event.payload = SttTranscriptEventPayload{std::move(text).value(), std::move(language).value()};
    } else if (type.value() == "stt.failed") {
        if (!hasExactly(*payload, {"code", "retriable"}, {"retry_after_ms"}))
            return invalidSchemaValue<ProtocolEvent>("STT failure payload fields mismatch");
        auto code = requireString(*payload, "code");
        auto retriable = requireBoolean(*payload, "retriable");
        if (!code || (code.value() != "invalid_audio" && code.value() != "provider_invalid_output"
                && code.value() != "provider_timeout" && code.value() != "provider_unavailable"))
            return invalidSchemaValue<ProtocolEvent>("STT failure code mismatch");
        if (!retriable) return invalidSchemaValue<ProtocolEvent>(retriable.error().message);
        SttFailedEventPayload failure{std::move(code).value(), retriable.value(), std::nullopt};
        if (json::find(*payload, "retry_after_ms")) {
            auto retry = requireUnsigned(*payload, "retry_after_ms",
                static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()));
            if (!retry) return invalidSchemaValue<ProtocolEvent>(retry.error().message);
            failure.retryAfterMs = retry.value();
        }
        event.type = ProtocolEventType::stt_failed;
        event.payload = std::move(failure);
    } else if (type.value() == "speech.ready") {
        if (!hasExactly(*payload, {"media_id", "sha256", "bytes", "codec", "duration_ms", "expires_at"}))
            return invalidSchemaValue<ProtocolEvent>("speech payload fields mismatch");
        auto media = requireUuid(*payload, "media_id");
        auto hash = requireString(*payload, "sha256");
        auto bytes = requireUnsigned(*payload, "bytes", kMaxMediaBytes, 1);
        auto codec = requireString(*payload, "codec");
        auto duration = requireUnsigned(*payload, "duration_ms", kMaximumProtocolInteger, 1);
        auto expiresAt = requireTimestamp(*payload, "expires_at");
        if (!media) return invalidSchemaValue<ProtocolEvent>(media.error().message);
        if (!hash || hash.value().size() != 64) return invalidSchemaValue<ProtocolEvent>("speech hash must use 64 lowercase hexadecimal digits");
        for (const char character : hash.value()) {
            if (!((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')))
                return invalidSchemaValue<ProtocolEvent>("speech hash must use 64 lowercase hexadecimal digits");
        }
        if (!bytes) return invalidSchemaValue<ProtocolEvent>(bytes.error().message);
        if (!codec) return invalidSchemaValue<ProtocolEvent>(codec.error().message);
        MediaCodec mappedCodec;
        if (codec.value() == "wav") mappedCodec = MediaCodec::wav;
        else if (codec.value() == "ogg") mappedCodec = MediaCodec::ogg;
        else if (codec.value() == "mp3") mappedCodec = MediaCodec::mp3;
        else return invalidSchemaValue<ProtocolEvent>("unknown speech codec");
        if (!duration) return invalidSchemaValue<ProtocolEvent>(duration.error().message);
        if (!expiresAt) return invalidSchemaValue<ProtocolEvent>(expiresAt.error().message);
        event.type = ProtocolEventType::speech_ready;
        event.payload = SpeechReadyEventPayload{MediaId(std::move(media).value()), std::move(hash).value(),
            bytes.value(), mappedCodec, duration.value(), std::move(expiresAt).value()};
    } else {
        return invalidSchemaValue<ProtocolEvent>("unknown event type");
    }
    return Result<ProtocolEvent>::success(std::move(event));
}

} // namespace

Result<ProtocolIdentity> parseProtocolIdentity(std::string_view body, json::ParseLimits limits)
{
    auto parsed = json::parse(body, limits);
    if (!parsed)
        return Result<ProtocolIdentity>::failure(parsed.error());
    return parseIdentity(parsed.value());
}

Result<void> parseHealthResponse(std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto object = parseObject(body, headers, "almsivi.health.v1", limits);
    if (!object)
        return Result<void>::failure(object.error());
    if (!hasExactly(object.value(), {"schema"}))
        return invalidSchema("health response contains unknown fields");
    return Result<void>::success();
}

Result<ProtocolError> parseProtocolErrorResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto object = parseObject(body, headers, "almsivi.error.v1", limits);
    if (!object)
        return Result<ProtocolError>::failure(object.error());
    if (!hasExactly(object.value(), {"schema", "code", "message", "correlation_id", "retriable"},
            {"retry_after_ms"}))
        return invalidSchemaValue<ProtocolError>("error response fields mismatch");

    auto code = requireString(object.value(), "code");
    auto message = requireString(object.value(), "message", 1, 1024);
    auto correlation = requireUuid(object.value(), "correlation_id");
    auto retriable = requireBoolean(object.value(), "retriable");
    if (!code) return invalidSchemaValue<ProtocolError>(code.error().message);
    if (!message) return invalidSchemaValue<ProtocolError>(message.error().message);
    if (!correlation) return invalidSchemaValue<ProtocolError>(correlation.error().message);
    if (!retriable) return invalidSchemaValue<ProtocolError>(retriable.error().message);
    const auto mappedCode = protocolCode(code.value());
    if (!mappedCode)
        return invalidSchemaValue<ProtocolError>("unknown protocol error code");

    ProtocolError parsed{*mappedCode, std::move(correlation).value(), retriable.value(), std::nullopt};
    if (json::find(object.value(), "retry_after_ms")) {
        auto retry = requireUnsigned(object.value(), "retry_after_ms",
            static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()));
        if (!retry) return invalidSchemaValue<ProtocolError>(retry.error().message);
        parsed.retryAfterMs = retry.value();
    }
    return Result<ProtocolError>::success(std::move(parsed));
}

Result<SessionAcceptedResponse> parseSessionAcceptedResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto object = parseObject(body, headers, "almsivi.session.accepted.v1", limits);
    if (!object) return Result<SessionAcceptedResponse>::failure(object.error());
    if (!hasExactly(object.value(), {"schema", "message_id", "session_id", "generation", "capabilities", "config_revision", "event_cursor"}))
        return invalidSchemaValue<SessionAcceptedResponse>("session accepted fields mismatch");
    auto message = requireUuid(object.value(), "message_id");
    auto session = requireUuid(object.value(), "session_id");
    auto generation = requireUnsigned(object.value(), "generation");
    auto revision = requireString(object.value(), "config_revision", 1, 128);
    auto cursor = requireUnsigned(object.value(), "event_cursor");
    const auto* capabilitiesValue = json::find(object.value(), "capabilities");
    const auto* capabilities = capabilitiesValue ? capabilitiesValue->array() : nullptr;
    if (!message) return invalidSchemaValue<SessionAcceptedResponse>(message.error().message);
    if (!session) return invalidSchemaValue<SessionAcceptedResponse>(session.error().message);
    if (!generation) return invalidSchemaValue<SessionAcceptedResponse>(generation.error().message);
    if (!revision) return invalidSchemaValue<SessionAcceptedResponse>(revision.error().message);
    if (!cursor) return invalidSchemaValue<SessionAcceptedResponse>(cursor.error().message);
    if (!capabilities || capabilities->size() > kMaximumCapabilities)
        return invalidSchemaValue<SessionAcceptedResponse>("capabilities must be a bounded array");
    std::vector<std::string> parsedCapabilities;
    std::set<std::string> unique;
    parsedCapabilities.reserve(capabilities->size());
    for (const auto& value : *capabilities) {
        if (!value.string() || value.string()->empty() || value.string()->size() > kMaximumCapabilityBytes
            || !unique.insert(*value.string()).second)
            return invalidSchemaValue<SessionAcceptedResponse>("capabilities must contain unique bounded strings");
        parsedCapabilities.push_back(*value.string());
    }
    return Result<SessionAcceptedResponse>::success({MessageId(std::move(message).value()),
        SessionId(std::move(session).value()), Generation(generation.value()), std::move(parsedCapabilities),
        std::move(revision).value(), cursor.value()});
}

Result<TurnAcceptedResponse> parseTurnAcceptedResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto object = parseObject(body, headers, "almsivi.turn.accepted.v1", limits);
    if (!object) return Result<TurnAcceptedResponse>::failure(object.error());
    if (!hasExactly(object.value(), {"schema", "message_id", "request_id", "turn_id", "session_id", "generation", "event_cursor"}))
        return invalidSchemaValue<TurnAcceptedResponse>("turn accepted fields mismatch");
    auto correlation = parseCorrelation(object.value());
    auto cursor = requireUnsigned(object.value(), "event_cursor");
    if (!correlation) return invalidSchemaValue<TurnAcceptedResponse>(correlation.error().message);
    if (!cursor) return invalidSchemaValue<TurnAcceptedResponse>(cursor.error().message);
    return Result<TurnAcceptedResponse>::success({std::move(correlation).value(), cursor.value()});
}

Result<EventsResponse> parseEventsResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto object = parseObject(body, headers, "almsivi.events.v1", limits);
    if (!object) return Result<EventsResponse>::failure(object.error());
    if (!hasExactly(object.value(), {"schema", "session_id", "generation", "next_after", "events"}))
        return invalidSchemaValue<EventsResponse>("events response fields mismatch");
    auto session = requireUuid(object.value(), "session_id");
    auto generation = requireUnsigned(object.value(), "generation");
    auto nextAfter = requireUnsigned(object.value(), "next_after");
    const auto* eventsValue = json::find(object.value(), "events");
    const auto* events = eventsValue ? eventsValue->array() : nullptr;
    if (!session) return invalidSchemaValue<EventsResponse>(session.error().message);
    if (!generation) return invalidSchemaValue<EventsResponse>(generation.error().message);
    if (!nextAfter) return invalidSchemaValue<EventsResponse>(nextAfter.error().message);
    if (!events || events->size() > kMaximumEvents)
        return invalidSchemaValue<EventsResponse>("events must be an array of at most 100 items");
    EventsResponse parsed{SessionId(std::move(session).value()), Generation(generation.value()), nextAfter.value(), {}};
    parsed.events.reserve(events->size());
    std::uint64_t previous = 0;
    for (const auto& value : *events) {
        auto event = parseEvent(value, parsed.session, parsed.generation);
        if (!event) return invalidSchemaValue<EventsResponse>(event.error().message);
        if (!parsed.events.empty() && event.value().sequence <= previous)
            return invalidSchemaValue<EventsResponse>("events must have strictly increasing sequence values");
        previous = event.value().sequence;
        parsed.events.push_back(std::move(event).value());
    }
    return Result<EventsResponse>::success(std::move(parsed));
}

Result<InterruptionAcceptedResponse> parseInterruptionAcceptedResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto object = parseObject(body, headers, "almsivi.interruption.accepted.v1", limits);
    if (!object) return Result<InterruptionAcceptedResponse>::failure(object.error());
    if (!hasExactly(object.value(), {"schema", "message_id", "request_id", "turn_id", "session_id", "generation", "event_cursor", "duplicate"}))
        return invalidSchemaValue<InterruptionAcceptedResponse>("interruption accepted fields mismatch");
    auto correlation = parseCorrelation(object.value());
    auto cursor = requireUnsigned(object.value(), "event_cursor");
    auto duplicate = requireBoolean(object.value(), "duplicate");
    if (!correlation) return invalidSchemaValue<InterruptionAcceptedResponse>(correlation.error().message);
    if (!cursor) return invalidSchemaValue<InterruptionAcceptedResponse>(cursor.error().message);
    if (!duplicate) return invalidSchemaValue<InterruptionAcceptedResponse>(duplicate.error().message);
    return Result<InterruptionAcceptedResponse>::success(
        {std::move(correlation).value(), cursor.value(), duplicate.value()});
}

Result<ActionResultAcceptedResponse> parseActionResultAcceptedResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto object = parseObject(body, headers, "almsivi.action-result.accepted.v1", limits);
    if (!object) return Result<ActionResultAcceptedResponse>::failure(object.error());
    if (!hasExactly(object.value(), {"schema", "message_id", "request_id", "action_id", "turn_id", "session_id", "generation", "status", "duplicate"}))
        return invalidSchemaValue<ActionResultAcceptedResponse>("action-result accepted fields mismatch");
    auto correlation = parseCorrelation(object.value());
    auto action = requireUuid(object.value(), "action_id");
    auto status = parseTerminalStatus(object.value());
    auto duplicate = requireBoolean(object.value(), "duplicate");
    if (!correlation) return invalidSchemaValue<ActionResultAcceptedResponse>(correlation.error().message);
    if (!action) return invalidSchemaValue<ActionResultAcceptedResponse>(action.error().message);
    if (!status) return invalidSchemaValue<ActionResultAcceptedResponse>(status.error().message);
    if (!duplicate) return invalidSchemaValue<ActionResultAcceptedResponse>(duplicate.error().message);
    return Result<ActionResultAcceptedResponse>::success({std::move(correlation).value(),
        ActionId(std::move(action).value()), status.value(), duplicate.value()});
}

Result<SttAcceptedResponse> parseSttAcceptedResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto object = parseObject(body, headers, "almsivi.stt.accepted.v1", limits);
    if (!object) return Result<SttAcceptedResponse>::failure(object.error());
    if (!hasExactly(object.value(), {"schema", "message_id", "request_id", "turn_id", "session_id", "generation", "event_cursor", "duplicate"}))
        return invalidSchemaValue<SttAcceptedResponse>("STT accepted fields mismatch");
    auto correlation = parseCorrelation(object.value());
    auto cursor = requireUnsigned(object.value(), "event_cursor");
    auto duplicate = requireBoolean(object.value(), "duplicate");
    if (!correlation) return invalidSchemaValue<SttAcceptedResponse>(correlation.error().message);
    if (!cursor) return invalidSchemaValue<SttAcceptedResponse>(cursor.error().message);
    if (!duplicate) return invalidSchemaValue<SttAcceptedResponse>(duplicate.error().message);
    return Result<SttAcceptedResponse>::success(
        {std::move(correlation).value(), cursor.value(), duplicate.value()});
}

Result<DialogueDeliveryResultAcceptedResponse> parseDialogueDeliveryResultAcceptedResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto object = parseObject(body, headers, "almsivi.dialogue-delivery-result.accepted.v1", limits);
    if (!object) return Result<DialogueDeliveryResultAcceptedResponse>::failure(object.error());
    if (!hasExactly(object.value(), {"schema", "message_id", "request_id", "dialogue_message_id", "turn_id", "session_id", "generation", "status", "duplicate"}))
        return invalidSchemaValue<DialogueDeliveryResultAcceptedResponse>("dialogue delivery acceptance fields mismatch");
    auto correlation = parseCorrelation(object.value());
    auto dialogueMessage = requireUuid(object.value(), "dialogue_message_id");
    auto status = parseDialogueDeliveryStatus(object.value());
    auto duplicate = requireBoolean(object.value(), "duplicate");
    if (!correlation) return invalidSchemaValue<DialogueDeliveryResultAcceptedResponse>(correlation.error().message);
    if (!dialogueMessage) return invalidSchemaValue<DialogueDeliveryResultAcceptedResponse>(dialogueMessage.error().message);
    if (!status) return invalidSchemaValue<DialogueDeliveryResultAcceptedResponse>(status.error().message);
    if (!duplicate) return invalidSchemaValue<DialogueDeliveryResultAcceptedResponse>(duplicate.error().message);
    return Result<DialogueDeliveryResultAcceptedResponse>::success({std::move(correlation).value(),
        MessageId(std::move(dialogueMessage).value()), status.value(), duplicate.value()});
}

Result<SessionEndedResponse> parseSessionEndedResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto object = parseObject(body, headers, "almsivi.session.ended.v1", limits);
    if (!object) return Result<SessionEndedResponse>::failure(object.error());
    if (!hasExactly(object.value(), {"schema", "request_id", "session_id", "generation", "ended"}))
        return invalidSchemaValue<SessionEndedResponse>("session ended fields mismatch");
    auto request = requireUuid(object.value(), "request_id");
    auto session = requireUuid(object.value(), "session_id");
    auto generation = requireUnsigned(object.value(), "generation");
    auto ended = requireBoolean(object.value(), "ended");
    if (!request) return invalidSchemaValue<SessionEndedResponse>(request.error().message);
    if (!session) return invalidSchemaValue<SessionEndedResponse>(session.error().message);
    if (!generation) return invalidSchemaValue<SessionEndedResponse>(generation.error().message);
    if (!ended) return invalidSchemaValue<SessionEndedResponse>(ended.error().message);
    return Result<SessionEndedResponse>::success({RequestId(std::move(request).value()),
        SessionId(std::move(session).value()), Generation(generation.value()), ended.value()});
}

Result<void> validateHealthHttpResponse(
    unsigned status, std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    if (status >= 300 && status < 400)
        return Result<void>::failure(makeError(ErrorCode::redirect_rejected, "HTTP redirects are rejected"));
    if (status >= 200 && status < 300)
        return parseHealthResponse(body, headers, limits);

    auto parsed = parseProtocolErrorResponse(body, headers, limits);
    if (!parsed)
        return Result<void>::failure(parsed.error());
    return Result<void>::failure(makeError(parsed.value().code, "server returned a typed protocol error",
        parsed.value().retriable, parsed.value().retryAfterMs));
}

} // namespace almsivi
