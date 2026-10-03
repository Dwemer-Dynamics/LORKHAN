#include "lorkhan/client_config_path.hpp"
#include <fstream>
#include <lorkhan/record_provenance.hpp>
#include <lorkhan/playback.hpp>
#include <lorkhan/session_identity.hpp>
#include "lorkhan/actions.hpp"
#include "lorkhan/bridge_service.hpp"
#include "lorkhan/events.hpp"
#include "lorkhan/json.hpp"
#include "lorkhan/media.hpp"
#include "lorkhan/plugin_package.hpp"
#include "lorkhan/protocol_response.hpp"
#include "lorkhan/queues.hpp"
#include "lorkhan/validation.hpp"
#include "lorkhan/voice_capture.hpp"

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <limits>
#include <mutex>
#include <span>
#include <stop_token>
#include <string>
#include <thread>
#include <type_traits>
#include <tuple>
#include <vector>

using namespace std::chrono_literals;

namespace {

int failures = 0;
#define CHECK(expression) do { if (!(expression)) { std::cerr << __FILE__ << ':' << __LINE__ << ": CHECK failed: " #expression "\n"; ++failures; } } while (false)

constexpr const char* kInstallation = "01900000-0000-7000-8000-000000000001";
constexpr const char* kProfile = "01900000-0000-7000-8000-000000000002";
constexpr const char* kPlaythrough = "01900000-0000-7000-8000-000000000003";
constexpr const char* kSession = "01900000-0000-7000-8000-000000000004";
constexpr const char* kTurn = "01900000-0000-7000-8000-000000000005";
constexpr const char* kMessage = "01900000-0000-7000-8000-000000000006";
constexpr const char* kAction = "01900000-0000-7000-8000-000000000007";

class FakeClock final : public lorkhan::IClock {
public:
    std::chrono::steady_clock::time_point steadyNow() const noexcept override { return steady; }
    std::chrono::system_clock::time_point systemNow() const noexcept override { return system; }
    std::chrono::steady_clock::time_point steady{10s};
    std::chrono::system_clock::time_point system{std::chrono::seconds(100)};
};

struct TransportState {
    std::atomic<unsigned> executions{0};
    std::atomic<unsigned> interrupts{0};
    std::atomic<unsigned> pollWaitMs{9999};
    std::atomic<bool> block{false};
};

class FakeTransport final : public lorkhan::ITransport {
public:
    explicit FakeTransport(std::shared_ptr<TransportState> state) : m_state(std::move(state)) {}
    lorkhan::Result<lorkhan::InboundResult> execute(
        const lorkhan::OutboundRequest& request, std::stop_token cancellation) override
    {
        if (const auto* poll = std::get_if<lorkhan::EventPollRequest>(&request.payload))
            m_state->pollWaitMs = poll->waitMs;
        ++m_state->executions;
        while (m_state->block.load() && !cancellation.stop_requested())
            std::this_thread::yield();
        if (cancellation.stop_requested())
            return lorkhan::Result<lorkhan::InboundResult>::failure(
                lorkhan::makeError(lorkhan::ErrorCode::cancelled, "cancelled"));
        return lorkhan::Result<lorkhan::InboundResult>::success(
            {request.id, request.session, request.generation, lorkhan::ResponseKind::completed, "{}", std::nullopt});
    }
    void interrupt(const lorkhan::RequestId&) noexcept override { ++m_state->interrupts; m_state->block = false; }
private:
    std::shared_ptr<TransportState> m_state;
};

std::string uuidFor(unsigned value)
{
    std::string uuid = "01900000-0000-7000-8000-000000000000";
    constexpr char hex[] = "0123456789abcdef";
    uuid[34] = hex[(value >> 4U) & 0xFU];
    uuid[35] = hex[value & 0xFU];
    return uuid;
}

std::string protocolIdentity()
{
    return R"({"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"})";
}

lorkhan::OutboundRequest request(std::string id, lorkhan::Generation generation)
{
    lorkhan::EnvelopeIds ids{lorkhan::InstallationId(kInstallation), lorkhan::ProfileId(kProfile),
        lorkhan::PlaythroughId(kPlaythrough), lorkhan::SessionId(kSession), lorkhan::RequestId(id),
        lorkhan::TurnId(kTurn), lorkhan::MessageId(kMessage), generation};
    return {lorkhan::RequestId(std::move(id)), lorkhan::SessionId(kSession), generation,
        lorkhan::RequestKind::turn, lorkhan::TurnRequest{std::move(ids), generation, {}, "sha256:test",
            "2026-07-18T20:00:00Z", "{}"}};
}

void testUtf8()
{
    CHECK(lorkhan::isValidUtf8("plain"));
    CHECK(lorkhan::isValidUtf8("Morrowind \xE2\x9C\x93"));
    CHECK(!lorkhan::isValidUtf8(std::string("\xC0\x80", 2)));
    CHECK(!lorkhan::isValidUtf8(std::string("\xED\xA0\x80", 3)));
    CHECK(!lorkhan::isValidUtf8(std::string("\xF4\x90\x80\x80", 4)));
    CHECK(!lorkhan::requireValidUtf8("abcd", 3));
    CHECK(lorkhan::isCanonicalUuid(kSession));
    const auto referenceProfile=std::string("ref:")+kInstallation+":"+kPlaythrough+":morrowind.esm|4294967295";
    CHECK(lorkhan::isProfileId(referenceProfile));
    CHECK(!lorkhan::isCanonicalUuid(referenceProfile));
    CHECK(!lorkhan::isProfileId(referenceProfile+"0"));
    CHECK(!lorkhan::isProfileId(std::string("ref:")+kInstallation+":"+kPlaythrough+":Morrowind.esm|1"));
    CHECK(!lorkhan::isProfileId(std::string("ref:")+kInstallation+":"+kPlaythrough+":../morrowind.esm|1"));
    CHECK(!lorkhan::isProfileId(std::string("ref:")+kInstallation+":"+kPlaythrough+":morrowind.esm|01"));
    CHECK(!lorkhan::isCanonicalUuid("01900000-0000-7000-8000-00000000000"));
    CHECK(!lorkhan::isCanonicalUuid("01900000-0000-7000-8000-00000000000g"));
    CHECK(!lorkhan::isCanonicalUuid("01900000-0000-7000-8000-00000000000A"));
}

void testUrls()
{
    const std::vector<std::string> valid{
        "http://127.0.0.1:7514/LorkhanServer/api/v1", "http://127.1.2.3/", "http://[::1]:7514/api"};
    for (const auto& url : valid)
        CHECK(lorkhan::parseLoopbackBaseUrl(url));
    const std::vector<std::string> invalid{
        "https://127.0.0.1/", "HTTP://127.0.0.1/", "http://localhost/", "http://127.0.0.1.evil/",
        "http://2130706433/", "http://0177.0.0.1/", "http://0x7f.0.0.1/", "http://[::ffff:127.0.0.1]/",
        "http://user@127.0.0.1/", "http://127.0.0.1/a?b", "http://127.0.0.1/a#b",
        "http://127.0.0.1/%2e%2e/x", "http://127.0.0.1/a/../b", "http://127.0.0.1:080/",
        "http://127.0.0.1:0/", "http://127.0.0.1\r\nX: y/", "http://[0:0:0:0:0:0:0:1]/"};
    for (const auto& url : invalid)
        CHECK(!lorkhan::parseLoopbackBaseUrl(url));
    const auto parsed = lorkhan::parseLoopbackBaseUrl("http://[::1]:7514/api/");
    CHECK(parsed && parsed.value().basePath == "/api" && parsed.value().authority() == "[::1]:7514");
}

void testHeaders()
{
    CHECK(lorkhan::validateJsonContentType({{"Content-Type", "application/json; charset=utf-8"}}));
    CHECK(!lorkhan::validateJsonContentType({{"Content-Type", "application/json"}}));
    CHECK(!lorkhan::validateHeaders({{"X-Test", "one"}, {"x-test", "two"}}));
    CHECK(!lorkhan::validateHeaders({{"X-Test", "one\r\ntwo"}}));
    CHECK(lorkhan::parseContentType("audio/ogg", true));
    CHECK(!lorkhan::parseContentType("text/plain"));
}

void testJson()
{
    using lorkhan::ErrorCode;
    using lorkhan::json::find;
    using lorkhan::json::parse;

    auto parsed = parse(R"json({"schema":"lorkhan.health.v1","null":null,"ok":true,"sequence":7,"fraction":-1.25e+2,"text":"Morrowind ✓","escaped":"\"\\\/\b\f\n\r\t","unicode":"¢€😀","array":[false,0]})json");
    CHECK(parsed && parsed.value().object());
    if (parsed && parsed.value().object()) {
        const auto& object = *parsed.value().object();
        CHECK(find(object, "null") && find(object, "null")->isNull());
        CHECK(find(object, "ok") && find(object, "ok")->boolean() && *find(object, "ok")->boolean());
        CHECK(find(object, "sequence") && find(object, "sequence")->integer()
            && *find(object, "sequence")->integer() == 7);
        CHECK(find(object, "fraction") && find(object, "fraction")->number()
            && *find(object, "fraction")->number() == -125.0);
        CHECK(find(object, "text") && find(object, "text")->string()
            && *find(object, "text")->string() == "Morrowind ✓");
        CHECK(find(object, "escaped") && find(object, "escaped")->string()
            && *find(object, "escaped")->string() == std::string("\"\\/\b\f\n\r\t"));
        CHECK(find(object, "unicode") && find(object, "unicode")->string()
            && *find(object, "unicode")->string() == std::string("\xC2\xA2\xE2\x82\xAC\xF0\x9F\x98\x80", 9));
        CHECK(find(object, "array") && find(object, "array")->array()
            && find(object, "array")->array()->size() == 2);
    }

    const std::vector<std::string> valid{
        "null", " true \n", "false", "0", "-0", "9223372036854775807", "-9223372036854775808",
        "0.0", "-0.125", "1e0", "1E+308", "[ ]", "{}", R"({"a":1,"b":[2,3]})",
        R"("𝄞")", std::string("\"") + "\\u0000" + "\""};
    for (const auto& input : valid) {
        const auto value = parse(input);
        if (!value)
            std::cerr << "valid JSON rejected: " << input << " (" << value.error().message << ")\n";
        CHECK(value);
    }

    const std::vector<std::string> invalid{
        "", " ", "+1", ".1", "1.", "01", "-01", "--1", "1e", "1e+", "1e309",
        "9223372036854775808", "-9223372036854775809", "NaN", "Infinity", "truex", "nul",
        "[] trailing", "[, ]", "[1,]", "[1 2]", "{,}", R"({"a":1,})", R"({"a" 1})",
        R"({"duplicate":1,"duplicate":2})", R"("unterminated)", std::string("\"control\n\""),
        R"("\x00")", R"("\u12")", R"("\uZZZZ")", R"("\uD800")", R"("\uD800A")",
        R"("\uDC00")"};
    for (const auto& input : invalid)
        CHECK(!parse(input));

    auto schema = lorkhan::json::requireObjectWithSchema(
        R"({"schema":"lorkhan.health.v1"})", "lorkhan.health.v1");
    CHECK(schema && find(schema.value(), "schema") != nullptr);
    auto wrongSchema = lorkhan::json::requireObjectWithSchema(
        R"({"schema":"lorkhan.error.v1"})", "lorkhan.health.v1");
    CHECK(!wrongSchema && wrongSchema.error().code == ErrorCode::invalid_schema);
    auto nonObject = lorkhan::json::requireObjectWithSchema("[]", "lorkhan.health.v1");
    CHECK(!nonObject && nonObject.error().code == ErrorCode::invalid_schema);

    auto oversized = parse(std::string(2U * 1024U * 1024U + 1U, ' '));
    CHECK(!oversized && oversized.error().code == ErrorCode::payload_too_large);
    auto invalidUtf8 = parse(std::string("\xC0\x80", 2));
    CHECK(!invalidUtf8 && invalidUtf8.error().code == ErrorCode::invalid_utf8);
    auto syntax = parse("[");
    CHECK(!syntax && syntax.error().code == ErrorCode::invalid_json);

    lorkhan::json::ParseLimits limits;
    limits.maximumDepth = 1;
    CHECK(parse(R"({"scalar":1})", limits));
    auto tooDeep = parse(R"({"nested":{"too":"deep"}})", limits);
    CHECK(!tooDeep && tooDeep.error().code == ErrorCode::payload_too_large);
    limits = {};
    limits.maximumValues = 3;
    CHECK(parse("[1,2]", limits));
    auto tooMany = parse("[1,2,3]", limits);
    CHECK(!tooMany && tooMany.error().code == ErrorCode::payload_too_large);
    limits = {};
    limits.maximumStringBytes = 3;
    CHECK(parse(R"("abc")", limits));
    auto longString = parse(R"("abcd")", limits);
    CHECK(!longString && longString.error().code == ErrorCode::payload_too_large);
    auto escapedLongString = parse(R"("€x")", limits);
    CHECK(!escapedLongString && escapedLongString.error().code == ErrorCode::payload_too_large);
}

void testProtocolResponses()
{
    const lorkhan::Headers jsonHeaders{{"Content-Type", "application/json; charset=utf-8"}};
    // Physical diary DTOs never admit record properties, invalid hashes, or oversized plaintext.
    CHECK(lorkhan::parseDiaryBookResponse(R"DIARY({"schema":"lorkhan.diary-book.v1","message_id":"00000000-0000-4000-8000-000000000040","request_id":"00000000-0000-4000-8000-000000000041","session_id":"00000000-0000-4000-8000-000000000007","generation":7,"book":{"delivery_id":"00000000-0000-4000-8000-000000000042","book_id":"00000000-0000-4000-8000-000000000043","target":{"cell":{"kind":"interior","name":"Balmora"},"content_file":"Morrowind.esm","display_name":"Player","kind":"npc","record_id":"player","refnum":{"content_file":0,"index":16384}},"title":"Fargoth's Diary","content":"I wrote about today in Balmora.","content_hash":"2b95b1d49768775d44f2bb976a0ce7d4815cae7bbfbdf83e97683b67aebb125c"}})DIARY",jsonHeaders));
    CHECK(!lorkhan::parseDiaryBookResponse(R"DIARY({"schema":"lorkhan.diary-book.v1","message_id":"00000000-0000-4000-8000-000000000040","request_id":"00000000-0000-4000-8000-000000000041","session_id":"00000000-0000-4000-8000-000000000007","generation":7,"book":{"delivery_id":"00000000-0000-4000-8000-000000000042","book_id":"00000000-0000-4000-8000-000000000043","target":{"cell":{"kind":"interior","name":"Balmora"},"content_file":"Morrowind.esm","display_name":"Player","kind":"npc","record_id":"player","refnum":{"content_file":0,"index":16384}},"title":"Fargoth's Diary","content":"I wrote about today in Balmora.","content_hash":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"}})DIARY",jsonHeaders));
    CHECK(!lorkhan::parseDiaryBookResponse(R"DIARY({"schema":"lorkhan.diary-book.v1","message_id":"00000000-0000-4000-8000-000000000040","request_id":"00000000-0000-4000-8000-000000000041","session_id":"00000000-0000-4000-8000-000000000007","generation":7,"book":{"delivery_id":"00000000-0000-4000-8000-000000000042","book_id":"00000000-0000-4000-8000-000000000043","target":{"cell":{"kind":"interior","name":"Balmora"},"content_file":"Morrowind.esm","display_name":"Player","kind":"npc","record_id":"player","refnum":{"content_file":0,"index":16384}},"title":"Fargoth's Diary","content":"I wrote about today in Balmora.","content_hash":"2b95b1d49768775d44f2bb976a0ce7d4815cae7bbfbdf83e97683b67aebb125c","script":"evil"}})DIARY",jsonHeaders));
    CHECK(!lorkhan::parseDiaryBookResponse(R"DIARY({"schema":"lorkhan.diary-book.v1","message_id":"00000000-0000-4000-8000-000000000040","request_id":"00000000-0000-4000-8000-000000000041","session_id":"00000000-0000-4000-8000-000000000007","generation":7,"book":{"delivery_id":"00000000-0000-4000-8000-000000000042","book_id":"00000000-0000-4000-8000-000000000043","target":{"cell":{"kind":"interior","name":"Balmora"},"content_file":"Morrowind.esm","display_name":"Player","kind":"npc","record_id":"player","refnum":{"content_file":0,"index":16384}},"title":"Fargoth's Diary","content":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","content_hash":"d2bc1d811fcb4da2cc5719f1fc1654084a6ed72d777e7c1bed597f6dbf007829"}})DIARY",jsonHeaders));
    CHECK(lorkhan::parseDiaryBookResponse(R"DIARY({"schema":"lorkhan.diary-book.v1","message_id":"00000000-0000-4000-8000-000000000040","request_id":"00000000-0000-4000-8000-000000000041","session_id":"00000000-0000-4000-8000-000000000007","generation":7,"book":{"delivery_id":"00000000-0000-4000-8000-000000000042","book_id":"00000000-0000-4000-8000-000000000043","target":{"cell":{"kind":"interior","name":"Balmora"},"content_file":"Morrowind.esm","display_name":"Player","kind":"npc","record_id":"player","refnum":{"content_file":0,"index":16384}},"title":"Fargoth's Diary","content":"<img src=\"bad\"> & plaintext","content_hash":"3339998ab18d9001ff837834d203010d40aaee03d6ba342377aeef597cee0010"}})DIARY",jsonHeaders));
    CHECK(!lorkhan::parseDiaryBookResponse(R"DIARY({"schema":"lorkhan.diary-book.v1","message_id":"00000000-0000-4000-8000-000000000040","request_id":"00000000-0000-4000-8000-000000000041","session_id":"00000000-0000-4000-8000-000000000007","generation":7,"book":{"delivery_id":"00000000-0000-4000-8000-000000000042","book_id":"00000000-0000-4000-8000-000000000043","target":{"cell":{"kind":"interior","name":"Balmora"},"content_file":"Morrowind.esm","display_name":"Player","kind":"npc","record_id":"player","refnum":{"content_file":0,"index":16384}},"title":"Fargoth's Diary","content":"abc\u007f","content_hash":"1a9ec42a79da6245b586c5419b47d712b65eee7638ec1e1e6001a1a4011a108e"}})DIARY",jsonHeaders));
    CHECK(lorkhan::parseHealthResponse(R"({"schema":"lorkhan.health.v1"})", jsonHeaders));
    CHECK(!lorkhan::parseHealthResponse(R"({"schema":"lorkhan.health.v1","extra":true})", jsonHeaders));
    CHECK(!lorkhan::parseHealthResponse(R"({"schema":"lorkhan.health.v1"})",
        {{"Content-Type", "application/json"}}));

    const std::string error = R"({"schema":"lorkhan.error.v1","code":"rate_limited","message":"not trusted for display","correlation_id":"01900000-0000-7000-8000-000000000001","retriable":true,"retry_after_ms":500})";
    auto parsed = lorkhan::parseProtocolErrorResponse(error, jsonHeaders);
    CHECK(parsed && parsed.value().code == lorkhan::ErrorCode::rate_limited
        && parsed.value().retriable && parsed.value().retryAfterMs == 500);
    CHECK(!lorkhan::parseProtocolErrorResponse(
        R"({"schema":"lorkhan.error.v1","code":"invented","message":"x","correlation_id":"01900000-0000-7000-8000-000000000001","retriable":false})",
        jsonHeaders));
    CHECK(!lorkhan::parseProtocolErrorResponse(
        R"({"schema":"lorkhan.error.v1","code":"unauthorized","message":"x","correlation_id":"bad","retriable":false})",
        jsonHeaders));
    auto expandedCode = lorkhan::parseProtocolErrorResponse(
        R"({"schema":"lorkhan.error.v1","code":"unknown_action","message":"unknown action","correlation_id":"01900000-0000-7000-8000-000000000001","retriable":false})",
        jsonHeaders);
    CHECK(expandedCode && expandedCode.value().code == lorkhan::ErrorCode::invalid_action);
    for (const auto& [code, expected] : std::array{
             std::pair{"action_parameters_invalid", lorkhan::ErrorCode::invalid_action},
             std::pair{"action_target_invalid", lorkhan::ErrorCode::invalid_action},
             std::pair{"action_tier_mismatch", lorkhan::ErrorCode::invalid_action},
             std::pair{"invalid_audio", lorkhan::ErrorCode::media_rejected},
             std::pair{"operation_cancelled", lorkhan::ErrorCode::cancelled},
             std::pair{"rechat_cooldown", lorkhan::ErrorCode::cancelled},
             std::pair{"conversation_cooldown", lorkhan::ErrorCode::cancelled},
             std::pair{"invalid_rechat_context", lorkhan::ErrorCode::invalid_schema}}) {
        const auto response = lorkhan::parseProtocolErrorResponse(
            std::string(R"({"schema":"lorkhan.error.v1","code":")") + code
                + R"(","message":"Request rejected","correlation_id":"01900000-0000-7000-8000-000000000001","retriable":false})", jsonHeaders);
        CHECK(response && response.value().code == expected && response.value().wireCode == code);
    }
    CHECK(!lorkhan::parseProtocolErrorResponse(
        R"({"schema":"lorkhan.error.v1","code":"internal_error","message":"","correlation_id":"01900000-0000-7000-8000-000000000001","retriable":false})",
        jsonHeaders));

    auto redirect = lorkhan::validateHealthHttpResponse(302, "", {});
    CHECK(!redirect && redirect.error().code == lorkhan::ErrorCode::redirect_rejected);
    auto success = lorkhan::validateHealthHttpResponse(
        200, R"({"schema":"lorkhan.health.v1"})", jsonHeaders);
    CHECK(success);
    auto failure = lorkhan::validateHealthHttpResponse(429, error, jsonHeaders);
    CHECK(!failure && failure.error().code == lorkhan::ErrorCode::rate_limited
        && failure.error().retriable && failure.error().retryAfterMs == 500
        && failure.error().message.find("not trusted") == std::string::npos);
}

void testAcceptedProtocolResponses()
{
    const lorkhan::Headers jsonHeaders{{"Content-Type", "application/json; charset=utf-8"}};

    const std::string sessionBody = R"({"schema":"lorkhan.session.accepted.v1","message_id":"01900000-0000-7000-8000-000000000006","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"capabilities":["dialogue.text","speech.say"],"config_revision":"revision-9","client_settings":{"schema":"lorkhan.client-settings.v1","behavior":{"auto_greeting":false,"rechat":false,"rechat_delay_seconds":45,"rechat_max_depth":2,"rechat_probability_percent":50,"rechat_mode":"random","rechat_strict_targeting":false,"open_rechat":true,"rechat_allow_actions":false,"end_conversation_cooldown_seconds":60,"boredom":false,"boredom_delay_seconds":180,"combat_barks":false,"combat_bark_period_seconds":600},"memory":{"recent_turn_limit":20,"knowledge_limit":5},"narrator":{"enabled":false,"name":"The Narrator","context_visibility":true,"inline_mode":"Disabled","welcome_events":false,"welcome_cooldown_minutes":10,"random_events":false,"random_chance_percent":15,"random_cooldown_rounds":2,"bored_events":false,"bored_chance_percent":25,"quest_events":false,"quest_chance_percent":10,"quest_cooldown_minutes":3,"book_events":false},"presentation":{"show_status_hud":true,"transcript_rows":8,"tts_volume_boost":3},"safety":{"actions_enabled":true,"allow_hostile":false,"allow_creatures":false}},"event_cursor":3})";
    auto session = lorkhan::parseSessionAcceptedResponse(sessionBody,jsonHeaders);
    CHECK(session && session.value().clientSettings.behavior.aiEnabled);
    for (const int limit : {0, 200, 201, -1}) {
        auto changed = sessionBody;
        const std::string original = "\"recent_turn_limit\":20";
        changed.replace(changed.find(original), original.size(), "\"recent_turn_limit\":" + std::to_string(limit));
        auto parsed = lorkhan::parseSessionAcceptedResponse(changed, jsonHeaders);
        if (limit == 0 || limit == 200) CHECK(parsed);
        else CHECK(!parsed);
    }
    for(const auto& identity : {std::string(kMessage),std::string("invalid")}) {
        auto changed=sessionBody;changed.insert(1,"\"character_id\":\""+identity+"\",");
        auto parsed=lorkhan::parseSessionAcceptedResponse(changed,jsonHeaders);
        if(identity==kMessage)CHECK(parsed && parsed.value().characterId==identity);
        else CHECK(!parsed);
    }
    for(const auto& identity : {std::string(kMessage),std::string("invalid")}) {
        auto changed=sessionBody;changed.insert(1,"\"profile_id\":\""+identity+"\",");
        auto parsed=lorkhan::parseSessionAcceptedResponse(changed,jsonHeaders);
        if(identity==kMessage)CHECK(parsed && parsed.value().profileId==identity);
        else CHECK(!parsed);
    }
    for(const auto& identity : {std::string(kMessage),std::string("invalid")}) {
        auto changed=sessionBody;changed.insert(1,"\"playthrough_id\":\""+identity+"\",");
        auto parsed=lorkhan::parseSessionAcceptedResponse(changed,jsonHeaders);
        if(identity==kMessage)CHECK(parsed && parsed.value().playthroughId==identity);
        else CHECK(!parsed);
    }
    for (const std::string value : {"true", "false", "0", "null", "\"false\""}) {
        auto changed=sessionBody;changed.insert(changed.find("\"auto_greeting\""),"\"ai_enabled\":"+value+",");
        auto parsed=lorkhan::parseSessionAcceptedResponse(changed,jsonHeaders);
        if(value=="true"||value=="false")CHECK(parsed && parsed.value().clientSettings.behavior.aiEnabled==(value=="true"));
        else CHECK(!parsed);
    }
    CHECK(session && session.value().message == lorkhan::MessageId(kMessage)
        && session.value().session == lorkhan::SessionId(kSession)
        && session.value().generation == lorkhan::Generation(7)
        && session.value().capabilities.size() == 2
        && session.value().configRevision == "revision-9" && session.value().eventCursor == 3
        && session.value().clientSettings.behavior.combatBarkPeriodSeconds == 600
        && session.value().clientSettings.narrator.welcomeCooldownMinutes == 10
        && session.value().clientSettings.narrator.randomChancePercent == 15
        && session.value().clientSettings.narrator.boredChancePercent == 25);
    CHECK(!lorkhan::parseSessionAcceptedResponse(
        R"({"schema":"lorkhan.session.accepted.v1","message_id":"01900000-0000-7000-8000-000000000006","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"capabilities":["dialogue.text","dialogue.text"],"config_revision":"revision-9","client_settings":{"schema":"lorkhan.client-settings.v1","behavior":{"auto_greeting":false,"rechat":false,"rechat_delay_seconds":45,"rechat_max_depth":2,"rechat_probability_percent":50,"rechat_mode":"random","rechat_strict_targeting":false,"open_rechat":true,"rechat_allow_actions":false,"end_conversation_cooldown_seconds":60,"boredom":false,"boredom_delay_seconds":180,"combat_barks":false,"combat_bark_period_seconds":20},"memory":{"recent_turn_limit":20,"knowledge_limit":5},"narrator":{"enabled":false,"name":"The Narrator","context_visibility":true,"inline_mode":"Disabled","welcome_events":false,"welcome_cooldown_minutes":10,"random_events":false,"random_chance_percent":15,"random_cooldown_rounds":2,"bored_events":false,"bored_chance_percent":25,"quest_events":false,"quest_chance_percent":10,"quest_cooldown_minutes":3,"book_events":false},"presentation":{"show_status_hud":true,"transcript_rows":8,"tts_volume_boost":3},"safety":{"actions_enabled":true,"allow_hostile":false,"allow_creatures":false}},"event_cursor":3})",
        jsonHeaders));
    CHECK(!lorkhan::parseSessionAcceptedResponse(
        R"({"schema":"lorkhan.session.accepted.v1","message_id":"01900000-0000-7000-8000-000000000006","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"capabilities":[],"config_revision":"revision-9","client_settings":{"schema":"lorkhan.client-settings.v1","behavior":{"auto_greeting":false,"rechat":false,"rechat_delay_seconds":45,"rechat_max_depth":2,"rechat_probability_percent":50,"rechat_mode":"random","rechat_strict_targeting":false,"open_rechat":true,"rechat_allow_actions":false,"end_conversation_cooldown_seconds":60,"boredom":false,"boredom_delay_seconds":180,"combat_barks":false,"combat_bark_period_seconds":20},"memory":{"recent_turn_limit":20,"knowledge_limit":5},"narrator":{"enabled":false,"name":"The Narrator","context_visibility":true,"inline_mode":"Disabled","welcome_events":false,"welcome_cooldown_minutes":10,"random_events":false,"random_chance_percent":15,"random_cooldown_rounds":2,"bored_events":false,"bored_chance_percent":25,"quest_events":false,"quest_chance_percent":10,"quest_cooldown_minutes":3,"book_events":false},"presentation":{"show_status_hud":true,"transcript_rows":8,"tts_volume_boost":3},"safety":{"actions_enabled":true,"allow_hostile":false,"allow_creatures":false}},"event_cursor":3,"extra":true})",
        jsonHeaders));

    auto turn = lorkhan::parseTurnAcceptedResponse(
        R"({"schema":"lorkhan.turn.accepted.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"event_cursor":4})",
        jsonHeaders);
    CHECK(turn && turn.value().correlation.message == lorkhan::MessageId(kMessage)
        && turn.value().correlation.request == lorkhan::RequestId(kInstallation)
        && turn.value().correlation.turn == lorkhan::TurnId(kTurn)
        && turn.value().correlation.session == lorkhan::SessionId(kSession)
        && turn.value().correlation.generation == lorkhan::Generation(7)
        && turn.value().eventCursor == 4);
    CHECK(!lorkhan::parseTurnAcceptedResponse(
        R"({"schema":"lorkhan.turn.accepted.v1","message_id":"BAD","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"event_cursor":4})",
        jsonHeaders));

    auto interruption = lorkhan::parseInterruptionAcceptedResponse(
        R"({"schema":"lorkhan.interruption.accepted.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"event_cursor":6,"duplicate":true})",
        jsonHeaders);
    CHECK(interruption && interruption.value().duplicate && interruption.value().eventCursor == 6
        && interruption.value().correlation.turn == lorkhan::TurnId(kTurn));
    CHECK(!lorkhan::parseInterruptionAcceptedResponse(
        R"({"schema":"lorkhan.interruption.accepted.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"event_cursor":6,"duplicate":"true"})",
        jsonHeaders));

    auto action = lorkhan::parseActionResultAcceptedResponse(
        R"({"schema":"lorkhan.action-result.accepted.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","action_id":"01900000-0000-7000-8000-000000000007","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"status":"succeeded","duplicate":false})",
        jsonHeaders);
    CHECK(action && action.value().action == lorkhan::ActionId(kAction)
        && action.value().status == lorkhan::ActionTerminalStatus::succeeded
        && !action.value().duplicate && action.value().correlation.session == lorkhan::SessionId(kSession));
    CHECK(!lorkhan::parseActionResultAcceptedResponse(
        R"({"schema":"lorkhan.action-result.accepted.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","action_id":"01900000-0000-7000-8000-000000000007","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"status":"pending","duplicate":false})",
        jsonHeaders));

    auto ended = lorkhan::parseSessionEndedResponse(
        R"({"schema":"lorkhan.session.ended.v1","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"ended":true})",
        jsonHeaders);
    CHECK(ended && ended.value().request == lorkhan::RequestId(kInstallation)
        && ended.value().session == lorkhan::SessionId(kSession)
        && ended.value().generation == lorkhan::Generation(7) && ended.value().ended);
    CHECK(!lorkhan::parseSessionEndedResponse(
        R"({"schema":"lorkhan.session.ended.v1","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":-1,"ended":true})",
        jsonHeaders));

    auto gameData = lorkhan::parseGameDataAcceptedResponse(
        R"({"schema":"lorkhan.gamedata.accepted.v1","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"type":"captured_dialogue","duplicate":false})",
        jsonHeaders);
    CHECK(gameData && gameData.value().request == lorkhan::RequestId(kInstallation)
        && gameData.value().session == lorkhan::SessionId(kSession)
        && gameData.value().generation == lorkhan::Generation(7)
        && gameData.value().type == "captured_dialogue" && !gameData.value().duplicate);
    auto actorProfile = lorkhan::parseGameDataAcceptedResponse(
        R"({"schema":"lorkhan.gamedata.accepted.v1","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"type":"actor_profile","duplicate":false})",
        jsonHeaders);
    CHECK(actorProfile && actorProfile.value().type == "actor_profile");
    auto pickupPlayer = protocolIdentity(); pickupPlayer.replace(pickupPlayer.find("npc"), 3, "player");
    const std::string pickupPrefix = "{\"player\":" + pickupPlayer + R"(,"item_record_id":"gold_001","item_name":"Gold","count":500,"unit_value":1,"game_time":100,"source_kind":"world")";
    CHECK(lorkhan::validateItemPickupPayload(pickupPrefix + "}"));
    CHECK(lorkhan::validateItemPickupPayload(pickupPrefix + R"(,"source":{"record_id":"chest","display_name":"Chest"}})"));
    CHECK(!lorkhan::validateItemPickupPayload(pickupPrefix + R"(,"source":{"record_id":"chest","display_name":"Chest","actor":true}})"));
    auto badPickup = pickupPrefix; badPickup.replace(badPickup.find(":500"), 4, ":0");
    CHECK(!lorkhan::validateItemPickupPayload(badPickup + "}"));
    auto badKindPickup = pickupPrefix; badKindPickup.replace(badKindPickup.find("world"), 5, "barter");
    CHECK(!lorkhan::validateItemPickupPayload(badKindPickup + "}"));
    CHECK(!lorkhan::validateItemPickupPayload(pickupPrefix + R"(,"code":"additem"})"));
    CHECK(lorkhan::validateItemPickupPayload(pickupPrefix + ",\"audience\":[" + protocolIdentity() + "]}"));
    CHECK(!lorkhan::validateItemPickupPayload(pickupPrefix + ",\"audience\":[" + protocolIdentity() + "," + protocolIdentity() + "]}"));
    const std::string barterLine = R"({"item_record_id":"common_shirt_01","item_name":"Common Shirt","count":2,"unit_value":5})";
    const std::string barterPrefix = "{\"player\":" + pickupPlayer + ",\"merchant\":" + protocolIdentity();
    const auto barter = [&](const std::string& received, const std::string& gave, const std::string& rest) {
        return barterPrefix + ",\"player_received\":[" + received + "],\"player_gave\":[" + gave + "]" + rest + "}";
    };
    CHECK(lorkhan::validateBarterTradePayload(barter(barterLine, "", R"(,"gold_to_player":-150,"game_time":100)")));
    CHECK(lorkhan::validateBarterTradePayload(barter("", barterLine, R"(,"gold_to_player":150,"game_time":100,"calendar":{"year":427,"month":8,"day":16,"hour":12.5})")));
    CHECK(!lorkhan::validateBarterTradePayload(barter("", "", R"(,"gold_to_player":150,"game_time":100)")));
    CHECK(!lorkhan::validateBarterTradePayload(barter(barterLine, "", R"(,"gold_to_player":1.5,"game_time":100)")));
    CHECK(!lorkhan::validateBarterTradePayload(barter(barterLine, "", R"(,"gold_to_player":-2147483648,"game_time":100)")));
    CHECK(!lorkhan::validateBarterTradePayload(barter(barterLine, "", R"(,"gold_to_player":0,"game_time":100,"code":"additem")")));
    auto zeroBarterLine = barterLine; zeroBarterLine.replace(zeroBarterLine.find("\"count\":2"), 9, "\"count\":0");
    CHECK(!lorkhan::validateBarterTradePayload(barter(zeroBarterLine, "", R"(,"gold_to_player":0,"game_time":100)")));
    auto pricedBarterLine = barterLine; pricedBarterLine.insert(pricedBarterLine.size() - 1, R"(,"price":3)");
    CHECK(!lorkhan::validateBarterTradePayload(barter(pricedBarterLine, "", R"(,"gold_to_player":0,"game_time":100)")));
    std::string manyBarterLines = barterLine;
    for (int index = 1; index < 33; ++index) manyBarterLines += "," + barterLine;
    CHECK(!lorkhan::validateBarterTradePayload(barter(manyBarterLines, "", R"(,"gold_to_player":0,"game_time":100)")));
    auto playerMerchant = barter(barterLine, "", R"(,"gold_to_player":0,"game_time":100)");
    playerMerchant.replace(playerMerchant.find("\"merchant\":") + 11, protocolIdentity().size(), pickupPlayer);
    CHECK(!lorkhan::validateBarterTradePayload(playerMerchant));
    CHECK(!lorkhan::validateBarterTradePayload(barter(barterLine, "", R"(,"gold_to_player":0,"game_time":100,"audience":[)" + protocolIdentity() + "," + protocolIdentity() + "]")));
    auto barterAccepted = lorkhan::parseGameDataAcceptedResponse(
        R"({"schema":"lorkhan.gamedata.accepted.v1","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"type":"barter_trade","duplicate":false})",
        jsonHeaders);
    CHECK(barterAccepted && barterAccepted.value().type == "barter_trade");
    const std::string castPrefix = "{\"caster\":" + protocolIdentity() + R"(,"spell_id":"firebite","spell_name":"Firebite","game_time":100)";
    CHECK(lorkhan::validateSpellCastPayload(castPrefix + "}"));
    const auto resurrection=std::string("{\"actor\":")+protocolIdentity()+",\"audience\":[],\"game_time\":1}";
    CHECK(lorkhan::validateActorResurrectedPayload(resurrection));
    auto invalidResurrection=resurrection;invalidResurrection.insert(1,"\"command\":\"resurrect\",");
    CHECK(!lorkhan::validateActorResurrectedPayload(invalidResurrection));
    CHECK(!lorkhan::validateActorResurrectedPayload("{\"actor\":{},\"audience\":[],\"game_time\":1}"));
    auto witness = protocolIdentity(); witness.replace(witness.find("\"index\":112"), 11, "\"index\":113");
    const auto death = std::string("{\"victim\":") + protocolIdentity() + ",\"audience\":[" + witness + "],\"game_time\":1";
    CHECK(lorkhan::validateActorDiedPayload(death + "}"));
    CHECK(lorkhan::validateActorDiedPayload(death + R"(,"calendar":{"year":427,"month":8,"day":16,"hour":12.5}})"));
    CHECK(!lorkhan::validateActorDiedPayload(death + R"(,"killer":)" + witness + "}"));
    CHECK(!lorkhan::validateActorDiedPayload(death + R"(,"weapon":"iron dagger"})"));
    CHECK(!lorkhan::validateActorDiedPayload(resurrection));
    CHECK(!lorkhan::validateActorResurrectedPayload(death + "}"));
    CHECK(!lorkhan::validateActorDiedPayload("{\"victim\":" + pickupPlayer + ",\"audience\":[],\"game_time\":1}"));
    CHECK(!lorkhan::validateActorDiedPayload("{\"victim\":" + protocolIdentity() + ",\"audience\":[" + protocolIdentity() + "],\"game_time\":1}"));
    CHECK(!lorkhan::validateActorDiedPayload("{\"victim\":" + protocolIdentity() + ",\"audience\":[],\"game_time\":-1}"));
    CHECK(!lorkhan::validateActorDiedPayload(death + R"(,"calendar":{"year":427,"month":12,"day":16,"hour":12}})"));
    auto deathAccepted = lorkhan::parseGameDataAcceptedResponse(
        R"({"schema":"lorkhan.gamedata.accepted.v1","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"type":"actor_died","duplicate":false})",
        jsonHeaders);
    CHECK(deathAccepted && deathAccepted.value().type == "actor_died");
    static_assert(lorkhan::countsActorDeath(false, false) && lorkhan::countsActorDeath(false, true));
    static_assert(!lorkhan::countsActorDeath(true, false), "placed corpses replay a death on cell load");
    static_assert(lorkhan::countsActorDeath(true, true), "persistent corpses die again only after resurrection");

    CHECK(lorkhan::validateSpellCastPayload(castPrefix + R"(,"calendar":{"year":427,"month":8,"day":16,"hour":12.5}})"));
    CHECK(lorkhan::validateItemPickupPayload(pickupPrefix + R"(,"calendar":{"year":427,"month":8,"day":16,"hour":12.5}})"));
    CHECK(!lorkhan::validateSpellCastPayload(castPrefix + R"(,"calendar":{"year":427,"month":12,"day":16,"hour":12}})"));
    CHECK(!lorkhan::validateItemPickupPayload(pickupPrefix + R"(,"calendar":{"year":427,"month":12,"day":16,"hour":12}})"));
    CHECK(!lorkhan::validateSpellCastPayload(castPrefix + R"(,"calendar":{"year":427,"month":1,"day":30,"hour":12}})"));
    CHECK(!lorkhan::validateItemPickupPayload(pickupPrefix + R"(,"calendar":{"year":427,"month":1,"day":30,"hour":12}})"));
    CHECK(!lorkhan::validateSpellCastPayload(castPrefix + R"(,"calendar":{"year":427,"month":1,"day":3}})"));
    CHECK(!lorkhan::validateItemPickupPayload(pickupPrefix + R"(,"calendar":{"year":427,"month":1,"day":3}})"));
    // RPG/quest observations predate calendars, so an omitted date stays valid; a present one must be real.
    const std::string rpgPrefix = "{\"kind\":\"levelup\",\"player\":" + pickupPlayer + R"(,"game_time":100,"text":"The player reached level 2.")";
    CHECK(lorkhan::validateObservationCalendarPayload(rpgPrefix + "}"));
    CHECK(lorkhan::validateObservationCalendarPayload(rpgPrefix + R"(,"calendar":{"year":427,"month":7,"day":15,"hour":11.999}})"));
    CHECK(!lorkhan::validateObservationCalendarPayload(rpgPrefix + R"(,"calendar":{"year":427,"month":1,"day":29,"hour":12}})"));
    CHECK(!lorkhan::validateObservationCalendarPayload(rpgPrefix + R"(,"calendar":{"year":427,"month":7,"day":15,"hour":24}})"));
    CHECK(!lorkhan::validateObservationCalendarPayload(rpgPrefix + R"(,"calendar":{"year":427,"month":7,"day":15}})"));
    CHECK(!lorkhan::validateObservationCalendarPayload(rpgPrefix + R"(,"calendar":{"year":427,"month":7,"day":15,"hour":12,"days_passed":3}})"));
    CHECK(!lorkhan::validateObservationCalendarPayload(rpgPrefix + R"(,"calendar":"427-08-15"})"));
    CHECK(!lorkhan::validateObservationCalendarPayload("[]"));

    CHECK(lorkhan::validateSpellCastPayload(castPrefix + ",\"audience\":[" + protocolIdentity() + "]}"));
    CHECK(!lorkhan::validateSpellCastPayload(castPrefix + ",\"audience\":[" + protocolIdentity() + "," + protocolIdentity() + "]}"));
    CHECK(!lorkhan::validateSpellCastPayload(castPrefix + R"(,"audience":[{}]})"));

    CHECK(lorkhan::validateSpellCastPayload(castPrefix + ",\"target\":" + protocolIdentity() + "}"));
    CHECK(!lorkhan::validateSpellCastPayload(castPrefix + R"(,"code":"cast firebite"})"));
    CHECK(!lorkhan::validateSpellCastPayload(castPrefix + R"(,"target":{})"));
    std::string castAudience;
    for (int index = 0; index < 13; ++index) {
        auto actor = protocolIdentity(); actor.replace(actor.find("112"), 3, std::to_string(200 + index));
        castAudience += (index ? "," : "") + actor;
        if (index == 11) CHECK(lorkhan::validateSpellCastPayload(castPrefix + ",\"audience\":[" + castAudience + "]}"));
    }
    CHECK(!lorkhan::validateSpellCastPayload(castPrefix + ",\"audience\":[" + castAudience + "]}"));
    auto negativeCast = castPrefix; negativeCast.replace(negativeCast.find(":100"), 4, ":-1");
    CHECK(!lorkhan::validateSpellCastPayload(negativeCast + "}"));
    auto narratorCast = castPrefix; narratorCast.replace(narratorCast.find("npc"), 3, "narrator");
    CHECK(!lorkhan::validateSpellCastPayload(narratorCast + "}"));
    auto longCast = castPrefix; longCast.replace(longCast.find("Firebite"), 8, std::string(257, 'x'));
    CHECK(!lorkhan::validateSpellCastPayload(longCast + "}"));
    auto inventoryAccepted = lorkhan::parseGameDataAcceptedResponse(
        R"({"schema":"lorkhan.gamedata.accepted.v1","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"type":"inventory","duplicate":false})",
        jsonHeaders);
    CHECK(inventoryAccepted && inventoryAccepted.value().type == "inventory");
    const std::string inventoryPrefix = R"({"owner":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"items":[)";
    const std::string dispositionActor = R"({"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"})";
    auto dispositionPlayer = dispositionActor;
    dispositionPlayer.replace(dispositionPlayer.find("npc"), 3, "player");
    const std::string dispositionPrefix = "{\"actor\":" + dispositionActor + ",\"player\":" + dispositionPlayer;
    CHECK(lorkhan::validateDispositionPayload(dispositionPrefix + R"(,"base_disposition":-10,"disposition":0,"dialogue_open":false})"));
    CHECK(!lorkhan::validateDispositionPayload(dispositionPrefix + R"(,"base_disposition":50,"disposition":101,"dialogue_open":false})"));
    CHECK(!lorkhan::validateDispositionPayload(dispositionPrefix + R"(,"base_disposition":50,"disposition":50,"dialogue_open":false,"status":"applied"})"));
    CHECK(lorkhan::validateDispositionPayload(dispositionPrefix + R"(,"base_disposition":50,"disposition":50,"dialogue_open":false,"adjustment_id":"01900000-0000-7000-8000-000000000001","status":"applied"})"));
    const std::string adjustmentEvents = R"({"schema":"lorkhan.events.v1","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"next_after":1,"events":[{"message_id":"01900000-0000-7000-8000-00000000000f","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-18T20:00:07Z","type":"relationship.adjust","payload":{"adjustment_id":"01900000-0000-7000-8000-000000000001","actor":)" + dispositionActor + ",\"player\":" + dispositionPlayer + R"(,"delta":2,"expires_at":"2026-07-18T20:02:07Z"}}],"autonomy":[]})";
    auto adjustment = lorkhan::parseEventsResponse(adjustmentEvents, jsonHeaders);
    CHECK(adjustment && adjustment.value().events[0].type == lorkhan::ProtocolEventType::relationship_adjust);
    auto excessiveAdjustment = adjustmentEvents;
    excessiveAdjustment.replace(excessiveAdjustment.find("\"delta\":2"), 9, "\"delta\":4");
    CHECK(!lorkhan::parseEventsResponse(excessiveAdjustment, jsonHeaders));
    const std::string inventoryItem = R"({"record_id":"gold_001","name":"Gold","count":3,"value":1,"equipped":false})";
    CHECK(lorkhan::validateInventoryPayload(inventoryPrefix + "]}"));
    auto creatureInventory = inventoryPrefix;
    creatureInventory.replace(creatureInventory.find("npc"), 3, "creature");
    CHECK(lorkhan::validateInventoryPayload(creatureInventory + "]}"));
    auto narratorInventory = inventoryPrefix;
    narratorInventory.replace(narratorInventory.find("npc"), 3, "narrator");
    CHECK(!lorkhan::validateInventoryPayload(narratorInventory + "]}"));
    CHECK(lorkhan::validateInventoryPayload(inventoryPrefix + inventoryItem + "]}"));
    CHECK(lorkhan::validateInventoryPayload(inventoryPrefix + R"({"record_id":"iron_dagger","name":"Iron dagger","count":1,"value":10,"equipped":true,"condition":0.5,"content_file":"Morrowind.esm"}]})"));
    CHECK(!lorkhan::validateInventoryPayload(inventoryPrefix + R"({"record_id":"gold_001","name":"Gold","count":0,"value":1,"equipped":false}]})"));
    CHECK(!lorkhan::validateInventoryPayload(inventoryPrefix + R"({"record_id":"gold_001","name":"Gold","count":1,"value":1,"equipped":false,"condition":2}]})"));
    CHECK(!lorkhan::validateInventoryPayload(inventoryPrefix + R"({"record_id":"gold_001","name":"Gold","count":1,"value":1,"equipped":false,"url":"http://localhost"}]})"));
    std::string inventoryMaximum = inventoryPrefix;
    for (int item = 0; item < 512; ++item) inventoryMaximum += (item ? "," : "") + inventoryItem;
    CHECK(lorkhan::validateInventoryPayload(inventoryMaximum + "]}"));
    CHECK(!lorkhan::validateInventoryPayload(inventoryMaximum + "," + inventoryItem + "]}"));
    auto rpgEvent = lorkhan::parseGameDataAcceptedResponse(
        R"({"schema":"lorkhan.gamedata.accepted.v1","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"type":"rpg_event","duplicate":false,"comment_requested":true})",
        jsonHeaders);
    CHECK(rpgEvent && rpgEvent.value().commentRequested && !rpgEvent.value().duplicate);
    auto boredEvent = lorkhan::parseGameDataAcceptedResponse(
        R"({"schema":"lorkhan.gamedata.accepted.v1","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"type":"bored_event","duplicate":false,"comment_requested":false})",
        jsonHeaders);
    CHECK(boredEvent && boredEvent.value().type == "bored_event" && !boredEvent.value().commentRequested);
    auto questEvent = lorkhan::parseGameDataAcceptedResponse(
        R"({"schema":"lorkhan.gamedata.accepted.v1","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"type":"quest_event","duplicate":false,"comment_requested":true})",
        jsonHeaders);
    CHECK(questEvent && questEvent.value().type == "quest_event" && questEvent.value().commentRequested);


    CHECK(!lorkhan::parseGameDataAcceptedResponse(
        R"({"schema":"lorkhan.gamedata.accepted.v1","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"type":"journal","duplicate":false})",
        jsonHeaders));

    const std::string controlsJson =
        R"({"schema":"lorkhan.controls.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"target":{"kind":"npc","record_id":"fargoth","refnum":{"index":42,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"interior","name":"Seyda Neen, Census and Excise Office"},"display_name":"Fargoth"},"selected_model_slot_key":"standard","resolved_model_slot_key":"standard","selected_profile_id":null,"narrator_profile_id":"10000000-0000-4000-8000-000000000408","effective_settings":{"schema":"lorkhan.effective-settings.v1","change_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","profile_id":null,"profile_revision":null,"core_profile_id":"10000000-0000-4000-8000-000000000409","core_profile_revision":1,"settings":{"behavior":{"auto_greeting":false,"rechat":false,"rechat_delay_seconds":45,"rechat_max_depth":2,"rechat_probability_percent":50,"rechat_mode":"random","rechat_strict_targeting":false,"open_rechat":true,"rechat_allow_actions":false,"end_conversation_cooldown_seconds":60,"boredom":false,"boredom_delay_seconds":180,"combat_barks":false,"combat_bark_period_seconds":600},"memory":{"recent_turn_limit":20,"knowledge_limit":5},"narrator":{"enabled":false,"name":"The Narrator","context_visibility":true,"inline_mode":"Disabled","welcome_events":false,"welcome_cooldown_minutes":10,"random_events":false,"random_chance_percent":15,"random_cooldown_rounds":2,"bored_events":false,"bored_chance_percent":25,"quest_events":false,"quest_chance_percent":10,"quest_cooldown_minutes":3,"book_events":false},"presentation":{"show_status_hud":true,"transcript_rows":8,"tts_volume_boost":3},"safety":{"actions_enabled":true,"allow_hostile":false,"allow_creatures":false}},"routing":{"llm_configuration_id":"10000000-0000-4000-8000-000000000406"},"source_map":{"settings.memory.recent_turn_limit":"global","settings.memory.knowledge_limit":"global","settings.narrator.enabled":"global","settings.narrator.name":"global","settings.narrator.context_visibility":"global","settings.narrator.inline_mode":"global","settings.narrator.welcome_events":"narrator_profile","settings.narrator.random_events":"global","settings.narrator.quest_events":"global","settings.narrator.book_events":"global","settings.safety.actions_enabled":"global","settings.safety.allow_hostile":"global","settings.safety.allow_creatures":"global","routing.llm_configuration_id":"core_profile"}},"model_slots":[{"key":"standard","label":"Standard","available":true,"configuration_id":"10000000-0000-4000-8000-000000000406","configuration_name":"Dialogue","revision":1,"driver":"configured","model":"gpt-5-mini"},{"key":"fast","label":"Fast","available":false,"configuration_id":null,"configuration_name":null,"revision":null,"driver":null,"model":null},{"key":"powerful","label":"Powerful","available":false,"configuration_id":null,"configuration_name":null,"revision":null,"driver":null,"model":null},{"key":"experimental","label":"Experimental","available":false,"configuration_id":null,"configuration_name":null,"revision":null,"driver":null,"model":null}],"profiles":[{"profile_id":"10000000-0000-4000-8000-000000000407","name":"Fargoth","revision":2}]})";
    // Exercise actual response parsing, not only the standalone key validator.
    const auto npcProfile=std::string("ref:")+kInstallation+":"+kPlaythrough+":morrowind.esm|42";
    auto scopedControls=controlsJson;
    const std::string oldNpc="10000000-0000-4000-8000-000000000407";
    scopedControls.replace(scopedControls.find(oldNpc),oldNpc.size(),npcProfile);
    const std::string selected="\"selected_profile_id\":null";
    scopedControls.replace(scopedControls.find(selected),selected.size(),"\"selected_profile_id\":\""+npcProfile+"\"");
    const std::string effective="\"profile_id\":null,\"profile_revision\":null";
    scopedControls.replace(scopedControls.find(effective),effective.size(),"\"profile_id\":\""+npcProfile+"\",\"profile_revision\":2");
    auto scoped=lorkhan::parseControlsResponse(scopedControls,jsonHeaders);
    CHECK(scoped && scoped.value().selectedProfileId==npcProfile && scoped.value().effectiveSettings.profileId==npcProfile);
    const std::string core="10000000-0000-4000-8000-000000000409";
    scopedControls.replace(scopedControls.find(core),core.size(),npcProfile);
    CHECK(!lorkhan::parseControlsResponse(scopedControls,jsonHeaders));
    auto controls = lorkhan::parseControlsResponse(controlsJson, jsonHeaders);
    CHECK(controls && controls.value().effectiveSettings.behavior.aiEnabled);
    for (const std::string value : {"false", "null", "1"}) {
        auto changed=controlsJson;changed.insert(changed.find("\"auto_greeting\""),"\"ai_enabled\":"+value+",");
        auto parsed=lorkhan::parseControlsResponse(changed,jsonHeaders);
        if(value=="false")CHECK(parsed && !parsed.value().effectiveSettings.behavior.aiEnabled);
        else CHECK(!parsed);
    }
    auto invalidCombatCooldown = controlsJson;
    const std::string cooldownField = "\"combat_bark_period_seconds\":600";
    invalidCombatCooldown.replace(invalidCombatCooldown.find(cooldownField), cooldownField.size(), "\"combat_bark_period_seconds\":601");
    CHECK(!lorkhan::parseControlsResponse(invalidCombatCooldown, jsonHeaders));
    CHECK(controls && controls.value().request == lorkhan::RequestId(kInstallation)
        && controls.value().session == lorkhan::SessionId(kSession)
        && controls.value().generation == lorkhan::Generation(7)
        && controls.value().target.recordId == "fargoth"
        && controls.value().selectedModelSlotKey == "standard"
        && controls.value().resolvedModelSlotKey && *controls.value().resolvedModelSlotKey == "standard"
        && !controls.value().selectedProfileId
        && controls.value().narratorProfileId
        && *controls.value().narratorProfileId == "10000000-0000-4000-8000-000000000408"
        && controls.value().effectiveSettings.changeToken == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        && controls.value().effectiveSettings.coreProfileRevision == 1
        && controls.value().effectiveSettings.safety.actionsEnabled
        && !controls.value().effectiveSettings.behavior.rechat
        && controls.value().effectiveSettings.behavior.combatBarkPeriodSeconds == 600
        && controls.value().effectiveSettings.behavior.rechatMaxDepth == 2
        && controls.value().effectiveSettings.behavior.rechatProbabilityPercent == 50
        && controls.value().effectiveSettings.behavior.openRechat
        && controls.value().effectiveSettings.behavior.endConversationCooldownSeconds == 60
        && controls.value().modelSlots.size() == 4 && controls.value().profiles.size() == 1
        && controls.value().modelSlots[0].key == "standard" && controls.value().modelSlots[0].available
        && controls.value().modelSlots[0].model && *controls.value().modelSlots[0].model == "gpt-5-mini"
        && !controls.value().modelSlots[1].available && controls.value().profiles[0].revision == 2);
    CHECK(!lorkhan::parseControlsResponse(
        R"({"schema":"lorkhan.controls.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"target":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"selected_model_slot_id":"01900000-0000-7000-8000-000000000099","selected_profile_id":null,"narrator_profile_id":null,"effective_settings":{"schema":"lorkhan.effective-settings.v1","change_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","profile_id":null,"profile_revision":null,"core_profile_id":"01900000-0000-7000-8000-000000000014","core_profile_revision":1,"settings":{"memory":{"recent_turn_limit":20,"knowledge_limit":5},"narrator":{"enabled":false,"name":"The Narrator","context_visibility":true,"inline_mode":"Disabled","welcome_events":false,"welcome_cooldown_minutes":10,"random_events":false,"random_chance_percent":15,"random_cooldown_rounds":2,"bored_events":false,"bored_chance_percent":25,"quest_events":false,"quest_chance_percent":10,"quest_cooldown_minutes":3,"book_events":false},"safety":{"actions_enabled":true,"allow_hostile":false,"allow_creatures":false}},"routing":{},"source_map":{}},"model_slots":[],"profiles":[]})",
        jsonHeaders));

    auto debugCommand = lorkhan::parseDebugCommandResponse(
        R"({"schema":"lorkhan.debug-command.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"command":{"command_id":"01900000-0000-7000-8000-000000000007","name":"god_mode.set","parameters":{"enabled":true},"expires_at":"2026-08-31T12:00:30Z"}})",
        jsonHeaders);
    CHECK(debugCommand && debugCommand.value().command
        && debugCommand.value().command->name == "god_mode.set"
        && std::get<bool>(debugCommand.value().command->parameters.at("enabled")) == true);
    const std::string browserSpeech=R"({"schema":"lorkhan.debug-command.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"command":{"command_id":"01900000-0000-7000-8000-000000000007","name":"player.dialogue.submit","parameters":{"text":"Where is Caius? *curious* / ordinary text","language":"en-US"},"expires_at":"2026-08-31T12:00:30Z"}})";
    auto speechCommand=lorkhan::parseDebugCommandResponse(browserSpeech,jsonHeaders);
    CHECK(speechCommand&&speechCommand.value().command&&std::get<std::string>(speechCommand.value().command->parameters.at("text"))=="Where is Caius? *curious* / ordinary text");
    for(const auto& invalid:std::array<std::string,3>{"en-","e-US","EN-us"}){
        auto changed=browserSpeech;changed.replace(changed.find("en-US"),5,invalid);
        CHECK(!lorkhan::parseDebugCommandResponse(changed,jsonHeaders));
    }
    const std::string npcCommandPrefix = R"({"schema":"lorkhan.debug-command.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"command":{"command_id":"01900000-0000-7000-8000-000000000007","name":")";
    const std::string npcCommandSuffix = R"(},"expires_at":"2026-08-31T12:00:30Z"}})";
    const std::string npcActor = R"({"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"})";
    for (const std::string name : {"npc.status", "npc.visit", "npc.teleport", "npc.return"}) {
        const auto prefix = npcCommandPrefix + name + R"(","parameters":{"actor":)";
        auto manager = lorkhan::parseDebugCommandResponse(prefix + npcActor + npcCommandSuffix, jsonHeaders);
        CHECK(manager && manager.value().command
            && std::get<lorkhan::ProtocolIdentity>(manager.value().command->parameters.at("actor")).refnumIndex == 112);
        auto creature = npcActor; creature.replace(creature.find("npc"), 3, "creature");
        CHECK(lorkhan::parseDebugCommandResponse(prefix + creature + npcCommandSuffix, jsonHeaders));
        for (const std::string kind : {"player", "narrator"}) {
            auto invalid = npcActor; invalid.replace(invalid.find("npc"), 3, kind);
            CHECK(!lorkhan::parseDebugCommandResponse(prefix + invalid + npcCommandSuffix, jsonHeaders));
        }
        CHECK(!lorkhan::parseDebugCommandResponse(prefix + "{}" + npcCommandSuffix, jsonHeaders));
        CHECK(!lorkhan::parseDebugCommandResponse(prefix + npcActor + R"(,"x":42)" + npcCommandSuffix, jsonHeaders));
        CHECK(!lorkhan::parseDebugCommandResponse(prefix + npcActor + R"(,"code":"tgm")" + npcCommandSuffix, jsonHeaders));
    }
    auto inventoryDebugCommand = lorkhan::parseDebugCommandResponse(
        R"({"schema":"lorkhan.debug-command.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"command":{"command_id":"01900000-0000-7000-8000-000000000007","name":"player.inventory.add","parameters":{"record_id":"fur_colovian_helm","count":1},"expires_at":"2026-08-31T12:00:30Z"}})",
        jsonHeaders);
    CHECK(inventoryDebugCommand && inventoryDebugCommand.value().command
        && std::get<std::string>(inventoryDebugCommand.value().command->parameters.at("record_id")) == "fur_colovian_helm"
        && std::get<std::int64_t>(inventoryDebugCommand.value().command->parameters.at("count")) == 1);
    CHECK(!lorkhan::parseDebugCommandResponse(
        R"({"schema":"lorkhan.debug-command.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"command":{"command_id":"01900000-0000-7000-8000-000000000007","name":"console.execute","parameters":{"text":"tgm"},"expires_at":"2026-08-31T12:00:30Z"}})",
        jsonHeaders));
    auto debugAccepted = lorkhan::parseDebugCommandResultAcceptedResponse(
        R"({"schema":"lorkhan.debug-command-result.accepted.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","command_id":"01900000-0000-7000-8000-000000000007","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"status":"succeeded","duplicate":false})",
        jsonHeaders);
    CHECK(debugAccepted && debugAccepted.value().status == lorkhan::DebugCommandResultStatus::succeeded
        && !debugAccepted.value().duplicate);

    auto menuDialogue = lorkhan::parseMenuDialogueTtsReadyResponse(
        R"({"schema":"lorkhan.menu-dialogue-tts.ready.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"actor":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"media":{"media_id":"01900000-0000-7000-8000-000000000013","dialogue_message_id":"01900000-0000-7000-8000-000000000006","sha256":"e12e115acf4552b2568b55e93cbd39394c4ef81c82447faed7738adf06e9ba61","bytes":4,"codec":"ogg","duration_ms":100,"expires_at":"2026-07-18T21:00:00Z"}})",
        jsonHeaders);
    CHECK(menuDialogue && menuDialogue.value().message == lorkhan::MessageId(kMessage)
        && menuDialogue.value().request == lorkhan::RequestId(kInstallation)
        && menuDialogue.value().actor.recordId == "fargoth"
        && menuDialogue.value().media.dialogueMessage == lorkhan::MessageId(kMessage));
    CHECK(!lorkhan::parseMenuDialogueTtsReadyResponse(
        R"({"schema":"lorkhan.menu-dialogue-tts.ready.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"actor":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"media":{"media_id":"01900000-0000-7000-8000-000000000013","dialogue_message_id":"01900000-0000-7000-8000-000000000006","sha256":"e12e115acf4552b2568b55e93cbd39394c4ef81c82447faed7738adf06e9ba61","bytes":4,"codec":"ogg","duration_ms":100,"expires_at":"2026-07-18T21:00:00Z"},"extra":true})",
        jsonHeaders));

    const std::string menuCancel = R"({"schema":"lorkhan.menu-dialogue-tts.cancel.accepted.v1","message_id":"01900000-0000-7000-8000-000000000011","request_id":"01900000-0000-7000-8000-000000000012","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"target_message_id":"01900000-0000-7000-8000-000000000006","status":"cancelled"})";
    auto cancelAccepted = lorkhan::parseMenuDialogueTtsCancelAcceptedResponse(menuCancel, jsonHeaders);
    CHECK(cancelAccepted && cancelAccepted.value().target == lorkhan::MessageId(kMessage)
        && cancelAccepted.value().session == lorkhan::SessionId(kSession) && cancelAccepted.value().generation == lorkhan::Generation(7)
        && cancelAccepted.value().status == lorkhan::MenuDialogueTtsCancelStatus::cancelled);
    auto cancelCompleted = lorkhan::parseMenuDialogueTtsCancelAcceptedResponse(
        std::string(menuCancel).replace(menuCancel.find("\"cancelled\""), 11, "\"completed\""), jsonHeaders);
    CHECK(cancelCompleted && cancelCompleted.value().status == lorkhan::MenuDialogueTtsCancelStatus::completed);
    CHECK(!lorkhan::parseMenuDialogueTtsCancelAcceptedResponse(
        std::string(menuCancel).replace(menuCancel.find("\"cancelled\""), 11, "\"abandoned\""), jsonHeaders));
    CHECK(!lorkhan::parseMenuDialogueTtsCancelAcceptedResponse(
        std::string(menuCancel).insert(menuCancel.size() - 1, ",\"media\":null"), jsonHeaders));

    auto playerAutochat = lorkhan::parsePlayerAutochatReadyResponse(
        R"({"schema":"lorkhan.player-autochat.ready.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"text":"Fargoth, have you found your ring yet?"})",
        jsonHeaders);
    CHECK(playerAutochat && playerAutochat.value().message == lorkhan::MessageId(kMessage)
        && playerAutochat.value().request == lorkhan::RequestId(kInstallation)
        && playerAutochat.value().session == lorkhan::SessionId(kSession)
        && playerAutochat.value().generation == lorkhan::Generation(7)
        && playerAutochat.value().text == "Fargoth, have you found your ring yet?");
    CHECK(!lorkhan::parsePlayerAutochatReadyResponse(
        R"({"schema":"lorkhan.player-autochat.ready.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"text":""})",
        jsonHeaders));
}

void testProtocolEventResponses()
{
    const lorkhan::Headers jsonHeaders{{"Content-Type", "application/json; charset=utf-8"}};
    const std::string events = R"json({
        "schema":"lorkhan.events.v1",
        "session_id":"01900000-0000-7000-8000-000000000004",
        "generation":7,
        "next_after":7,
        "events":[
          {"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-18T20:00:01Z","type":"turn.accepted","payload":{"status":"accepted"}},
          {"message_id":"01900000-0000-7000-8000-000000000009","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":2,"created_at":"2026-07-18T20:00:02.123Z","type":"dialogue.complete","payload":{"speaker":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"addressee":{"kind":"player","record_id":"player","refnum":{"index":1,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"interior","name":"Seyda Neen, Census Office"},"display_name":"Player"},"text":"You have found my ring."}},
          {"message_id":"01900000-0000-7000-8000-00000000000a","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":3,"created_at":"2026-07-18T20:00:03Z","type":"action.intent","payload":{"schema":"lorkhan.action-intent.v1","action_id":"01900000-0000-7000-8000-000000000007","turn_id":"01900000-0000-7000-8000-000000000005","name":"ai.follow","tier":1,"actor":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"target":{"kind":"player","record_id":"player","refnum":{"index":1,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"interior","name":"Seyda Neen, Census Office"},"display_name":"Player"},"parameters":{"distance":192},"display_name":"Follow","confirmation_required":false,"followup_enabled":true,"followup_actions_allowed":true,"followup_depth":0,"expires_at":"2026-07-18T20:00:10Z"}},
          {"message_id":"01900000-0000-7000-8000-00000000000b","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":4,"created_at":"2026-07-18T20:00:04Z","type":"speech.ready","payload":{"media_id":"01900000-0000-7000-8000-00000000000c","dialogue_message_id":"01900000-0000-7000-8000-000000000009","sha256":"e12e115acf4552b2568b55e93cbd39394c4ef81c82447faed7738adf06e9ba61","bytes":4,"codec":"ogg","duration_ms":100,"expires_at":"2026-07-18T21:00:00Z"}},
          {"message_id":"01900000-0000-7000-8000-00000000000d","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":5,"created_at":"2026-07-18T20:00:05Z","type":"turn.failed","payload":{"code":"provider_timeout","retriable":true,"retry_after_ms":250}},
          {"message_id":"01900000-0000-7000-8000-00000000000e","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":6,"created_at":"2026-07-18T20:00:06Z","type":"turn.cancelled","payload":{"reason":"interrupted"}},
          {"message_id":"01900000-0000-7000-8000-00000000000f","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":7,"created_at":"2026-07-18T20:00:07Z","type":"turn.complete","payload":{"status":"complete"}}
        ],
        "autonomy":[
          {"schema":"lorkhan.autonomy-directive.v1","schedule_id":"01900000-0000-7000-8000-000000000010","kind":"rechat","issued_at":"2026-07-18T20:00:08Z"}
        ]
    })json";
    // A provider rejection must deliver its terminal event, not poison polling forever.
    for (const auto* code : {"provider_invalid_output", "provider_invalid_action",
             "provider_action_not_allowed", "director_plan_failed"}) {
        std::string rejected = events;
        rejected.replace(rejected.find("provider_timeout"), std::string("provider_timeout").size(), code);
        CHECK(lorkhan::parseEventsResponse(rejected, jsonHeaders));
    }
    std::string unknownFailure = events;
    unknownFailure.replace(unknownFailure.find("provider_timeout"), std::string("provider_timeout").size(), "untrusted_failure");
    CHECK(!lorkhan::parseEventsResponse(unknownFailure, jsonHeaders));
    auto parsed = lorkhan::parseEventsResponse(events, jsonHeaders);
    CHECK(parsed && parsed.value().session == lorkhan::SessionId(kSession)
        && parsed.value().generation == lorkhan::Generation(7)
        && parsed.value().nextAfter == 7 && parsed.value().events.size() == 7
        && parsed.value().autonomy.size() == 1);
    if (parsed && parsed.value().autonomy.size() == 1) {
        CHECK(parsed.value().autonomy[0].scheduleId == "01900000-0000-7000-8000-000000000010"
            && parsed.value().autonomy[0].kind == "rechat"
            && parsed.value().autonomy[0].issuedAt == "2026-07-18T20:00:08Z");
    }
    if (parsed && parsed.value().events.size() == 7) {
        CHECK(parsed.value().events[0].type == lorkhan::ProtocolEventType::turn_accepted
            && std::get_if<lorkhan::TurnAcceptedEventPayload>(&parsed.value().events[0].payload));
        const auto* dialogue = std::get_if<lorkhan::DialogueCompleteEventPayload>(&parsed.value().events[1].payload);
        CHECK(dialogue && dialogue->speaker.recordId == "fargoth" && dialogue->speaker.cell.gridX == -2
            && dialogue->addressee.cell.kind == lorkhan::ProtocolCell::Kind::interior
            && dialogue->text == "You have found my ring.");
        const auto* intent = std::get_if<lorkhan::ActionIntentEventPayload>(&parsed.value().events[2].payload);
        CHECK(intent && intent->intent.action == lorkhan::ActionId(kAction)
            && intent->intent.turn == lorkhan::TurnId(kTurn) && intent->intent.followDistance == 192
            && intent->intent.actor.recordId == "fargoth" && intent->intent.target.recordId == "player"
            && intent->intent.displayName == "Follow" && intent->intent.confirmationRequired == false
            && intent->intent.followupEnabled == true && intent->intent.followupActionsAllowed == true
            && intent->intent.followupDepth == 0);
        const auto* speech = std::get_if<lorkhan::SpeechReadyEventPayload>(&parsed.value().events[3].payload);
        CHECK(speech && speech->codec == lorkhan::MediaCodec::ogg && speech->bytes == 4
            && speech->dialogueMessage.value() == "01900000-0000-7000-8000-000000000009"
            && speech->durationMs == 100 && speech->sha256.size() == 64);
        const auto* failed = std::get_if<lorkhan::TurnFailedEventPayload>(&parsed.value().events[4].payload);
        CHECK(failed && failed->code == lorkhan::ErrorCode::timeout && failed->retriable
            && failed->retryAfterMs == 250);
        const auto* cancelled = std::get_if<lorkhan::TurnCancelledEventPayload>(&parsed.value().events[5].payload);
        CHECK(cancelled && cancelled->reason == "interrupted");
        CHECK(parsed.value().events[6].type == lorkhan::ProtocolEventType::turn_complete
            && std::get_if<lorkhan::TurnCompleteEventPayload>(&parsed.value().events[6].payload));
    }

    auto canonical = lorkhan::parseEventsResponse(
        R"json({"schema":"lorkhan.events.v1","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"next_after":1,"events":[{"message_id":"01900000-0000-7000-8000-000000000020","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-08-09T18:00:02Z","type":"response.complete","payload":{"schema":"lorkhan.response.v1","response_id":"01900000-0000-7000-8000-000000000020","installation_id":"01900000-0000-7000-8000-000000000021","profile_id":"01900000-0000-7000-8000-000000000022","playthrough_id":"01900000-0000-7000-8000-000000000023","session_id":"01900000-0000-7000-8000-000000000004","turn_id":"01900000-0000-7000-8000-000000000005","request_id":"01900000-0000-7000-8000-000000000001","generation":7,"runtime_generation":3,"created_at":"2026-08-09T18:00:02Z","ok":true,"lines":[{"schema":"lorkhan.response.line.v1","line_id":"01900000-0000-7000-8000-000000000024","line_index":0,"speaker":"Fargoth","display_name":"Fargoth","speaker_identity":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"action":"say","text":"You found my ring!","subtitle":"You found my ring!","tts_text":"You found my ring!","request_id":"01900000-0000-7000-8000-000000000001","utterance_id":"01900000-0000-7000-8000-000000000025","listener":"Player","listener_identity":{"kind":"player","record_id":"player","refnum":{"index":1,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"interior","name":"Office"},"display_name":"Player"},"rechat_target":"Fargoth","rechat_target_identity":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"final_response_line":true,"metadata":{"emotion":"relieved","rechat_depth":0,"speech_enabled":true,"source":"llm"}},{"schema":"lorkhan.response.line.v1","line_id":"01900000-0000-7000-8000-000000000026","line_index":1,"speaker":"Fargoth","display_name":"Fargoth","speaker_identity":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"action":"rolecommand","text":"","subtitle":"","tts_text":"","request_id":"01900000-0000-7000-8000-000000000001","utterance_id":"01900000-0000-7000-8000-000000000027","listener":"Player","listener_identity":{"kind":"player","record_id":"player","refnum":{"index":1,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"interior","name":"Office"},"display_name":"Player"},"rechat_target":"Fargoth","rechat_target_identity":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"final_response_line":false,"metadata":{"rechat_depth":0,"source":"llm"},"command_name":"ai.follow","command_args":["player","192"]}],"close":false,"error":""}}],"autonomy":[]})json",
        jsonHeaders);
    CHECK(canonical && canonical.value().events.size() == 1);
    if (canonical && canonical.value().events.size() == 1) {
        const auto* response = std::get_if<lorkhan::ResponseCompleteEventPayload>(&canonical.value().events[0].payload);
        CHECK(response && response->response.runtimeGeneration == lorkhan::Generation(3)
            && response->response.lines.size() == 2 && response->response.lines[0].finalResponseLine
            && response->response.lines[0].metadata.speechEnabled == true
            && response->response.lines[1].commandName == "ai.follow"
            && response->response.lines[1].commandArgs.size() == 2);
    }

    const std::string prefix = R"({"schema":"lorkhan.events.v1","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"next_after":1,"events":[)";
    const std::string suffix = "],\"autonomy\":[]}";
    auto delta = lorkhan::parseEventsResponse(prefix
        + R"({"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-18T20:00:01Z","type":"dialogue.delta","payload":{"text":"Welcome to "}})"
        + suffix, jsonHeaders);
    CHECK(delta && std::get_if<lorkhan::DialogueDeltaEventPayload>(&delta.value().events[0].payload));
    auto speechFailed = lorkhan::parseEventsResponse(prefix
        + R"({"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-18T20:00:01Z","type":"speech.failed","payload":{"dialogue_message_id":"01900000-0000-7000-8000-000000000009","code":"provider_unavailable"}})"
        + suffix, jsonHeaders);
    const auto* noAudio = speechFailed ? std::get_if<lorkhan::SpeechFailedEventPayload>(&speechFailed.value().events[0].payload) : nullptr;
    CHECK(noAudio && speechFailed.value().events[0].type == lorkhan::ProtocolEventType::speech_failed
        && noAudio->dialogueMessage.value() == "01900000-0000-7000-8000-000000000009" && noAudio->code == "provider_unavailable");
    CHECK(!lorkhan::parseEventsResponse(prefix
        + R"({"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-18T20:00:01Z","type":"speech.failed","payload":{"dialogue_message_id":"01900000-0000-7000-8000-000000000009","code":"provider_unavailable","media_id":"01900000-0000-7000-8000-00000000000c"}})"
        + suffix, jsonHeaders));
    CHECK(!lorkhan::parseEventsResponse(prefix
        + R"({"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-18T20:00:01Z","type":"speech.failed","payload":{"dialogue_message_id":"01900000-0000-7000-8000-000000000009","code":"invalid_audio"}})"
        + suffix, jsonHeaders));
    CHECK(!lorkhan::parseEventsResponse(prefix
        + R"({"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":8,"sequence":1,"created_at":"2026-07-18T20:00:01Z","type":"turn.accepted","payload":{"status":"accepted"}})"
        + suffix, jsonHeaders));
    CHECK(!lorkhan::parseEventsResponse(prefix
        + R"({"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-18 20:00:01Z","type":"turn.accepted","payload":{"status":"accepted"}})"
        + suffix, jsonHeaders));
    CHECK(!lorkhan::parseEventsResponse(prefix
        + R"({"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-02-30T20:00:01Z","type":"turn.accepted","payload":{"status":"accepted"}})"
        + suffix, jsonHeaders));
    CHECK(!lorkhan::parseEventsResponse(prefix
        + R"({"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-18T20:00:01Z","type":"server.notice","payload":{}})"
        + suffix, jsonHeaders));
    CHECK(!lorkhan::parseEventsResponse(prefix
        + R"({"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-18T20:00:01Z","type":"action.intent","payload":{"schema":"lorkhan.action-intent.v1","action_id":"01900000-0000-7000-8000-000000000007","turn_id":"01900000-0000-7000-8000-000000000006","name":"ai.follow","tier":1,"actor":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"target":{"kind":"player","record_id":"player","refnum":{"index":1,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"interior","name":"Office"},"display_name":"Player"},"parameters":{"distance":192},"expires_at":"2026-07-18T20:00:10Z"}})"
        + suffix, jsonHeaders));
    CHECK(!lorkhan::parseEventsResponse(prefix
        + R"({"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-18T20:00:01Z","type":"speech.ready","payload":{"media_id":"01900000-0000-7000-8000-00000000000c","sha256":"E12E115ACF4552B2568B55E93CBD39394C4EF81C82447FAED7738ADF06E9BA61","bytes":4,"codec":"ogg","duration_ms":100,"expires_at":"2026-07-18T21:00:00Z"}})"
        + suffix, jsonHeaders));
    auto cursorAhead = lorkhan::parseEventsResponse(
        R"({"schema":"lorkhan.events.v1","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"next_after":9,"events":[{"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-18T20:00:01Z","type":"turn.accepted","payload":{"status":"accepted"}}],"autonomy":[]})",
        jsonHeaders);
    CHECK(cursorAhead && cursorAhead.value().nextAfter == 9);

    auto extended = lorkhan::parseEventsResponse(
        R"({"schema":"lorkhan.events.v1","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"next_after":3,"events":[{"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-19T20:00:01Z","type":"stt.transcript","payload":{"text":"Hello there.","language":"en-US"}},{"message_id":"01900000-0000-7000-8000-000000000009","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":2,"created_at":"2026-07-19T20:00:02Z","type":"stt.failed","payload":{"code":"provider_timeout","retriable":true,"retry_after_ms":1000}},{"message_id":"01900000-0000-7000-8000-00000000000a","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":3,"created_at":"2026-07-19T20:00:03Z","type":"action.intent","payload":{"schema":"lorkhan.action-intent.v1","action_id":"01900000-0000-7000-8000-000000000007","turn_id":"01900000-0000-7000-8000-000000000005","name":"inspect.report","tier":0,"actor":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"target":{"kind":"player","record_id":"player","refnum":{"index":1,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"interior","name":"Office"},"display_name":"Player"},"parameters":{},"expires_at":"2026-07-19T20:00:30Z"}}],"autonomy":[]})",
        jsonHeaders);
    CHECK(extended && extended.value().events.size() == 3);
    if (extended && extended.value().events.size() == 3) {
        const auto* transcript = std::get_if<lorkhan::SttTranscriptEventPayload>(&extended.value().events[0].payload);
        const auto* sttFailure = std::get_if<lorkhan::SttFailedEventPayload>(&extended.value().events[1].payload);
        const auto* inspect = std::get_if<lorkhan::ActionIntentEventPayload>(&extended.value().events[2].payload);
        CHECK(transcript && transcript->text == "Hello there." && transcript->language == "en-US");
        CHECK(sttFailure && sttFailure->code == "provider_timeout" && sttFailure->retryAfterMs == 1000);
        CHECK(inspect && inspect->intent.kind == lorkhan::ActionIntentKind::inspect_report
            && inspect->intent.followDistance == 0);
    }
    auto equipment = lorkhan::parseEventsResponse(
        R"({"schema":"lorkhan.events.v1","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"next_after":1,"events":[{"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-19T20:00:03Z","type":"action.intent","payload":{"schema":"lorkhan.action-intent.v1","action_id":"01900000-0000-7000-8000-000000000007","turn_id":"01900000-0000-7000-8000-000000000005","name":"item.equip","tier":2,"actor":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"target":{"kind":"player","record_id":"player","refnum":{"index":1,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"interior","name":"Office"},"display_name":"Player"},"parameters":{"record_id":"iron dagger","slot":"carried_right"},"expires_at":"2026-07-19T20:00:30Z"}}],"autonomy":[]})",
        jsonHeaders);
    CHECK(equipment && equipment.value().events.size() == 1);
    if (equipment && equipment.value().events.size() == 1) {
        const auto* equip = std::get_if<lorkhan::ActionIntentEventPayload>(&equipment.value().events[0].payload);
        CHECK(equip && equip->intent.kind == lorkhan::ActionIntentKind::item_equip
            && equip->intent.stringParameter == "iron dagger"
            && equip->intent.secondaryStringParameter == "carried_right");
    }
    const std::string parityActionsJson =
        R"({"schema":"lorkhan.events.v1","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"next_after":3,"events":[
        {"message_id":"01900000-0000-7000-8000-000000000021","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-19T20:00:03Z","type":"action.intent","payload":{"schema":"lorkhan.action-intent.v1","action_id":"01900000-0000-7000-8000-000000000031","turn_id":"01900000-0000-7000-8000-000000000005","name":"inventory.inspect","tier":0,"actor":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"target":{"kind":"player","record_id":"player","refnum":{"index":1,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Player"},"parameters":{},"expires_at":"2026-07-19T20:00:30Z"}},
        {"message_id":"01900000-0000-7000-8000-000000000022","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":2,"created_at":"2026-07-19T20:00:04Z","type":"action.intent","payload":{"schema":"lorkhan.action-intent.v1","action_id":"01900000-0000-7000-8000-000000000032","turn_id":"01900000-0000-7000-8000-000000000005","name":"ai.approach","tier":1,"actor":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"target":{"kind":"player","record_id":"player","refnum":{"index":1,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Player"},"parameters":{},"expires_at":"2026-07-19T20:00:30Z"}},
        {"message_id":"01900000-0000-7000-8000-000000000023","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":3,"created_at":"2026-07-19T20:00:05Z","type":"action.intent","payload":{"schema":"lorkhan.action-intent.v1","action_id":"01900000-0000-7000-8000-000000000033","turn_id":"01900000-0000-7000-8000-000000000005","name":"ai.wait","tier":1,"actor":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"target":{"kind":"player","record_id":"player","refnum":{"index":1,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Player"},"parameters":{"duration_seconds":3600},"expires_at":"2026-07-19T20:00:30Z"}}
        ],"autonomy":[]})";
    auto parityActions = lorkhan::parseEventsResponse(parityActionsJson, jsonHeaders);
    CHECK(parityActions && parityActions.value().events.size() == 3);
    if (parityActions && parityActions.value().events.size() == 3) {
        const auto* inventory = std::get_if<lorkhan::ActionIntentEventPayload>(&parityActions.value().events[0].payload);
        const auto* approach = std::get_if<lorkhan::ActionIntentEventPayload>(&parityActions.value().events[1].payload);
        const auto* wait = std::get_if<lorkhan::ActionIntentEventPayload>(&parityActions.value().events[2].payload);
        CHECK(inventory && inventory->intent.kind == lorkhan::ActionIntentKind::inventory_inspect);
        CHECK(approach && approach->intent.kind == lorkhan::ActionIntentKind::ai_approach);
        CHECK(wait && wait->intent.kind == lorkhan::ActionIntentKind::ai_wait
            && wait->intent.wanderDurationSeconds == 3600);
    }
    auto endJson = parityActionsJson;
    const auto approachName = endJson.find("ai.approach");
    CHECK(approachName != std::string::npos);
    endJson.replace(approachName, std::string("ai.approach").size(), "conversation.end");
    auto ended = lorkhan::parseEventsResponse(endJson, jsonHeaders);
    CHECK(ended && ended.value().events.size() == 3);
    if (ended && ended.value().events.size() == 3) {
        const auto* end = std::get_if<lorkhan::ActionIntentEventPayload>(&ended.value().events[1].payload);
        CHECK(end && end->intent.kind == lorkhan::ActionIntentKind::conversation_end);
    }
    auto sheatheJson = parityActionsJson;
    sheatheJson.replace(approachName, std::string("ai.approach").size(), "weapon.sheathe");
    const auto sheathed = lorkhan::parseEventsResponse(sheatheJson, jsonHeaders);
    CHECK(sheathed && sheathed.value().events.size() == 3);
    if (sheathed && sheathed.value().events.size() == 3) {
        const auto* action = std::get_if<lorkhan::ActionIntentEventPayload>(&sheathed.value().events[1].payload);
        CHECK(action && action->intent.kind == lorkhan::ActionIntentKind::weapon_sheathe);
    }
    for (const auto& [name,parameters]:std::vector<std::pair<std::string,std::string>>{
        {"item.give",R"({"item_id":"@0x123","count":2})"}, {"item.take",R"({"item_id":"0x12","count":1000})"},
        {"item.pickup",R"({"item_id":"@0xffffffffffffffff"})"}, {"gold.give",R"({"amount":100000})"}, {"gold.take",R"({"amount":1})"}}) {
        auto wire=parityActionsJson;wire.replace(approachName,std::string("ai.approach").size(),name);
        const auto tierPosition=wire.find("\"tier\":1",approachName);CHECK(tierPosition!=std::string::npos);
        wire.replace(tierPosition,std::string("\"tier\":1").size(),"\"tier\":2,\"confirmation_required\":true");
        const auto paramsPosition=wire.find("\"parameters\":{}",approachName);CHECK(paramsPosition!=std::string::npos);
        wire.replace(paramsPosition,std::string("\"parameters\":{}").size(),"\"parameters\":"+parameters);
        CHECK(lorkhan::parseEventsResponse(wire,jsonHeaders));
        auto noApproval=wire;const auto approval=noApproval.find("\"confirmation_required\":true",approachName);
        noApproval.replace(approval,std::string("\"confirmation_required\":true").size(),"\"confirmation_required\":false");
        CHECK(lorkhan::parseEventsResponse(noApproval,jsonHeaders));
        auto unknown=wire;const auto parametersStart=unknown.find("\"parameters\":{",approachName);
        unknown.insert(parametersStart+std::string("\"parameters\":{").size(),"\"script\":\"bad\",");
        CHECK(!lorkhan::parseEventsResponse(unknown,jsonHeaders));
        auto missingApproval=wire;
        missingApproval.erase(approval,std::string("\"confirmation_required\":true,").size());
        CHECK(!lorkhan::parseEventsResponse(missingApproval,jsonHeaders));
        for(const auto& invalidParameters: name.starts_with("gold.")
            ? std::vector<std::string>{R"({"amount":0})",R"({"amount":100001})"}
            : name=="item.pickup" ? std::vector<std::string>{R"({"item_id":"player"})",R"({"item_id":"@0xABC"})"}
            : std::vector<std::string>{R"({"item_id":"0x12","count":0})",R"({"item_id":"0x12","count":1001})"}) {
            auto invalid=wire;
            invalid.replace(paramsPosition,std::string("\"parameters\":").size()+parameters.size(),"\"parameters\":"+invalidParameters);
            CHECK(!lorkhan::parseEventsResponse(invalid,jsonHeaders));
        }
    }
    for(const auto& [name,parameters]:std::vector<std::pair<std::string,std::string>>{
        {"item.create",R"({"record_id":"test_item","count":100})"}, {"gold.create",R"({"amount":100000})"},
        {"actor.spawn",R"({"record_id":"test_actor","count":4})"}, {"player.teleport",R"({"destination_id":"destination:1"})"},
        {"actor.teleport_to_player","{}"}, {"actor.restore","{}"}, {"actor.resurrect","{}"}, {"actor.kill","{}"}}){
        auto wire=parityActionsJson;wire.replace(approachName,std::string("ai.approach").size(),name);
        const auto tier=wire.find("\"tier\":1",approachName);
        wire.replace(tier,std::string("\"tier\":1").size(),"\"tier\":2,\"confirmation_required\":true");
        const auto params=wire.find("\"parameters\":{}",approachName);
        wire.replace(params,std::string("\"parameters\":{}").size(),"\"parameters\":"+parameters);
        CHECK(!lorkhan::parseEventsResponse(wire,jsonHeaders)); // Only the player has advanced authority.
        const auto actorStart=wire.find("\"actor\":",approachName),targetStart=wire.find("\"target\":",actorStart);
        const auto targetEnd=wire.find(",\"parameters\":",targetStart);
        const auto playerIdentity=wire.substr(targetStart+9,targetEnd-targetStart-9);
        const auto npcIdentity=wire.substr(actorStart+8,targetStart-actorStart-9);
        wire.replace(actorStart,targetStart-actorStart,"\"actor\":"+playerIdentity+",");
        if(name=="actor.kill"||name=="actor.resurrect"||name=="actor.teleport_to_player"){
            const auto position=wire.find("\"target\":",actorStart);
            wire.replace(position+9,playerIdentity.size(),npcIdentity);
        }
        CHECK(lorkhan::parseEventsResponse(wire,jsonHeaders));
        auto noApproval=wire;const auto approval=noApproval.find("\"confirmation_required\":true",approachName);
        noApproval.replace(approval,std::string("\"confirmation_required\":true").size(),"\"confirmation_required\":false");
        CHECK(lorkhan::parseEventsResponse(noApproval,jsonHeaders));
        auto wrongTier=wire;wrongTier.replace(wrongTier.find("\"tier\":2",approachName),8,"\"tier\":1");
        CHECK(!lorkhan::parseEventsResponse(wrongTier,jsonHeaders));
        auto arbitrary=wire;const auto position=arbitrary.find("\"parameters\":",approachName);
        arbitrary.replace(position+13,parameters.size(),R"({"script":"bad"})");
        CHECK(!lorkhan::parseEventsResponse(arbitrary,jsonHeaders));
        if(name=="item.create"||name=="actor.spawn"||name=="gold.create"){
            auto overflow=wire;const auto amount=overflow.find(name=="gold.create"?"100000":name=="item.create"?"100":"4",overflow.find("\"parameters\":",approachName));
            overflow.insert(amount,"9");CHECK(!lorkhan::parseEventsResponse(overflow,jsonHeaders));
        }
    }
    for(const char* name:{"service.barter","service.training","service.spells","service.travel","service.spellmaking","service.enchanting","service.repair"}){
        auto wire=parityActionsJson;wire.replace(approachName,std::string("ai.approach").size(),name);
        CHECK(lorkhan::parseEventsResponse(wire,jsonHeaders));
        auto invalid=wire;const auto position=invalid.find("\"parameters\":{}",approachName);
        invalid.replace(position,std::string("\"parameters\":{}").size(),"\"parameters\":{\"purchase\":true}");
        CHECK(!lorkhan::parseEventsResponse(invalid,jsonHeaders));
    }
    {
        auto wire=parityActionsJson;wire.replace(approachName,std::string("ai.approach").size(),"spell.cast");
        const auto tier=wire.find("\"tier\":1",approachName);
        wire.replace(tier,std::string("\"tier\":1").size(),"\"tier\":2,\"confirmation_required\":true");
        const auto params=wire.find("\"parameters\":{}",approachName);
        wire.replace(params,std::string("\"parameters\":{}").size(),"\"parameters\":{\"spell_id\":\"fire bite\"}");
        CHECK(lorkhan::parseEventsResponse(wire,jsonHeaders));
        auto denied=wire;const auto approval=denied.find("\"confirmation_required\":true",approachName);
        denied.replace(approval,std::string("\"confirmation_required\":true").size(),"\"confirmation_required\":false");
        CHECK(lorkhan::parseEventsResponse(denied,jsonHeaders));
        auto empty=wire;empty.replace(empty.find("fire bite",params),std::string("fire bite").size(),"");
        CHECK(!lorkhan::parseEventsResponse(empty,jsonHeaders));
    }
    const std::string directorInstruction=R"({"instruction_id":"01900000-0000-7000-8000-000000000040","actor":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"recipient":{"kind":"player","record_id":"player","refnum":{"index":1,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Player"},"instruction":"Greet the traveler.","scene_note":""})";
    const std::string directorPrefix=R"({"schema":"lorkhan.events.v1","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"next_after":1,"events":[{"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-19T20:00:01Z","type":"director.instructions","payload":{"plan_id":"01900000-0000-7000-8000-000000000039","origin_turn_id":"01900000-0000-7000-8000-000000000005","expires_at":"2026-07-19T20:01:00Z","instructions":[)";
    const std::string directorSuffix=R"(]}}],"autonomy":[]})";
    auto directed=lorkhan::parseEventsResponse(directorPrefix+directorInstruction+directorSuffix,jsonHeaders);
    CHECK(directed&&directed.value().events.size()==1);
    if(directed){
        const auto* plan=std::get_if<lorkhan::DirectorInstructionsEventPayload>(&directed.value().events[0].payload);
        CHECK(plan&&plan->instructions.size()==1&&plan->instructions[0].text=="Greet the traveler.");
    }
    CHECK(!lorkhan::parseEventsResponse(directorPrefix+directorSuffix,jsonHeaders));
    CHECK(!lorkhan::parseEventsResponse(directorPrefix+directorInstruction+","+directorInstruction+directorSuffix,jsonHeaders));
    auto secondDirector=directorInstruction;secondDirector.replace(secondDirector.find("000000000040"),12,"000000000041");
    CHECK(lorkhan::parseEventsResponse(directorPrefix+directorInstruction+","+secondDirector+directorSuffix,jsonHeaders));
    std::string scene;
    for(unsigned i=0;i<13;++i){
        auto instruction=directorInstruction;instruction.replace(instruction.find("000000000040"),12,"0000000000"+std::to_string(40+i));
        if(i)scene+=",";scene+=instruction;
        if(i==11)CHECK(lorkhan::parseEventsResponse(directorPrefix+scene+directorSuffix,jsonHeaders));
    }
    CHECK(!lorkhan::parseEventsResponse(directorPrefix+scene+directorSuffix,jsonHeaders));
    auto playerDirector=directorInstruction;playerDirector.replace(playerDirector.find("\"kind\":\"npc\""),12,"\"kind\":\"player\"");
    CHECK(!lorkhan::parseEventsResponse(directorPrefix+playerDirector+directorSuffix,jsonHeaders));
    auto invalidSheathe = sheatheJson;
    const auto sheatheParams = invalidSheathe.find("\"parameters\":{}", approachName);
    CHECK(sheatheParams != std::string::npos);
    invalidSheathe.replace(sheatheParams, std::string("\"parameters\":{}").size(), "\"parameters\":{\"force\":true}");
    CHECK(!lorkhan::parseEventsResponse(invalidSheathe, jsonHeaders));
}

void testQueue()
{
    lorkhan::BoundedQueue<int> queue(5, 2);
    CHECK(queue.tryPush(1)); CHECK(queue.tryPush(2)); CHECK(queue.tryPush(3));
    CHECK(!queue.tryPush(4));
    CHECK(queue.tryPush(99, true)); CHECK(queue.tryPush(100, true)); CHECK(!queue.tryPush(101, true));
    auto drained = queue.drain(5);
    CHECK(drained.size() == 5 && drained[0] == 100 && drained[1] == 99);
    CHECK(queue.tryPush(1)); CHECK(queue.tryPush(2)); CHECK(queue.tryPush(3));
    const auto speech = [](int value) { return value >= 2; };
    CHECK(queue.waitPop([](int value) { return value == 3; }, speech) == 3);
    CHECK(queue.waitPop(speech) == 2);
    CHECK(queue.waitPop(speech) == 1);
    queue.close();
    CHECK(!queue.tryPush(1));
    CHECK(!queue.waitPop(speech));
}

void testLifecycleAndCancellation()
{
    lorkhan::GenerationState generations;
    CHECK(generations.current() == lorkhan::Generation(0));
    CHECK(generations.invalidate() == lorkhan::Generation(1));
    lorkhan::GenerationState seeded(lorkhan::Generation(42));
    CHECK(seeded.current() == lorkhan::Generation(42));
    CHECK(seeded.invalidate() == lorkhan::Generation(43));
    lorkhan::CancellationRegistry registry;
    auto token = registry.registerRequest(lorkhan::RequestId("a"), lorkhan::Generation(1));
    CHECK(token && !token.value().stop_requested());
    CHECK(!registry.registerRequest(lorkhan::RequestId("a"), lorkhan::Generation(1)));
    CHECK(registry.cancel(lorkhan::RequestId("a")) && token.value().stop_requested());
    registry.complete(lorkhan::RequestId("a"));
    CHECK(registry.size() == 0);
}

void testEvents()
{
    lorkhan::EventTracker tracker;
    const lorkhan::SessionId session(kSession);
    const lorkhan::MessageId message1(kMessage);
    const lorkhan::MessageId message2("01900000-0000-7000-8000-000000000008");
    const lorkhan::MessageId message3("01900000-0000-7000-8000-000000000009");
    CHECK(tracker.observe({session, 1, message1}).disposition == lorkhan::EventDisposition::accepted);
    CHECK(tracker.observe({session, 1, message1}).disposition == lorkhan::EventDisposition::duplicate);
    auto gap = tracker.observe({session, 3, message3});
    CHECK(gap.disposition == lorkhan::EventDisposition::gap && gap.expectedSequence == 2);
    CHECK(tracker.observe({session, 2, message2}).disposition == lorkhan::EventDisposition::accepted);
    CHECK(tracker.observe({lorkhan::SessionId("bad"), 3, message3}).disposition == lorkhan::EventDisposition::invalid);
    CHECK(tracker.observe({session, 3, lorkhan::MessageId("BAD")}).disposition == lorkhan::EventDisposition::invalid);
    CHECK(tracker.cursor(session) == 2);
}

void testActions()
{
    lorkhan::ActionCommitGate beforeConfirmation;
    CHECK(beforeConfirmation.cancel()); CHECK(!beforeConfirmation.queue()); CHECK(!beforeConfirmation.begin());
    lorkhan::ActionCommitGate pending;
    CHECK(pending.queue()); CHECK(!pending.queue()); CHECK(pending.cancel()); CHECK(!pending.begin());
    lorkhan::ActionCommitGate committed;
    CHECK(committed.queue()); CHECK(committed.begin()); CHECK(!committed.begin()); CHECK(!committed.cancel());
    committed.finish(); CHECK(!committed.queue()); CHECK(!committed.begin()); CHECK(!committed.cancel());
    const auto follow = lorkhan::validateAiFollow(192);
    CHECK(follow && follow.value().distance == 192);
    CHECK(!lorkhan::validateAiFollow(0));
    CHECK(!lorkhan::validateAiFollow(191));
    CHECK(!lorkhan::validateAiFollow(193));
    CHECK(!lorkhan::validateAiFollow(std::numeric_limits<std::uint32_t>::max()));
    lorkhan::ActionResultRegistry registry;
    const lorkhan::ActionId action(kAction);
    CHECK(!registry.registerAction(lorkhan::ActionId("action"), lorkhan::Generation(2)));
    CHECK(!registry.registerAction(lorkhan::ActionId("01900000-0000-7000-8000-00000000000A"), lorkhan::Generation(2)));
    CHECK(registry.registerAction(action, lorkhan::Generation(2)));
    CHECK(registry.finish({action, lorkhan::ActionTerminalStatus::succeeded, "package_started"}));
    CHECK(!registry.finish({action, lorkhan::ActionTerminalStatus::failed, "duplicate"}));
    CHECK(registry.terminal(action));
}

void testPairingToken()
{
    static_assert(!std::is_copy_constructible_v<lorkhan::PairingToken>);
    static_assert(!std::is_copy_assignable_v<lorkhan::PairingToken>);
    static_assert(std::is_move_constructible_v<lorkhan::PairingToken>);
    static_assert(std::is_constructible_v<lorkhan::PairingToken, lorkhan::PairingToken::Secret>);
    static_assert(!std::is_constructible_v<lorkhan::PairingToken, std::string>);
    lorkhan::PairingToken::Secret secret{};
    secret[0] = std::byte{0x42};
    lorkhan::PairingToken token(secret);
    CHECK(!token.empty() && token.redacted() == "<redacted>");
    lorkhan::PairingToken moved(std::move(token));
    CHECK(token.empty() && token.redacted() == "<unset>");
    CHECK(!moved.empty() && moved.redacted() == "<redacted>");
}

void testMedia()
{
    lorkhan::MediaDescriptor descriptor;
    descriptor.id = lorkhan::MediaId("01912345-6789-7abc-8def-0123456789ab");
    descriptor.bytes = 123; descriptor.expiresAt = std::chrono::system_clock::time_point(200s);
    CHECK(lorkhan::validateMediaDescriptor(descriptor, {}, std::chrono::system_clock::time_point(100s)));
    const auto route = lorkhan::mediaRoute(descriptor.id);
    CHECK(route && route.value() == "/media/01912345-6789-7abc-8def-0123456789ab");
    descriptor.id = lorkhan::MediaId("../secret");
    CHECK(!lorkhan::validateMediaDescriptor(descriptor, {}, std::chrono::system_clock::time_point(100s)));
    CHECK(!lorkhan::mediaRoute(descriptor.id));
    descriptor.id = lorkhan::MediaId("01912345-6789-7ABC-8def-0123456789ab");
    CHECK(!lorkhan::validateMediaDescriptor(descriptor, {}, std::chrono::system_clock::time_point(100s)));
    CHECK(lorkhan::resolveCachePath("cache", std::string(64, 'a'), lorkhan::MediaCodec::ogg));
    CHECK(!lorkhan::resolveCachePath("cache", std::string(63, 'a'), lorkhan::MediaCodec::ogg));
}

void testBridgeDialogueDeliveryValidation()
{
    auto state = std::make_shared<TransportState>();
    auto clock = std::make_shared<FakeClock>();
    lorkhan::BridgeService bridge(std::make_unique<FakeTransport>(state), clock);
    const auto generation = bridge.generation();
    // A cancellation has its own operation ID but refers to the original dialogue request.
    CHECK(bridge.enqueue({lorkhan::RequestId(uuidFor(79)), lorkhan::SessionId(kSession), generation,
        lorkhan::RequestKind::interruption, lorkhan::InterruptionRequest{lorkhan::MessageId(kMessage),
            lorkhan::RequestId(uuidFor(78)), lorkhan::TurnId(kTurn), lorkhan::SessionId(kSession),
            generation, "2026-07-19T20:00:02.123Z", "superseded_by_player"}}));
    const auto makeDelivery = [&](std::string id) {
        return lorkhan::OutboundRequest{lorkhan::RequestId(id), lorkhan::SessionId(kSession), generation,
            lorkhan::RequestKind::dialogue_delivery_result,
            lorkhan::DialogueDeliveryResultRequest{lorkhan::MessageId(kMessage),
                {lorkhan::RequestId(id), lorkhan::SessionId(kSession), generation},
                lorkhan::MessageId(kAction), lorkhan::TurnId(kTurn), protocolIdentity(),
                lorkhan::DialogueDeliveryStatus::played, "playback_completed", "2026-07-19T20:00:02.123Z"}};
    };
    auto separatelyCorrelated = makeDelivery(uuidFor(80));
    std::get<lorkhan::DialogueDeliveryResultRequest>(separatelyCorrelated.payload).correlation.request
        = lorkhan::RequestId(uuidFor(79));
    CHECK(bridge.enqueue(std::move(separatelyCorrelated)));
    auto mismatchedKind = makeDelivery(uuidFor(81));
    mismatchedKind.kind = lorkhan::RequestKind::turn;
    CHECK(!bridge.enqueue(std::move(mismatchedKind)));
    auto badSpeaker = makeDelivery(uuidFor(82));
    std::get<lorkhan::DialogueDeliveryResultRequest>(badSpeaker.payload).serializedSpeaker = "{}";
    CHECK(!bridge.enqueue(std::move(badSpeaker)));
    auto badCorrelation = makeDelivery(uuidFor(83));
    std::get<lorkhan::DialogueDeliveryResultRequest>(badCorrelation.payload).correlation.request
        = lorkhan::RequestId("request");
    CHECK(!bridge.enqueue(std::move(badCorrelation)));
    auto badReason = makeDelivery(uuidFor(85));
    std::get<lorkhan::DialogueDeliveryResultRequest>(badReason.payload).reasonCode = "Bad-Reason";
    CHECK(!bridge.enqueue(std::move(badReason)));
    auto badTimestamp = makeDelivery(uuidFor(86));
    std::get<lorkhan::DialogueDeliveryResultRequest>(badTimestamp.payload).completedAt = "2026-02-30T20:00:02Z";
    CHECK(!bridge.enqueue(std::move(badTimestamp)));

    lorkhan::OutboundRequest inventory{lorkhan::RequestId(uuidFor(88)), lorkhan::SessionId(kSession), generation,
        lorkhan::RequestKind::gamedata,
        lorkhan::GameDataRequest{lorkhan::InstallationId(kInstallation), lorkhan::PlaythroughId(kPlaythrough),
            lorkhan::RequestId(uuidFor(88)), generation, "2026-07-19T20:00:02Z", lorkhan::GameDataType::inventory,
            "{\"owner\":" + protocolIdentity() + ",\"items\":[]}"}};
    CHECK(bridge.enqueue(inventory));
    inventory.id = lorkhan::RequestId(uuidFor(89));
    auto& invalidInventory = std::get<lorkhan::GameDataRequest>(inventory.payload);
    invalidInventory.request = inventory.id;
    invalidInventory.serializedPayload = "{}";
    CHECK(!bridge.enqueue(inventory));
    invalidInventory.serializedPayload = "{\"owner\":" + protocolIdentity() + ",\"items\":[]}";
    invalidInventory.runtimeGeneration = lorkhan::Generation(generation.value() + 1);
    CHECK(!bridge.enqueue(inventory));
    const std::string questBody = "{\"responder\":" + protocolIdentity() + R"(,"game_time":100,"text":"Quest a: b.")";
    for (const auto& [index, type, calendar, accepted] : std::vector<std::tuple<unsigned, lorkhan::GameDataType, std::string, bool>>{
             {90u, lorkhan::GameDataType::quest_event, "", true},
             {91u, lorkhan::GameDataType::quest_event, R"(,"calendar":{"year":427,"month":7,"day":15,"hour":12.5})", true},
             {92u, lorkhan::GameDataType::quest_event, R"(,"calendar":{"year":427,"month":7,"day":32,"hour":12.5})", false},
             {93u, lorkhan::GameDataType::rpg_event, R"(,"calendar":{"year":0,"month":7,"day":15,"hour":12.5})", false}}) {
        lorkhan::OutboundRequest observation{lorkhan::RequestId(uuidFor(index)), lorkhan::SessionId(kSession), generation,
            lorkhan::RequestKind::gamedata,
            lorkhan::GameDataRequest{lorkhan::InstallationId(kInstallation), lorkhan::PlaythroughId(kPlaythrough),
                lorkhan::RequestId(uuidFor(index)), generation, "2026-07-19T20:00:02Z", type, questBody + calendar + "}"}};
        CHECK(static_cast<bool>(bridge.enqueue(std::move(observation))) == accepted);
    }

    lorkhan::EnvelopeIds sttIds{lorkhan::InstallationId(kInstallation), lorkhan::ProfileId(kProfile),
        lorkhan::PlaythroughId(kPlaythrough), lorkhan::SessionId(kSession), lorkhan::RequestId(uuidFor(87)),
        lorkhan::TurnId(kTurn), lorkhan::MessageId(kMessage), generation};
    lorkhan::OutboundRequest stt{lorkhan::RequestId(uuidFor(87)), lorkhan::SessionId(kSession), generation,
        lorkhan::RequestKind::stt, lorkhan::SttRequest{std::move(sttIds), "2026-07-19T20:00:02Z",
            "ogg", "en-US", std::string(64, 'a'), {std::byte{'O'}}}};
    CHECK(!bridge.enqueue(std::move(stt)));
    bridge.halt();
}

void testBridge()
{
    {
        auto pollState = std::make_shared<TransportState>();
        lorkhan::BridgeService pollBridge(std::make_unique<FakeTransport>(pollState), std::make_shared<FakeClock>());
        const auto generation = pollBridge.generation();
        CHECK(pollBridge.enqueue({lorkhan::RequestId(uuidFor(700)), lorkhan::SessionId(kSession), generation,
            lorkhan::RequestKind::event_poll,
            lorkhan::EventPollRequest{lorkhan::SessionId(kSession), generation, 0, 1000}}));
        const auto deadline = std::chrono::steady_clock::now() + 2s;
        while (pollState->executions.load() == 0 && std::chrono::steady_clock::now() < deadline)
            std::this_thread::yield();
        CHECK(pollState->executions == 1);
        CHECK(pollState->pollWaitMs == 0);
    }
    auto state = std::make_shared<TransportState>();
    auto clock = std::make_shared<FakeClock>();
    lorkhan::BridgeService bridge(std::make_unique<FakeTransport>(state), clock);
    const auto generation = bridge.generation();
    CHECK(!bridge.enqueue(request("one", generation)));
    CHECK(!bridge.enqueue(request("01900000-0000-7000-8000-00000000000A", generation)));
    auto malformedSession = request(uuidFor(14), generation);
    malformedSession.session = lorkhan::SessionId("session");
    CHECK(!bridge.enqueue(std::move(malformedSession)));
    auto malformedEnvelope = request(uuidFor(15), generation);
    std::get<lorkhan::TurnRequest>(malformedEnvelope.payload).ids.profile = lorkhan::ProfileId("PROFILE");
    CHECK(!bridge.enqueue(std::move(malformedEnvelope)));
    lorkhan::EnvelopeIds initIds{lorkhan::InstallationId(kInstallation), lorkhan::ProfileId(kProfile),
        lorkhan::PlaythroughId(kPlaythrough), {}, lorkhan::RequestId(uuidFor(13)), lorkhan::TurnId(kTurn),
        lorkhan::MessageId(kMessage), generation};
    lorkhan::OutboundRequest init{lorkhan::RequestId(uuidFor(13)), {}, generation, lorkhan::RequestKind::init,
        lorkhan::InitRequest{std::move(initIds), {}, "sha256:test", "2026-07-18T20:00:00Z"}};
    CHECK(bridge.enqueue(std::move(init)));
    CHECK(bridge.enqueue(request(uuidFor(16), generation)));
    CHECK(!bridge.enqueue(request(uuidFor(16), generation)));
    for (int tries = 0; tries < 10000 && state->executions.load() < 2; ++tries)
        std::this_thread::yield();
    CHECK(state->executions == 2);
    state->block = true;
    CHECK(bridge.enqueue(request(uuidFor(17), generation)));
    for (int tries = 0; tries < 10000 && state->executions.load() < 3; ++tries)
        std::this_thread::yield();
    CHECK(bridge.cancel(lorkhan::RequestId(uuidFor(17))));
    bool sawCancelled = false;
    for (int tries = 0; tries < 10000 && !sawCancelled; ++tries) {
        for (const auto& result : bridge.poll(8))
            sawCancelled = sawCancelled || (result.request == lorkhan::RequestId(uuidFor(17))
                && result.kind == lorkhan::ResponseKind::cancelled);
        std::this_thread::yield();
    }
    CHECK(sawCancelled);
    state->block = true;
    CHECK(bridge.enqueue(request(uuidFor(21), generation)));
    for (int tries = 0; tries < 10000 && state->executions.load() < 4; ++tries)
        std::this_thread::yield();
    CHECK(bridge.enqueue(request(uuidFor(22), generation)));
    const auto interruptsBeforeQueuedCancel = state->interrupts.load();
    CHECK(bridge.cancel(lorkhan::RequestId(uuidFor(22))));
    CHECK(state->interrupts.load() == interruptsBeforeQueuedCancel);
    state->block = false;
    auto next = bridge.cancelGeneration(generation);
    CHECK(next && next.value() == lorkhan::Generation(generation.value() + 1));
    CHECK(!bridge.enqueue(request(uuidFor(18), generation)));
    CHECK(bridge.enqueue(request(uuidFor(19), bridge.generation())));
    bridge.halt();
    CHECK(bridge.halted());
    CHECK(!bridge.enqueue(request(uuidFor(20), bridge.generation())));
}

struct SpeechTransportState {
    std::mutex mutex;
    std::vector<lorkhan::OutboundRequest> executed;
    std::atomic<unsigned> started{0};
    std::atomic<bool> holdSpeech{true};
};

// Holds speech until cancelled, like a provider still synthesizing, and fails every cancel acknowledgement.
class SpeechTransport final : public lorkhan::ITransport {
public:
    explicit SpeechTransport(std::shared_ptr<SpeechTransportState> state) : m_state(std::move(state)) {}
    lorkhan::Result<lorkhan::InboundResult> execute(
        const lorkhan::OutboundRequest& request, std::stop_token cancellation) override
    {
        {
            std::lock_guard lock(m_state->mutex);
            m_state->executed.push_back(request);
        }
        ++m_state->started;
        const bool speech = request.kind == lorkhan::RequestKind::menu_dialogue_tts
            || request.kind == lorkhan::RequestKind::book_read_aloud;
        while (speech && m_state->holdSpeech.load() && !cancellation.stop_requested())
            std::this_thread::sleep_for(1ms);
        if (cancellation.stop_requested())
            return lorkhan::Result<lorkhan::InboundResult>::failure(lorkhan::makeError(lorkhan::ErrorCode::cancelled, "cancelled"));
        if (request.kind == lorkhan::RequestKind::menu_dialogue_tts_cancel)
            return lorkhan::Result<lorkhan::InboundResult>::failure(
                lorkhan::makeError(lorkhan::ErrorCode::provider_unavailable, "cancel acknowledgement lost"));
        return lorkhan::Result<lorkhan::InboundResult>::success(
            {request.id, request.session, request.generation, lorkhan::ResponseKind::completed, "{}", std::nullopt});
    }
    void interrupt(const lorkhan::RequestId&) noexcept override {}
private:
    std::shared_ptr<SpeechTransportState> m_state;
};

template <class Predicate>
bool waitUntil(Predicate predicate)
{
    const auto deadline = std::chrono::steady_clock::now() + 2s;
    while (!predicate()) {
        if (std::chrono::steady_clock::now() >= deadline)
            return false;
        std::this_thread::sleep_for(1ms);
    }
    return true;
}

void testBridgeSpeechCancel()
{
    auto state = std::make_shared<SpeechTransportState>();
    auto clock = std::make_shared<FakeClock>();
    clock->system = std::chrono::system_clock::time_point(std::chrono::seconds(1784404800));
    lorkhan::BridgeService bridge(std::make_unique<SpeechTransport>(state), clock);
    const auto generation = bridge.generation();
    const auto menu = [&](unsigned request, unsigned message) {
        return lorkhan::OutboundRequest{lorkhan::RequestId(uuidFor(request)), lorkhan::SessionId(kSession), generation,
            lorkhan::RequestKind::menu_dialogue_tts, lorkhan::MenuDialogueTtsRequest{lorkhan::MessageId(uuidFor(message)),
                {lorkhan::RequestId(uuidFor(request)), lorkhan::SessionId(kSession), generation},
                "2026-07-18T20:00:00Z", protocolIdentity(), "Speculative topic text."}};
    };
    const auto executed = [&] {
        std::lock_guard lock(state->mutex);
        return state->executed;
    };
    const auto cancels = [&] {
        std::vector<lorkhan::MenuDialogueTtsCancelRequest> found;
        for (const auto& request : executed())
            if (const auto* cancel = std::get_if<lorkhan::MenuDialogueTtsCancelRequest>(&request.payload))
                found.push_back(*cancel);
        return found;
    };
    const auto idle = [&] { const auto d = bridge.diagnostics(); return d.outbound == 0 && d.active == 0; };

    lorkhan::OutboundRequest selfCancel{lorkhan::RequestId(uuidFor(30)), lorkhan::SessionId(kSession), generation,
        lorkhan::RequestKind::menu_dialogue_tts_cancel, lorkhan::MenuDialogueTtsCancelRequest{lorkhan::MessageId(uuidFor(31)),
            {lorkhan::RequestId(uuidFor(30)), lorkhan::SessionId(kSession), generation}, "2026-07-18T20:00:00Z",
            lorkhan::MessageId(uuidFor(31))}};
    CHECK(!bridge.enqueue(std::move(selfCancel)));

    // In flight: the server is told which message to abandon; only the target's cancellation reaches Lua.
    CHECK(bridge.enqueue(menu(40, 41)));
    CHECK(waitUntil([&] { return state->started.load() == 1; }));
    CHECK(bridge.cancel(lorkhan::RequestId(uuidFor(40))));
    CHECK(waitUntil([&] { return cancels().size() == 1 && idle(); }));
    const auto all = executed();
    CHECK(all.size() == 2 && all[1].kind == lorkhan::RequestKind::menu_dialogue_tts_cancel);
    if (all.size() == 2) {
        const auto& sent = std::get<lorkhan::MenuDialogueTtsCancelRequest>(all[1].payload);
        CHECK(sent.target == lorkhan::MessageId(uuidFor(41)) && sent.message != sent.target
            && lorkhan::isCanonicalUuid(sent.message.value()) && lorkhan::isCanonicalUuid(all[1].id.value())
            && all[1].id != lorkhan::RequestId(uuidFor(40)) && sent.correlation.request == all[1].id
            && all[1].session == lorkhan::SessionId(kSession) && sent.correlation.session == all[1].session
            && all[1].generation == generation && sent.correlation.generation == generation
            && sent.createdAt == "2026-07-18T20:00:00Z");
    }
    std::vector<lorkhan::InboundResult> results;
    CHECK(waitUntil([&] { for (auto& item : bridge.poll(16)) results.push_back(std::move(item)); return !results.empty(); }));
    std::this_thread::sleep_for(20ms);
    for (auto& item : bridge.poll(16)) results.push_back(std::move(item));
    CHECK(results.size() == 1 && results[0].request == lorkhan::RequestId(uuidFor(40))
        && results[0].kind == lorkhan::ResponseKind::cancelled);

    // Queued speech was never sent, so it needs no server cancel; the active one still does.
    CHECK(bridge.enqueue(menu(42, 43)));
    CHECK(waitUntil([&] { return state->started.load() == 3; }));
    CHECK(bridge.enqueue(menu(44, 45)));
    CHECK(bridge.cancel(lorkhan::RequestId(uuidFor(44))));
    CHECK(bridge.cancel(lorkhan::RequestId(uuidFor(42))));
    CHECK(waitUntil([&] { return cancels().size() == 2 && idle(); }));
    CHECK(cancels().size() == 2 && cancels()[1].target == lorkhan::MessageId(uuidFor(43)));
    for (const auto& request : executed())
        CHECK(request.id != lorkhan::RequestId(uuidFor(44)));
    static_cast<void>(bridge.poll(16));

    // Completed speech already has media and nothing left to stop.
    state->holdSpeech = false;
    CHECK(bridge.enqueue(menu(46, 47)));
    CHECK(waitUntil([&] { return state->started.load() == 5 && idle(); }));
    std::this_thread::sleep_for(10ms);
    CHECK(!bridge.cancel(lorkhan::RequestId(uuidFor(46))));
    std::this_thread::sleep_for(20ms);
    CHECK(cancels().size() == 2);
    static_cast<void>(bridge.poll(16));

    // Book read-aloud uses the same server cancel route.
    state->holdSpeech = true;
    CHECK(bridge.enqueue({lorkhan::RequestId(uuidFor(48)), lorkhan::SessionId(kSession), generation,
        lorkhan::RequestKind::book_read_aloud, lorkhan::BookReadAloudRequest{lorkhan::MessageId(uuidFor(49)),
            {lorkhan::RequestId(uuidFor(48)), lorkhan::SessionId(kSession), generation},
            "2026-07-18T20:00:00Z", "bk_fixture", "Fixture", "One page."}}));
    CHECK(waitUntil([&] { return state->started.load() == 6; }));
    CHECK(bridge.cancel(lorkhan::RequestId(uuidFor(48))));
    CHECK(waitUntil([&] { return cancels().size() == 3 && idle(); }));
    CHECK(cancels().size() == 3 && cancels()[2].target == lorkhan::MessageId(uuidFor(49)));

    // A superseded generation is fenced by the server session itself, so no stale cancel is sent.
    CHECK(bridge.enqueue(menu(50, 51)));
    CHECK(waitUntil([&] { return state->started.load() == 8; }));
    CHECK(bridge.cancelGeneration(generation));
    CHECK(waitUntil(idle));
    std::this_thread::sleep_for(20ms);
    CHECK(cancels().size() == 3);
    bridge.halt();
}

void testVoiceCapturePrimitives()
{
    const std::string abc = "abc";
    CHECK(lorkhan::sha256Hex(std::as_bytes(std::span(abc.data(), abc.size())))
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    const std::array pcm{std::byte{0x00}, std::byte{0x00}, std::byte{0xff}, std::byte{0x7f}};
    const auto wav = lorkhan::makePcm16MonoWav(pcm);
    CHECK(wav.size() == 48);
    CHECK(std::to_integer<char>(wav[0]) == 'R' && std::to_integer<char>(wav[8]) == 'W');
    CHECK(std::to_integer<unsigned>(wav[40]) == 4U && wav[44] == pcm[0] && wav[47] == pcm[3]);
    CHECK(lorkhan::makePcm16MonoWav(std::span<const std::byte>{}).empty());
    const std::array<std::byte, 8> silence{};
    const std::array<std::byte, 8> voice{std::byte{0x00},std::byte{0x10},std::byte{0x00},std::byte{0x10},
        std::byte{0x00},std::byte{0x10},std::byte{0x00},std::byte{0x10}};
    CHECK(!lorkhan::pcm16HasVoice(silence));
    CHECK(lorkhan::pcm16HasVoice(voice));
#ifndef _WIN32
    auto& capture = lorkhan::VoiceCaptureService::instance();
    CHECK(!capture.supported());
    CHECK(capture.state() == lorkhan::VoiceCaptureState::unsupported);
    CHECK(capture.currentDeviceName() == "Unavailable");
    CHECK(!capture.start());
#endif
}

void testRecordProvenance()
{
    lorkhan::RecordProvenance record;
    record.observe("Morrowind.esm"); record.observe("Patch.esp"); record.observe("Patch.esp");
    CHECK(record.complete && record.files.size() == 2 && record.winningFile == "Patch.esp");
    for (int i = 0; i < 130; ++i) record.observe("Override" + std::to_string(i) + ".esp");
    CHECK(!record.complete && record.files.size() == 128 && record.winningFile == "Override129.esp");
    record.observe("../private.esp"); CHECK(record.winningFile.empty() && !record.complete);
    record.observe("unsafe:mod.esp"); CHECK(record.winningFile.empty());
    record.observe("bad\nmod.esp"); CHECK(record.winningFile.empty());
    record.observe("Final.esp"); CHECK(!record.complete && record.winningFile == "Final.esp");
}

// actor.identity.dynamic.v1 is additive: placed identities parse unchanged and the sentinel never aliases one.
void testDynamicActorIdentity()
{
    const std::string dynamicActor = R"({"kind":"npc","record_id":"imperial guard","refnum":{"index":0,"content_file":0},"content_file":"lorkhan:dynamic","cell":{"kind":"interior","name":"Office"},"display_name":"Guard","dynamic":{"uuid":"01900000-0000-7000-8000-0000000000d1","runtime_ref":"@0x1f"}})";
    const auto placed = lorkhan::parseProtocolIdentity(protocolIdentity());
    CHECK(placed && !placed.value().dynamic && placed.value().refnumIndex == 112);
    const auto parsed = lorkhan::parseProtocolIdentity(dynamicActor);
    CHECK(parsed && parsed.value().dynamic && parsed.value().dynamic->uuid == "01900000-0000-7000-8000-0000000000d1"
        && parsed.value().dynamic->runtimeRef == "@0x1f" && parsed.value().dynamic->runtimeIndex == 0x1fU);
    const auto maximum = lorkhan::parseProtocolIdentity(std::string(dynamicActor).replace(dynamicActor.find("@0x1f"), 5, "@0xffffffff"));
    CHECK(maximum && maximum.value().dynamic->runtimeIndex == 0xffffffffU);
    for (const auto& [from, to] : std::vector<std::pair<std::string, std::string>>{
             {"@0x1f", "@0x01f"}, {"@0x1f", "@0x0"}, {"@0x1f", "@0x1F"}, {"@0x1f", "0x1f"}, {"@0x1f", "@0x100000000"},
             {"0000000000d1", "0000000000D1"}, {"01900000-0000-7000-8000-0000000000d1", "00000000-0000-0000-0000-000000000000"},
             {"\"runtime_ref\"", "\"extra\":1,\"runtime_ref\""},
             {"\"index\":0", "\"index\":31"}, {"\"lorkhan:dynamic\"", "\"Morrowind.esm\""}, {"\"kind\":\"npc\"", "\"kind\":\"player\""}}) {
        auto changed = dynamicActor; changed.replace(changed.find(from), from.size(), to);
        CHECK(!lorkhan::parseProtocolIdentity(changed));
    }
    auto sentinel = protocolIdentity(); sentinel.replace(sentinel.find("Morrowind.esm"), 13, "lorkhan:dynamic");
    CHECK(!lorkhan::parseProtocolIdentity(sentinel));
    const auto dynamicProfile = std::string("dyn:") + kInstallation + ":" + kPlaythrough + ":01900000-0000-7000-8000-0000000000d1";
    CHECK(lorkhan::isProfileId(dynamicProfile));
    CHECK(!lorkhan::isProfileId(dynamicProfile + "0"));
    // Nil is rejected only as the dynamic actor UUID; generic UUID and dyn scope semantics are unchanged.
    const std::string nilUuid = "00000000-0000-0000-0000-000000000000";
    CHECK(!lorkhan::isDynamicActorUuid(nilUuid) && lorkhan::isCanonicalUuid(nilUuid));
    CHECK(!lorkhan::isProfileId(std::string("dyn:") + kInstallation + ":" + kPlaythrough + ":" + nilUuid));
    CHECK(lorkhan::isProfileId(std::string("dyn:") + nilUuid + ":" + nilUuid + ":01900000-0000-7000-8000-0000000000d1"));
    CHECK(!lorkhan::isProfileId(std::string("dyn:") + kInstallation + ":" + kPlaythrough + ":@0x1f"));
    CHECK(lorkhan::kDynamicActorIdentityCapability == "actor.identity.dynamic.v1");
}

void testSavedCharacterIdentity()
{
    unsigned sequence=50;
    auto generate=[&]{return uuidFor(sequence++);};
    lorkhan::CharacterSessionIdentity first;
    first.prepare(true,"","","",kPlaythrough,generate);
    const auto firstCharacter=first.character,firstPlaythrough=first.playthrough;
    CHECK(first.selected() && first.binding=="new" && first.playthrough!=kPlaythrough);
    lorkhan::CharacterSessionIdentity second;
    second.prepare(true,"","","",kPlaythrough,generate);
    CHECK(second.character!=firstCharacter && second.playthrough!=firstPlaythrough);
    first.clear();first.prepare(false,firstCharacter,firstPlaythrough,"new",kPlaythrough,generate);
    CHECK(first.selected() && first.character==firstCharacter && first.playthrough==firstPlaythrough);
    first.clear();first.prepare(false,"",kPlaythrough,"",kPlaythrough,generate);
    CHECK(!first.selected() && first.legacyPlaythrough==kPlaythrough);
    const auto pendingCharacter=first.character;
    first.clear();first.prepare(false,pendingCharacter,kPlaythrough,"",kPlaythrough,generate);
    CHECK(!first.selected() && first.character==pendingCharacter);
    try{first.choose(second.character,"existing",generate);CHECK(false);}catch(const std::invalid_argument&){}
    first.choose(pendingCharacter,"existing",generate);const auto allocated=sequence;
    first.choose(pendingCharacter,"existing",generate);
    CHECK(first.playthrough==kPlaythrough && first.binding=="existing" && sequence==allocated);
    try{first.choose(pendingCharacter,"new",generate);CHECK(false);}catch(const std::invalid_argument&){}
    first.clear();first.prepare(false,"","","",kPlaythrough,generate);first.choose(first.character,"new",generate);
    CHECK(first.selected() && first.playthrough!=kPlaythrough);
    first.clear();
    try{first.prepare(false,"bad",kPlaythrough,"existing",kPlaythrough,generate);CHECK(false);}catch(const std::invalid_argument&){}
    CHECK(!first.prepared);
}

void testPlaybackSettings()
{
    lorkhan::PlaybackSettings settings;
    CHECK(lorkhan::validPlayback(settings));
    CHECK(lorkhan::playbackGain(settings,100,10,100,false,false)==0);
    CHECK(lorkhan::playbackGain(settings,100,10,100,false,true)==1);
    settings.voiceVolumePercent=0;
    CHECK(lorkhan::playbackGain(settings,0,10,100,false,false)==0);
    settings.voiceVolumePercent=100;settings.headVoiceVolumePercent=50;
    CHECK(lorkhan::playbackGain(settings,100,10,100,false,true)==.5f);
    settings.audioMode=2;settings.dropoffInsidePercent=200;settings.dropoffOutsidePercent=100;
    CHECK(lorkhan::playbackGain(settings,55,10,100,false,false)==.25f);
    CHECK(lorkhan::playbackGain(settings,55,10,100,true,false)==.5f);
    settings.audioMode=3;
    CHECK(lorkhan::playbackGain(settings,1000,10,100,false,false)==1);
    settings.distanceScale=std::numeric_limits<float>::infinity();
    CHECK(!lorkhan::validPlayback(settings));
    CHECK(lorkhan::clipFrames(44100,100)==4410);
    CHECK(lorkhan::clipFrames(48000,2000)==96000);
    lorkhan::PlaybackClipWindow window(3,2);
    window.append("ab",2); CHECK(window.available()==0);
    window.append("cdef",4); CHECK(window.available()==1);
    char result[16]{}; CHECK(window.read(result,16)==1 && result[0]=='d');
    window.append("ghi",3); CHECK(window.read(result,16)==3 && std::string(result,3)=="efg");
    CHECK(window.read(result,16)==0);
    lorkhan::PlaybackClipWindow shortClip(100,200);
    shortClip.append("abc",3); CHECK(shortClip.available()==0);
    CHECK(lorkhan::lipAmplitude(.75f,2)==1 && lorkhan::lipAmplitude(.5f,.5f)==.25f);
    CHECK(lorkhan::validConnectionTimeout(15) && lorkhan::validConnectionTimeout(300));
    CHECK(!lorkhan::validConnectionTimeout(14) && !lorkhan::validConnectionTimeout(301));
}

void testClientConfigPath()
{
    const auto root = std::filesystem::temp_directory_path() / "lorkhan-config-path-test";
    std::filesystem::create_directories(root / "OpenMW");
    std::filesystem::create_directories(root / "Config");
    std::ofstream(root / "Config" / "lorkhan-client.conf") << "test";
    CHECK(lorkhan::clientConfigPath("", root / "OpenMW") == root / "Config" / "lorkhan-client.conf");
    CHECK(lorkhan::clientConfigPath("explicit-missing.conf", root / "OpenMW") == "explicit-missing.conf");
    std::filesystem::remove(root / "Config" / "lorkhan-client.conf");
    std::ofstream(root / "OpenMW" / "lorkhan-client.conf") << "test";
    CHECK(lorkhan::clientConfigPath("", root / "OpenMW") == root / "OpenMW" / "lorkhan-client.conf");
    std::filesystem::remove(root / "OpenMW" / "lorkhan-client.conf");
    bool rejected = false;
    try { (void)lorkhan::clientConfigPath("", root / "OpenMW"); }
    catch (const std::runtime_error&) { rejected = true; }
    CHECK(rejected);
}

void testConcurrency()
{
    auto state = std::make_shared<TransportState>();
    auto clock = std::make_shared<FakeClock>();
    lorkhan::BridgeService bridge(std::make_unique<FakeTransport>(state), clock);
    const auto generation = bridge.generation();
    std::atomic<unsigned> accepted{0};
    std::vector<std::jthread> producers;
    for (unsigned thread = 0; thread < 8; ++thread) {
        producers.emplace_back([&, thread] {
            for (unsigned i = 0; i < 20; ++i)
                if (bridge.enqueue(request(uuidFor(32 + thread * 20 + i), generation)))
                    ++accepted;
        });
    }
    producers.clear();
    for (unsigned spins = 0; spins < 10000 && state->executions.load() < accepted.load(); ++spins)
        std::this_thread::yield();
    CHECK(accepted <= 160);
    bridge.halt();
}

} // namespace

// Plugin messages are canonical and session-bound; plugin.action.intent is exact before Lua sees it.
void testPluginContract()
{
    const lorkhan::Headers jsonHeaders{{"Content-Type", "application/json; charset=utf-8"}};
    const std::string session = "00000000-0000-4000-8000-000000000007";
    const std::string actor = R"({"cell":{"grid_x":-2,"grid_y":-9,"kind":"exterior"},"content_file":"Morrowind.esm","display_name":"Fargoth","kind":"npc","record_id":"fargoth","refnum":{"content_file":0,"index":112}})";
    const lorkhan::RequestCorrelation registrationIds{lorkhan::RequestId("00000000-0000-4000-8000-000000000302"),
        lorkhan::SessionId(session), lorkhan::Generation(7)};
    const lorkhan::MessageId registrationMessage("00000000-0000-4000-8000-000000000301");
    const std::string registration = R"({"actions":[{"actors":[)" + actor + R"(],"confirmation":"none","executor_kinds":["npc"],"name":"fetch_water","tier":1},{"confirmation":"required","executor_kinds":["npc"],"name":"share_meal","tier":2}],"events":["meal_shared"],"manifest_sha256":"5f1c1a3b0e8f7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a392817060504","plugin_id":"ashlander.camp_tasks","prompt_slots":["scene_notes"],"version":"1.2.0"})";
    const auto registrationMessageJson = [&](const std::string& plugin, const std::string& operation = "register") {
        return R"({"created_at":"2026-10-02T12:00:00Z","generation":7,"message_id":"00000000-0000-4000-8000-000000000301","operation":")"
            + operation + R"(","plugins":[)" + plugin + R"(],"request_id":"00000000-0000-4000-8000-000000000302","schema":"lorkhan.plugin.registration.v1","session_id":")"
            + session + "\"}";
    };
    auto canonical = lorkhan::canonicalPluginRegistration(registrationMessageJson(registration), registrationIds, registrationMessage);
    CHECK(canonical && canonical.value() == registrationMessageJson(registration));
    const auto rejectsRegistration = [&](const std::string& message) {
        return !lorkhan::canonicalPluginRegistration(message, registrationIds, registrationMessage);
    };
    const auto replaced = [](std::string value, const std::string& from, const std::string& to) {
        return value.replace(value.find(from), from.size(), to);
    };
    CHECK(rejectsRegistration(registrationMessageJson(replaced(registration, "ashlander.", "lorkhan."))));
    CHECK(rejectsRegistration(registrationMessageJson(replaced(registration, R"("required","executor_kinds":["npc"],"name":"share_meal")", R"("none","executor_kinds":["npc"],"name":"share_meal")"))));
    CHECK(rejectsRegistration(registrationMessageJson(replaced(registration, R"("events":)", R"("command":"tgm","events":)"))));
    for (const std::string version : {"1.2.0.4", "1.2.0.", "1.2", "01.2.0"})
        CHECK(rejectsRegistration(registrationMessageJson(replaced(registration, R"("1.2.0")", "\"" + version + "\""))));
    CHECK(rejectsRegistration(registrationMessageJson(registration, "unregister")));
    CHECK(rejectsRegistration(registrationMessageJson(registration + "," + registration)));
    CHECK(lorkhan::canonicalPluginRegistration(registrationMessageJson(R"({"plugin_id":"ashlander.camp_tasks","version":"1.2.0"})", "unregister"), registrationIds, registrationMessage));
    auto stale = lorkhan::canonicalPluginRegistration(registrationMessageJson(registration),
        {registrationIds.request, registrationIds.session, lorkhan::Generation(8)}, registrationMessage);
    CHECK(!stale && stale.error().code == lorkhan::ErrorCode::stale_generation);
    CHECK(!lorkhan::canonicalPluginRegistration(registrationMessageJson(registration), registrationIds, lorkhan::MessageId(kMessage)));
    auto oversized = lorkhan::canonicalPluginRegistration(registrationMessageJson(registration) + std::string(64U * 1024U, ' '),
        registrationIds, registrationMessage);
    CHECK(!oversized && oversized.error().code == lorkhan::ErrorCode::payload_too_large);

    const lorkhan::RequestCorrelation eventIds{lorkhan::RequestId("00000000-0000-4000-8000-000000000321"),
        lorkhan::SessionId(session), lorkhan::Generation(7)};
    const lorkhan::MessageId eventMessage("00000000-0000-4000-8000-000000000320");
    const auto eventJson = [&](const std::string& fields) {
        return R"({"event":"meal_shared","fields":)" + fields + R"(,"generation":7,"message_id":"00000000-0000-4000-8000-000000000320","observed_at":"2026-10-02T12:05:00Z","plugin_id":"ashlander.camp_tasks","plugin_version":"1.2.0","request_id":"00000000-0000-4000-8000-000000000321","schema":"lorkhan.plugin.event.v1","session_id":")"
            + session + "\"}";
    };
    const std::string fields = R"({"dish":"Scuttle pie","host":)" + actor + R"(,"servings":2.5})";
    auto event = lorkhan::canonicalPluginEvent(eventJson(fields), eventIds, eventMessage);
    CHECK(event && event.value() == eventJson(fields));
    auto empty = lorkhan::canonicalPluginEvent(eventJson("[]"), eventIds, eventMessage);
    CHECK(empty && empty.value() == eventJson("{}"));
    const auto rejectsEvent = [&](const std::string& eventFields) {
        return !lorkhan::canonicalPluginEvent(eventJson(eventFields), eventIds, eventMessage);
    };
    const std::string controlText = R"({"dish":"Scuttle\npie"})";
    const std::string longText = R"({"dish":")" + std::string(513, 'x') + R"("})";
    const std::string oversizedEvent = R"({"dish":")" + std::string(16U * 1024U, 'x') + R"("})";
    CHECK(rejectsEvent(controlText));
    // Unicode Cc includes C1 U+0080..U+009F, escaped or raw; U+00A0 is the first allowed code point after it.
    CHECK(rejectsEvent("{\"dish\":\"Scuttle\\u0085pie\"}"));
    CHECK(rejectsEvent("{\"dish\":\"Scuttle\xc2\x9fpie\"}"));
    CHECK(!rejectsEvent("{\"dish\":\"Scuttle\\u00a0pie\"}"));
    CHECK(rejectsEvent(longText));
    CHECK(rejectsEvent(R"({"Dish":"pie"})"));
    CHECK(rejectsEvent(oversizedEvent));

    CHECK(lorkhan::parsePluginRegistrationAcceptedResponse(R"({"schema":"lorkhan.plugin.registration.accepted.v1","message_id":"00000000-0000-4000-8000-000000000301","request_id":"00000000-0000-4000-8000-000000000302","session_id":"00000000-0000-4000-8000-000000000007","generation":7,"plugins":[{"plugin_id":"ashlander.camp_tasks","version":"1.2.0","state":"active","reason_code":"registered"}]})", jsonHeaders));
    CHECK(!lorkhan::parsePluginRegistrationAcceptedResponse(R"({"schema":"lorkhan.plugin.registration.accepted.v1","message_id":"00000000-0000-4000-8000-000000000301","request_id":"00000000-0000-4000-8000-000000000302","session_id":"00000000-0000-4000-8000-000000000007","generation":7,"plugins":[{"plugin_id":"ashlander.camp_tasks","version":"1.2.0","state":"loaded","reason_code":"registered"}]})", jsonHeaders));
    auto eventAccepted = lorkhan::parsePluginEventAcceptedResponse(R"({"schema":"lorkhan.plugin.event.accepted.v1","message_id":"00000000-0000-4000-8000-000000000320","request_id":"00000000-0000-4000-8000-000000000321","session_id":"00000000-0000-4000-8000-000000000007","generation":7,"duplicate":true})", jsonHeaders);
    CHECK(eventAccepted && eventAccepted.value().duplicate);

    const auto intentEvents = [&](const std::string& intent) {
        return lorkhan::parseEventsResponse(R"({"schema":"lorkhan.events.v1","session_id":")" + session
            + R"(","generation":7,"next_after":4,"events":[{"message_id":"00000000-0000-4000-8000-000000000311","request_id":"00000000-0000-4000-8000-000000000010","turn_id":"00000000-0000-4000-8000-000000000008","session_id":")"
            + session + R"(","generation":7,"sequence":4,"created_at":"2026-10-02T12:00:00Z","type":"plugin.action.intent","payload":)"
            + intent + "}],\"autonomy\":[]}", jsonHeaders);
    };
    const std::string intent = R"({"schema":"lorkhan.plugin.action-intent.v1","action_id":"00000000-0000-4000-8000-000000000310","turn_id":"00000000-0000-4000-8000-000000000008","session_id":")"
        + session + R"(","generation":7,"plugin_id":"ashlander.camp_tasks","plugin_version":"1.2.0","action":"fetch_water","tier":1,"confirmation_required":false,"cancellable":true,"actor":)"
        + actor + R"(,"target":null,"parameters":{"trips":2,"vessel":"jug"},"expires_at":"2026-10-02T12:02:00Z"})";
    auto decoded = intentEvents(intent);
    const auto* plugin = decoded ? std::get_if<lorkhan::PluginActionIntentEventPayload>(&decoded.value().events[0].payload) : nullptr;
    CHECK(plugin && decoded.value().events[0].type == lorkhan::ProtocolEventType::plugin_action_intent
        && plugin->intent.pluginId == "ashlander.camp_tasks" && plugin->intent.name == "fetch_water"
        && !plugin->intent.target && plugin->intent.parameters.size() == 2
        && std::get<std::int64_t>(plugin->intent.parameters[0].second) == 2
        && std::get<std::string>(plugin->intent.parameters[1].second) == "jug");
    CHECK(!intentEvents(replaced(intent, R"("jug")", R"("https://example.invalid/payload.lua")")));
    CHECK(!intentEvents(replaced(intent, R"("cancellable":true,)", R"("cancellable":true,"command":"tgm",)")));
    CHECK(!intentEvents(replaced(intent, R"("generation":7,"plugin_id")", R"("generation":6,"plugin_id")")));
    CHECK(!intentEvents(replaced(intent, R"("tier":1)", R"("tier":2)")));
    CHECK(!intentEvents(replaced(intent, R"("1.2.0")", R"("1.2.0.4")")));
    CHECK(!intentEvents(replaced(intent, R"("schema":"lorkhan.plugin.action-intent.v1")", R"("schema":"lorkhan.action-intent.v1")")));
    CHECK(!intentEvents(replaced(intent, R"("kind":"npc")", R"("kind":"player")")));

    // The bridge accepts only the canonical message whose IDs match the typed request.
    lorkhan::BridgeService bridge(std::make_unique<FakeTransport>(std::make_shared<TransportState>()),
        std::make_shared<FakeClock>(), lorkhan::Generation(7));
    const auto pluginRequest = [&](std::string message) {
        return lorkhan::OutboundRequest{eventIds.request, eventIds.session, eventIds.generation, lorkhan::RequestKind::plugin_event,
            lorkhan::PluginEventRequest{{eventMessage, eventIds, std::move(message)}}};
    };
    CHECK(!bridge.enqueue(pluginRequest(eventJson("[]"))));
    auto wrongKind = pluginRequest(eventJson(fields));
    wrongKind.kind = lorkhan::RequestKind::plugin_registration;
    CHECK(!bridge.enqueue(std::move(wrongKind)));
    CHECK(bridge.enqueue(pluginRequest(eventJson(fields))));
}

// Scripted server half for runPluginPackageSync: no socket, every step recorded.
class FakePackageWire final : public lorkhan::IPluginPackageWire {
public:
    using Probe = lorkhan::PluginPackageProbe;
    using Upload = lorkhan::PluginPackageUpload;
    using Operation = lorkhan::PluginPackageOperation;
    using State = lorkhan::PluginPackageOperationState;

    lorkhan::Result<Probe> probe(std::string_view pluginId, std::string_view version, std::string_view sha256) override
    {
        probeCalls.push_back(std::string(pluginId) + "|" + std::string(version) + "|" + std::string(sha256));
        if (transportFailure) return lorkhan::Result<Probe>::failure(*transportFailure);
        return lorkhan::Result<Probe>::success(probes[std::min(probeCalls.size(), probes.size()) - 1]);
    }
    lorkhan::Result<Upload> startUpload(std::string_view, std::string_view, std::uint64_t size, std::string_view sha) override
    {
        declaredSize = size;
        declaredSha = std::string(sha);
        if (startError) return lorkhan::Result<Upload>::failure(*startError);
        return lorkhan::Result<Upload>::success({kUpload, 0, 0, chunkBytes, false});
    }
    lorkhan::Result<Upload> putChunk(std::string_view uploadId, std::uint64_t index, std::span<const std::byte> bytes) override
    {
        ++chunkAttempts;
        if (cancelOnChunk && index == 1) cancelOnChunk->request_stop();
        if (rateLimitedChunks > 0) {
            --rateLimitedChunks;
            return lorkhan::Result<Upload>::failure(lorkhan::makeError(lorkhan::ErrorCode::rate_limited, "rate_limited",
                true, 1, std::string(kSyncRequest)));
        }
        CHECK(uploadId == kUpload && index == chunkIndexes.size());
        chunkIndexes.push_back(index);
        uploaded.append(reinterpret_cast<const char*>(bytes.data()), bytes.size());
        return lorkhan::Result<Upload>::success({kUpload, index + 1, uploaded.size(), 0, uploaded.size() == declaredSize});
    }
    lorkhan::Result<Operation> submit(bool update, const lorkhan::RequestId& request, std::string_view uploadId, std::string_view expectedManifestSha256) override
    {
        submitted.push_back(std::string(update ? "update|" : "install|") + request.value() + "|" + std::string(uploadId));
        if (submitError) return lorkhan::Result<Operation>::failure(*submitError);
        return lorkhan::Result<Operation>::success(operationAt(0, update));
    }
    lorkhan::Result<Operation> operation(std::string_view operationId) override
    {
        CHECK(operationId == kOperation);
        ++operationPolls;
        return lorkhan::Result<Operation>::success(operationAt(operationPolls, submitted.back().starts_with("update")));
    }

    Operation operationAt(std::size_t index, bool update) const
    {
        const State state = states[std::min(index, states.size() - 1)];
        return {kOperation, "ashlander.camp_tasks", update, "1.2.0", declaredSha, state,
            state == State::failed ? std::optional<std::string>("package_checksum_mismatch") : std::nullopt};
    }

    static constexpr const char* kUpload = "00000000-0000-4000-8000-000000000501";
    static constexpr const char* kOperation = "00000000-0000-4000-8000-000000000500";
    static constexpr const char* kSyncRequest = "00000000-0000-4000-8000-000000000500";
    std::vector<Probe> probes;
    std::vector<State> states{State::queued, State::succeeded};
    std::optional<lorkhan::Error> transportFailure;
    std::optional<lorkhan::Error> startError;
    std::optional<lorkhan::Error> submitError;
    std::stop_source* cancelOnChunk{};
    unsigned rateLimitedChunks{};
    std::uint64_t chunkBytes{lorkhan::kPluginPackageChunkBytes};
    std::vector<std::string> probeCalls;
    std::vector<std::string> submitted;
    std::vector<std::uint64_t> chunkIndexes;
    std::string uploaded;
    std::uint64_t declaredSize{};
    std::string declaredSha;
    unsigned chunkAttempts{};
    std::size_t operationPolls{};
};

void testPluginPackageSync()
{
    namespace fs = std::filesystem;
    using Action = lorkhan::PluginPackageProbeAction;
    using Status = lorkhan::PluginPackageSyncStatus;
    const lorkhan::Headers jsonHeaders{{"Content-Type", "application/json; charset=utf-8"}};
    const std::string id = "ashlander.camp_tasks";
    const std::string manifestSha(64, 'a');
    const fs::path base = fs::temp_directory_path() / "lorkhan-package-sync-tests";
    std::error_code ignored;
    fs::remove_all(base, ignored);
    const fs::path rootA = base / "data-a";
    const fs::path rootB = base / "data-b";
    const auto writePackage = [&](const fs::path& root, const std::string& version, const std::string& bytes) {
        const fs::path directory = root / "lorkhan-packages" / id;
        fs::create_directories(directory);
        std::ofstream(directory / (id + "-" + version + ".dwpkg"), std::ios::binary) << bytes;
        return directory / (id + "-" + version + ".dwpkg");
    };
    fs::create_directories(rootA);
    fs::create_directories(rootB);
    CHECK(lorkhan::pluginPackageRelativePath(id, "1.2.0") == "lorkhan-packages/ashlander.camp_tasks/ashlander.camp_tasks-1.2.0.dwpkg");

    // Override order follows the VFS: the later data root wins; an absent later file falls back.
    const std::string bytesA(30, 'A');
    const std::string bytesB(40, 'B');
    writePackage(rootA, "1.2.0", bytesA);
    const fs::path fileB = writePackage(rootB, "1.2.0", bytesB);
    const std::vector<std::string> roots{rootA.string(), rootB.string()};
    auto resolved = lorkhan::resolvePluginPackage(roots, id, "1.2.0");
    CHECK(resolved && resolved.value().bytes == 40 && resolved.value().path == fs::canonical(fileB));
    resolved = lorkhan::resolvePluginPackage({rootB.string(), rootA.string()}, id, "1.2.0");
    CHECK(resolved && resolved.value().bytes == 30);
    resolved = lorkhan::resolvePluginPackage({rootA.string(), (base / "absent").string(), rootB.string()}, id, "1.2.0");
    CHECK(resolved && resolved.value().bytes == 40);
    const auto reason = [](const auto& result) { return result ? std::string("ok") : result.error().message; };
    CHECK(reason(lorkhan::resolvePluginPackage(roots, id, "9.9.9")) == "package_not_found");
    CHECK(reason(lorkhan::resolvePluginPackage({"relative/data"}, id, "1.2.0")) == "package_roots_invalid");
    CHECK(reason(lorkhan::resolvePluginPackage({}, id, "1.2.0")) == "package_roots_invalid");
    for (const std::string hostile : {"lorkhan.core", "../evil.addon", "ashlander.camp_tasks/../x", "Ashlander.camp"})
        CHECK(reason(lorkhan::resolvePluginPackage(roots, hostile, "1.2.0")) == "package_identity_invalid");
    CHECK(reason(lorkhan::resolvePluginPackage(roots, id, "1.2.0/../../x")) == "package_identity_invalid");
    writePackage(rootB, "1.0.1", "tiny");
    CHECK(reason(lorkhan::resolvePluginPackage(roots, id, "1.0.1")) == "package_archive_invalid");
    const fs::path huge = writePackage(rootB, "1.0.2", "x");
    fs::resize_file(huge, lorkhan::kMaxPluginPackageBytes + 1);
    CHECK(reason(lorkhan::resolvePluginPackage(roots, id, "1.0.2")) == "package_too_large");
    fs::create_directories(rootB / "lorkhan-packages" / id / (id + "-1.0.3.dwpkg"));
    CHECK(reason(lorkhan::resolvePluginPackage(roots, id, "1.0.3")) == "package_not_regular");
    // A link anywhere below the root fails closed instead of falling back to a lower root.
    const fs::path outside = base / "outside";
    fs::create_directories(outside / id);
    std::ofstream(outside / id / (id + "-1.0.4.dwpkg"), std::ios::binary) << std::string(64, 'L');
    std::ofstream(outside / "target.dwpkg", std::ios::binary) << std::string(64, 'L');
    writePackage(rootA, "1.0.4", std::string(64, 'a'));
    std::error_code linkError;
    fs::create_symlink(outside / "target.dwpkg", rootB / "lorkhan-packages" / id / (id + "-1.0.4.dwpkg"), linkError);
    if (!linkError)
        CHECK(reason(lorkhan::resolvePluginPackage(roots, id, "1.0.4")) == "package_link_rejected");
    else
        std::cout << "file symlink creation unavailable; junction case still runs\n";
    const fs::path linkedRoot = base / "data-linked";
    fs::create_directories(linkedRoot);
#ifdef _WIN32
    const std::string junction = "mklink /J \"" + (linkedRoot / "lorkhan-packages").string() + "\" \"" + outside.string()
        + "\" >NUL 2>&1";
    const bool linked = std::system(junction.c_str()) == 0;
#else
    std::error_code directoryLinkError;
    fs::create_directory_symlink(outside, linkedRoot / "lorkhan-packages", directoryLinkError);
    const bool linked = !directoryLinkError;
#endif
    CHECK(linked);
    CHECK(reason(lorkhan::resolvePluginPackage({linkedRoot.string()}, id, "1.0.4")) == "package_link_rejected");

    // Strict package response parsers: closed keys and states, no paths, no contradictions.
    const std::string sha(64, 'b');
    const std::string package = R"({"plugin_id":"ashlander.camp_tasks","display_name":"Camp","version":"1.1.0","state":"installed","enabled":false,"archive_sha256":")"
        + sha + R"(","manifest_sha256":")" + manifestSha + R"(","previous_version":null,"revision":2,"installed_at":"2026-10-02 12:00:00+00","updated_at":"2026-10-02 12:00:00+00"})";
    auto probe = lorkhan::parsePluginPackageProbeResponse(R"({"plugin_id":"ashlander.camp_tasks","action":"update","pending":false,"installed":)" + package + "}", jsonHeaders);
    CHECK(probe && probe.value().action == Action::update && probe.value().installed && !probe.value().installed->enabled
        && probe.value().installed->version == "1.1.0");
    CHECK(lorkhan::parsePluginPackageProbeResponse(R"({"plugin_id":"ashlander.camp_tasks","action":"install","pending":true,"installed":null})", jsonHeaders));
    CHECK(!lorkhan::parsePluginPackageProbeResponse(R"({"plugin_id":"ashlander.camp_tasks","action":"current","pending":false,"installed":null})", jsonHeaders));
    CHECK(!lorkhan::parsePluginPackageProbeResponse(R"({"plugin_id":"ashlander.camp_tasks","action":"downgrade","pending":false,"installed":null})", jsonHeaders));
    CHECK(!lorkhan::parsePluginPackageProbeResponse(R"({"plugin_id":"ashlander.camp_tasks","action":"install","pending":false,"installed":null,"path":"/var/lib"})", jsonHeaders));
    CHECK(!lorkhan::parsePluginPackageProbeResponse(R"({"plugin_id":"other.plugin","action":"update","pending":false,"installed":)" + package + "}", jsonHeaders));
    CHECK(!lorkhan::parsePluginPackageProbeResponse(R"({"plugin_id":"ashlander.camp_tasks","action":"install","pending":false,"installed":null})", {}));
    CHECK(lorkhan::parsePluginPackageUploadResponse(R"({"upload_id":"00000000-0000-4000-8000-000000000501","next_index":0,"chunk_bytes":1048576,"complete":false})", jsonHeaders, true));
    CHECK(!lorkhan::parsePluginPackageUploadResponse(R"({"upload_id":"00000000-0000-4000-8000-000000000501","next_index":0,"chunk_bytes":2097152,"complete":false})", jsonHeaders, true));
    CHECK(!lorkhan::parsePluginPackageUploadResponse(R"({"upload_id":"00000000-0000-4000-8000-000000000501","next_index":1,"chunk_bytes":1048576,"complete":false})", jsonHeaders, true));
    auto chunk = lorkhan::parsePluginPackageUploadResponse(R"({"upload_id":"00000000-0000-4000-8000-000000000501","next_index":2,"received":2048,"complete":true})", jsonHeaders, false);
    CHECK(chunk && chunk.value().nextIndex == 2 && chunk.value().received == 2048 && chunk.value().complete);
    const auto operationJson = [&](const std::string& state, const std::string& error) {
        return R"({"operation":{"operation_id":"00000000-0000-4000-8000-000000000502","plugin_id":"ashlander.camp_tasks","operation":"update","version":"1.2.0","archive_sha256":")"
            + sha + R"(","state":")" + state + R"(","error_code":)" + error + R"(,"created_at":"2026-10-02 12:00:00+00","finished_at":null}})";
    };
    auto operation = lorkhan::parsePluginPackageOperationResponse(operationJson("failed", "\"package_checksum_mismatch\""), jsonHeaders);
    CHECK(operation && operation.value().update && operation.value().errorCode == "package_checksum_mismatch");
    CHECK(lorkhan::parsePluginPackageOperationResponse(operationJson("queued", "null"), jsonHeaders));
    CHECK(!lorkhan::parsePluginPackageOperationResponse(operationJson("failed", "null"), jsonHeaders));
    CHECK(!lorkhan::parsePluginPackageOperationResponse(operationJson("succeeded", "\"package_apply_failed\""), jsonHeaders));
    CHECK(!lorkhan::parsePluginPackageOperationResponse(operationJson("running", "null"), jsonHeaders));
    const auto errorJson = [](const std::string& code) {
        return R"({"schema":"lorkhan.error.v1","code":")" + code + R"(","message":"Package request rejected.","correlation_id":"00000000-0000-4000-8000-000000000500","retriable":true})";
    };
    auto busy = lorkhan::parsePluginPackageErrorResponse(errorJson("package_storage_busy"), jsonHeaders);
    CHECK(busy && busy.value().wireCode == "package_storage_busy" && busy.value().code == lorkhan::ErrorCode::provider_unavailable);
    CHECK(lorkhan::parsePluginPackageErrorResponse(errorJson("rate_limited"), jsonHeaders));
    CHECK(!lorkhan::parsePluginPackageErrorResponse(errorJson("package_anything"), jsonHeaders));
    CHECK(!lorkhan::parseProtocolErrorResponse(errorJson("package_storage_busy"), jsonHeaders));

    // The sync engine: probe first, upload only when needed, never downgrade or overwrite a conflict.
    std::string archive(2U * lorkhan::kPluginPackageChunkBytes + 4096U, '\0');
    for (std::size_t index = 0; index < archive.size(); ++index)
        archive[index] = static_cast<char>((index * 131U + 7U) & 0xffU);
    writePackage(rootB, "1.2.0", archive);
    const std::string archiveSha = lorkhan::sha256Hex(std::as_bytes(std::span(archive.data(), archive.size())));
    const lorkhan::RequestId syncRequest(FakePackageWire::kSyncRequest);
    const lorkhan::SessionId syncSession("00000000-0000-4000-8000-000000000007");
    const lorkhan::PluginPackageSyncRequest sync{{syncRequest, syncSession, lorkhan::Generation(7)}, id, "1.2.0", manifestSha, roots};
    lorkhan::PluginPackageSyncLimits limits;
    limits.pendingWait = 30ms;
    limits.operationWait = 60ms;
    limits.pollInterval = 2ms;
    limits.maximumPollInterval = 5ms;
    limits.maximumRetryAfter = 2ms;
    const auto installedRow = [&](const std::string& version, const std::string& archiveHash, bool enabled,
                                  const std::string& manifest) {
        return lorkhan::PluginPackageInfo{id, version, "installed", enabled, archiveHash, manifest};
    };
    const auto probeOf = [&](Action action, bool pending, std::optional<lorkhan::PluginPackageInfo> installed) {
        return lorkhan::PluginPackageProbe{id, action, pending, std::move(installed)};
    };
    const auto run = [&](FakePackageWire& wire, std::stop_token token = {}) {
        return lorkhan::runPluginPackageSync(sync, syncRequest, wire, token, limits);
    };
    {
        FakePackageWire wire;
        wire.probes = {probeOf(Action::current, false, installedRow("1.2.0", archiveSha, true, manifestSha))};
        auto outcome = run(wire);
        CHECK(outcome && outcome.value().status == Status::current && outcome.value().enabled == true
            && wire.declaredSize == 0 && wire.submitted.empty() && wire.probeCalls.size() == 1
            && wire.probeCalls[0] == id + "|1.2.0|" + archiveSha);
    }
    {
        FakePackageWire wire;
        wire.probes = {probeOf(Action::current, false, installedRow("1.2.0", archiveSha, true, std::string(64, 'c')))};
        auto outcome = run(wire);
        CHECK(outcome && outcome.value().status == Status::failed && outcome.value().reasonCode == "package_manifest_mismatch");
    }
    {
        FakePackageWire wire;
        wire.probes = {probeOf(Action::older, false, installedRow("2.0.0", sha, false, manifestSha))};
        auto outcome = run(wire);
        CHECK(outcome && outcome.value().status == Status::newer_installed && outcome.value().installedVersion == "2.0.0"
            && wire.declaredSize == 0 && wire.submitted.empty());
        wire.probes = {probeOf(Action::conflict, false, installedRow("1.2.0", sha, false, manifestSha))};
        outcome = run(wire);
        CHECK(outcome && outcome.value().status == Status::conflict && outcome.value().reasonCode == "package_version_conflict"
            && wire.declaredSize == 0 && wire.submitted.empty());
    }
    {
        FakePackageWire wire;
        wire.probes = {probeOf(Action::install, false, std::nullopt),
            probeOf(Action::current, false, installedRow("1.2.0", archiveSha, false, manifestSha))};
        wire.rateLimitedChunks = 1;
        auto outcome = run(wire);
        CHECK(outcome && outcome.value().status == Status::installed && outcome.value().reasonCode == "package_installed"
            && outcome.value().enabled == false && outcome.value().uploadedBytes == archive.size());
        CHECK(wire.uploaded == archive && wire.chunkIndexes == std::vector<std::uint64_t>({0, 1, 2})
            && wire.chunkAttempts == 4 && wire.declaredSha == archiveSha && wire.declaredSize == archive.size());
        CHECK(wire.submitted.size() == 1 && wire.submitted[0] == std::string("install|") + FakePackageWire::kSyncRequest + "|" + FakePackageWire::kUpload);
        CHECK(wire.operationPolls == 1 && wire.probeCalls.size() == 2);
        CHECK(lorkhan::serializePluginPackageSyncOutcome(outcome.value())
            == R"({"enabled":false,"installed_version":"1.2.0","plugin_id":"ashlander.camp_tasks","reason_code":"package_installed","status":"installed","uploaded_bytes":2101248,"version":"1.2.0"})");
    }
    {
        FakePackageWire wire;
        wire.chunkBytes = 1024U * 1024U - 1U;
        wire.probes = {probeOf(Action::update, false, installedRow("1.1.0", sha, true, std::string(64, 'd'))),
            probeOf(Action::current, false, installedRow("1.2.0", archiveSha, true, manifestSha))};
        auto outcome = run(wire);
        CHECK(outcome && outcome.value().status == Status::updated && outcome.value().enabled == true
            && wire.chunkIndexes.size() == 3 && wire.uploaded == archive && wire.submitted[0].starts_with("update|"));
    }
    {
        FakePackageWire wire;
        wire.probes = {probeOf(Action::update, false, installedRow("1.1.0", sha, true, manifestSha))};
        wire.states = {FakePackageWire::State::queued, FakePackageWire::State::failed};
        auto outcome = run(wire);
        CHECK(outcome && outcome.value().status == Status::failed && outcome.value().reasonCode == "package_checksum_mismatch"
            && outcome.value().installedVersion == "1.1.0" && wire.probeCalls.size() == 1);
        wire = FakePackageWire{};
        wire.probes = {probeOf(Action::install, false, std::nullopt)};
        wire.states = {FakePackageWire::State::queued};
        outcome = run(wire);
        CHECK(outcome && outcome.value().status == Status::pending && outcome.value().reasonCode == "package_operation_queued"
            && wire.operationPolls >= 2);
    }
    {
        FakePackageWire wire;
        wire.probes = {probeOf(Action::install, true, std::nullopt)};
        auto outcome = run(wire);
        CHECK(outcome && outcome.value().status == Status::pending && outcome.value().reasonCode == "package_operation_pending"
            && wire.probeCalls.size() >= 2 && wire.declaredSize == 0);
        wire = FakePackageWire{};
        wire.probes = {probeOf(Action::install, true, std::nullopt), probeOf(Action::current, false,
            installedRow("1.2.0", archiveSha, false, manifestSha))};
        outcome = run(wire);
        CHECK(outcome && outcome.value().status == Status::current && wire.declaredSize == 0);
    }
    {
        FakePackageWire wire;
        wire.probes = {probeOf(Action::install, false, std::nullopt)};
        wire.startError = lorkhan::makeError(lorkhan::ErrorCode::provider_unavailable, "package_storage_full", false,
            std::nullopt, std::string(FakePackageWire::kSyncRequest));
        auto outcome = run(wire);
        CHECK(outcome && outcome.value().status == Status::failed && outcome.value().reasonCode == "package_storage_full");
        wire = FakePackageWire{};
        wire.probes = {probeOf(Action::install, false, std::nullopt)};
        wire.submitError = lorkhan::makeError(lorkhan::ErrorCode::duplicate_conflict, "package_operation_pending", false,
            std::nullopt, std::string(FakePackageWire::kSyncRequest));
        outcome = run(wire);
        CHECK(outcome && outcome.value().status == Status::pending);
        wire = FakePackageWire{};
        wire.transportFailure = lorkhan::makeError(lorkhan::ErrorCode::timeout, "socket timed out");
        outcome = run(wire);
        CHECK(!outcome && outcome.error().code == lorkhan::ErrorCode::timeout);
    }
    {
        FakePackageWire wire;
        std::stop_source stop;
        wire.cancelOnChunk = &stop;
        wire.probes = {probeOf(Action::install, false, std::nullopt)};
        auto outcome = run(wire, stop.get_token());
        CHECK(!outcome && outcome.error().code == lorkhan::ErrorCode::cancelled && wire.submitted.empty());
    }
    {
        FakePackageWire wire;
        auto missing = sync;
        missing.version = "3.0.0";
        auto outcome = lorkhan::runPluginPackageSync(missing, syncRequest, wire, {}, limits);
        CHECK(outcome && outcome.value().status == Status::missing && wire.probeCalls.empty());
        auto linked = sync;
        linked.dataRoots = {linkedRoot.string()};
        linked.version = "1.0.4";
        outcome = lorkhan::runPluginPackageSync(linked, syncRequest, wire, {}, limits);
        CHECK(outcome && outcome.value().status == Status::failed && outcome.value().reasonCode == "package_link_rejected"
            && wire.probeCalls.empty());
    }

    // The bridge admits only the typed DTO for this exact request, session and generation.
    lorkhan::BridgeService bridge(std::make_unique<FakeTransport>(std::make_shared<TransportState>()),
        std::make_shared<FakeClock>(), lorkhan::Generation(7));
    const auto syncOutbound = [&](lorkhan::PluginPackageSyncRequest payload) {
        return lorkhan::OutboundRequest{syncRequest, syncSession, lorkhan::Generation(7),
            lorkhan::RequestKind::plugin_package_sync, std::move(payload)};
    };
    auto relative = sync;
    relative.dataRoots = {"Data Files"};
    CHECK(!bridge.enqueue(syncOutbound(relative)));
    auto badSha = sync;
    badSha.manifestSha256 = std::string(64, 'G');
    CHECK(!bridge.enqueue(syncOutbound(badSha)));
    auto reserved = sync;
    reserved.pluginId = "openmw.core_scripts";
    CHECK(!bridge.enqueue(syncOutbound(reserved)));
    auto stale = sync;
    stale.correlation.generation = lorkhan::Generation(6);
    CHECK(!bridge.enqueue(syncOutbound(stale)));
    auto tooMany = sync;
    tooMany.dataRoots.assign(lorkhan::kMaxPluginPackageRoots + 1, rootA.string());
    CHECK(!bridge.enqueue(syncOutbound(tooMany)));
    auto wrongKind = syncOutbound(sync);
    wrongKind.kind = lorkhan::RequestKind::plugin_event;
    CHECK(!bridge.enqueue(std::move(wrongKind)));
    CHECK(bridge.enqueue(syncOutbound(sync)));
    fs::remove_all(base, ignored);
}

int main()
{
    testClientConfigPath();
    testSavedCharacterIdentity(); testDynamicActorIdentity(); testPlaybackSettings(); testRecordProvenance(); testUtf8(); testUrls(); testHeaders(); testJson(); testProtocolResponses(); testAcceptedProtocolResponses();
    testProtocolEventResponses(); testQueue(); testLifecycleAndCancellation();
    testEvents(); testActions(); testPairingToken(); testMedia(); testBridgeDialogueDeliveryValidation();
    testBridge(); testBridgeSpeechCancel(); testConcurrency(); testVoiceCapturePrimitives(); testPluginContract();
    testPluginPackageSync();
    // A waiting package yields to queued foreground work on the existing worker, then finishes.
    {
        struct CooperativeTransport final : lorkhan::ITransport {
            std::atomic<bool> started{false}, foreground{false};
            lorkhan::Result<lorkhan::InboundResult> execute(const lorkhan::OutboundRequest& request, std::stop_token) override {
                foreground = true;
                return lorkhan::Result<lorkhan::InboundResult>::success({request.id, request.session, request.generation,
                    lorkhan::ResponseKind::completed, "foreground", std::nullopt});
            }
            lorkhan::Result<lorkhan::InboundResult> executeBackground(const lorkhan::OutboundRequest& request,
                std::stop_token token, const std::function<void()>& yield) override {
                started = true;
                const auto deadline = std::chrono::steady_clock::now() + 2s;
                while (!foreground && !token.stop_requested() && std::chrono::steady_clock::now() < deadline) {
                    yield(); std::this_thread::sleep_for(1ms);
                }
                return lorkhan::Result<lorkhan::InboundResult>::success({request.id, request.session, request.generation,
                    lorkhan::ResponseKind::completed, "package", std::nullopt});
            }
            void interrupt(const lorkhan::RequestId&) noexcept override {}
        };
        auto transport = std::make_unique<CooperativeTransport>();
        auto* observed = transport.get();
        lorkhan::BridgeService bridge(std::move(transport), std::make_shared<FakeClock>(), lorkhan::Generation(7));
        const lorkhan::RequestId packageId(uuidFor(950)), foregroundId(uuidFor(951));
        const lorkhan::SessionId session(kSession);
        CHECK(bridge.enqueue({packageId, session, lorkhan::Generation(7), lorkhan::RequestKind::plugin_package_sync,
            lorkhan::PluginPackageSyncRequest{{packageId, session, lorkhan::Generation(7)}, "parity.example", "1.0.0",
                std::string(64, 'a'), {std::filesystem::temp_directory_path().string()}}}));
        CHECK(waitUntil([&] { return observed->started.load(); }));
        CHECK(bridge.enqueue({foregroundId, session, lorkhan::Generation(7), lorkhan::RequestKind::health, lorkhan::HealthRequest{}}));
        CHECK(waitUntil([&] { return bridge.diagnostics().inbound == 2; }));
        const auto results = bridge.poll(2);
        CHECK(results.size() == 2 && results[0].request == foregroundId && results[1].request == packageId);
    }
    if (failures != 0) {
        std::cerr << failures << " test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all native bridge tests passed\n";
    return EXIT_SUCCESS;
}
