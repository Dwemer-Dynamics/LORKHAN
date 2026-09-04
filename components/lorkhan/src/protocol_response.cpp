#include "lorkhan/protocol_response.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <initializer_list>
#include <limits>
#include <set>
#include <utility>

namespace lorkhan {
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

Result<double> requireNumber(const json::Object& object,std::string_view key,double minimum,double maximum)
{
    const auto* value=json::find(object,key);double parsed{};
    if(!value)return invalidSchemaValue<double>(std::string(key)+" must be a bounded number");
    if(value->number())parsed=*value->number();else if(value->integer())parsed=static_cast<double>(*value->integer());
    else return invalidSchemaValue<double>(std::string(key)+" must be a bounded number");
    if(!std::isfinite(parsed)||parsed<minimum||parsed>maximum)
        return invalidSchemaValue<double>(std::string(key)+" is outside the allowed range");
    return Result<double>::success(parsed);
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

bool isLowercaseHash(std::string_view value)
{
    if (value.size() != 64)
        return false;
    return std::all_of(value.begin(), value.end(), [](const char character) {
        return (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f');
    });
}

bool isCommandName(std::string_view value)
{
    if (value.empty() || value.size() > 64 || value.front() < 'a' || value.front() > 'z')
        return false;
    return std::all_of(value.begin() + 1, value.end(), [](const char character) {
        return (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9')
            || character == '_' || character == '.';
    });
}

bool isCacheKey(std::string_view value)
{
    if (value.empty() || value.size() > 256)
        return false;
    return std::all_of(value.begin(), value.end(), [](const char character) {
        return (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z')
            || (character >= '0' && character <= '9') || character == '.' || character == '_'
            || character == ':' || character == '-';
    });
}

Result<CanonicalMediaDescriptor> parseCanonicalMedia(const json::Value& value)
{
    const auto* object = value.object();
    if (!object || !hasExactly(*object,
            {"media_id", "dialogue_message_id", "sha256", "bytes", "codec", "duration_ms", "expires_at"}))
        return invalidSchemaValue<CanonicalMediaDescriptor>("canonical media fields mismatch");
    auto media = requireUuid(*object, "media_id");
    auto dialogue = requireUuid(*object, "dialogue_message_id");
    auto hash = requireString(*object, "sha256");
    auto bytes = requireUnsigned(*object, "bytes", kMaxMediaBytes, 1);
    auto codec = requireString(*object, "codec");
    auto duration = requireUnsigned(*object, "duration_ms", kMaximumProtocolInteger, 1);
    auto expiresAt = requireTimestamp(*object, "expires_at");
    if (!media) return invalidSchemaValue<CanonicalMediaDescriptor>(media.error().message);
    if (!dialogue) return invalidSchemaValue<CanonicalMediaDescriptor>(dialogue.error().message);
    if (!hash || !isLowercaseHash(hash.value()))
        return invalidSchemaValue<CanonicalMediaDescriptor>("canonical media hash mismatch");
    if (!bytes) return invalidSchemaValue<CanonicalMediaDescriptor>(bytes.error().message);
    if (!codec) return invalidSchemaValue<CanonicalMediaDescriptor>(codec.error().message);
    MediaCodec mappedCodec;
    if (codec.value() == "wav") mappedCodec = MediaCodec::wav;
    else if (codec.value() == "ogg") mappedCodec = MediaCodec::ogg;
    else if (codec.value() == "mp3") mappedCodec = MediaCodec::mp3;
    else return invalidSchemaValue<CanonicalMediaDescriptor>("canonical media codec mismatch");
    if (!duration) return invalidSchemaValue<CanonicalMediaDescriptor>(duration.error().message);
    if (!expiresAt) return invalidSchemaValue<CanonicalMediaDescriptor>(expiresAt.error().message);
    return Result<CanonicalMediaDescriptor>::success({MediaId(std::move(media).value()),
        MessageId(std::move(dialogue).value()), std::move(hash).value(), bytes.value(), mappedCodec,
        duration.value(), std::move(expiresAt).value()});
}

Result<CanonicalResponseMetadata> parseCanonicalMetadata(const json::Value& value)
{
    const auto* object = value.object();
    if (!object || !hasExactly(*object, {},
            {"animation", "emotion", "mood", "rechat_depth", "speech_enabled", "source"}))
        return invalidSchemaValue<CanonicalResponseMetadata>("canonical response metadata fields mismatch");
    CanonicalResponseMetadata metadata;
    auto parseOptionalString = [&](std::string_view key, std::optional<std::string>& destination) -> Result<void> {
        if (!json::find(*object, key))
            return Result<void>::success();
        auto parsed = requireString(*object, key, 0, 64);
        if (!parsed)
            return invalidSchema(parsed.error().message);
        destination = std::move(parsed).value();
        return Result<void>::success();
    };
    for (auto [key, destination] : std::array<std::pair<std::string_view, std::optional<std::string>*>, 4>{
             std::pair{"animation", &metadata.animation}, {"emotion", &metadata.emotion},
             {"mood", &metadata.mood}, {"source", &metadata.source}}) {
        auto parsed = parseOptionalString(key, *destination);
        if (!parsed)
            return invalidSchemaValue<CanonicalResponseMetadata>(parsed.error().message);
    }
    if (json::find(*object, "rechat_depth")) {
        auto depth = requireUnsigned(*object, "rechat_depth", 20);
        if (!depth) return invalidSchemaValue<CanonicalResponseMetadata>(depth.error().message);
        metadata.rechatDepth = depth.value();
    }
    if (json::find(*object, "speech_enabled")) {
        auto enabled = requireBoolean(*object, "speech_enabled");
        if (!enabled) return invalidSchemaValue<CanonicalResponseMetadata>(enabled.error().message);
        metadata.speechEnabled = enabled.value();
    }
    return Result<CanonicalResponseMetadata>::success(std::move(metadata));
}

Result<CanonicalResponseLine> parseCanonicalLine(const json::Value& value, const RequestId& responseRequest,
    std::uint64_t expectedIndex)
{
    const auto* object = value.object();
    if (!object || !hasExactly(*object,
            {"schema", "line_id", "line_index", "speaker", "display_name", "speaker_identity", "action",
                "text", "subtitle", "tts_text", "request_id", "utterance_id", "listener", "listener_identity",
                "rechat_target", "rechat_target_identity", "final_response_line", "metadata"},
            {"media", "tts_cache_key", "command_name", "command_args"}))
        return invalidSchemaValue<CanonicalResponseLine>("canonical response line fields mismatch");
    auto schema = requireString(*object, "schema");
    auto lineId = requireUuid(*object, "line_id");
    auto lineIndex = requireUnsigned(*object, "line_index", 63);
    auto speaker = requireString(*object, "speaker", 1, 256);
    auto displayName = requireString(*object, "display_name", 1, 256);
    auto action = requireString(*object, "action");
    auto text = requireString(*object, "text", 0, 4096);
    auto subtitle = requireString(*object, "subtitle", 0, 4096);
    auto ttsText = requireString(*object, "tts_text", 0, 4096);
    auto requestId = requireUuid(*object, "request_id");
    auto utteranceId = requireUuid(*object, "utterance_id");
    auto listener = requireString(*object, "listener", 1, 256);
    auto rechatTarget = requireString(*object, "rechat_target", 1, 256);
    auto finalLine = requireBoolean(*object, "final_response_line");
    if (!schema || schema.value() != "lorkhan.response.line.v1")
        return invalidSchemaValue<CanonicalResponseLine>("canonical response line schema mismatch");
    if (!lineId) return invalidSchemaValue<CanonicalResponseLine>(lineId.error().message);
    if (!lineIndex || lineIndex.value() != expectedIndex)
        return invalidSchemaValue<CanonicalResponseLine>("canonical response line index mismatch");
    if (!speaker) return invalidSchemaValue<CanonicalResponseLine>(speaker.error().message);
    if (!displayName) return invalidSchemaValue<CanonicalResponseLine>(displayName.error().message);
    if (!action || (action.value() != "say" && action.value() != "rolecommand"))
        return invalidSchemaValue<CanonicalResponseLine>("canonical response line action mismatch");
    if (!text) return invalidSchemaValue<CanonicalResponseLine>(text.error().message);
    if (!subtitle) return invalidSchemaValue<CanonicalResponseLine>(subtitle.error().message);
    if (!ttsText) return invalidSchemaValue<CanonicalResponseLine>(ttsText.error().message);
    if (!requestId || requestId.value() != responseRequest.value())
        return invalidSchemaValue<CanonicalResponseLine>("canonical response line request mismatch");
    if (!utteranceId) return invalidSchemaValue<CanonicalResponseLine>(utteranceId.error().message);
    if (!listener) return invalidSchemaValue<CanonicalResponseLine>(listener.error().message);
    if (!rechatTarget) return invalidSchemaValue<CanonicalResponseLine>(rechatTarget.error().message);
    if (!finalLine) return invalidSchemaValue<CanonicalResponseLine>(finalLine.error().message);
    auto speakerIdentity = parseIdentity(*json::find(*object, "speaker_identity"));
    auto listenerIdentity = parseIdentity(*json::find(*object, "listener_identity"));
    auto rechatTargetIdentity = parseIdentity(*json::find(*object, "rechat_target_identity"));
    auto metadata = parseCanonicalMetadata(*json::find(*object, "metadata"));
    if (!speakerIdentity) return invalidSchemaValue<CanonicalResponseLine>(speakerIdentity.error().message);
    if (!listenerIdentity) return invalidSchemaValue<CanonicalResponseLine>(listenerIdentity.error().message);
    if (!rechatTargetIdentity) return invalidSchemaValue<CanonicalResponseLine>(rechatTargetIdentity.error().message);
    if (!metadata) return invalidSchemaValue<CanonicalResponseLine>(metadata.error().message);

    CanonicalResponseLine line{MessageId(std::move(lineId).value()), lineIndex.value(), std::move(speaker).value(),
        std::move(displayName).value(), std::move(speakerIdentity).value(), std::move(action).value(),
        std::move(text).value(), std::move(subtitle).value(), std::move(ttsText).value(),
        RequestId(std::move(requestId).value()), MessageId(std::move(utteranceId).value()),
        std::move(listener).value(), std::move(listenerIdentity).value(), std::move(rechatTarget).value(),
        std::move(rechatTargetIdentity).value(), finalLine.value(), std::move(metadata).value()};

    if (const auto* mediaValue = json::find(*object, "media")) {
        auto media = parseCanonicalMedia(*mediaValue);
        if (!media) return invalidSchemaValue<CanonicalResponseLine>(media.error().message);
        if (media.value().dialogueMessage != line.line)
            return invalidSchemaValue<CanonicalResponseLine>("canonical media dialogue line mismatch");
        line.media = std::move(media).value();
    }
    if (json::find(*object, "tts_cache_key")) {
        auto cacheKey = requireString(*object, "tts_cache_key", 1, 256);
        if (!cacheKey || !isCacheKey(cacheKey.value()))
            return invalidSchemaValue<CanonicalResponseLine>("canonical response cache key mismatch");
        line.ttsCacheKey = std::move(cacheKey).value();
    }
    if (json::find(*object, "command_name")) {
        auto commandName = requireString(*object, "command_name", 1, 64);
        if (!commandName || !isCommandName(commandName.value()))
            return invalidSchemaValue<CanonicalResponseLine>("canonical response command name mismatch");
        line.commandName = std::move(commandName).value();
    }
    if (const auto* argumentsValue = json::find(*object, "command_args")) {
        const auto* arguments = argumentsValue->array();
        if (!arguments || arguments->size() > 16)
            return invalidSchemaValue<CanonicalResponseLine>("canonical response command arguments mismatch");
        for (const auto& argumentValue : *arguments) {
            const auto* argument = argumentValue.string();
            if (!argument || argument->size() > 512)
                return invalidSchemaValue<CanonicalResponseLine>("canonical response command argument mismatch");
            line.commandArgs.push_back(*argument);
        }
    }
    if (line.action == "say") {
        if (line.text.empty() || line.subtitle.empty() || line.ttsText.empty()
            || line.commandName || json::find(*object, "command_args"))
            return invalidSchemaValue<CanonicalResponseLine>("canonical say line fields mismatch");
    } else if (!line.commandName || !json::find(*object, "command_args") || line.media || line.finalResponseLine) {
        return invalidSchemaValue<CanonicalResponseLine>("canonical rolecommand line fields mismatch");
    }
    return Result<CanonicalResponseLine>::success(std::move(line));
}

Result<CanonicalResponse> parseCanonicalResponse(const json::Value& value, const ResponseCorrelation& correlation)
{
    const auto* object = value.object();
    if (!object || !hasExactly(*object,
            {"schema", "response_id", "installation_id", "profile_id", "playthrough_id", "session_id", "turn_id",
                "request_id", "generation", "runtime_generation", "created_at", "ok", "lines", "close", "error"}))
        return invalidSchemaValue<CanonicalResponse>("canonical response fields mismatch");
    auto schema = requireString(*object, "schema");
    auto responseId = requireUuid(*object, "response_id");
    auto installationId = requireUuid(*object, "installation_id");
    auto profileId = requireUuid(*object, "profile_id");
    auto playthroughId = requireUuid(*object, "playthrough_id");
    auto sessionId = requireUuid(*object, "session_id");
    auto turnId = requireUuid(*object, "turn_id");
    auto requestId = requireUuid(*object, "request_id");
    auto generation = requireUnsigned(*object, "generation", kMaximumProtocolInteger, 1);
    auto runtimeGeneration = requireUnsigned(*object, "runtime_generation", kMaximumProtocolInteger, 1);
    auto createdAt = requireTimestamp(*object, "created_at");
    auto ok = requireBoolean(*object, "ok");
    auto close = requireBoolean(*object, "close");
    auto error = requireString(*object, "error", 0, 256);
    if (!schema || schema.value() != "lorkhan.response.v1")
        return invalidSchemaValue<CanonicalResponse>("canonical response schema mismatch");
    if (!responseId || responseId.value() != correlation.message.value())
        return invalidSchemaValue<CanonicalResponse>("canonical response message mismatch");
    if (!installationId) return invalidSchemaValue<CanonicalResponse>(installationId.error().message);
    if (!profileId) return invalidSchemaValue<CanonicalResponse>(profileId.error().message);
    if (!playthroughId) return invalidSchemaValue<CanonicalResponse>(playthroughId.error().message);
    if (!sessionId || sessionId.value() != correlation.session.value())
        return invalidSchemaValue<CanonicalResponse>("canonical response session mismatch");
    if (!turnId || turnId.value() != correlation.turn.value())
        return invalidSchemaValue<CanonicalResponse>("canonical response turn mismatch");
    if (!requestId || requestId.value() != correlation.request.value())
        return invalidSchemaValue<CanonicalResponse>("canonical response request mismatch");
    if (!generation || generation.value() != correlation.generation.value())
        return invalidSchemaValue<CanonicalResponse>("canonical response generation mismatch");
    if (!runtimeGeneration) return invalidSchemaValue<CanonicalResponse>(runtimeGeneration.error().message);
    if (!createdAt) return invalidSchemaValue<CanonicalResponse>(createdAt.error().message);
    if (!ok) return invalidSchemaValue<CanonicalResponse>(ok.error().message);
    if (!close) return invalidSchemaValue<CanonicalResponse>(close.error().message);
    if (!error) return invalidSchemaValue<CanonicalResponse>(error.error().message);
    if ((ok.value() && !error.value().empty()) || (!ok.value() && error.value().empty()))
        return invalidSchemaValue<CanonicalResponse>("canonical response outcome mismatch");
    const auto* linesValue = json::find(*object, "lines");
    const auto* lines = linesValue ? linesValue->array() : nullptr;
    if (!lines || lines->size() > 64)
        return invalidSchemaValue<CanonicalResponse>("canonical response lines mismatch");
    CanonicalResponse response{MessageId(std::move(responseId).value()), InstallationId(std::move(installationId).value()),
        ProfileId(std::move(profileId).value()), PlaythroughId(std::move(playthroughId).value()),
        SessionId(std::move(sessionId).value()), TurnId(std::move(turnId).value()), RequestId(std::move(requestId).value()),
        Generation(generation.value()), Generation(runtimeGeneration.value()), std::move(createdAt).value(), ok.value(), {},
        close.value(), std::move(error).value()};
    std::set<std::string> lineIds;
    std::set<std::string> utteranceIds;
    std::set<std::string> mediaIds;
    bool sawAction = false;
    std::optional<std::size_t> finalDialogueIndex;
    for (std::size_t index = 0; index < lines->size(); ++index) {
        auto line = parseCanonicalLine((*lines)[index], response.request, index);
        if (!line) return invalidSchemaValue<CanonicalResponse>(line.error().message);
        if (!lineIds.insert(line.value().line.value()).second || !utteranceIds.insert(line.value().utterance.value()).second)
            return invalidSchemaValue<CanonicalResponse>("canonical response line identity duplicated");
        if (line.value().media && !mediaIds.insert(line.value().media->media.value()).second)
            return invalidSchemaValue<CanonicalResponse>("canonical response media identity duplicated");
        if (line.value().action == "rolecommand")
            sawAction = true;
        else {
            if (sawAction)
                return invalidSchemaValue<CanonicalResponse>("canonical dialogue must precede rolecommands");
            finalDialogueIndex = index;
        }
        response.lines.push_back(std::move(line).value());
    }
    for (std::size_t index = 0; index < response.lines.size(); ++index) {
        const bool expectedFinal = finalDialogueIndex && index == *finalDialogueIndex;
        if (response.lines[index].finalResponseLine != expectedFinal)
            return invalidSchemaValue<CanonicalResponse>("canonical final response line mismatch");
    }
    return Result<CanonicalResponse>::success(std::move(response));
}

Result<ActionIntent> parseActionIntent(const json::Value& value, const TurnId& envelopeTurn)
{
    const auto* object = value.object();
    if (!object || !hasExactly(*object,
            {"schema", "action_id", "turn_id", "name", "tier", "actor", "target", "parameters", "expires_at"},
            {"display_name", "confirmation_required", "followup_enabled", "followup_actions_allowed", "followup_depth"}))
        return invalidSchemaValue<ActionIntent>("action intent fields mismatch");
    auto schema = requireString(*object, "schema");
    auto action = requireUuid(*object, "action_id");
    auto turn = requireUuid(*object, "turn_id");
    auto name = requireString(*object, "name");
    auto tier = requireUnsigned(*object, "tier", 2, 0);
    auto expiresAt = requireTimestamp(*object, "expires_at");
    if (!schema || schema.value() != "lorkhan.action-intent.v1")
        return invalidSchemaValue<ActionIntent>("action intent schema mismatch");
    if (!action) return invalidSchemaValue<ActionIntent>(action.error().message);
    if (!turn) return invalidSchemaValue<ActionIntent>(turn.error().message);
    if (turn.value() != envelopeTurn.value())
        return invalidSchemaValue<ActionIntent>("action intent turn does not match event envelope");
    if (!name || (name.value() != "ai.follow" && name.value() != "ai.stop"
        && name.value() != "ai.approach" && name.value() != "ai.wait"
        && name.value() != "ai.travel" && name.value() != "ai.escort" && name.value() != "ai.face"
        && name.value() != "ai.wander" && name.value() != "combat.start"
        && name.value() != "combat.stop" && name.value() != "animation.play"
        && name.value() != "item.equip" && name.value() != "item.unequip"
        && name.value() != "item.use" && name.value() != "inspect.report" && name.value() != "inventory.inspect"))
        return invalidSchemaValue<ActionIntent>("unknown action intent name");
    if (!tier) return invalidSchemaValue<ActionIntent>(tier.error().message);
    if (((name.value() == "inspect.report" || name.value() == "inventory.inspect") && tier.value() != 0)
        || ((name.value() == "combat.start" || name.value() == "item.equip"
            || name.value() == "item.unequip" || name.value() == "item.use") && tier.value() != 2)
        || (name.value() != "inspect.report" && name.value() != "inventory.inspect" && name.value() != "combat.start"
            && name.value() != "item.equip" && name.value() != "item.unequip"
            && name.value() != "item.use" && tier.value() != 1))
        return invalidSchemaValue<ActionIntent>("action intent tier mismatch");
    if (!expiresAt) return invalidSchemaValue<ActionIntent>(expiresAt.error().message);
    std::string displayName;
    std::optional<bool> confirmationRequired;
    std::optional<bool> followupEnabled;
    std::optional<bool> followupActionsAllowed;
    std::optional<std::uint32_t> followupDepth;
    if (json::find(*object, "display_name")) {
        auto parsed = requireString(*object, "display_name", 1, 128);
        if (!parsed) return invalidSchemaValue<ActionIntent>(parsed.error().message);
        displayName = std::move(parsed).value();
    }
    if (json::find(*object, "confirmation_required")) {
        auto parsed = requireBoolean(*object, "confirmation_required");
        if (!parsed) return invalidSchemaValue<ActionIntent>(parsed.error().message);
        confirmationRequired = parsed.value();
    }
    if (json::find(*object, "followup_enabled")) {
        auto parsed = requireBoolean(*object, "followup_enabled");
        if (!parsed) return invalidSchemaValue<ActionIntent>(parsed.error().message);
        followupEnabled = parsed.value();
    }
    if (json::find(*object, "followup_actions_allowed")) {
        auto parsed = requireBoolean(*object, "followup_actions_allowed");
        if (!parsed) return invalidSchemaValue<ActionIntent>(parsed.error().message);
        followupActionsAllowed = parsed.value();
    }
    if (json::find(*object, "followup_depth")) {
        auto parsed = requireUnsigned(*object, "followup_depth", 1, 0);
        if (!parsed) return invalidSchemaValue<ActionIntent>(parsed.error().message);
        followupDepth = static_cast<std::uint32_t>(parsed.value());
    }

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
    std::uint32_t wanderDistance = 0;
    std::uint32_t wanderDurationSeconds = 0;
    std::string stringParameter;
    std::string secondaryStringParameter;
    double destinationX=0,destinationY=0,destinationZ=0;
    std::string destinationCell;
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
    } else if (name.value() == "ai.wander") {
        if (!hasExactly(*parameters, {"distance", "duration_seconds"}))
            return invalidSchemaValue<ActionIntent>("action intent parameters mismatch");
        auto distance = requireUnsigned(*parameters, "distance", 2048, 0);
        auto duration = requireUnsigned(*parameters, "duration_seconds", 86400, 3600);
        if (!distance) return invalidSchemaValue<ActionIntent>(distance.error().message);
        if (!duration || duration.value() % 3600 != 0)
            return invalidSchemaValue<ActionIntent>("wander duration must be whole game hours");
        intentKind = ActionIntentKind::ai_wander;
        wanderDistance = static_cast<std::uint32_t>(distance.value());
        wanderDurationSeconds = static_cast<std::uint32_t>(duration.value());
    } else if (name.value() == "ai.wait") {
        if (!hasExactly(*parameters, {"duration_seconds"}))
            return invalidSchemaValue<ActionIntent>("ai.wait parameters mismatch");
        auto duration = requireUnsigned(*parameters, "duration_seconds", 86400, 3600);
        if (!duration || duration.value() % 3600 != 0)
            return invalidSchemaValue<ActionIntent>("wait duration must be whole game hours");
        intentKind = ActionIntentKind::ai_wait;
        wanderDurationSeconds = static_cast<std::uint32_t>(duration.value());
    } else if (name.value() == "ai.travel" || name.value() == "ai.escort") {
        if(!hasExactly(*parameters,{"destination_x","destination_y","destination_z","destination_cell"}))
            return invalidSchemaValue<ActionIntent>(name.value()+" parameters mismatch");
        auto x=requireNumber(*parameters,"destination_x",-100000000,100000000);
        auto y=requireNumber(*parameters,"destination_y",-100000000,100000000);
        auto z=requireNumber(*parameters,"destination_z",-100000000,100000000);
        auto cell=requireString(*parameters,"destination_cell",1,300);
        if(!x)return invalidSchemaValue<ActionIntent>(x.error().message);
        if(!y)return invalidSchemaValue<ActionIntent>(y.error().message);
        if(!z)return invalidSchemaValue<ActionIntent>(z.error().message);
        if(!cell||(!cell.value().starts_with("interior:")&&!cell.value().starts_with("exterior:")))
            return invalidSchemaValue<ActionIntent>("destination cell key mismatch");
        destinationX=x.value();destinationY=y.value();destinationZ=z.value();destinationCell=std::move(cell).value();
        intentKind=name.value()=="ai.travel"?ActionIntentKind::ai_travel:ActionIntentKind::ai_escort;
    } else if (name.value() == "ai.face") {
        if(!hasExactly(*parameters,{}))return invalidSchemaValue<ActionIntent>("ai.face parameters must be empty");
        intentKind=ActionIntentKind::ai_face;
    } else if (name.value() == "ai.approach") {
        if (!hasExactly(*parameters, {})) return invalidSchemaValue<ActionIntent>("ai.approach parameters must be empty");
        intentKind = ActionIntentKind::ai_approach;
    } else if (name.value() == "ai.stop") {
        if (!hasExactly(*parameters, {})) return invalidSchemaValue<ActionIntent>("ai.stop parameters must be empty");
        intentKind = ActionIntentKind::ai_stop;
    } else if (name.value() == "combat.start") {
        if (!hasExactly(*parameters, {})) return invalidSchemaValue<ActionIntent>("combat.start parameters must be empty");
        intentKind = ActionIntentKind::combat_start;
    } else if (name.value() == "combat.stop") {
        if (!hasExactly(*parameters, {})) return invalidSchemaValue<ActionIntent>("combat.stop parameters must be empty");
        intentKind = ActionIntentKind::combat_stop;
    } else if (name.value() == "animation.play") {
        if (!hasExactly(*parameters, {"group"})) return invalidSchemaValue<ActionIntent>("animation.play parameters mismatch");
        auto group = requireString(*parameters, "group");
        if (!group || (group.value() != "idle2" && group.value() != "idle3" && group.value() != "idle4"
            && group.value() != "idle5" && group.value() != "idle6" && group.value() != "idle7"
            && group.value() != "idle8" && group.value() != "idle9"))
            return invalidSchemaValue<ActionIntent>("invalid animation group");
        intentKind = ActionIntentKind::animation_play;
        stringParameter = std::move(group).value();
    } else if (name.value() == "item.equip" || name.value() == "item.unequip") {
        const bool equip = name.value() == "item.equip";
        if (!hasExactly(*parameters, equip ? std::initializer_list<std::string_view>{"record_id", "slot"}
                                            : std::initializer_list<std::string_view>{"slot"}))
            return invalidSchemaValue<ActionIntent>(name.value() + " parameters mismatch");
        auto slot = requireString(*parameters, "slot");
        static constexpr std::array<std::string_view, 19> slots{"helmet","cuirass","greaves","left_pauldron",
            "right_pauldron","left_gauntlet","right_gauntlet","boots","shirt","pants","skirt","robe",
            "left_ring","right_ring","amulet","belt","carried_right","carried_left","ammunition"};
        if (!slot || std::find(slots.begin(), slots.end(), slot.value()) == slots.end())
            return invalidSchemaValue<ActionIntent>("invalid equipment slot");
        if (equip) {
            auto recordId = requireString(*parameters, "record_id");
            if (!recordId || recordId.value().empty() || recordId.value().size() > 128
                || recordId.value().find_first_of("/\\\r\n\t") != std::string::npos)
                return invalidSchemaValue<ActionIntent>("invalid item record id");
            stringParameter = std::move(recordId).value();
            intentKind = ActionIntentKind::item_equip;
        } else intentKind = ActionIntentKind::item_unequip;
        secondaryStringParameter = std::move(slot).value();
    } else if (name.value() == "item.use") {
        if (!hasExactly(*parameters, {"record_id"})) return invalidSchemaValue<ActionIntent>("item.use parameters mismatch");
        auto recordId = requireString(*parameters, "record_id");
        if (!recordId || recordId.value().empty() || recordId.value().size() > 128
            || recordId.value().find_first_of("/\\\r\n\t") != std::string::npos)
            return invalidSchemaValue<ActionIntent>("invalid item record id");
        intentKind = ActionIntentKind::item_use;
        stringParameter = std::move(recordId).value();
    } else if (!hasExactly(*parameters, {})) {
        return invalidSchemaValue<ActionIntent>(name.value() + " parameters must be empty");
    } else if (name.value() == "inventory.inspect") {
        intentKind = ActionIntentKind::inventory_inspect;
    }

    return Result<ActionIntent>::success({ActionId(std::move(action).value()),
        TurnId(std::move(turn).value()), std::move(actor).value(), std::move(target).value(),
        intentKind, followDistance, wanderDistance, wanderDurationSeconds, std::move(stringParameter),
        std::move(secondaryStringParameter),destinationX,destinationY,destinationZ,std::move(destinationCell),
        std::move(displayName), confirmationRequired, followupEnabled, followupActionsAllowed, followupDepth,
        std::move(expiresAt).value()});
}

Result<ClientSettings> parseClientSettings(const json::Value& value)
{
    const auto* root=value.object();
    if(!root||!hasExactly(*root,{"schema","behavior","memory","narrator","presentation","safety"}))
        return invalidSchemaValue<ClientSettings>("client settings fields mismatch");
    auto schema=requireString(*root,"schema",1,64);
    if(!schema||schema.value()!="lorkhan.client-settings.v1")return invalidSchemaValue<ClientSettings>("client settings schema mismatch");
    const auto objectFor=[&](std::string_view key)->const json::Object*{const auto* item=json::find(*root,key);return item?item->object():nullptr;};
    const auto* behavior=objectFor("behavior");const auto* memory=objectFor("memory");const auto* narrator=objectFor("narrator");
    const auto* presentation=objectFor("presentation");const auto* safety=objectFor("safety");
    if(!behavior||!hasExactly(*behavior,{"auto_greeting","rechat","rechat_delay_seconds","rechat_max_depth","rechat_probability_percent","rechat_mode","rechat_strict_targeting","open_rechat","rechat_allow_actions","end_conversation_cooldown_seconds","boredom","boredom_delay_seconds","combat_barks","combat_bark_period_seconds"})
        ||!memory||!hasExactly(*memory,{"recent_turn_limit","knowledge_limit"})
        ||!narrator||!hasExactly(*narrator,{"enabled","name","context_visibility","inline_mode","welcome_events","welcome_cooldown_minutes","random_events","random_chance_percent","random_cooldown_rounds","bored_events","bored_chance_percent","quest_events","quest_chance_percent","quest_cooldown_minutes","book_events"})
        ||!presentation||!hasExactly(*presentation,{"show_status_hud","transcript_rows","tts_volume_boost"})
        ||!safety||!hasExactly(*safety,{"actions_enabled","allow_hostile","allow_creatures"}))
        return invalidSchemaValue<ClientSettings>("client settings section mismatch");
    auto autoGreeting=requireBoolean(*behavior,"auto_greeting");auto rechat=requireBoolean(*behavior,"rechat");
    auto rechatDelay=requireUnsigned(*behavior,"rechat_delay_seconds",3600,30);auto rechatDepth=requireUnsigned(*behavior,"rechat_max_depth",20,1);
    auto rechatProbability=requireUnsigned(*behavior,"rechat_probability_percent",100);auto rechatMode=requireString(*behavior,"rechat_mode",1,16);
    auto strictRechat=requireBoolean(*behavior,"rechat_strict_targeting");auto openRechat=requireBoolean(*behavior,"open_rechat");
    auto rechatActions=requireBoolean(*behavior,"rechat_allow_actions");auto conversationCooldown=requireUnsigned(*behavior,"end_conversation_cooldown_seconds",300);
    auto boredom=requireBoolean(*behavior,"boredom");auto boredomDelay=requireUnsigned(*behavior,"boredom_delay_seconds",86400,30);
    auto combatBarks=requireBoolean(*behavior,"combat_barks");auto combatPeriod=requireUnsigned(*behavior,"combat_bark_period_seconds",300,5);
    auto recentTurns=requireUnsigned(*memory,"recent_turn_limit",100,1);auto knowledgeLimit=requireUnsigned(*memory,"knowledge_limit",20);
    auto narratorEnabled=requireBoolean(*narrator,"enabled");auto narratorName=requireString(*narrator,"name",1,128);
    auto contextVisibility=requireBoolean(*narrator,"context_visibility");auto inlineMode=requireString(*narrator,"inline_mode",1,16);
    auto welcomeEvents=requireBoolean(*narrator,"welcome_events");auto welcomeCooldown=requireUnsigned(*narrator,"welcome_cooldown_minutes",1440,1);
    auto randomEvents=requireBoolean(*narrator,"random_events");auto randomChance=requireUnsigned(*narrator,"random_chance_percent",100,1);
    auto randomCooldown=requireUnsigned(*narrator,"random_cooldown_rounds",10);auto boredEvents=requireBoolean(*narrator,"bored_events");
    auto boredChance=requireUnsigned(*narrator,"bored_chance_percent",100,1);auto questEvents=requireBoolean(*narrator,"quest_events");
    auto questChance=requireUnsigned(*narrator,"quest_chance_percent",100,1);auto questCooldown=requireUnsigned(*narrator,"quest_cooldown_minutes",60,1);
    auto bookEvents=requireBoolean(*narrator,"book_events");
    auto showStatus=requireBoolean(*presentation,"show_status_hud");auto transcriptRows=requireUnsigned(*presentation,"transcript_rows",20,2);
    auto volumeBoost=requireUnsigned(*presentation,"tts_volume_boost",4,1);auto actionsEnabled=requireBoolean(*safety,"actions_enabled");
    auto allowHostile=requireBoolean(*safety,"allow_hostile");auto allowCreatures=requireBoolean(*safety,"allow_creatures");
    if(!autoGreeting||!rechat||!rechatDelay||!rechatDepth||!rechatProbability||!rechatMode||!strictRechat||!openRechat
        ||!rechatActions||!conversationCooldown||!boredom||!boredomDelay||!combatBarks||!combatPeriod
        ||!recentTurns||!knowledgeLimit||!narratorEnabled||!narratorName||!contextVisibility||!inlineMode
        ||!welcomeEvents||!welcomeCooldown||!randomEvents||!randomChance||!randomCooldown||!boredEvents||!boredChance
        ||!questEvents||!questChance||!questCooldown||!bookEvents||!showStatus||!transcriptRows||!volumeBoost
        ||!actionsEnabled||!allowHostile||!allowCreatures)return invalidSchemaValue<ClientSettings>("client settings value mismatch");
    if(inlineMode.value()!="Disabled"&&inlineMode.value()!="Narrator"&&inlineMode.value()!="NPC"&&inlineMode.value()!="Text Only")
        return invalidSchemaValue<ClientSettings>("inline narration mode is invalid");
    if(rechatMode.value()!="tight"&&rechatMode.value()!="conversational"&&rechatMode.value()!="group"&&rechatMode.value()!="random")
        return invalidSchemaValue<ClientSettings>("rechat mode is invalid");
    return Result<ClientSettings>::success({
        {autoGreeting.value(),rechat.value(),rechatDelay.value(),rechatDepth.value(),rechatProbability.value(),std::move(rechatMode).value(),
            strictRechat.value(),openRechat.value(),rechatActions.value(),conversationCooldown.value(),boredom.value(),boredomDelay.value(),combatBarks.value(),combatPeriod.value()},
        {recentTurns.value(),knowledgeLimit.value()},
        {narratorEnabled.value(),std::move(narratorName).value(),contextVisibility.value(),std::move(inlineMode).value(),
            welcomeEvents.value(),welcomeCooldown.value(),randomEvents.value(),randomChance.value(),randomCooldown.value(),
            boredEvents.value(),boredChance.value(),questEvents.value(),questChance.value(),questCooldown.value(),bookEvents.value()},
        {showStatus.value(),transcriptRows.value(),volumeBoost.value()},
        {actionsEnabled.value(),allowHostile.value(),allowCreatures.value()}});
}

// Parse the target-scoped, secret-free settings snapshot returned by the controls endpoint.
Result<ControlsResponse::EffectiveSettings> parseEffectiveSettings(const json::Value& value)
{
    using Snapshot=ControlsResponse::EffectiveSettings;
    const auto* root=value.object();
    if(!root||!hasExactly(*root,{"schema","change_token","profile_id","profile_revision","core_profile_id",
            "core_profile_revision","settings","routing","source_map"}))
        return invalidSchemaValue<Snapshot>("effective settings fields mismatch");
    auto schema=requireString(*root,"schema",1,64);auto token=requireString(*root,"change_token",64,64);
    if(!schema||schema.value()!="lorkhan.effective-settings.v1"||!token
        ||!std::all_of(token.value().begin(),token.value().end(),[](unsigned char c){return(c>='0'&&c<='9')||(c>='a'&&c<='f');}))
        return invalidSchemaValue<Snapshot>("effective settings schema or change token mismatch");
    const auto nullableUuid=[&](std::string_view key)->Result<std::optional<std::string>>{
        const auto* item=json::find(*root,key);if(!item)return invalidSchemaValue<std::optional<std::string>>(std::string(key)+" is missing");
        if(item->isNull())return Result<std::optional<std::string>>::success(std::nullopt);
        if(!item->string()||!isCanonicalUuid(*item->string()))
            return invalidSchemaValue<std::optional<std::string>>(std::string(key)+" must be null or a canonical UUID");
        return Result<std::optional<std::string>>::success(*item->string());};
    const auto nullableRevision=[&](std::string_view key)->Result<std::optional<std::uint64_t>>{
        const auto* item=json::find(*root,key);if(!item)return invalidSchemaValue<std::optional<std::uint64_t>>(std::string(key)+" is missing");
        if(item->isNull())return Result<std::optional<std::uint64_t>>::success(std::nullopt);
        auto parsed=requireUnsigned(*root,key,kMaximumProtocolInteger,1);if(!parsed)return invalidSchemaValue<std::optional<std::uint64_t>>(parsed.error().message);
        return Result<std::optional<std::uint64_t>>::success(parsed.value());};
    auto profileId=nullableUuid("profile_id");auto profileRevision=nullableRevision("profile_revision");
    auto coreId=nullableUuid("core_profile_id");auto coreRevision=nullableRevision("core_profile_revision");
    if(!profileId||!profileRevision||!coreId||!coreRevision)return invalidSchemaValue<Snapshot>("effective settings identity mismatch");
    if(profileId.value().has_value()!=profileRevision.value().has_value()
        ||coreId.value().has_value()!=coreRevision.value().has_value())
        return invalidSchemaValue<Snapshot>("effective settings identity revision mismatch");

    const auto* settingsValue=json::find(*root,"settings");const auto* settings=settingsValue?settingsValue->object():nullptr;
    const auto* routingValue=json::find(*root,"routing");const auto* routing=routingValue?routingValue->object():nullptr;
    const auto* sourcesValue=json::find(*root,"source_map");const auto* sources=sourcesValue?sourcesValue->object():nullptr;
    if(!settings||!hasExactly(*settings,{"behavior","memory","narrator","presentation","safety"})||!routing||!sources||sources->size()>64)
        return invalidSchemaValue<Snapshot>("effective settings section mismatch");
    const auto objectFor=[&](std::string_view key)->const json::Object*{const auto* item=json::find(*settings,key);return item?item->object():nullptr;};
    const auto* behavior=objectFor("behavior");const auto* memory=objectFor("memory");const auto* narrator=objectFor("narrator");
    const auto* presentation=objectFor("presentation");const auto* safety=objectFor("safety");
    if(!behavior||!hasExactly(*behavior,{"auto_greeting","rechat","rechat_delay_seconds","rechat_max_depth","rechat_probability_percent","rechat_mode","rechat_strict_targeting","open_rechat","rechat_allow_actions","end_conversation_cooldown_seconds","boredom","boredom_delay_seconds","combat_barks","combat_bark_period_seconds"})
        ||!memory||!hasExactly(*memory,{"recent_turn_limit","knowledge_limit"})
        ||!narrator||!hasExactly(*narrator,{"enabled","name","context_visibility","inline_mode","welcome_events","welcome_cooldown_minutes","random_events","random_chance_percent","random_cooldown_rounds","bored_events","bored_chance_percent","quest_events","quest_chance_percent","quest_cooldown_minutes","book_events"})
        ||!presentation||!hasExactly(*presentation,{"show_status_hud","transcript_rows","tts_volume_boost"})
        ||!safety||!hasExactly(*safety,{"actions_enabled","allow_hostile","allow_creatures"}))
        return invalidSchemaValue<Snapshot>("effective settings value sections mismatch");
    auto autoGreeting=requireBoolean(*behavior,"auto_greeting");auto rechat=requireBoolean(*behavior,"rechat");
    auto rechatDelay=requireUnsigned(*behavior,"rechat_delay_seconds",3600,30);auto rechatDepth=requireUnsigned(*behavior,"rechat_max_depth",20,1);
    auto rechatProbability=requireUnsigned(*behavior,"rechat_probability_percent",100);auto rechatMode=requireString(*behavior,"rechat_mode",1,16);
    auto strictRechat=requireBoolean(*behavior,"rechat_strict_targeting");auto openRechat=requireBoolean(*behavior,"open_rechat");
    auto rechatActions=requireBoolean(*behavior,"rechat_allow_actions");auto conversationCooldown=requireUnsigned(*behavior,"end_conversation_cooldown_seconds",300);
    auto boredom=requireBoolean(*behavior,"boredom");auto boredomDelay=requireUnsigned(*behavior,"boredom_delay_seconds",86400,30);
    auto combatBarks=requireBoolean(*behavior,"combat_barks");auto combatPeriod=requireUnsigned(*behavior,"combat_bark_period_seconds",300,5);
    auto recentTurns=requireUnsigned(*memory,"recent_turn_limit",100,1);auto knowledgeLimit=requireUnsigned(*memory,"knowledge_limit",20);
    auto narratorEnabled=requireBoolean(*narrator,"enabled");auto narratorName=requireString(*narrator,"name",1,128);
    auto contextVisibility=requireBoolean(*narrator,"context_visibility");auto inlineMode=requireString(*narrator,"inline_mode",1,16);
    auto welcomeEvents=requireBoolean(*narrator,"welcome_events");auto welcomeCooldown=requireUnsigned(*narrator,"welcome_cooldown_minutes",1440,1);
    auto randomEvents=requireBoolean(*narrator,"random_events");auto randomChance=requireUnsigned(*narrator,"random_chance_percent",100,1);
    auto randomCooldown=requireUnsigned(*narrator,"random_cooldown_rounds",10);auto boredEvents=requireBoolean(*narrator,"bored_events");
    auto boredChance=requireUnsigned(*narrator,"bored_chance_percent",100,1);auto questEvents=requireBoolean(*narrator,"quest_events");
    auto questChance=requireUnsigned(*narrator,"quest_chance_percent",100,1);auto questCooldown=requireUnsigned(*narrator,"quest_cooldown_minutes",60,1);
    auto bookEvents=requireBoolean(*narrator,"book_events");
    auto showStatus=requireBoolean(*presentation,"show_status_hud");auto transcriptRows=requireUnsigned(*presentation,"transcript_rows",20,2);
    auto volumeBoost=requireUnsigned(*presentation,"tts_volume_boost",4,1);
    auto actionsEnabled=requireBoolean(*safety,"actions_enabled");auto allowHostile=requireBoolean(*safety,"allow_hostile");
    auto allowCreatures=requireBoolean(*safety,"allow_creatures");
    if(!autoGreeting||!rechat||!rechatDelay||!rechatDepth||!rechatProbability||!rechatMode||!strictRechat||!openRechat
        ||!rechatActions||!conversationCooldown||!boredom||!boredomDelay||!combatBarks||!combatPeriod
        ||!recentTurns||!knowledgeLimit||!narratorEnabled||!narratorName||!contextVisibility||!inlineMode
        ||!welcomeEvents||!welcomeCooldown||!randomEvents||!randomChance||!randomCooldown||!boredEvents||!boredChance
        ||!questEvents||!questChance||!questCooldown||!bookEvents||!showStatus||!transcriptRows||!volumeBoost
        ||!actionsEnabled||!allowHostile||!allowCreatures)
        return invalidSchemaValue<Snapshot>("effective settings value mismatch");
    if(inlineMode.value()!="Disabled"&&inlineMode.value()!="Narrator"&&inlineMode.value()!="NPC"&&inlineMode.value()!="Text Only")
        return invalidSchemaValue<Snapshot>("effective inline narration mode is invalid");
    if(rechatMode.value()!="tight"&&rechatMode.value()!="conversational"&&rechatMode.value()!="group"&&rechatMode.value()!="random")
        return invalidSchemaValue<Snapshot>("effective rechat mode is invalid");

    Snapshot parsed;parsed.schema=std::move(schema).value();parsed.changeToken=std::move(token).value();
    parsed.profileId=std::move(profileId).value();parsed.profileRevision=std::move(profileRevision).value();
    parsed.coreProfileId=std::move(coreId).value();parsed.coreProfileRevision=std::move(coreRevision).value();
    parsed.behavior={autoGreeting.value(),rechat.value(),rechatDelay.value(),rechatDepth.value(),rechatProbability.value(),
        std::move(rechatMode).value(),strictRechat.value(),openRechat.value(),rechatActions.value(),conversationCooldown.value(),
        boredom.value(),boredomDelay.value(),combatBarks.value(),combatPeriod.value()};
    parsed.memory={recentTurns.value(),knowledgeLimit.value()};
    parsed.narrator={narratorEnabled.value(),std::move(narratorName).value(),contextVisibility.value(),std::move(inlineMode).value(),
        welcomeEvents.value(),welcomeCooldown.value(),randomEvents.value(),randomChance.value(),randomCooldown.value(),
        boredEvents.value(),boredChance.value(),questEvents.value(),questChance.value(),questCooldown.value(),bookEvents.value()};
    parsed.presentation={showStatus.value(),transcriptRows.value(),volumeBoost.value()};
    parsed.safety={actionsEnabled.value(),allowHostile.value(),allowCreatures.value()};
    static constexpr std::array<std::string_view,7> routingIds={"prompt_configuration_id","llm_configuration_id",
        "llm_fast_configuration_id","llm_powerful_configuration_id","llm_experimental_configuration_id",
        "llm_fallback_configuration_id","tts_configuration_id"};
    static constexpr std::array<std::string_view,2> routingFlags={"llm_randomizer_enabled","llm_fallback_enabled"};
    for(const auto&[key,item]:*routing){
        const bool uuidField=std::find(routingIds.begin(),routingIds.end(),key)!=routingIds.end();
        const bool flagField=std::find(routingFlags.begin(),routingFlags.end(),key)!=routingFlags.end();
        if(uuidField){if(!item.string()||(!item.string()->empty()&&!isCanonicalUuid(*item.string())))
                return invalidSchemaValue<Snapshot>("effective routing UUID mismatch");
            parsed.routing.emplace_back(key,*item.string());}
        else if(flagField){if(!item.boolean())return invalidSchemaValue<Snapshot>("effective routing flag mismatch");
            parsed.routing.emplace_back(key,*item.boolean());}
        else return invalidSchemaValue<Snapshot>("unknown effective routing field");
    }
    static constexpr std::array<std::string_view,14> behaviorFields={"auto_greeting","rechat","rechat_delay_seconds","rechat_max_depth",
        "rechat_probability_percent","rechat_mode","rechat_strict_targeting","open_rechat","rechat_allow_actions",
        "end_conversation_cooldown_seconds","boredom","boredom_delay_seconds","combat_barks","combat_bark_period_seconds"};
    static constexpr std::array<std::string_view,2> memoryFields={"recent_turn_limit","knowledge_limit"};
    static constexpr std::array<std::string_view,15> narratorFields={"enabled","name","context_visibility","inline_mode",
        "welcome_events","welcome_cooldown_minutes","random_events","random_chance_percent","random_cooldown_rounds",
        "bored_events","bored_chance_percent","quest_events","quest_chance_percent","quest_cooldown_minutes","book_events"};
    static constexpr std::array<std::string_view,3> safetyFields={"actions_enabled","allow_hostile","allow_creatures"};
    static constexpr std::array<std::string_view,3> presentationFields={"show_status_hud","transcript_rows","tts_volume_boost"};
    const auto validSettingPath=[&](std::string_view path,std::string_view prefix,const auto& fields){
        if(!path.starts_with(prefix))return false;
        const auto suffix=path.substr(prefix.size());
        return std::find(fields.begin(),fields.end(),suffix)!=fields.end();};
    for(const auto&[key,item]:*sources){
        const bool validPath=validSettingPath(key,"settings.behavior.",behaviorFields)
            ||validSettingPath(key,"settings.memory.",memoryFields)
            ||validSettingPath(key,"settings.narrator.",narratorFields)||validSettingPath(key,"settings.safety.",safetyFields)
            ||validSettingPath(key,"settings.presentation.",presentationFields)
            ||(std::string_view(key).starts_with("routing.")
                &&(std::find(routingIds.begin(),routingIds.end(),std::string_view(key).substr(8))!=routingIds.end()
                    ||std::find(routingFlags.begin(),routingFlags.end(),std::string_view(key).substr(8))!=routingFlags.end()));
        if(!validPath||!item.string()||(*item.string()!="default"&&*item.string()!="global"
                &&*item.string()!="core_profile"&&*item.string()!="npc"&&*item.string()!="narrator_profile"))
            return invalidSchemaValue<Snapshot>("effective settings source map mismatch");
        parsed.sourceMap.emplace_back(key,*item.string());
    }
    return Result<Snapshot>::success(std::move(parsed));
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
        Mapping{"action_parameters_invalid", ErrorCode::invalid_action},
        Mapping{"action_result_expired", ErrorCode::invalid_action},
        Mapping{"action_result_mismatch", ErrorCode::invalid_action},
        Mapping{"action_target_invalid", ErrorCode::invalid_action},
        Mapping{"action_tier_mismatch", ErrorCode::invalid_action},
        Mapping{"cursor_expired", ErrorCode::cursor_expired},
        Mapping{"duplicate_conflict", ErrorCode::duplicate_conflict},
        Mapping{"forbidden", ErrorCode::forbidden},
        Mapping{"internal_error", ErrorCode::internal_error},
        Mapping{"invalid_audio", ErrorCode::media_rejected},
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
        Mapping{"rechat_chain_conflict", ErrorCode::duplicate_conflict},
        Mapping{"rechat_complete", ErrorCode::cancelled},
        Mapping{"rechat_cooldown", ErrorCode::cancelled},
        Mapping{"rechat_no_responder", ErrorCode::cancelled},
        Mapping{"rechat_unavailable", ErrorCode::cancelled},
        Mapping{"invalid_rechat_context", ErrorCode::invalid_schema},
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
    } else if (type.value() == "dialogue.delta") {
        if (!hasExactly(*payload, {"text"}))
            return invalidSchemaValue<ProtocolEvent>("dialogue delta payload fields mismatch");
        auto text = requireString(*payload, "text", 1, 4096);
        if (!text) return invalidSchemaValue<ProtocolEvent>(text.error().message);
        event.type = ProtocolEventType::dialogue_delta;
        event.payload = DialogueDeltaEventPayload{std::move(text).value()};
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
    } else if (type.value() == "response.complete") {
        auto response = parseCanonicalResponse(*payloadValue, correlation.value());
        if (!response) return invalidSchemaValue<ProtocolEvent>(response.error().message);
        event.type = ProtocolEventType::response_complete;
        event.payload = ResponseCompleteEventPayload{std::move(response).value()};
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
        if (!hasExactly(*payload, {"media_id", "dialogue_message_id", "sha256", "bytes", "codec", "duration_ms", "expires_at"}))
            return invalidSchemaValue<ProtocolEvent>("speech payload fields mismatch");
        auto media = requireUuid(*payload, "media_id");
        auto dialogueMessage = requireUuid(*payload, "dialogue_message_id");
        auto hash = requireString(*payload, "sha256");
        auto bytes = requireUnsigned(*payload, "bytes", kMaxMediaBytes, 1);
        auto codec = requireString(*payload, "codec");
        auto duration = requireUnsigned(*payload, "duration_ms", kMaximumProtocolInteger, 1);
        auto expiresAt = requireTimestamp(*payload, "expires_at");
        if (!media) return invalidSchemaValue<ProtocolEvent>(media.error().message);
        if (!dialogueMessage) return invalidSchemaValue<ProtocolEvent>(dialogueMessage.error().message);
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
        event.payload = SpeechReadyEventPayload{MediaId(std::move(media).value()), MessageId(std::move(dialogueMessage).value()), std::move(hash).value(),
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
    auto object = parseObject(body, headers, "lorkhan.health.v1", limits);
    if (!object)
        return Result<void>::failure(object.error());
    if (!hasExactly(object.value(), {"schema"}))
        return invalidSchema("health response contains unknown fields");
    return Result<void>::success();
}

Result<ProtocolError> parseProtocolErrorResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto object = parseObject(body, headers, "lorkhan.error.v1", limits);
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
    auto object = parseObject(body, headers, "lorkhan.session.accepted.v1", limits);
    if (!object) return Result<SessionAcceptedResponse>::failure(object.error());
    if (!hasExactly(object.value(), {"schema", "message_id", "session_id", "generation", "capabilities", "config_revision", "client_settings", "event_cursor"}))
        return invalidSchemaValue<SessionAcceptedResponse>("session accepted fields mismatch");
    auto message = requireUuid(object.value(), "message_id");
    auto session = requireUuid(object.value(), "session_id");
    auto generation = requireUnsigned(object.value(), "generation");
    auto revision = requireString(object.value(), "config_revision", 1, 128);
    auto cursor = requireUnsigned(object.value(), "event_cursor");
    const auto* settingsValue=json::find(object.value(),"client_settings");
    auto settings=settingsValue?parseClientSettings(*settingsValue):invalidSchemaValue<ClientSettings>("client settings are required");
    const auto* capabilitiesValue = json::find(object.value(), "capabilities");
    const auto* capabilities = capabilitiesValue ? capabilitiesValue->array() : nullptr;
    if (!message) return invalidSchemaValue<SessionAcceptedResponse>(message.error().message);
    if (!session) return invalidSchemaValue<SessionAcceptedResponse>(session.error().message);
    if (!generation) return invalidSchemaValue<SessionAcceptedResponse>(generation.error().message);
    if (!revision) return invalidSchemaValue<SessionAcceptedResponse>(revision.error().message);
    if (!cursor) return invalidSchemaValue<SessionAcceptedResponse>(cursor.error().message);
    if (!settings) return invalidSchemaValue<SessionAcceptedResponse>(settings.error().message);
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
        std::move(revision).value(),std::move(settings).value(),cursor.value()});
}

Result<TurnAcceptedResponse> parseTurnAcceptedResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto object = parseObject(body, headers, "lorkhan.turn.accepted.v1", limits);
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
    auto object = parseObject(body, headers, "lorkhan.events.v1", limits);
    if (!object) return Result<EventsResponse>::failure(object.error());
    if (!hasExactly(object.value(), {"schema", "session_id", "generation", "next_after", "events", "autonomy"}))
        return invalidSchemaValue<EventsResponse>("events response fields mismatch");
    auto session = requireUuid(object.value(), "session_id");
    auto generation = requireUnsigned(object.value(), "generation");
    auto nextAfter = requireUnsigned(object.value(), "next_after");
    const auto* eventsValue = json::find(object.value(), "events");
    const auto* events = eventsValue ? eventsValue->array() : nullptr;
    const auto* autonomyValue = json::find(object.value(), "autonomy");
    const auto* autonomy = autonomyValue ? autonomyValue->array() : nullptr;
    if (!session) return invalidSchemaValue<EventsResponse>(session.error().message);
    if (!generation) return invalidSchemaValue<EventsResponse>(generation.error().message);
    if (!nextAfter) return invalidSchemaValue<EventsResponse>(nextAfter.error().message);
    if (!events || events->size() > kMaximumEvents)
        return invalidSchemaValue<EventsResponse>("events must be an array of at most 100 items");
    if (!autonomy || autonomy->size() > 3)
        return invalidSchemaValue<EventsResponse>("autonomy must be an array of at most 3 items");
    EventsResponse parsed{SessionId(std::move(session).value()), Generation(generation.value()), nextAfter.value(), {}, {}};
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
    parsed.autonomy.reserve(autonomy->size());
    for (const auto& value : *autonomy) {
        const auto* directive = value.object();
        if (!directive || !hasExactly(*directive, {"schema", "schedule_id", "kind", "issued_at"}))
            return invalidSchemaValue<EventsResponse>("autonomy directive fields mismatch");
        auto schema = requireString(*directive, "schema");
        auto schedule = requireUuid(*directive, "schedule_id");
        auto kind = requireString(*directive, "kind");
        auto issuedAt = requireTimestamp(*directive, "issued_at");
        if (!schema || schema.value() != "lorkhan.autonomy-directive.v1")
            return invalidSchemaValue<EventsResponse>("autonomy directive schema mismatch");
        if (!schedule) return invalidSchemaValue<EventsResponse>(schedule.error().message);
        if (!kind || (kind.value() != "rechat" && kind.value() != "boredom" && kind.value() != "greeting"))
            return invalidSchemaValue<EventsResponse>("autonomy directive kind mismatch");
        if (!issuedAt) return invalidSchemaValue<EventsResponse>(issuedAt.error().message);
        parsed.autonomy.push_back({std::move(schedule).value(), std::move(kind).value(), std::move(issuedAt).value()});
    }
    return Result<EventsResponse>::success(std::move(parsed));
}

Result<InterruptionAcceptedResponse> parseInterruptionAcceptedResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto object = parseObject(body, headers, "lorkhan.interruption.accepted.v1", limits);
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
    auto object = parseObject(body, headers, "lorkhan.action-result.accepted.v1", limits);
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
    auto object = parseObject(body, headers, "lorkhan.stt.accepted.v1", limits);
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
    auto object = parseObject(body, headers, "lorkhan.dialogue-delivery-result.accepted.v1", limits);
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

Result<MenuDialogueTtsReadyResponse> parseMenuDialogueTtsReadyResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto object=parseObject(body,headers,"lorkhan.menu-dialogue-tts.ready.v1",limits);
    if(!object)return Result<MenuDialogueTtsReadyResponse>::failure(object.error());
    if(!hasExactly(object.value(),{"schema","message_id","request_id","session_id","generation","actor","media"}))
        return invalidSchemaValue<MenuDialogueTtsReadyResponse>("menu dialogue TTS fields mismatch");
    auto message=requireUuid(object.value(),"message_id");auto request=requireUuid(object.value(),"request_id");
    auto session=requireUuid(object.value(),"session_id");auto generation=requireUnsigned(object.value(),"generation");
    const auto* actorValue=json::find(object.value(),"actor");const auto* mediaValue=json::find(object.value(),"media");
    if(!message)return invalidSchemaValue<MenuDialogueTtsReadyResponse>(message.error().message);
    if(!request)return invalidSchemaValue<MenuDialogueTtsReadyResponse>(request.error().message);
    if(!session)return invalidSchemaValue<MenuDialogueTtsReadyResponse>(session.error().message);
    if(!generation)return invalidSchemaValue<MenuDialogueTtsReadyResponse>(generation.error().message);
    if(!actorValue||!mediaValue)return invalidSchemaValue<MenuDialogueTtsReadyResponse>("menu dialogue TTS payload is missing");
    auto actor=parseIdentity(*actorValue);auto media=parseCanonicalMedia(*mediaValue);
    if(!actor)return invalidSchemaValue<MenuDialogueTtsReadyResponse>(actor.error().message);
    if(!media)return invalidSchemaValue<MenuDialogueTtsReadyResponse>(media.error().message);
    return Result<MenuDialogueTtsReadyResponse>::success({MessageId(std::move(message).value()),
        RequestId(std::move(request).value()),SessionId(std::move(session).value()),Generation(generation.value()),
        std::move(actor).value(),std::move(media).value()});
}

Result<PlayerAutochatReadyResponse> parsePlayerAutochatReadyResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto object=parseObject(body,headers,"lorkhan.player-autochat.ready.v1",limits);
    if(!object)return Result<PlayerAutochatReadyResponse>::failure(object.error());
    if(!hasExactly(object.value(),{"schema","message_id","request_id","session_id","generation","text"}))
        return invalidSchemaValue<PlayerAutochatReadyResponse>("player autochat fields mismatch");
    auto message=requireUuid(object.value(),"message_id");auto request=requireUuid(object.value(),"request_id");
    auto session=requireUuid(object.value(),"session_id");auto generation=requireUnsigned(object.value(),"generation");
    auto text=requireString(object.value(),"text",1,4096);
    if(!message)return invalidSchemaValue<PlayerAutochatReadyResponse>(message.error().message);
    if(!request)return invalidSchemaValue<PlayerAutochatReadyResponse>(request.error().message);
    if(!session)return invalidSchemaValue<PlayerAutochatReadyResponse>(session.error().message);
    if(!generation)return invalidSchemaValue<PlayerAutochatReadyResponse>(generation.error().message);
    if(!text)return invalidSchemaValue<PlayerAutochatReadyResponse>(text.error().message);
    return Result<PlayerAutochatReadyResponse>::success({MessageId(std::move(message).value()),
        RequestId(std::move(request).value()),SessionId(std::move(session).value()),Generation(generation.value()),
        std::move(text).value()});
}

Result<GameDataAcceptedResponse> parseGameDataAcceptedResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto object = parseObject(body, headers, "lorkhan.gamedata.accepted.v1", limits);
    if (!object) return Result<GameDataAcceptedResponse>::failure(object.error());
    if (!hasExactly(object.value(), {"schema", "request_id", "session_id", "generation", "type", "duplicate"},{"comment_requested"}))
        return invalidSchemaValue<GameDataAcceptedResponse>("game-data accepted fields mismatch");
    auto request = requireUuid(object.value(), "request_id");
    auto session = requireUuid(object.value(), "session_id");
    auto generation = requireUnsigned(object.value(), "generation", kMaximumProtocolInteger, 1);
    auto type = requireString(object.value(), "type", 1, 64);
    auto duplicate = requireBoolean(object.value(), "duplicate");
    if (!request) return invalidSchemaValue<GameDataAcceptedResponse>(request.error().message);
    if (!session) return invalidSchemaValue<GameDataAcceptedResponse>(session.error().message);
    if (!generation) return invalidSchemaValue<GameDataAcceptedResponse>(generation.error().message);
    if (!type || (type.value() != "captured_dialogue" && type.value() != "actor_profile"
        &&type.value()!="automatic_diary"&&type.value()!="rpg_event"))
        return invalidSchemaValue<GameDataAcceptedResponse>("game-data type mismatch");
    if (!duplicate) return invalidSchemaValue<GameDataAcceptedResponse>(duplicate.error().message);
    bool comment=false;
    if(json::find(object.value(),"comment_requested")){
        auto value=requireBoolean(object.value(),"comment_requested");
        if(!value||type.value()!="rpg_event")return invalidSchemaValue<GameDataAcceptedResponse>("unexpected RPG commentary flag");
        comment=value.value();
    }
    return Result<GameDataAcceptedResponse>::success({RequestId(std::move(request).value()),
        SessionId(std::move(session).value()), Generation(generation.value()), std::move(type).value(), duplicate.value(),comment});
}

Result<SessionEndedResponse> parseSessionEndedResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto object = parseObject(body, headers, "lorkhan.session.ended.v1", limits);
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

Result<ControlsResponse> parseControlsResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto object=parseObject(body,headers,"lorkhan.controls.v1",limits);
    if(!object)return Result<ControlsResponse>::failure(object.error());
    if(!hasExactly(object.value(),{"schema","message_id","request_id","session_id","generation","target",
            "selected_model_slot_key","resolved_model_slot_key","selected_profile_id","narrator_profile_id",
            "effective_settings","model_slots","profiles"},{"settings_editor"}))
        return invalidSchemaValue<ControlsResponse>("controls response fields mismatch");
    auto message=requireUuid(object.value(),"message_id");auto request=requireUuid(object.value(),"request_id");
    auto session=requireUuid(object.value(),"session_id");auto generation=requireUnsigned(object.value(),"generation");
    if(!message)return invalidSchemaValue<ControlsResponse>(message.error().message);
    if(!request)return invalidSchemaValue<ControlsResponse>(request.error().message);
    if(!session)return invalidSchemaValue<ControlsResponse>(session.error().message);
    if(!generation)return invalidSchemaValue<ControlsResponse>(generation.error().message);
    const auto* targetValue=json::find(object.value(),"target");auto target=parseIdentity(*targetValue);
    if(!target)return invalidSchemaValue<ControlsResponse>(target.error().message);
    const auto validSlotKey=[](std::string_view key){return key=="standard"||key=="fast"||key=="powerful"||key=="experimental";};
    const auto nullableUuid=[&object](std::string_view key)->Result<std::optional<std::string>>{
        const auto* value=json::find(object.value(),key);
        if(!value)return invalidSchemaValue<std::optional<std::string>>(std::string(key)+" is missing");
        if(value->isNull())return Result<std::optional<std::string>>::success(std::nullopt);
        if(!value->string()||!isCanonicalUuid(*value->string()))
            return invalidSchemaValue<std::optional<std::string>>(std::string(key)+" must be null or a canonical UUID");
        return Result<std::optional<std::string>>::success(*value->string());
    };
    auto selectedModel=requireString(object.value(),"selected_model_slot_key");
    if(!selectedModel||!validSlotKey(selectedModel.value()))return invalidSchemaValue<ControlsResponse>("selected model slot mismatch");
    const auto* resolvedValue=json::find(object.value(),"resolved_model_slot_key");
    if(!resolvedValue)return invalidSchemaValue<ControlsResponse>("resolved model slot is missing");
    std::optional<std::string> resolvedModel;
    if(!resolvedValue->isNull()){
        if(!resolvedValue->string()||!validSlotKey(*resolvedValue->string()))
            return invalidSchemaValue<ControlsResponse>("resolved model slot mismatch");
        resolvedModel=*resolvedValue->string();
    }
    auto selectedProfile=nullableUuid("selected_profile_id");
    auto narratorProfile=nullableUuid("narrator_profile_id");
    if(!selectedProfile)return invalidSchemaValue<ControlsResponse>(selectedProfile.error().message);
    if(!narratorProfile)return invalidSchemaValue<ControlsResponse>(narratorProfile.error().message);
    const auto* effectiveValue=json::find(object.value(),"effective_settings");auto effective=parseEffectiveSettings(*effectiveValue);
    if(!effective)return invalidSchemaValue<ControlsResponse>(effective.error().message);
    const auto* slotsValue=json::find(object.value(),"model_slots");const auto* slots=slotsValue?slotsValue->array():nullptr;
    const auto* profilesValue=json::find(object.value(),"profiles");const auto* profiles=profilesValue?profilesValue->array():nullptr;
    if(!slots||slots->size()!=4)return invalidSchemaValue<ControlsResponse>("model slots must contain exactly four items");
    if(!profiles||profiles->size()>100)return invalidSchemaValue<ControlsResponse>("profiles must be an array of at most 100 items");
    ControlsResponse parsed{MessageId(std::move(message).value()),RequestId(std::move(request).value()),
        SessionId(std::move(session).value()),Generation(generation.value()),std::move(target).value(),
        std::move(selectedModel).value(),std::move(resolvedModel),std::move(selectedProfile).value(),std::move(narratorProfile).value(),
        std::move(effective).value(),{}, {}};
    const std::array<std::pair<std::string_view,std::string_view>,4> expectedSlots{{
        {"standard","Standard"},{"fast","Fast"},{"powerful","Powerful"},{"experimental","Experimental"}}};
    for(std::size_t index=0;index<slots->size();++index){const auto* row=(*slots)[index].object();
        if(!row||!hasExactly(*row,{"key","label","available","configuration_id","configuration_name","revision","driver","model"}))
            return invalidSchemaValue<ControlsResponse>("model slot fields mismatch");
        auto key=requireString(*row,"key");auto label=requireString(*row,"label",1,32);auto available=requireBoolean(*row,"available");
        if(!key||!label||!available||key.value()!=expectedSlots[index].first||label.value()!=expectedSlots[index].second)
            return invalidSchemaValue<ControlsResponse>("model slot order or label mismatch");
        const auto nullableString=[row](std::string_view field,std::size_t maximum)->Result<std::optional<std::string>>{
            const auto* value=json::find(*row,field);if(!value)return invalidSchemaValue<std::optional<std::string>>(std::string(field)+" is missing");
            if(value->isNull())return Result<std::optional<std::string>>::success(std::nullopt);
            if(!value->string()||value->string()->empty()||value->string()->size()>maximum)
                return invalidSchemaValue<std::optional<std::string>>(std::string(field)+" is invalid");
            return Result<std::optional<std::string>>::success(*value->string());};
        const auto nullableRowUuid=[row](std::string_view field)->Result<std::optional<std::string>>{
            const auto* value=json::find(*row,field);if(!value)return invalidSchemaValue<std::optional<std::string>>(std::string(field)+" is missing");
            if(value->isNull())return Result<std::optional<std::string>>::success(std::nullopt);
            if(!value->string()||!isCanonicalUuid(*value->string()))
                return invalidSchemaValue<std::optional<std::string>>(std::string(field)+" must be null or a canonical UUID");
            return Result<std::optional<std::string>>::success(*value->string());};
        const auto nullableRevision=[row](std::string_view field)->Result<std::optional<std::uint64_t>>{
            const auto* value=json::find(*row,field);if(!value)return invalidSchemaValue<std::optional<std::uint64_t>>(std::string(field)+" is missing");
            if(value->isNull())return Result<std::optional<std::uint64_t>>::success(std::nullopt);
            auto revision=requireUnsigned(*row,field,kMaximumProtocolInteger,1);if(!revision)
                return invalidSchemaValue<std::optional<std::uint64_t>>(revision.error().message);
            return Result<std::optional<std::uint64_t>>::success(revision.value());};
        auto id=nullableRowUuid("configuration_id");auto name=nullableString("configuration_name",128);
        auto revision=nullableRevision("revision");auto driver=nullableString("driver",32);auto model=nullableString("model",256);
        if(!id||!name||!revision||!driver||!model)return invalidSchemaValue<ControlsResponse>("model slot connector fields mismatch");
        const bool complete=id.value().has_value()&&name.value().has_value()&&revision.value().has_value()
            &&driver.value().has_value()&&model.value().has_value();
        const bool empty=!id.value().has_value()&&!name.value().has_value()&&!revision.value().has_value()
            &&!driver.value().has_value()&&!model.value().has_value();
        if((available.value()&&!complete)||(!available.value()&&!empty)
            ||(driver.value()&&*driver.value()!="configured"&&*driver.value()!="mock"))
            return invalidSchemaValue<ControlsResponse>("model slot availability mismatch");
        parsed.modelSlots.push_back({std::move(key).value(),std::move(label).value(),available.value(),
            std::move(id).value(),std::move(name).value(),std::move(revision).value(),std::move(driver).value(),std::move(model).value()});}
    std::set<std::string> unique;
    for(const auto& value:*profiles){const auto* row=value.object();
        if(!row||!hasExactly(*row,{"profile_id","name","revision"}))
            return invalidSchemaValue<ControlsResponse>("profile fields mismatch");
        auto id=requireUuid(*row,"profile_id");auto name=requireString(*row,"name",1,256);
        auto revision=requireUnsigned(*row,"revision",kMaximumProtocolInteger,1);
        if(!id)return invalidSchemaValue<ControlsResponse>(id.error().message);
        if(!name)return invalidSchemaValue<ControlsResponse>(name.error().message);
        if(!revision)return invalidSchemaValue<ControlsResponse>(revision.error().message);
        if(!unique.insert(id.value()).second)return invalidSchemaValue<ControlsResponse>("duplicate profile");
        parsed.profiles.push_back({std::move(id).value(),std::move(name).value(),revision.value()});}
    if(parsed.resolvedModelSlotKey&&!std::any_of(parsed.modelSlots.begin(),parsed.modelSlots.end(),
        [&parsed](const ControlsResponse::ModelSlot& slot){return slot.key==*parsed.resolvedModelSlotKey&&slot.available;}))
        return invalidSchemaValue<ControlsResponse>("resolved model slot is unavailable");
    if(parsed.selectedProfileId&&!std::any_of(parsed.profiles.begin(),parsed.profiles.end(),
        [&parsed](const ControlsResponse::Profile& profile){return profile.profileId==*parsed.selectedProfileId;}))
        return invalidSchemaValue<ControlsResponse>("selected profile is absent from the list");
    if(const auto* editorValue=json::find(object.value(),"settings_editor")){
        const auto* editor=editorValue->object();
        if(!editor||!hasExactly(*editor,{"change_token","sections"}))
            return invalidSchemaValue<ControlsResponse>("settings editor fields mismatch");
        auto token=requireString(*editor,"change_token",64,64);
        const auto* sectionsValue=json::find(*editor,"sections");
        const auto* sections=sectionsValue?sectionsValue->array():nullptr;
        if(!token||!std::all_of(token.value().begin(),token.value().end(),[](char c){return(c>='0'&&c<='9')||(c>='a'&&c<='f');})
            ||!sections||sections->size()>3)
            return invalidSchemaValue<ControlsResponse>("settings editor token or sections invalid");
        ControlsResponse::SettingsEditor result{token.value(),{}};
        std::set<std::string> scopes;
        for(const auto& sectionValue:*sections){
            const auto* section=sectionValue.object();
            if(!section||!hasExactly(*section,{"scope","label","fields"}))
                return invalidSchemaValue<ControlsResponse>("settings section fields mismatch");
            auto scope=requireString(*section,"scope",1,32);auto label=requireString(*section,"label",1,128);
            const auto* fieldsValue=json::find(*section,"fields");const auto* fields=fieldsValue?fieldsValue->array():nullptr;
            if(!scope||!label||(scope.value()!="global"&&scope.value()!="core_profile"&&scope.value()!="npc")
                ||!scopes.insert(scope.value()).second||!fields||fields->size()>64)
                return invalidSchemaValue<ControlsResponse>("settings section invalid");
            ControlsResponse::SettingsSection sectionResult{scope.value(),label.value(),{}};
            std::set<std::string> keys;
            for(const auto& fieldValue:*fields){
                const auto* field=fieldValue.object();
                if(!field||!hasExactly(*field,{"key","label","kind","value"},{"choices","minimum","maximum"}))
                    return invalidSchemaValue<ControlsResponse>("setting field mismatch");
                auto key=requireString(*field,"key",1,128);auto name=requireString(*field,"label",1,128);
                auto kind=requireString(*field,"kind",1,16);auto value=requireString(*field,"value",0,512);
                if(!key||!name||!kind||!value||!keys.insert(key.value()).second
                    ||(kind.value()!="boolean"&&kind.value()!="integer"&&kind.value()!="string"&&kind.value()!="choice"))
                    return invalidSchemaValue<ControlsResponse>("setting descriptor invalid");
                ControlsResponse::SettingsField item{key.value(),name.value(),kind.value(),value.value(),{},std::nullopt,std::nullopt};
                if(item.kind=="boolean"&&item.value!="true"&&item.value!="false")
                    return invalidSchemaValue<ControlsResponse>("setting boolean invalid");
                for(const auto bound:{"minimum","maximum"})if(const auto* limit=json::find(*field,bound)){
                    if(!limit->integer()||*limit->integer() < -1000000||*limit->integer()>1000000)
                        return invalidSchemaValue<ControlsResponse>("setting bounds invalid");
                    if(std::string_view(bound)=="minimum")item.minimum=*limit->integer();else item.maximum=*limit->integer();
                }
                if(item.minimum&&item.maximum&&*item.minimum>*item.maximum)
                    return invalidSchemaValue<ControlsResponse>("setting bounds reversed");
                if(const auto* choicesValue=json::find(*field,"choices")){
                    const auto* choices=choicesValue->array();
                    if(!choices||choices->size()>64)return invalidSchemaValue<ControlsResponse>("setting choices invalid");
                    std::set<std::string> values;
                    for(const auto& choiceValue:*choices){const auto* choice=choiceValue.object();
                        if(!choice||!hasExactly(*choice,{"value","label"}))return invalidSchemaValue<ControlsResponse>("setting choice fields mismatch");
                        auto choiceValueText=requireString(*choice,"value",0,512);auto choiceLabel=requireString(*choice,"label",1,128);
                        if(!choiceValueText||!choiceLabel||!values.insert(choiceValueText.value()).second)
                            return invalidSchemaValue<ControlsResponse>("setting choice invalid");
                        item.choices.emplace_back(choiceValueText.value(),choiceLabel.value());
                    }
                }
                sectionResult.fields.push_back(std::move(item));
            }
            result.sections.push_back(std::move(sectionResult));
        }
        parsed.settingsEditor=std::move(result);
    }
    return Result<ControlsResponse>::success(std::move(parsed));
}

Result<DebugCommandResponse> parseDebugCommandResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto object=parseObject(body,headers,"lorkhan.debug-command.v1",limits);
    if(!object)return Result<DebugCommandResponse>::failure(object.error());
    if(!hasExactly(object.value(),{"schema","message_id","request_id","session_id","generation","command"}))
        return invalidSchemaValue<DebugCommandResponse>("debug command response fields mismatch");
    auto message=requireUuid(object.value(),"message_id");auto request=requireUuid(object.value(),"request_id");
    auto session=requireUuid(object.value(),"session_id");auto generation=requireUnsigned(object.value(),"generation",kMaximumProtocolInteger,1);
    if(!message)return invalidSchemaValue<DebugCommandResponse>(message.error().message);
    if(!request)return invalidSchemaValue<DebugCommandResponse>(request.error().message);
    if(!session)return invalidSchemaValue<DebugCommandResponse>(session.error().message);
    if(!generation)return invalidSchemaValue<DebugCommandResponse>(generation.error().message);
    DebugCommandResponse parsed{MessageId(std::move(message).value()),RequestId(std::move(request).value()),
        SessionId(std::move(session).value()),Generation(generation.value()),std::nullopt};
    const auto* commandValue=json::find(object.value(),"command");
    if(!commandValue)return invalidSchemaValue<DebugCommandResponse>("debug command is missing");
    if(commandValue->isNull())return Result<DebugCommandResponse>::success(std::move(parsed));
    const auto* command=commandValue->object();
    if(!command||!hasExactly(*command,{"command_id","name","parameters","expires_at"}))
        return invalidSchemaValue<DebugCommandResponse>("debug command fields mismatch");
    auto id=requireUuid(*command,"command_id");auto name=requireString(*command,"name",1,64);auto expires=requireTimestamp(*command,"expires_at");
    if(!id)return invalidSchemaValue<DebugCommandResponse>(id.error().message);
    if(!name)return invalidSchemaValue<DebugCommandResponse>(name.error().message);
    if(!expires)return invalidSchemaValue<DebugCommandResponse>(expires.error().message);
    const auto* parametersValue=json::find(*command,"parameters");const auto* parameters=parametersValue?parametersValue->object():nullptr;
    if(!parameters)return invalidSchemaValue<DebugCommandResponse>("debug parameters must be an object");
    std::map<std::string,DebugCommandResponse::Parameter,std::less<>> parsedParameters;
    const auto addString=[&](std::string_view key,std::size_t maximum)->Result<void>{
        auto value=requireString(*parameters,key,1,maximum);
        if(!value)return invalidSchema(value.error().message);
        if(value.value().find_first_of("/\\\r\n\t")!=std::string::npos)
            return invalidSchemaValue<void>("unsafe debug string parameter");
        parsedParameters.emplace(std::string(key),std::move(value).value());
        return Result<void>::success();
    };
    const auto addUnsigned=[&](std::string_view key,std::uint64_t minimum,std::uint64_t maximum)->Result<void>{
        auto value=requireUnsigned(*parameters,key,maximum,minimum);
        if(!value)return invalidSchema(value.error().message);
        parsedParameters.emplace(std::string(key),static_cast<std::int64_t>(value.value()));
        return Result<void>::success();
    };
    const auto addNumber=[&](std::string_view key,double minimum,double maximum)->Result<void>{
        auto value=requireNumber(*parameters,key,minimum,maximum);
        if(!value)return invalidSchema(value.error().message);
        parsedParameters.emplace(std::string(key),value.value());
        return Result<void>::success();
    };
    const bool empty=name.value()=="status.snapshot"||name.value()=="shaders.reload"
        ||name.value()=="player.vitals.restore"||name.value()=="target.actor.kill"
        ||name.value()=="target.actor.restore"||name.value()=="target.teleport.to_player";
    const bool switchCommand=name.value()=="god_mode.set"||name.value()=="collision.set"||name.value()=="ai.set"
        ||name.value()=="mwscript.set"||name.value()=="shader_hot_reload.set";
    if(empty){if(!parameters->empty())return invalidSchemaValue<DebugCommandResponse>("debug command takes no parameters");}
    else if(switchCommand){if(!hasExactly(*parameters,{"enabled"}))return invalidSchemaValue<DebugCommandResponse>("debug switch fields mismatch");
        auto value=requireBoolean(*parameters,"enabled");if(!value)return invalidSchemaValue<DebugCommandResponse>(value.error().message);}
    else if(name.value()=="render_mode.toggle"){
        if(!hasExactly(*parameters,{"mode"}))return invalidSchemaValue<DebugCommandResponse>("render mode fields mismatch");
        auto value=requireString(*parameters,"mode",1,32);if(!value)return invalidSchemaValue<DebugCommandResponse>(value.error().message);
        static constexpr std::array<std::string_view,8> modes={"collision","wireframe","pathgrid","water","scene","navmesh","actors_paths","recast_mesh"};
        if(std::find(modes.begin(),modes.end(),value.value())==modes.end())return invalidSchemaValue<DebugCommandResponse>("unknown render mode");
        parsedParameters.emplace("mode",std::move(value).value());
    }else if(name.value()=="player.inventory.add"||name.value()=="player.inventory.remove"){
        if(!hasExactly(*parameters,{"record_id","count"}))return invalidSchemaValue<DebugCommandResponse>("inventory debug fields mismatch");
        auto record=addString("record_id",256);auto count=addUnsigned("count",1,10000);
        if(!record)return invalidSchemaValue<DebugCommandResponse>(record.error().message);
        if(!count)return invalidSchemaValue<DebugCommandResponse>(count.error().message);
    }else if(name.value()=="player.spell.add"||name.value()=="player.spell.remove"){
        if(!hasExactly(*parameters,{"record_id"}))return invalidSchemaValue<DebugCommandResponse>("spell debug fields mismatch");
        auto record=addString("record_id",256);if(!record)return invalidSchemaValue<DebugCommandResponse>(record.error().message);
    }else if(name.value()=="player.stat.set"){
        if(!hasExactly(*parameters,{"stat","value"}))return invalidSchemaValue<DebugCommandResponse>("stat debug fields mismatch");
        auto stat=addString("stat",16);auto value=addNumber("value",0,1000000);
        if(!stat)return invalidSchemaValue<DebugCommandResponse>(stat.error().message);
        const auto& selected=std::get<std::string>(parsedParameters.at("stat"));
        static constexpr std::array<std::string_view,3> names={"health","magicka","fatigue"};
        if(std::find(names.begin(),names.end(),selected)==names.end())return invalidSchemaValue<DebugCommandResponse>("unknown dynamic stat");
        if(!value)return invalidSchemaValue<DebugCommandResponse>(value.error().message);
    }else if(name.value()=="player.attribute.set"){
        if(!hasExactly(*parameters,{"attribute","value"}))return invalidSchemaValue<DebugCommandResponse>("attribute debug fields mismatch");
        auto attribute=addString("attribute",32);auto value=addNumber("value",0,1000);
        if(!attribute)return invalidSchemaValue<DebugCommandResponse>(attribute.error().message);
        const auto& selected=std::get<std::string>(parsedParameters.at("attribute"));
        static constexpr std::array<std::string_view,8> names={"strength","intelligence","willpower","agility","speed","endurance","personality","luck"};
        if(std::find(names.begin(),names.end(),selected)==names.end())return invalidSchemaValue<DebugCommandResponse>("unknown attribute");
        if(!value)return invalidSchemaValue<DebugCommandResponse>(value.error().message);
    }else if(name.value()=="player.skill.set"){
        if(!hasExactly(*parameters,{"skill","value"}))return invalidSchemaValue<DebugCommandResponse>("skill debug fields mismatch");
        auto skill=addString("skill",32);auto value=addNumber("value",0,1000);
        if(!skill)return invalidSchemaValue<DebugCommandResponse>(skill.error().message);
        const auto& selected=std::get<std::string>(parsedParameters.at("skill"));
        static constexpr std::array<std::string_view,27> names={"block","armorer","mediumarmor","heavyarmor","bluntweapon","longblade","axe","spear","athletics","enchant","destruction","alteration","illusion","conjuration","mysticism","restoration","alchemy","unarmored","security","sneak","acrobatics","lightarmor","shortblade","marksman","mercantile","speechcraft","handtohand"};
        if(std::find(names.begin(),names.end(),selected)==names.end())return invalidSchemaValue<DebugCommandResponse>("unknown skill");
        if(!value)return invalidSchemaValue<DebugCommandResponse>(value.error().message);
    }else if(name.value()=="player.level.set"||name.value()=="player.bounty.set"){
        if(!hasExactly(*parameters,{"value"}))return invalidSchemaValue<DebugCommandResponse>("integer debug fields mismatch");
        auto value=addUnsigned("value",name.value()=="player.level.set"?1:0,name.value()=="player.level.set"?1000:1000000000);
        if(!value)return invalidSchemaValue<DebugCommandResponse>(value.error().message);
    }else if(name.value()=="player.scale.set"||name.value()=="target.scale.set"||name.value()=="world.timescale.set"||name.value()=="world.time.advance"){
        if(!hasExactly(*parameters,{"value"}))return invalidSchemaValue<DebugCommandResponse>("numeric debug fields mismatch");
        double minimum=0;double maximum=10000;
        if(name.value()=="player.scale.set"||name.value()=="target.scale.set"){minimum=0.01;maximum=100;}
        else if(name.value()=="world.time.advance")maximum=8760;
        auto value=addNumber("value",minimum,maximum);if(!value)return invalidSchemaValue<DebugCommandResponse>(value.error().message);
    }else if(name.value()=="player.teleport"){
        if(!hasExactly(*parameters,{"cell","x","y","z"}))return invalidSchemaValue<DebugCommandResponse>("teleport debug fields mismatch");
        auto cell=addString("cell",300);auto x=addNumber("x",-100000000,100000000);
        auto y=addNumber("y",-100000000,100000000);auto z=addNumber("z",-100000000,100000000);
        if(!cell)return invalidSchemaValue<DebugCommandResponse>(cell.error().message);
        if(!x)return invalidSchemaValue<DebugCommandResponse>(x.error().message);
        if(!y)return invalidSchemaValue<DebugCommandResponse>(y.error().message);
        if(!z)return invalidSchemaValue<DebugCommandResponse>(z.error().message);
    }else if(name.value()=="world.weather.set"){
        if(!hasExactly(*parameters,{"region_id","weather"}))return invalidSchemaValue<DebugCommandResponse>("weather debug fields mismatch");
        auto region=addString("region_id",128);auto weather=addString("weather",32);
        if(!region)return invalidSchemaValue<DebugCommandResponse>(region.error().message);
        if(!weather)return invalidSchemaValue<DebugCommandResponse>(weather.error().message);
        const auto& selected=std::get<std::string>(parsedParameters.at("weather"));
        static constexpr std::array<std::string_view,10> names={"clear","cloudy","foggy","overcast","rain","thunderstorm","ashstorm","blight","snow","blizzard"};
        if(std::find(names.begin(),names.end(),selected)==names.end())return invalidSchemaValue<DebugCommandResponse>("unknown weather");
    }else return invalidSchemaValue<DebugCommandResponse>("unknown debug command");
    if(switchCommand){
        auto value=requireBoolean(*parameters,"enabled");
        parsedParameters.emplace("enabled",value.value());
    }
    parsed.command=DebugCommandResponse::Command{MessageId(std::move(id).value()),std::move(name).value(),
        std::move(parsedParameters),std::move(expires).value()};
    return Result<DebugCommandResponse>::success(std::move(parsed));
}

Result<DebugCommandResultAcceptedResponse> parseDebugCommandResultAcceptedResponse(
    std::string_view body, const Headers& headers, json::ParseLimits limits)
{
    auto object=parseObject(body,headers,"lorkhan.debug-command-result.accepted.v1",limits);
    if(!object)return Result<DebugCommandResultAcceptedResponse>::failure(object.error());
    if(!hasExactly(object.value(),{"schema","message_id","request_id","command_id","session_id","generation","status","duplicate"}))
        return invalidSchemaValue<DebugCommandResultAcceptedResponse>("debug command result fields mismatch");
    auto message=requireUuid(object.value(),"message_id");auto request=requireUuid(object.value(),"request_id");
    auto command=requireUuid(object.value(),"command_id");auto session=requireUuid(object.value(),"session_id");
    auto generation=requireUnsigned(object.value(),"generation",kMaximumProtocolInteger,1);auto status=requireString(object.value(),"status",1,16);
    auto duplicate=requireBoolean(object.value(),"duplicate");
    if(!message)return invalidSchemaValue<DebugCommandResultAcceptedResponse>(message.error().message);
    if(!request)return invalidSchemaValue<DebugCommandResultAcceptedResponse>(request.error().message);
    if(!command)return invalidSchemaValue<DebugCommandResultAcceptedResponse>(command.error().message);
    if(!session)return invalidSchemaValue<DebugCommandResultAcceptedResponse>(session.error().message);
    if(!generation)return invalidSchemaValue<DebugCommandResultAcceptedResponse>(generation.error().message);
    if(!status)return invalidSchemaValue<DebugCommandResultAcceptedResponse>(status.error().message);
    if(!duplicate)return invalidSchemaValue<DebugCommandResultAcceptedResponse>(duplicate.error().message);
    if(status.value()!="succeeded"&&status.value()!="failed"&&status.value()!="rejected")
        return invalidSchemaValue<DebugCommandResultAcceptedResponse>("unknown debug result status");
    const auto mapped=status.value()=="succeeded"?DebugCommandResultStatus::succeeded
        :status.value()=="failed"?DebugCommandResultStatus::failed:DebugCommandResultStatus::rejected;
    return Result<DebugCommandResultAcceptedResponse>::success({MessageId(std::move(message).value()),
        RequestId(std::move(request).value()),MessageId(std::move(command).value()),SessionId(std::move(session).value()),
        Generation(generation.value()),mapped,duplicate.value()});
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

} // namespace lorkhan
