#include "lorkhan/beast_transport.hpp"

#ifdef LORKHAN_WITH_BOOST_BEAST
#include "lorkhan/json.hpp"
#include "lorkhan/media.hpp"
#include "lorkhan/protocol_response.hpp"

#include <boost/asio/connect.hpp>
#include <boost/asio/ip/address.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/post.hpp>
#include <boost/beast/http/write.hpp>
#include <boost/beast/core/flat_buffer.hpp>
#include <boost/beast/core/tcp_stream.hpp>
#include <boost/beast/http.hpp>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <limits>
#include <mutex>
#include <optional>
#include <random>
#include <span>
#include <sstream>
#include <tuple>
#include <string>
#include <string_view>
#include <utility>

namespace lorkhan {
namespace {

std::string_view gameDataTypeName(GameDataType type)
{
    switch (type) {
        case GameDataType::captured_dialogue: return "captured_dialogue";
        case GameDataType::actor_profile: return "actor_profile";
        case GameDataType::automatic_diary: return "automatic_diary";
        case GameDataType::rpg_event: return "rpg_event";
        case GameDataType::bored_event: return "bored_event";
    }
    return {};
}

namespace asio = boost::asio;
namespace beast = boost::beast;
namespace http = beast::http;
using tcp = asio::ip::tcp;

constexpr std::string_view kJsonContentType = "application/json; charset=utf-8";
constexpr std::size_t kMaximumHeaderBytes = 32U * 1024U;

std::string escapeJson(std::string_view value)
{
    static constexpr char hex[] = "0123456789abcdef";
    std::string result;
    result.reserve(value.size() + 2);
    result.push_back('"');
    for (const unsigned char character : value) {
        switch (character) {
            case '"': result += "\\\""; break;
            case '\\': result += "\\\\"; break;
            case '\b': result += "\\b"; break;
            case '\f': result += "\\f"; break;
            case '\n': result += "\\n"; break;
            case '\r': result += "\\r"; break;
            case '\t': result += "\\t"; break;
            default:
                if (character < 0x20U) {
                    result += "\\u00";
                    result.push_back(hex[character >> 4U]);
                    result.push_back(hex[character & 0x0FU]);
                } else {
                    result.push_back(static_cast<char>(character));
                }
        }
    }
    result.push_back('"');
    return result;
}

std::string runtimeJson(const RuntimeInfo& runtime)
{
    std::string capabilities = "[";
    for (std::size_t index = 0; index < runtime.capabilities.size(); ++index) {
        if (index != 0)
            capabilities.push_back(',');
        capabilities += escapeJson(runtime.capabilities[index]);
    }
    capabilities.push_back(']');
    return "{\"game\":" + escapeJson(runtime.game)
        + ",\"variant\":" + escapeJson(runtime.variant)
        + ",\"openmw_version\":" + escapeJson(runtime.openmwVersion)
        + ",\"openmw_commit\":" + escapeJson(runtime.openmwCommit)
        + ",\"lua_api_revision\":" + std::to_string(runtime.luaApiRevision)
        + ",\"client_version\":" + escapeJson(runtime.clientVersion)
        + ",\"platform\":" + escapeJson(runtime.platform)
        + ",\"capabilities\":" + capabilities + "}";
}

std::string statusName(ActionTerminalStatus status)
{
    switch (status) {
        case ActionTerminalStatus::succeeded: return "succeeded";
        case ActionTerminalStatus::failed: return "failed";
        case ActionTerminalStatus::rejected: return "rejected";
        case ActionTerminalStatus::timed_out: return "timed_out";
        case ActionTerminalStatus::cancelled: return "cancelled";
    }
    return {};
}

std::string deliveryStatusName(DialogueDeliveryStatus status)
{
    switch (status) {
        case DialogueDeliveryStatus::played: return "played";
        case DialogueDeliveryStatus::failed: return "failed";
        case DialogueDeliveryStatus::expired: return "expired";
        case DialogueDeliveryStatus::interrupted: return "interrupted";
    }
    return {};
}

bool isLowerHexSha256(std::string_view value)
{
    if (value.size() != 64)
        return false;
    return std::all_of(value.begin(), value.end(), [](char character) {
        return (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f');
    });
}

std::string hexBytes(const std::array<std::byte, 32>& value)
{
    static constexpr char alphabet[] = "0123456789abcdef";
    std::string result(64, '0');
    for (std::size_t index = 0; index < value.size(); ++index) {
        const auto byte = std::to_integer<unsigned char>(value[index]);
        result[index * 2] = alphabet[byte >> 4U];
        result[index * 2 + 1] = alphabet[byte & 0x0FU];
    }
    return result;
}

class Sha256 {
public:
    void update(std::span<const std::byte> input)
    {
        for (const std::byte value : input) {
            m_buffer[m_bufferSize++] = std::to_integer<std::uint8_t>(value);
            if (m_bufferSize == m_buffer.size()) {
                transform();
                m_bitCount += 512;
                m_bufferSize = 0;
            }
        }
    }

    std::array<std::byte, 32> finish()
    {
        const std::uint64_t totalBits = m_bitCount + m_bufferSize * 8U;
        m_buffer[m_bufferSize++] = 0x80U;
        if (m_bufferSize > 56) {
            while (m_bufferSize < 64) m_buffer[m_bufferSize++] = 0;
            transform();
            m_bufferSize = 0;
        }
        while (m_bufferSize < 56) m_buffer[m_bufferSize++] = 0;
        for (unsigned index = 0; index < 8; ++index)
            m_buffer[63 - index] = static_cast<std::uint8_t>(totalBits >> (index * 8U));
        transform();
        std::array<std::byte, 32> output{};
        for (std::size_t word = 0; word < m_state.size(); ++word)
            for (unsigned byte = 0; byte < 4; ++byte)
                output[word * 4 + byte] = std::byte(m_state[word] >> (24U - byte * 8U));
        return output;
    }

private:
    static constexpr std::array<std::uint32_t, 64> k{
        0x428a2f98U,0x71374491U,0xb5c0fbcfU,0xe9b5dba5U,0x3956c25bU,0x59f111f1U,0x923f82a4U,0xab1c5ed5U,
        0xd807aa98U,0x12835b01U,0x243185beU,0x550c7dc3U,0x72be5d74U,0x80deb1feU,0x9bdc06a7U,0xc19bf174U,
        0xe49b69c1U,0xefbe4786U,0x0fc19dc6U,0x240ca1ccU,0x2de92c6fU,0x4a7484aaU,0x5cb0a9dcU,0x76f988daU,
        0x983e5152U,0xa831c66dU,0xb00327c8U,0xbf597fc7U,0xc6e00bf3U,0xd5a79147U,0x06ca6351U,0x14292967U,
        0x27b70a85U,0x2e1b2138U,0x4d2c6dfcU,0x53380d13U,0x650a7354U,0x766a0abbU,0x81c2c92eU,0x92722c85U,
        0xa2bfe8a1U,0xa81a664bU,0xc24b8b70U,0xc76c51a3U,0xd192e819U,0xd6990624U,0xf40e3585U,0x106aa070U,
        0x19a4c116U,0x1e376c08U,0x2748774cU,0x34b0bcb5U,0x391c0cb3U,0x4ed8aa4aU,0x5b9cca4fU,0x682e6ff3U,
        0x748f82eeU,0x78a5636fU,0x84c87814U,0x8cc70208U,0x90befffaU,0xa4506cebU,0xbef9a3f7U,0xc67178f2U};
    static std::uint32_t rotate(std::uint32_t value, unsigned bits) { return (value >> bits) | (value << (32U - bits)); }
    void transform()
    {
        std::array<std::uint32_t, 64> words{};
        for (std::size_t index = 0; index < 16; ++index)
            words[index] = (static_cast<std::uint32_t>(m_buffer[index * 4]) << 24U)
                | (static_cast<std::uint32_t>(m_buffer[index * 4 + 1]) << 16U)
                | (static_cast<std::uint32_t>(m_buffer[index * 4 + 2]) << 8U)
                | static_cast<std::uint32_t>(m_buffer[index * 4 + 3]);
        for (std::size_t index = 16; index < 64; ++index) {
            const auto s0 = rotate(words[index - 15], 7) ^ rotate(words[index - 15], 18) ^ (words[index - 15] >> 3U);
            const auto s1 = rotate(words[index - 2], 17) ^ rotate(words[index - 2], 19) ^ (words[index - 2] >> 10U);
            words[index] = words[index - 16] + s0 + words[index - 7] + s1;
        }
        auto [a,b,c,d,e,f,g,h] = std::tuple{m_state[0],m_state[1],m_state[2],m_state[3],m_state[4],m_state[5],m_state[6],m_state[7]};
        for (std::size_t index = 0; index < 64; ++index) {
            const auto s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25);
            const auto choice = (e & f) ^ ((~e) & g);
            const auto temp1 = h + s1 + choice + k[index] + words[index];
            const auto s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22);
            const auto majority = (a & b) ^ (a & c) ^ (b & c);
            const auto temp2 = s0 + majority;
            h=g; g=f; f=e; e=d+temp1; d=c; c=b; b=a; a=temp1+temp2;
        }
        m_state[0]+=a; m_state[1]+=b; m_state[2]+=c; m_state[3]+=d;
        m_state[4]+=e; m_state[5]+=f; m_state[6]+=g; m_state[7]+=h;
    }
    std::array<std::uint32_t, 8> m_state{0x6a09e667U,0xbb67ae85U,0x3c6ef372U,0xa54ff53aU,0x510e527fU,0x9b05688cU,0x1f83d9abU,0x5be0cd19U};
    std::array<std::uint8_t, 64> m_buffer{};
    std::size_t m_bufferSize{};
    std::uint64_t m_bitCount{};
};

std::array<std::byte, 32> sha256(std::string_view value)
{
    Sha256 digest;
    digest.update(std::as_bytes(std::span(value.data(), value.size())));
    return digest.finish();
}

std::array<std::byte, 32> hmacSha256(const PairingToken::Secret& key, std::string_view message)
{
    std::array<std::byte, 64> block{};
    std::copy(key.begin(), key.end(), block.begin());
    std::array<std::byte, 64> innerPad{};
    std::array<std::byte, 64> outerPad{};
    for (std::size_t index = 0; index < block.size(); ++index) {
        innerPad[index] = block[index] ^ std::byte{0x36};
        outerPad[index] = block[index] ^ std::byte{0x5c};
    }
    Sha256 inner;
    inner.update(innerPad);
    inner.update(std::as_bytes(std::span(message.data(), message.size())));
    const auto innerHash = inner.finish();
    Sha256 outer;
    outer.update(outerPad);
    outer.update(innerHash);
    return outer.finish();
}

std::string utcTimestamp()
{
    const auto now = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
    std::tm value{};
#ifdef _WIN32
    gmtime_s(&value, &now);
#else
    gmtime_r(&now, &value);
#endif
    std::ostringstream stream;
    stream << std::put_time(&value, "%Y-%m-%dT%H:%M:%SZ");
    return stream.str();
}

std::string randomNonce()
{
    std::array<std::byte, 16> value{};
    std::random_device source;
    for (auto& byte : value)
        byte = std::byte(source() & 0xffU);
    static constexpr char alphabet[] = "0123456789abcdef";
    std::string result(32, '0');
    for (std::size_t index = 0; index < value.size(); ++index) {
        const auto byte = std::to_integer<unsigned char>(value[index]);
        result[index * 2] = alphabet[byte >> 4U];
        result[index * 2 + 1] = alphabet[byte & 0x0fU];
    }
    return result;
}

std::string mediaContentType(MediaCodec codec)
{
    switch (codec) {
        case MediaCodec::wav: return "audio/wav";
        case MediaCodec::ogg: return "audio/ogg";
        case MediaCodec::mp3: return "audio/mpeg";
    }
    return {};
}

bool isSttLanguage(std::string_view value)
{
    if (value.size() < 2 || value.size() > 35)
        return false;
    std::size_t partLength = 0;
    std::size_t partIndex = 0;
    for (const char character : value) {
        if (character == '-') {
            if ((partIndex == 0 && (partLength < 2 || partLength > 3))
                || (partIndex != 0 && (partLength < 1 || partLength > 8)))
                return false;
            ++partIndex;
            partLength = 0;
        } else {
            const bool alpha = (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z');
            const bool digit = character >= '0' && character <= '9';
            if ((!alpha && (partIndex == 0 || !digit)) || ++partLength > 8)
                return false;
        }
    }
    return partIndex == 0 ? partLength >= 2 && partLength <= 3 : partLength >= 1 && partLength <= 8;
}

bool isSttTimestamp(std::string_view value)
{
    if (value.size() != 20 || value[4] != '-' || value[7] != '-' || value[10] != 'T'
        || value[13] != ':' || value[16] != ':' || value[19] != 'Z')
        return false;
    for (const auto index : std::array<std::size_t, 14>{0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18}) {
        if (value[index] < '0' || value[index] > '9')
            return false;
    }
    return true;
}

Result<void> requireJsonObject(std::string_view value, std::string_view field)
{
    auto parsed = json::parse(value);
    if (!parsed)
        return Result<void>::failure(parsed.error());
    if (!parsed.value().object())
        return Result<void>::failure(makeError(ErrorCode::invalid_schema,
            std::string(field) + " must be a JSON object"));
    return Result<void>::success();
}

struct WireRequest {
    http::verb method{http::verb::get};
    std::string target;
    std::string body;
    std::optional<std::string> idempotencyKey;
    std::string contentType;
    Headers fixedHeaders;
    unsigned expectedStatus{};
    std::size_t requestBodyLimit{kMaxJsonBytes};
    std::size_t responseBodyLimit{kMaxJsonBytes};
    const MediaDescriptor* mediaDescriptor{};
};

Result<WireRequest> serializeRequest(const BaseUrl& baseUrl, const OutboundRequest& request)
{
    const auto route = [&baseUrl](std::string_view suffix) {
        return baseUrl.basePath == "/" ? std::string(suffix) : baseUrl.basePath + std::string(suffix);
    };
    WireRequest wire;
    switch (request.kind) {
        case RequestKind::health:
            wire.target = route("/health");
            wire.expectedStatus = 200;
            break;
        case RequestKind::init: {
            const auto* init = std::get_if<InitRequest>(&request.payload);
            if (!init)
                break;
            wire.method = http::verb::post;
            wire.target = route("/sessions");
            wire.expectedStatus = 201;
            wire.idempotencyKey = init->ids.message.value();
            wire.body = "{\"schema\":\"lorkhan.session.init.v1\",\"message_id\":" + escapeJson(init->ids.message.value())
                + ",\"installation_id\":" + escapeJson(init->ids.installation.value())
                + ",\"profile_id\":" + escapeJson(init->ids.profile.value())
                + ",\"playthrough_id\":" + escapeJson(init->ids.playthrough.value())
                + ",\"generation\":" + std::to_string(init->ids.generation.value())
                + ",\"created_at\":" + escapeJson(init->createdAt)
                + ",\"runtime\":" + runtimeJson(init->runtime)
                + ",\"content_fingerprint\":" + escapeJson(init->contentFingerprint) + "}";
            break;
        }
        case RequestKind::turn: {
            const auto* turn = std::get_if<TurnRequest>(&request.payload);
            if (!turn)
                break;
            auto payload = requireJsonObject(turn->serializedPayload, "turn payload");
            if (!payload)
                return Result<WireRequest>::failure(payload.error());
            wire.method = http::verb::post;
            wire.target = route("/turns");
            wire.expectedStatus = 202;
            wire.idempotencyKey = turn->ids.message.value();
            wire.body = "{\"schema\":\"lorkhan.turn.v1\",\"message_id\":" + escapeJson(turn->ids.message.value())
                + ",\"request_id\":" + escapeJson(turn->ids.request.value())
                + ",\"turn_id\":" + escapeJson(turn->ids.turn.value())
                + ",\"installation_id\":" + escapeJson(turn->ids.installation.value())
                + ",\"profile_id\":" + escapeJson(turn->ids.profile.value())
                + ",\"playthrough_id\":" + escapeJson(turn->ids.playthrough.value())
                + ",\"session_id\":" + escapeJson(turn->ids.session.value())
                + ",\"generation\":" + std::to_string(turn->ids.generation.value())
                + ",\"runtime_generation\":" + std::to_string(turn->runtimeGeneration.value())
                + ",\"created_at\":" + escapeJson(turn->createdAt)
                + ",\"runtime\":" + runtimeJson(turn->runtime)
                + ",\"content_fingerprint\":" + escapeJson(turn->contentFingerprint)
                + ",\"payload\":" + turn->serializedPayload + "}";
            break;
        }
        case RequestKind::event_poll: {
            const auto* poll = std::get_if<EventPollRequest>(&request.payload);
            if (!poll)
                break;
            wire.target = route("/events") + "?session_id=" + poll->session.value()
                + "&generation=" + std::to_string(poll->generation.value())
                + "&after=" + std::to_string(poll->after)
                + "&wait_ms=" + std::to_string(poll->waitMs);
            wire.expectedStatus = 200;
            break;
        }
        case RequestKind::interruption: {
            const auto* interruption = std::get_if<InterruptionRequest>(&request.payload);
            if (!interruption)
                break;
            wire.method = http::verb::post;
            wire.target = route("/interruptions");
            wire.expectedStatus = 202;
            wire.idempotencyKey = interruption->message.value();
            wire.body = "{\"schema\":\"lorkhan.interrupt.v1\",\"message_id\":" + escapeJson(interruption->message.value())
                + ",\"request_id\":" + escapeJson(interruption->request.value())
                + ",\"turn_id\":" + escapeJson(interruption->turn.value())
                + ",\"session_id\":" + escapeJson(interruption->session.value())
                + ",\"generation\":" + std::to_string(interruption->generation.value())
                + ",\"created_at\":" + escapeJson(interruption->createdAt)
                + ",\"reason\":" + escapeJson(interruption->reason) + "}";
            break;
        }
        case RequestKind::action_result: {
            const auto* action = std::get_if<ActionResultRequest>(&request.payload);
            if (!action)
                break;
            auto observed = requireJsonObject(action->serializedObserved, "action-result observed");
            if (!observed)
                return Result<WireRequest>::failure(observed.error());
            wire.method = http::verb::post;
            wire.target = route("/action-results");
            wire.expectedStatus = 200;
            wire.idempotencyKey = action->message.value();
            wire.body = "{\"schema\":\"lorkhan.action-result.v1\",\"message_id\":" + escapeJson(action->message.value())
                + ",\"request_id\":" + escapeJson(action->correlation.request.value())
                + ",\"action_id\":" + escapeJson(action->action.value())
                + ",\"turn_id\":" + escapeJson(action->turn.value())
                + ",\"session_id\":" + escapeJson(action->correlation.session.value())
                + ",\"generation\":" + std::to_string(action->correlation.generation.value())
                + ",\"status\":" + escapeJson(statusName(action->status))
                + ",\"reason_code\":" + escapeJson(action->reasonCode)
                + ",\"observed\":" + action->serializedObserved
                + ",\"completed_at\":" + escapeJson(action->completedAt) + "}";
            break;
        }
        case RequestKind::dialogue_delivery_result: {
            const auto* delivery = std::get_if<DialogueDeliveryResultRequest>(&request.payload);
            if (!delivery)
                break;
            auto speaker = requireJsonObject(delivery->serializedSpeaker, "dialogue delivery speaker");
            if (!speaker)
                return Result<WireRequest>::failure(speaker.error());
            wire.method = http::verb::post;
            wire.target = route("/dialogue-delivery-results");
            wire.expectedStatus = 200;
            wire.idempotencyKey = delivery->message.value();
            wire.contentType = std::string(kJsonContentType);
            wire.body = "{\"schema\":\"lorkhan.dialogue-delivery-result.v1\",\"message_id\":" + escapeJson(delivery->message.value())
                + ",\"request_id\":" + escapeJson(delivery->correlation.request.value())
                + ",\"dialogue_message_id\":" + escapeJson(delivery->dialogueMessage.value())
                + ",\"turn_id\":" + escapeJson(delivery->turn.value())
                + ",\"session_id\":" + escapeJson(delivery->correlation.session.value())
                + ",\"generation\":" + std::to_string(delivery->correlation.generation.value())
                + ",\"speaker\":" + delivery->serializedSpeaker
                + ",\"status\":" + escapeJson(deliveryStatusName(delivery->status))
                + ",\"reason_code\":" + escapeJson(delivery->reasonCode)
                + ",\"completed_at\":" + escapeJson(delivery->completedAt) + "}";
            break;
        }
        case RequestKind::session_end: {
            const auto* end = std::get_if<SessionEndRequest>(&request.payload);
            if (!end)
                break;
            wire.method = http::verb::delete_;
            wire.target = route("/sessions/") + end->session.value();
            wire.expectedStatus = 200;
            wire.idempotencyKey = end->request.value();
            break;
        }
        case RequestKind::stt: {
            const auto* stt = std::get_if<SttRequest>(&request.payload);
            if (!stt)
                break;
            if (stt->audio.empty() || stt->audio.size() > kMaxSttBytes)
                return Result<WireRequest>::failure(makeError(ErrorCode::payload_too_large,
                    "STT audio must contain 1 through 16777216 bytes"));
            if (stt->codec != "wav" || !isSttLanguage(stt->language) || !isSttTimestamp(stt->createdAt)
                || !isLowerHexSha256(stt->sha256) || !isCanonicalUuid(stt->ids.message.value())
                || !isCanonicalUuid(stt->ids.request.value()) || !isCanonicalUuid(stt->ids.turn.value())
                || !isCanonicalUuid(stt->ids.session.value()))
                return Result<WireRequest>::failure(makeError(ErrorCode::invalid_argument,
                    "STT metadata is outside the closed contract"));
            wire.method = http::verb::post;
            wire.target = route("/stt");
            wire.expectedStatus = 202;
            wire.idempotencyKey = stt->ids.message.value();
            wire.contentType = "application/octet-stream";
            wire.requestBodyLimit = kMaxSttBytes;
            wire.body.assign(reinterpret_cast<const char*>(stt->audio.data()), stt->audio.size());
            wire.fixedHeaders = {
                {"X-LORKHAN-Schema", "lorkhan.stt.request.v1"},
                {"X-LORKHAN-Message-Id", stt->ids.message.value()},
                {"X-LORKHAN-Request-Id", stt->ids.request.value()},
                {"X-LORKHAN-Turn-Id", stt->ids.turn.value()},
                {"X-LORKHAN-Session-Id", stt->ids.session.value()},
                {"X-LORKHAN-Generation", std::to_string(stt->ids.generation.value())},
                {"X-LORKHAN-Created-At", stt->createdAt},
                {"X-LORKHAN-Codec", stt->codec},
                {"X-LORKHAN-Language", stt->language},
                {"X-LORKHAN-Audio-Bytes", std::to_string(stt->audio.size())},
                {"X-LORKHAN-Sha256", stt->sha256},
            };
            break;
        }
        case RequestKind::controls_query: {
            const auto* controls = std::get_if<ControlsQueryRequest>(&request.payload);
            if (!controls) break;
            auto target = requireJsonObject(controls->serializedTarget, "controls target");
            if (!target) return Result<WireRequest>::failure(target.error());
            wire.method = http::verb::post;
            wire.target = route("/controls/query");
            wire.expectedStatus = 200;
            wire.body = "{\"schema\":\"lorkhan.controls.query.v1\",\"message_id\":" + escapeJson(controls->message.value())
                + ",\"request_id\":" + escapeJson(controls->correlation.request.value())
                + ",\"session_id\":" + escapeJson(controls->correlation.session.value())
                + ",\"generation\":" + std::to_string(controls->correlation.generation.value())
                + (controls->includeSettingsEditor ? ",\"include_settings_editor\":true" : "")
                + ",\"target\":" + controls->serializedTarget + "}";
            break;
        }
        case RequestKind::controls_select: {
            const auto* controls = std::get_if<ControlsSelectRequest>(&request.payload);
            if (!controls) break;
            auto target = requireJsonObject(controls->serializedTarget, "controls target");
            if (!target) return Result<WireRequest>::failure(target.error());
            wire.method = http::verb::post;
            wire.target = route("/controls/select");
            wire.expectedStatus = 200;
            wire.idempotencyKey = controls->message.value();
            wire.body = "{\"schema\":\"lorkhan.controls.select.v1\",\"message_id\":" + escapeJson(controls->message.value())
                + ",\"request_id\":" + escapeJson(controls->correlation.request.value())
                + ",\"session_id\":" + escapeJson(controls->correlation.session.value())
                + ",\"generation\":" + std::to_string(controls->correlation.generation.value())
                + ",\"created_at\":" + escapeJson(controls->createdAt)
                + ",\"kind\":" + escapeJson(controls->kind == SessionControlKind::model_slot ? "model_slot"
                    : controls->kind == SessionControlKind::actor_profile ? "actor_profile"
                    : controls->kind == SessionControlKind::profile_generate ? "profile_generate"
                    : controls->kind == SessionControlKind::setting ? "setting" : "narrator_profile_generate")
                + ",\"selection_id\":" + (controls->selectionId ? escapeJson(*controls->selectionId) : "null")
                + ",\"selection_key\":" + (controls->selectionKey ? escapeJson(*controls->selectionKey) : "null")
                + ",\"target\":" + controls->serializedTarget + "}";
            if(controls->setting){const auto& setting=*controls->setting;
                wire.body.pop_back();wire.body+=",\"setting\":{\"scope\":"+escapeJson(setting.scope)
                    +",\"key\":"+escapeJson(setting.key)+",\"value\":"+escapeJson(setting.value)
                    +",\"change_token\":"+escapeJson(setting.changeToken)+"}}";
            }
            break;
        }
        case RequestKind::debug_command_query: {
            const auto* debug=std::get_if<DebugCommandQueryRequest>(&request.payload);if(!debug)break;
            wire.method=http::verb::post;wire.target=route("/debug-commands/query");wire.expectedStatus=200;
            wire.body="{\"schema\":\"lorkhan.debug-command.query.v1\",\"message_id\":"+escapeJson(debug->message.value())
                +",\"request_id\":"+escapeJson(debug->correlation.request.value())
                +",\"session_id\":"+escapeJson(debug->correlation.session.value())
                +",\"generation\":"+std::to_string(debug->correlation.generation.value())+"}";
            break;
        }
        case RequestKind::debug_command_result: {
            const auto* debug=std::get_if<DebugCommandResultRequest>(&request.payload);if(!debug)break;
            auto observed=requireJsonObject(debug->serializedObserved,"debug command observed");
            if(!observed)return Result<WireRequest>::failure(observed.error());
            const char* status=debug->status==DebugCommandResultStatus::succeeded?"succeeded"
                :debug->status==DebugCommandResultStatus::failed?"failed":"rejected";
            wire.method=http::verb::post;wire.target=route("/debug-command-results");wire.expectedStatus=200;
            wire.idempotencyKey=debug->message.value();
            wire.body="{\"schema\":\"lorkhan.debug-command-result.v1\",\"message_id\":"+escapeJson(debug->message.value())
                +",\"request_id\":"+escapeJson(debug->correlation.request.value())
                +",\"command_id\":"+escapeJson(debug->command.value())
                +",\"session_id\":"+escapeJson(debug->correlation.session.value())
                +",\"generation\":"+std::to_string(debug->correlation.generation.value())
                +",\"status\":"+escapeJson(status)+",\"reason_code\":"+escapeJson(debug->reasonCode)
                +",\"observed\":"+debug->serializedObserved+",\"completed_at\":"+escapeJson(debug->completedAt)+"}";
            break;
        }
        case RequestKind::menu_dialogue_tts: {
            const auto* menu=std::get_if<MenuDialogueTtsRequest>(&request.payload);
            if(!menu)break;
            auto actor=requireJsonObject(menu->serializedActor,"menu dialogue actor");
            if(!actor)return Result<WireRequest>::failure(actor.error());
            wire.method=http::verb::post;wire.target=route("/menu-dialogue-tts");wire.expectedStatus=201;
            wire.idempotencyKey=menu->message.value();
            wire.body="{\"schema\":\"lorkhan.menu-dialogue-tts.v1\",\"message_id\":"+escapeJson(menu->message.value())
                +",\"request_id\":"+escapeJson(menu->correlation.request.value())
                +",\"session_id\":"+escapeJson(menu->correlation.session.value())
                +",\"generation\":"+std::to_string(menu->correlation.generation.value())
                +",\"created_at\":"+escapeJson(menu->createdAt)+",\"actor\":"+menu->serializedActor
                +",\"text\":"+escapeJson(menu->text)+"}";
            break;
        }
        case RequestKind::book_read_aloud: {
            const auto* book=std::get_if<BookReadAloudRequest>(&request.payload);if(!book)break;
            wire.method=http::verb::post;wire.target=route("/book/read-aloud");wire.expectedStatus=201;
            wire.idempotencyKey=book->message.value();
            wire.body="{\"schema\":\"lorkhan.book.read-aloud.v1\",\"message_id\":"+escapeJson(book->message.value())
                +",\"request_id\":"+escapeJson(book->correlation.request.value())
                +",\"session_id\":"+escapeJson(book->correlation.session.value())
                +",\"generation\":"+std::to_string(book->correlation.generation.value())
                +",\"created_at\":"+escapeJson(book->createdAt)+",\"book_id\":"+escapeJson(book->bookId)
                +",\"title\":"+escapeJson(book->title)+",\"text\":"+escapeJson(book->text)+"}";
            break;
        }
        case RequestKind::player_autochat: {
            const auto* autochat=std::get_if<PlayerAutochatRequest>(&request.payload);
            if(!autochat)break;
            auto player=requireJsonObject(autochat->serializedPlayer,"player autochat player");
            auto target=requireJsonObject(autochat->serializedTarget,"player autochat target");
            if(!player)return Result<WireRequest>::failure(player.error());
            if(!target)return Result<WireRequest>::failure(target.error());
            wire.method=http::verb::post;wire.target=route("/player-autochat");wire.expectedStatus=201;
            wire.idempotencyKey=autochat->message.value();
            wire.body="{\"schema\":\"lorkhan.player-autochat.v1\",\"message_id\":"+escapeJson(autochat->message.value())
                +",\"request_id\":"+escapeJson(autochat->correlation.request.value())
                +",\"session_id\":"+escapeJson(autochat->correlation.session.value())
                +",\"generation\":"+std::to_string(autochat->correlation.generation.value())
                +",\"created_at\":"+escapeJson(autochat->createdAt)+",\"player\":"+autochat->serializedPlayer
                +",\"target\":"+autochat->serializedTarget+",\"intent\":"+escapeJson(autochat->intent)+"}";
            break;
        }
        case RequestKind::gamedata: {
            const auto* gamedata = std::get_if<GameDataRequest>(&request.payload);
            if (!gamedata) break;
            const auto type = gameDataTypeName(gamedata->type);
            if (type.empty())
                return Result<WireRequest>::failure(makeError(ErrorCode::invalid_argument, "unsupported game-data type"));
            auto payload = requireJsonObject(gamedata->serializedPayload, "game-data payload");
            if (!payload) return Result<WireRequest>::failure(payload.error());
            wire.method = http::verb::post;
            wire.target = route("/gamedata");
            wire.expectedStatus = 202;
            wire.idempotencyKey = gamedata->request.value();
            wire.body = "{\"schema\":\"lorkhan.gamedata.v1\",\"installation_id\":"
                + escapeJson(gamedata->installation.value()) + ",\"playthrough_id\":"
                + escapeJson(gamedata->playthrough.value()) + ",\"session_id\":"
                + escapeJson(request.session.value()) + ",\"request_id\":"
                + escapeJson(gamedata->request.value()) + ",\"generation\":"
                + std::to_string(request.generation.value()) + ",\"runtime_generation\":"
                + std::to_string(gamedata->runtimeGeneration.value()) + ",\"observed_at\":"
                + escapeJson(gamedata->observedAt) + ",\"game\":\"tes3\",\"type\":" + escapeJson(type) + ",\"payload\":"
                + gamedata->serializedPayload + "}";
            break;
        }
        case RequestKind::media: {
            const auto* media = std::get_if<MediaPrepareRequest>(&request.payload);
            if (!media)
                break;
            auto suffix = mediaRoute(media->descriptor.id);
            if (!suffix)
                return Result<WireRequest>::failure(suffix.error());
            wire.target = route(suffix.value());
            wire.expectedStatus = 200;
            wire.responseBodyLimit = std::max(media->descriptor.bytes, kMaxJsonBytes);
            wire.mediaDescriptor = &media->descriptor;
            break;
        }
    }
    if (wire.target.empty())
        return Result<WireRequest>::failure(makeError(ErrorCode::invalid_argument,
            "request kind does not match typed payload"));
    if (wire.method == http::verb::post && wire.contentType.empty())
        wire.contentType = std::string(kJsonContentType);
    if (wire.body.size() > wire.requestBodyLimit)
        return Result<WireRequest>::failure(makeError(ErrorCode::payload_too_large,
            "serialized request exceeds endpoint byte limit"));
    return Result<WireRequest>::success(std::move(wire));
}

Headers responseHeaders(const http::response<http::string_body>& response)
{
    Headers headers;
    for (const auto& field : response.base())
        headers.emplace_back(std::string(field.name_string()), std::string(field.value()));
    return headers;
}

Result<InboundResult> protocolFailure(const OutboundRequest& request, unsigned status,
    std::string_view body, const Headers& headers)
{
    if (status >= 300 && status < 400)
        return Result<InboundResult>::failure(makeError(ErrorCode::redirect_rejected,
            "HTTP redirects are rejected"));
    auto parsed = parseProtocolErrorResponse(body, headers);
    if (!parsed)
        return Result<InboundResult>::failure(parsed.error());
    if (parsed.value().correlationId != request.id.value())
        return Result<InboundResult>::failure(makeError(ErrorCode::transport_failure,
            "typed protocol error correlation mismatch"));
    return Result<InboundResult>::failure(makeError(parsed.value().code,
        "server returned a typed protocol error", parsed.value().retriable, parsed.value().retryAfterMs,
        parsed.value().correlationId));
}

Result<InboundResult> validateResponse(const OutboundRequest& request, const WireRequest& wire,
    const http::response<http::string_body>& response)
{
    const unsigned status = response.result_int();
    const Headers headers = responseHeaders(response);
    if (status != wire.expectedStatus) {
        if (status >= 200 && status < 300)
            return Result<InboundResult>::failure(makeError(ErrorCode::transport_failure,
                "server returned an unexpected success status"));
        return protocolFailure(request, status, response.body(), headers);
    }

    SessionId session = request.session;
    ResponseKind kind = ResponseKind::accepted;
    switch (request.kind) {
        case RequestKind::health: {
            auto parsed = parseHealthResponse(response.body(), headers);
            if (!parsed) return Result<InboundResult>::failure(parsed.error());
            kind = ResponseKind::status;
            break;
        }
        case RequestKind::init: {
            const auto& sent = std::get<InitRequest>(request.payload);
            auto parsed = parseSessionAcceptedResponse(response.body(), headers);
            if (!parsed) return Result<InboundResult>::failure(parsed.error());
            if (parsed.value().message != sent.ids.message || parsed.value().generation != request.generation)
                return Result<InboundResult>::failure(makeError(ErrorCode::transport_failure,
                    "session response correlation mismatch"));
            session = parsed.value().session;
            break;
        }
        case RequestKind::turn: {
            const auto& sent = std::get<TurnRequest>(request.payload);
            auto parsed = parseTurnAcceptedResponse(response.body(), headers);
            if (!parsed) return Result<InboundResult>::failure(parsed.error());
            const auto& correlation = parsed.value().correlation;
            if (correlation.message != sent.ids.message || correlation.request != sent.ids.request
                || correlation.turn != sent.ids.turn || correlation.session != sent.ids.session
                || correlation.generation != sent.ids.generation)
                return Result<InboundResult>::failure(makeError(ErrorCode::transport_failure,
                    "turn response correlation mismatch"));
            break;
        }
        case RequestKind::event_poll: {
            const auto& sent = std::get<EventPollRequest>(request.payload);
            auto parsed = parseEventsResponse(response.body(), headers);
            if (!parsed) return Result<InboundResult>::failure(parsed.error());
            if (parsed.value().session != sent.session || parsed.value().generation != sent.generation
                || parsed.value().nextAfter < sent.after)
                return Result<InboundResult>::failure(makeError(ErrorCode::transport_failure,
                    "events response correlation mismatch"));
            kind = ResponseKind::event;
            break;
        }
        case RequestKind::interruption: {
            const auto& sent = std::get<InterruptionRequest>(request.payload);
            auto parsed = parseInterruptionAcceptedResponse(response.body(), headers);
            if (!parsed) return Result<InboundResult>::failure(parsed.error());
            const auto& correlation = parsed.value().correlation;
            if (correlation.message != sent.message || correlation.request != sent.request
                || correlation.turn != sent.turn || correlation.session != sent.session
                || correlation.generation != sent.generation)
                return Result<InboundResult>::failure(makeError(ErrorCode::transport_failure,
                    "interruption response correlation mismatch"));
            break;
        }
        case RequestKind::action_result: {
            const auto& sent = std::get<ActionResultRequest>(request.payload);
            auto parsed = parseActionResultAcceptedResponse(response.body(), headers);
            if (!parsed) return Result<InboundResult>::failure(parsed.error());
            const auto& correlation = parsed.value().correlation;
            if (correlation.message != sent.message || correlation.request != sent.correlation.request
                || correlation.turn != sent.turn || correlation.session != sent.correlation.session
                || correlation.generation != sent.correlation.generation || parsed.value().action != sent.action
                || parsed.value().status != sent.status)
                return Result<InboundResult>::failure(makeError(ErrorCode::transport_failure,
                    "action-result response correlation mismatch"));
            kind = ResponseKind::completed;
            break;
        }
        case RequestKind::dialogue_delivery_result: {
            const auto& sent = std::get<DialogueDeliveryResultRequest>(request.payload);
            auto parsed = parseDialogueDeliveryResultAcceptedResponse(response.body(), headers);
            if (!parsed) return Result<InboundResult>::failure(parsed.error());
            const auto& correlation = parsed.value().correlation;
            if (correlation.message != sent.message || correlation.request != sent.correlation.request
                || correlation.turn != sent.turn || correlation.session != sent.correlation.session
                || correlation.generation != sent.correlation.generation
                || parsed.value().dialogueMessage != sent.dialogueMessage
                || parsed.value().status != sent.status)
                return Result<InboundResult>::failure(makeError(ErrorCode::transport_failure,
                    "dialogue delivery response correlation mismatch"));
            kind = ResponseKind::completed;
            break;
        }
        case RequestKind::session_end: {
            const auto& sent = std::get<SessionEndRequest>(request.payload);
            auto parsed = parseSessionEndedResponse(response.body(), headers);
            if (!parsed) return Result<InboundResult>::failure(parsed.error());
            if (parsed.value().request != sent.request || parsed.value().session != sent.session
                || parsed.value().generation != sent.generation || !parsed.value().ended)
                return Result<InboundResult>::failure(makeError(ErrorCode::transport_failure,
                    "session-end response correlation mismatch"));
            kind = ResponseKind::completed;
            break;
        }
        case RequestKind::stt: {
            const auto& sent = std::get<SttRequest>(request.payload);
            auto parsed = parseSttAcceptedResponse(response.body(), headers);
            if (!parsed) return Result<InboundResult>::failure(parsed.error());
            const auto& correlation = parsed.value().correlation;
            if (correlation.message != sent.ids.message || correlation.request != sent.ids.request
                || correlation.turn != sent.ids.turn || correlation.session != sent.ids.session
                || correlation.generation != sent.ids.generation)
                return Result<InboundResult>::failure(makeError(ErrorCode::transport_failure,
                    "STT response correlation mismatch"));
            break;
        }
        case RequestKind::controls_query: {
            const auto& sent = std::get<ControlsQueryRequest>(request.payload);
            auto parsed = parseControlsResponse(response.body(), headers);
            if (!parsed) return Result<InboundResult>::failure(parsed.error());
            if (parsed.value().message != sent.message || parsed.value().request != sent.correlation.request
                || parsed.value().session != sent.correlation.session || parsed.value().generation != sent.correlation.generation)
                return Result<InboundResult>::failure(makeError(ErrorCode::transport_failure,
                    "controls-query response correlation mismatch"));
            kind = ResponseKind::controls;
            break;
        }
        case RequestKind::controls_select: {
            const auto& sent = std::get<ControlsSelectRequest>(request.payload);
            auto parsed = parseControlsResponse(response.body(), headers);
            if (!parsed) return Result<InboundResult>::failure(parsed.error());
            if (parsed.value().message != sent.message || parsed.value().request != sent.correlation.request
                || parsed.value().session != sent.correlation.session || parsed.value().generation != sent.correlation.generation)
                return Result<InboundResult>::failure(makeError(ErrorCode::transport_failure,
                    "controls-select response correlation mismatch"));
            kind = ResponseKind::controls;
            break;
        }
        case RequestKind::debug_command_query: {
            const auto& sent=std::get<DebugCommandQueryRequest>(request.payload);
            auto parsed=parseDebugCommandResponse(response.body(),headers);
            if(!parsed)return Result<InboundResult>::failure(parsed.error());
            if(parsed.value().message!=sent.message||parsed.value().request!=sent.correlation.request
                ||parsed.value().session!=sent.correlation.session||parsed.value().generation!=sent.correlation.generation)
                return Result<InboundResult>::failure(makeError(ErrorCode::transport_failure,"debug-command response correlation mismatch"));
            kind=ResponseKind::debug_command;break;
        }
        case RequestKind::debug_command_result: {
            const auto& sent=std::get<DebugCommandResultRequest>(request.payload);
            auto parsed=parseDebugCommandResultAcceptedResponse(response.body(),headers);
            if(!parsed)return Result<InboundResult>::failure(parsed.error());
            if(parsed.value().message!=sent.message||parsed.value().request!=sent.correlation.request
                ||parsed.value().command!=sent.command||parsed.value().session!=sent.correlation.session
                ||parsed.value().generation!=sent.correlation.generation||parsed.value().status!=sent.status)
                return Result<InboundResult>::failure(makeError(ErrorCode::transport_failure,"debug-command result correlation mismatch"));
            kind=ResponseKind::completed;break;
        }
        case RequestKind::menu_dialogue_tts: {
            const auto& sent=std::get<MenuDialogueTtsRequest>(request.payload);
            auto parsed=parseMenuDialogueTtsReadyResponse(response.body(),headers);
            if(!parsed)return Result<InboundResult>::failure(parsed.error());
            if(parsed.value().message!=sent.message||parsed.value().request!=sent.correlation.request
                ||parsed.value().session!=sent.correlation.session||parsed.value().generation!=sent.correlation.generation
                ||parsed.value().media.dialogueMessage!=sent.message)
                return Result<InboundResult>::failure(makeError(ErrorCode::transport_failure,
                    "menu dialogue TTS response correlation mismatch"));
            kind=ResponseKind::menu_dialogue_ready;
            break;
        }
        case RequestKind::book_read_aloud: {
            const auto& sent=std::get<BookReadAloudRequest>(request.payload);
            auto parsed=parseMenuDialogueTtsReadyResponse(response.body(),headers);
            if(!parsed)return Result<InboundResult>::failure(parsed.error());
            if(parsed.value().message!=sent.message||parsed.value().request!=sent.correlation.request
                ||parsed.value().session!=sent.correlation.session||parsed.value().generation!=sent.correlation.generation
                ||parsed.value().media.dialogueMessage!=sent.message)
                return Result<InboundResult>::failure(makeError(ErrorCode::transport_failure,"book read-aloud response correlation mismatch"));
            kind=ResponseKind::menu_dialogue_ready;break;
        }
        case RequestKind::player_autochat: {
            const auto& sent=std::get<PlayerAutochatRequest>(request.payload);
            auto parsed=parsePlayerAutochatReadyResponse(response.body(),headers);
            if(!parsed)return Result<InboundResult>::failure(parsed.error());
            if(parsed.value().message!=sent.message||parsed.value().request!=sent.correlation.request
                ||parsed.value().session!=sent.correlation.session||parsed.value().generation!=sent.correlation.generation)
                return Result<InboundResult>::failure(makeError(ErrorCode::transport_failure,
                    "player autochat response correlation mismatch"));
            kind=ResponseKind::player_autochat_ready;
            break;
        }
        case RequestKind::gamedata: {
            const auto& sent = std::get<GameDataRequest>(request.payload);
            auto parsed = parseGameDataAcceptedResponse(response.body(), headers);
            if (!parsed) return Result<InboundResult>::failure(parsed.error());
            if (parsed.value().request != sent.request || parsed.value().session != request.session
                || parsed.value().generation != request.generation || parsed.value().type != gameDataTypeName(sent.type))
                return Result<InboundResult>::failure(makeError(ErrorCode::transport_failure,
                    "game-data response correlation mismatch"));
            break;
        }
        case RequestKind::media:
            kind = ResponseKind::media_ready;
            break;
    }
    return Result<InboundResult>::success(
        {request.id, std::move(session), request.generation, kind, response.body(), std::nullopt});
}

std::chrono::milliseconds boundedStage(std::chrono::steady_clock::time_point totalDeadline,
    std::chrono::milliseconds configured)
{
    const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
        totalDeadline - std::chrono::steady_clock::now());
    return std::max(std::chrono::milliseconds(1), std::min(configured, remaining));
}

Error socketError(const boost::system::error_code& error, bool cancelled, bool deadlineExpired = false)
{
    if (cancelled)
        return makeError(ErrorCode::cancelled, "transport operation cancelled");
    if (deadlineExpired || error == beast::error::timeout || error == asio::error::operation_aborted)
        return makeError(ErrorCode::timeout, "transport stage deadline expired", true);
    return makeError(ErrorCode::transport_failure, "loopback HTTP transport failed");
}

} // namespace

std::string PairingToken::authorizationToken() const
{
    static constexpr char alphabet[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        "abcdefghijklmnopqrstuvwxyz"
        "0123456789-_";
    std::string encoded;
    encoded.reserve(43);
    std::uint32_t accumulator = 0;
    unsigned bits = 0;
    for (const std::byte byte : m_secret) {
        accumulator = (accumulator << 8U) | std::to_integer<unsigned char>(byte);
        bits += 8U;
        while (bits >= 6U) {
            bits -= 6U;
            encoded.push_back(alphabet[(accumulator >> bits) & 0x3FU]);
        }
    }
    if (bits != 0U)
        encoded.push_back(alphabet[(accumulator << (6U - bits)) & 0x3FU]);
    return encoded;
}

struct TransportOperation {
    explicit TransportOperation(RequestId operationRequest)
        : request(std::move(operationRequest)), stream(context)
    {
    }

    void cancel() noexcept
    {
        cancelled = true;
        boost::system::error_code ignored;
        stream.socket().cancel(ignored);
        stream.socket().shutdown(tcp::socket::shutdown_both, ignored);
        stream.socket().close(ignored);
    }

    RequestId request;
    asio::io_context context;
    beast::tcp_stream stream;
    bool cancelled{};
};

struct BeastTransport::Impl {
    Impl(BaseUrl url, InstallationId installationId, PairingToken pairingToken,
        std::filesystem::path configuredCacheRoot, Deadlines configuredDeadlines)
        : baseUrl(std::move(url)), installation(std::move(installationId)), token(std::move(pairingToken)),
          cacheRoot(std::move(configuredCacheRoot)),
          deadlines(configuredDeadlines)
    {
        const std::string canonicalUrl = "http://" + baseUrl.authority() + baseUrl.basePath;
        auto reparsed = parseLoopbackBaseUrl(canonicalUrl);
        if (!reparsed || reparsed.value().host != baseUrl.host || reparsed.value().port != baseUrl.port
            || reparsed.value().basePath != baseUrl.basePath || reparsed.value().ipv6 != baseUrl.ipv6)
            throw std::invalid_argument("BeastTransport requires a prevalidated literal-loopback base URL");
        boost::system::error_code error;
        address = asio::ip::make_address(baseUrl.host, error);
        if (error || !address.is_loopback())
            throw std::invalid_argument("BeastTransport requires a literal loopback address");
        if (!isCanonicalUuid(installation.value()))
            throw std::invalid_argument("BeastTransport requires a canonical installation ID");
        if (token.empty())
            throw std::invalid_argument("BeastTransport requires a request-MAC key");
        if (cacheRoot.empty())
            throw std::invalid_argument("BeastTransport requires a private media cache root");
        std::error_code filesystemError;
        std::filesystem::create_directories(cacheRoot, filesystemError);
        if (filesystemError || std::filesystem::is_symlink(cacheRoot, filesystemError)
            || !std::filesystem::is_directory(cacheRoot, filesystemError))
            throw std::invalid_argument("BeastTransport requires a real media cache directory");
#ifndef _WIN32
        std::filesystem::permissions(cacheRoot, std::filesystem::perms::owner_all,
            std::filesystem::perm_options::replace, filesystemError);
        if (filesystemError)
            throw std::invalid_argument("BeastTransport could not restrict media cache permissions");
#endif
        if (deadlines.connect <= std::chrono::milliseconds::zero()
            || deadlines.write <= std::chrono::milliseconds::zero()
            || deadlines.firstByte <= std::chrono::milliseconds::zero()
            || deadlines.read <= std::chrono::milliseconds::zero()
            || deadlines.total <= std::chrono::milliseconds::zero())
            throw std::invalid_argument("BeastTransport deadlines must be positive");
    }

    BaseUrl baseUrl;
    InstallationId installation;
    PairingToken token;
    std::filesystem::path cacheRoot;
    Deadlines deadlines;
    asio::ip::address address;
    std::mutex operationMutex;
    std::shared_ptr<TransportOperation> activeOperation;
};

BeastTransport::BeastTransport(BaseUrl baseUrl, InstallationId installation, PairingToken token,
    std::filesystem::path mediaCacheRoot)
    : BeastTransport(std::move(baseUrl), std::move(installation), std::move(token),
        std::move(mediaCacheRoot), Deadlines{})
{
}

BeastTransport::BeastTransport(BaseUrl baseUrl, InstallationId installation, PairingToken token,
    std::filesystem::path mediaCacheRoot, Deadlines deadlines)
    : m_impl(std::make_unique<Impl>(std::move(baseUrl), std::move(installation), std::move(token),
        std::move(mediaCacheRoot), deadlines))
{
}

BeastTransport::~BeastTransport() = default;

Result<InboundResult> BeastTransport::execute(const OutboundRequest& request, std::stop_token cancellation)
{
    if (cancellation.stop_requested())
        return Result<InboundResult>::failure(makeError(ErrorCode::cancelled, "transport operation cancelled"));
    auto operation = std::make_shared<TransportOperation>(request.id);
    {
        std::lock_guard lock(m_impl->operationMutex);
        if (m_impl->activeOperation)
            return Result<InboundResult>::failure(makeError(ErrorCode::transport_failure,
                "transport already owns an active operation"));
        m_impl->activeOperation = operation;
    }
    struct OperationCleanup {
        Impl& impl;
        std::shared_ptr<TransportOperation> operation;
        ~OperationCleanup()
        {
            std::lock_guard lock(impl.operationMutex);
            if (impl.activeOperation == operation)
                impl.activeOperation.reset();
        }
    } operationCleanup{*m_impl, operation};

    auto serialized = serializeRequest(m_impl->baseUrl, request);
    if (!serialized)
        return Result<InboundResult>::failure(serialized.error());
    WireRequest wire = std::move(serialized).value();
    const auto totalDeadline = std::chrono::steady_clock::now() + m_impl->deadlines.total;
    const auto cancelled = [&operation, &cancellation] {
        return cancellation.stop_requested() || operation->cancelled;
    };
    std::stop_callback cancellationCallback(cancellation, [weak = std::weak_ptr(operation)] {
        if (auto active = weak.lock())
            asio::post(active->context, [weak] {
                if (auto current = weak.lock())
                    current->cancel();
            });
    });

    boost::system::error_code error;
    operation->stream.expires_after(boundedStage(totalDeadline, m_impl->deadlines.connect));
    operation->stream.async_connect(tcp::endpoint(m_impl->address, m_impl->baseUrl.port),
        [&error](const boost::system::error_code& result) { error = result; });
    operation->context.run();
    operation->context.restart();
    if (error || cancelled())
        return Result<InboundResult>::failure(socketError(error, cancelled()));

    http::request<http::string_body> message{wire.method, wire.target, 11};
    message.set(http::field::host, m_impl->baseUrl.authority());
    message.set(http::field::user_agent, "LORKHAN/" + std::string(kClientVersion));
    message.set(http::field::accept,
        wire.mediaDescriptor ? mediaContentType(wire.mediaDescriptor->codec) : std::string(kJsonContentType));
    message.set(http::field::connection, "close");
    message.set("X-LORKHAN-Request-Id", request.id.value());
    if (wire.idempotencyKey)
        message.set("Idempotency-Key", *wire.idempotencyKey);
    if (wire.method == http::verb::post)
        message.set(http::field::content_type, wire.contentType);
    for (const auto& [name, value] : wire.fixedHeaders)
        message.set(name, value);
    message.body() = std::move(wire.body);
    message.prepare_payload();
    const std::string timestamp = utcTimestamp();
    const std::string nonce = randomNonce();
    const std::string digest = hexBytes(sha256(message.body()));
    const std::string contentType = std::string(message[http::field::content_type]);
    const std::string canonicalTarget = wire.target;
    const std::string canonical = "hmac-sha256-v1\n" + std::string(message.method_string()) + "\n"
        + canonicalTarget + "\n" + contentType + "\n" + digest + "\n"
        + m_impl->installation.value() + "\n" + timestamp + "\n" + nonce;
    message.set("X-LORKHAN-Auth", "hmac-sha256-v1");
    message.set("X-LORKHAN-Installation-Id", m_impl->installation.value());
    message.set("X-LORKHAN-Timestamp", timestamp);
    message.set("X-LORKHAN-Nonce", nonce);
    message.set("X-LORKHAN-Content-SHA256", digest);
    message.set("X-LORKHAN-Signature", hexBytes(hmacSha256(m_impl->token.macKey(), canonical)));

    operation->stream.expires_after(boundedStage(totalDeadline, m_impl->deadlines.write));
    http::async_write(operation->stream, message,
        [&error](const boost::system::error_code& result, std::size_t) { error = result; });
    operation->context.run();
    operation->context.restart();
    if (error || cancelled())
        return Result<InboundResult>::failure(socketError(error, cancelled()));

    beast::flat_buffer buffer;
    buffer.max_size(kMaximumHeaderBytes + wire.responseBodyLimit);
    http::response_parser<http::string_body> parser;
    parser.eager(false);
    parser.header_limit(kMaximumHeaderBytes);
    parser.body_limit(wire.responseBodyLimit);
    const auto firstByteDeadline = std::chrono::steady_clock::now()
        + boundedStage(totalDeadline, m_impl->deadlines.firstByte);
    operation->stream.expires_at(firstByteDeadline);
    http::async_read_header(operation->stream, buffer, parser,
        [&error](const boost::system::error_code& result, std::size_t) { error = result; });
    operation->context.run();
    operation->context.restart();
    if (error || cancelled())
        return Result<InboundResult>::failure(socketError(error, cancelled(),
            std::chrono::steady_clock::now() >= firstByteDeadline));

    const auto contentLength = parser.content_length();
    if (parser.chunked() || !contentLength)
        return Result<InboundResult>::failure(makeError(ErrorCode::transport_failure,
            "response requires one bounded Content-Length body"));
    if (*contentLength > wire.responseBodyLimit)
        return Result<InboundResult>::failure(makeError(ErrorCode::payload_too_large,
            "response body exceeds endpoint byte limit"));
    const unsigned responseStatus = parser.get().result_int();
    const bool mediaSuccess = wire.mediaDescriptor && responseStatus == wire.expectedStatus;
    if (wire.mediaDescriptor && !mediaSuccess && *contentLength > kMaxJsonBytes)
        return Result<InboundResult>::failure(makeError(ErrorCode::payload_too_large,
            "typed media error exceeds JSON byte limit"));
    if (mediaSuccess) {
        if (*contentLength != wire.mediaDescriptor->bytes)
            return Result<InboundResult>::failure(makeError(ErrorCode::media_rejected,
                "media Content-Length does not match descriptor"));
        const Headers headers = responseHeaders(parser.get());
        auto validHeaders = validateHeaders(headers);
        if (!validHeaders)
            return Result<InboundResult>::failure(validHeaders.error());
        auto responseContentType = parseContentType(std::string(parser.get()[http::field::content_type]), true);
        const BodyType expected = wire.mediaDescriptor->codec == MediaCodec::wav ? BodyType::media_wav
            : wire.mediaDescriptor->codec == MediaCodec::ogg ? BodyType::media_ogg : BodyType::media_mpeg;
        if (!responseContentType || responseContentType.value() != expected)
            return Result<InboundResult>::failure(makeError(ErrorCode::invalid_content_type,
                "media Content-Type does not match descriptor codec"));
    }

    operation->stream.expires_after(boundedStage(totalDeadline, m_impl->deadlines.read));
    http::async_read(operation->stream, buffer, parser,
        [&error](const boost::system::error_code& result, std::size_t) { error = result; });
    operation->context.run();
    operation->context.restart();
    if (error || cancelled())
        return Result<InboundResult>::failure(socketError(error, cancelled()));

    boost::system::error_code shutdownError;
    operation->stream.socket().shutdown(tcp::socket::shutdown_both, shutdownError);
    if (!wire.mediaDescriptor)
        return validateResponse(request, wire, parser.get());
    if (!mediaSuccess)
        return protocolFailure(request, responseStatus, parser.get().body(), responseHeaders(parser.get()));

    const auto& descriptor = *wire.mediaDescriptor;
    const std::string hash = hexBytes(descriptor.sha256);
    Sha256 mediaDigest;
    mediaDigest.update(std::as_bytes(std::span(parser.get().body().data(), parser.get().body().size())));
    if (mediaDigest.finish() != descriptor.sha256)
        return Result<InboundResult>::failure(makeError(ErrorCode::media_rejected,
            "media SHA-256 does not match descriptor"));
    auto finalPathResult = resolveCachePath(m_impl->cacheRoot, hash, descriptor.codec);
    if (!finalPathResult)
        return Result<InboundResult>::failure(finalPathResult.error());
    const auto finalPath = finalPathResult.value();
    std::error_code filesystemError;
    const auto existingStatus = std::filesystem::symlink_status(finalPath, filesystemError);
    if (filesystemError && filesystemError != std::errc::no_such_file_or_directory)
        return Result<InboundResult>::failure(makeError(ErrorCode::media_rejected,
            "existing media cache entry could not be inspected"));
    filesystemError.clear();
    if (std::filesystem::is_symlink(existingStatus))
        return Result<InboundResult>::failure(makeError(ErrorCode::media_rejected,
            "existing media cache entry is a symbolic link"));
    if (std::filesystem::is_regular_file(existingStatus)) {
        std::ifstream existing(finalPath, std::ios::binary);
        Sha256 existingDigest;
        std::array<char, 8192> bytes{};
        std::size_t existingBytes = 0;
        while (existing) {
            existing.read(bytes.data(), static_cast<std::streamsize>(bytes.size()));
            const auto count = existing.gcount();
            if (count > 0) {
                existingBytes += static_cast<std::size_t>(count);
                existingDigest.update(std::as_bytes(std::span(bytes.data(), static_cast<std::size_t>(count))));
            }
        }
        if (!existing.eof())
            return Result<InboundResult>::failure(makeError(ErrorCode::media_rejected,
                "existing media cache entry could not be verified"));
        if (existingBytes == descriptor.bytes && existingDigest.finish() == descriptor.sha256)
            return Result<InboundResult>::success({request.id, request.session, request.generation,
                ResponseKind::media_ready, descriptor.id.value(), std::nullopt});
    } else if (std::filesystem::exists(existingStatus)) {
        return Result<InboundResult>::failure(makeError(ErrorCode::media_rejected,
            "existing media cache entry is not a regular file"));
    }
    std::uintmax_t cacheBytes = 0;
    for (std::filesystem::recursive_directory_iterator entry(m_impl->cacheRoot,
             std::filesystem::directory_options::skip_permission_denied, filesystemError), end;
         !filesystemError && entry != end; entry.increment(filesystemError)) {
        if (entry->is_symlink(filesystemError))
            return Result<InboundResult>::failure(makeError(ErrorCode::media_rejected,
                "media cache contains a symbolic link"));
        if (entry->is_regular_file(filesystemError)) {
            const auto size = entry->file_size(filesystemError);
            if (filesystemError || size > std::numeric_limits<std::uintmax_t>::max() - cacheBytes)
                return Result<InboundResult>::failure(makeError(ErrorCode::media_rejected,
                    "media cache size could not be bounded"));
            cacheBytes += size;
        }
    }
    constexpr std::uintmax_t cacheQuota = 512U * 1024U * 1024U;
    if (filesystemError || descriptor.bytes > cacheQuota || cacheBytes > cacheQuota - descriptor.bytes)
        return Result<InboundResult>::failure(makeError(ErrorCode::media_rejected,
            "media cache quota would be exceeded"));
    std::filesystem::create_directories(finalPath.parent_path(), filesystemError);
    if (filesystemError || std::filesystem::is_symlink(finalPath.parent_path(), filesystemError))
        return Result<InboundResult>::failure(makeError(ErrorCode::media_rejected,
            "media cache parent is not a real directory"));
#ifndef _WIN32
    std::filesystem::permissions(finalPath.parent_path(), std::filesystem::perms::owner_all,
        std::filesystem::perm_options::replace, filesystemError);
    if (filesystemError)
        return Result<InboundResult>::failure(makeError(ErrorCode::media_rejected,
            "media cache parent permissions could not be restricted"));
#endif
    const auto temporary = finalPath.string() + ".tmp-" + descriptor.id.value();
    struct Cleanup {
        std::filesystem::path path;
        bool committed{};
        ~Cleanup() { if (!committed) { std::error_code ignored; std::filesystem::remove(path, ignored); } }
    } cleanup{temporary};
    {
        std::ofstream file(temporary, std::ios::binary | std::ios::trunc);
        if (!file)
            return Result<InboundResult>::failure(makeError(ErrorCode::media_rejected,
                "media temporary file could not be opened"));
        file.write(parser.get().body().data(), static_cast<std::streamsize>(parser.get().body().size()));
        file.flush();
        if (!file)
            return Result<InboundResult>::failure(makeError(ErrorCode::media_rejected,
                "media temporary file could not be written"));
    }
#ifndef _WIN32
    std::filesystem::permissions(temporary, std::filesystem::perms::owner_read | std::filesystem::perms::owner_write,
        std::filesystem::perm_options::replace, filesystemError);
    if (filesystemError)
        return Result<InboundResult>::failure(makeError(ErrorCode::media_rejected,
            "media temporary file permissions could not be restricted"));
#endif
    if (cancelled())
        return Result<InboundResult>::failure(makeError(ErrorCode::cancelled, "media preparation cancelled"));
#ifdef _WIN32
    const auto backup = finalPath.string() + ".old-" + descriptor.id.value();
    if (std::filesystem::exists(finalPath, filesystemError)) {
        std::filesystem::rename(finalPath, backup, filesystemError);
        if (filesystemError)
            return Result<InboundResult>::failure(makeError(ErrorCode::media_rejected,
                "corrupt media cache entry could not be isolated"));
    }
    std::filesystem::rename(temporary, finalPath, filesystemError);
    if (!filesystemError) {
        std::error_code ignored;
        std::filesystem::remove(backup, ignored);
    } else if (std::filesystem::exists(backup)) {
        std::error_code ignored;
        std::filesystem::rename(backup, finalPath, ignored);
    }
#else
    std::filesystem::rename(temporary, finalPath, filesystemError);
#endif
    if (filesystemError)
        return Result<InboundResult>::failure(makeError(ErrorCode::media_rejected,
            "verified media could not be atomically promoted"));
    cleanup.committed = true;
    return Result<InboundResult>::success({request.id, request.session, request.generation,
        ResponseKind::media_ready, descriptor.id.value(), std::nullopt});
}

void BeastTransport::interrupt(const RequestId& request) noexcept
{
    std::shared_ptr<TransportOperation> operation;
    {
        std::lock_guard lock(m_impl->operationMutex);
        if (!m_impl->activeOperation || m_impl->activeOperation->request != request)
            return;
        operation = m_impl->activeOperation;
    }
    asio::post(operation->context, [weak = std::weak_ptr(operation), request] {
        if (auto active = weak.lock(); active && active->request == request)
            active->cancel();
    });
}

} // namespace lorkhan
#endif
