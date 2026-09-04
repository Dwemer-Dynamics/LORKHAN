#include "lorkhan/actions.hpp"
#include "lorkhan/bridge_service.hpp"
#include "lorkhan/events.hpp"
#include "lorkhan/json.hpp"
#include "lorkhan/media.hpp"
#include "lorkhan/protocol_response.hpp"
#include "lorkhan/queues.hpp"
#include "lorkhan/validation.hpp"
#include "lorkhan/voice_capture.hpp"

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <mutex>
#include <string>
#include <thread>
#include <type_traits>
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
    std::atomic<bool> block{false};
};

class FakeTransport final : public lorkhan::ITransport {
public:
    explicit FakeTransport(std::shared_ptr<TransportState> state) : m_state(std::move(state)) {}
    lorkhan::Result<lorkhan::InboundResult> execute(
        const lorkhan::OutboundRequest& request, std::stop_token cancellation) override
    {
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
             std::pair{"rechat_cooldown", lorkhan::ErrorCode::cancelled},
             std::pair{"invalid_rechat_context", lorkhan::ErrorCode::invalid_schema}}) {
        const auto response = lorkhan::parseProtocolErrorResponse(
            std::string(R"({"schema":"lorkhan.error.v1","code":")") + code
                + R"(","message":"Request rejected","correlation_id":"01900000-0000-7000-8000-000000000001","retriable":false})", jsonHeaders);
        CHECK(response && response.value().code == expected);
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

    auto session = lorkhan::parseSessionAcceptedResponse(
        R"({"schema":"lorkhan.session.accepted.v1","message_id":"01900000-0000-7000-8000-000000000006","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"capabilities":["dialogue.text","speech.say"],"config_revision":"revision-9","client_settings":{"schema":"lorkhan.client-settings.v1","behavior":{"auto_greeting":false,"rechat":false,"rechat_delay_seconds":45,"rechat_max_depth":2,"rechat_probability_percent":50,"rechat_mode":"random","rechat_strict_targeting":false,"open_rechat":true,"rechat_allow_actions":false,"end_conversation_cooldown_seconds":60,"boredom":false,"boredom_delay_seconds":180,"combat_barks":false,"combat_bark_period_seconds":20},"memory":{"recent_turn_limit":20,"knowledge_limit":5},"narrator":{"enabled":false,"name":"The Narrator","context_visibility":true,"inline_mode":"Disabled","welcome_events":false,"welcome_cooldown_minutes":10,"random_events":false,"random_chance_percent":15,"random_cooldown_rounds":2,"bored_events":false,"bored_chance_percent":25,"quest_events":false,"quest_chance_percent":10,"quest_cooldown_minutes":3,"book_events":false},"presentation":{"show_status_hud":true,"transcript_rows":8,"tts_volume_boost":3},"safety":{"actions_enabled":true,"allow_hostile":false,"allow_creatures":false}},"event_cursor":3})",
        jsonHeaders);
    CHECK(session && session.value().message == lorkhan::MessageId(kMessage)
        && session.value().session == lorkhan::SessionId(kSession)
        && session.value().generation == lorkhan::Generation(7)
        && session.value().capabilities.size() == 2
        && session.value().configRevision == "revision-9" && session.value().eventCursor == 3
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
    auto rpgEvent = lorkhan::parseGameDataAcceptedResponse(
        R"({"schema":"lorkhan.gamedata.accepted.v1","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"type":"rpg_event","duplicate":false,"comment_requested":true})",
        jsonHeaders);
    CHECK(rpgEvent && rpgEvent.value().commentRequested && !rpgEvent.value().duplicate);
    CHECK(!lorkhan::parseGameDataAcceptedResponse(
        R"({"schema":"lorkhan.gamedata.accepted.v1","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"type":"journal","duplicate":false})",
        jsonHeaders));

    auto controls = lorkhan::parseControlsResponse(
        R"({"schema":"lorkhan.controls.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"target":{"kind":"npc","record_id":"fargoth","refnum":{"index":42,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"interior","name":"Seyda Neen, Census and Excise Office"},"display_name":"Fargoth"},"selected_model_slot_key":"standard","resolved_model_slot_key":"standard","selected_profile_id":null,"narrator_profile_id":"10000000-0000-4000-8000-000000000408","effective_settings":{"schema":"lorkhan.effective-settings.v1","change_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","profile_id":null,"profile_revision":null,"core_profile_id":"10000000-0000-4000-8000-000000000409","core_profile_revision":1,"settings":{"behavior":{"auto_greeting":false,"rechat":false,"rechat_delay_seconds":45,"rechat_max_depth":2,"rechat_probability_percent":50,"rechat_mode":"random","rechat_strict_targeting":false,"open_rechat":true,"rechat_allow_actions":false,"end_conversation_cooldown_seconds":60,"boredom":false,"boredom_delay_seconds":180,"combat_barks":false,"combat_bark_period_seconds":20},"memory":{"recent_turn_limit":20,"knowledge_limit":5},"narrator":{"enabled":false,"name":"The Narrator","context_visibility":true,"inline_mode":"Disabled","welcome_events":false,"welcome_cooldown_minutes":10,"random_events":false,"random_chance_percent":15,"random_cooldown_rounds":2,"bored_events":false,"bored_chance_percent":25,"quest_events":false,"quest_chance_percent":10,"quest_cooldown_minutes":3,"book_events":false},"presentation":{"show_status_hud":true,"transcript_rows":8,"tts_volume_boost":3},"safety":{"actions_enabled":true,"allow_hostile":false,"allow_creatures":false}},"routing":{"llm_configuration_id":"10000000-0000-4000-8000-000000000406"},"source_map":{"settings.memory.recent_turn_limit":"global","settings.memory.knowledge_limit":"global","settings.narrator.enabled":"global","settings.narrator.name":"global","settings.narrator.context_visibility":"global","settings.narrator.inline_mode":"global","settings.narrator.welcome_events":"narrator_profile","settings.narrator.random_events":"global","settings.narrator.quest_events":"global","settings.narrator.book_events":"global","settings.safety.actions_enabled":"global","settings.safety.allow_hostile":"global","settings.safety.allow_creatures":"global","routing.llm_configuration_id":"core_profile"}},"model_slots":[{"key":"standard","label":"Standard","available":true,"configuration_id":"10000000-0000-4000-8000-000000000406","configuration_name":"Dialogue","revision":1,"driver":"configured","model":"gpt-5-mini"},{"key":"fast","label":"Fast","available":false,"configuration_id":null,"configuration_name":null,"revision":null,"driver":null,"model":null},{"key":"powerful","label":"Powerful","available":false,"configuration_id":null,"configuration_name":null,"revision":null,"driver":null,"model":null},{"key":"experimental","label":"Experimental","available":false,"configuration_id":null,"configuration_name":null,"revision":null,"driver":null,"model":null}],"profiles":[{"profile_id":"10000000-0000-4000-8000-000000000407","name":"Fargoth","revision":2}]})",
        jsonHeaders);
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
    auto parityActions = lorkhan::parseEventsResponse(
        R"({"schema":"lorkhan.events.v1","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"next_after":3,"events":[
        {"message_id":"01900000-0000-7000-8000-000000000021","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-19T20:00:03Z","type":"action.intent","payload":{"schema":"lorkhan.action-intent.v1","action_id":"01900000-0000-7000-8000-000000000031","turn_id":"01900000-0000-7000-8000-000000000005","name":"inventory.inspect","tier":0,"actor":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"target":{"kind":"player","record_id":"player","refnum":{"index":1,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Player"},"parameters":{},"expires_at":"2026-07-19T20:00:30Z"}},
        {"message_id":"01900000-0000-7000-8000-000000000022","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":2,"created_at":"2026-07-19T20:00:04Z","type":"action.intent","payload":{"schema":"lorkhan.action-intent.v1","action_id":"01900000-0000-7000-8000-000000000032","turn_id":"01900000-0000-7000-8000-000000000005","name":"ai.approach","tier":1,"actor":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"target":{"kind":"player","record_id":"player","refnum":{"index":1,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Player"},"parameters":{},"expires_at":"2026-07-19T20:00:30Z"}},
        {"message_id":"01900000-0000-7000-8000-000000000023","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":3,"created_at":"2026-07-19T20:00:05Z","type":"action.intent","payload":{"schema":"lorkhan.action-intent.v1","action_id":"01900000-0000-7000-8000-000000000033","turn_id":"01900000-0000-7000-8000-000000000005","name":"ai.wait","tier":1,"actor":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"target":{"kind":"player","record_id":"player","refnum":{"index":1,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Player"},"parameters":{"duration_seconds":3600},"expires_at":"2026-07-19T20:00:30Z"}}
        ],"autonomy":[]})",
        jsonHeaders);
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
}

void testQueue()
{
    lorkhan::BoundedQueue<int> queue(5, 2);
    CHECK(queue.tryPush(1)); CHECK(queue.tryPush(2)); CHECK(queue.tryPush(3));
    CHECK(!queue.tryPush(4));
    CHECK(queue.tryPush(99, true)); CHECK(queue.tryPush(100, true)); CHECK(!queue.tryPush(101, true));
    auto drained = queue.drain(5);
    CHECK(drained.size() == 5 && drained[0] == 100 && drained[1] == 99);
    queue.close();
    CHECK(!queue.tryPush(1));
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

int main()
{
    testUtf8(); testUrls(); testHeaders(); testJson(); testProtocolResponses(); testAcceptedProtocolResponses();
    testProtocolEventResponses(); testQueue(); testLifecycleAndCancellation();
    testEvents(); testActions(); testPairingToken(); testMedia(); testBridgeDialogueDeliveryValidation();
    testBridge(); testConcurrency(); testVoiceCapturePrimitives();
    if (failures != 0) {
        std::cerr << failures << " test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all native bridge tests passed\n";
    return EXIT_SUCCESS;
}
