#include "almsivi/actions.hpp"
#include "almsivi/bridge_service.hpp"
#include "almsivi/events.hpp"
#include "almsivi/json.hpp"
#include "almsivi/media.hpp"
#include "almsivi/protocol_response.hpp"
#include "almsivi/queues.hpp"
#include "almsivi/validation.hpp"
#include "almsivi/voice_capture.hpp"

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

class FakeClock final : public almsivi::IClock {
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

class FakeTransport final : public almsivi::ITransport {
public:
    explicit FakeTransport(std::shared_ptr<TransportState> state) : m_state(std::move(state)) {}
    almsivi::Result<almsivi::InboundResult> execute(
        const almsivi::OutboundRequest& request, std::stop_token cancellation) override
    {
        ++m_state->executions;
        while (m_state->block.load() && !cancellation.stop_requested())
            std::this_thread::yield();
        if (cancellation.stop_requested())
            return almsivi::Result<almsivi::InboundResult>::failure(
                almsivi::makeError(almsivi::ErrorCode::cancelled, "cancelled"));
        return almsivi::Result<almsivi::InboundResult>::success(
            {request.id, request.session, request.generation, almsivi::ResponseKind::completed, "{}", std::nullopt});
    }
    void interrupt(const almsivi::RequestId&) noexcept override { ++m_state->interrupts; m_state->block = false; }
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

almsivi::OutboundRequest request(std::string id, almsivi::Generation generation)
{
    almsivi::EnvelopeIds ids{almsivi::InstallationId(kInstallation), almsivi::ProfileId(kProfile),
        almsivi::PlaythroughId(kPlaythrough), almsivi::SessionId(kSession), almsivi::RequestId(id),
        almsivi::TurnId(kTurn), almsivi::MessageId(kMessage), generation};
    return {almsivi::RequestId(std::move(id)), almsivi::SessionId(kSession), generation,
        almsivi::RequestKind::turn, almsivi::TurnRequest{std::move(ids), {}, "sha256:test",
            "2026-07-18T20:00:00Z", "{}"}};
}

void testUtf8()
{
    CHECK(almsivi::isValidUtf8("plain"));
    CHECK(almsivi::isValidUtf8("Morrowind \xE2\x9C\x93"));
    CHECK(!almsivi::isValidUtf8(std::string("\xC0\x80", 2)));
    CHECK(!almsivi::isValidUtf8(std::string("\xED\xA0\x80", 3)));
    CHECK(!almsivi::isValidUtf8(std::string("\xF4\x90\x80\x80", 4)));
    CHECK(!almsivi::requireValidUtf8("abcd", 3));
    CHECK(almsivi::isCanonicalUuid(kSession));
    CHECK(!almsivi::isCanonicalUuid("01900000-0000-7000-8000-00000000000"));
    CHECK(!almsivi::isCanonicalUuid("01900000-0000-7000-8000-00000000000g"));
    CHECK(!almsivi::isCanonicalUuid("01900000-0000-7000-8000-00000000000A"));
}

void testUrls()
{
    const std::vector<std::string> valid{
        "http://127.0.0.1:8089/ALMSIVIserver/api/v1", "http://127.1.2.3/", "http://[::1]:8089/api"};
    for (const auto& url : valid)
        CHECK(almsivi::parseLoopbackBaseUrl(url));
    const std::vector<std::string> invalid{
        "https://127.0.0.1/", "HTTP://127.0.0.1/", "http://localhost/", "http://127.0.0.1.evil/",
        "http://2130706433/", "http://0177.0.0.1/", "http://0x7f.0.0.1/", "http://[::ffff:127.0.0.1]/",
        "http://user@127.0.0.1/", "http://127.0.0.1/a?b", "http://127.0.0.1/a#b",
        "http://127.0.0.1/%2e%2e/x", "http://127.0.0.1/a/../b", "http://127.0.0.1:080/",
        "http://127.0.0.1:0/", "http://127.0.0.1\r\nX: y/", "http://[0:0:0:0:0:0:0:1]/"};
    for (const auto& url : invalid)
        CHECK(!almsivi::parseLoopbackBaseUrl(url));
    const auto parsed = almsivi::parseLoopbackBaseUrl("http://[::1]:8089/api/");
    CHECK(parsed && parsed.value().basePath == "/api" && parsed.value().authority() == "[::1]:8089");
}

void testHeaders()
{
    CHECK(almsivi::validateJsonContentType({{"Content-Type", "application/json; charset=utf-8"}}));
    CHECK(!almsivi::validateJsonContentType({{"Content-Type", "application/json"}}));
    CHECK(!almsivi::validateHeaders({{"X-Test", "one"}, {"x-test", "two"}}));
    CHECK(!almsivi::validateHeaders({{"X-Test", "one\r\ntwo"}}));
    CHECK(almsivi::parseContentType("audio/ogg", true));
    CHECK(!almsivi::parseContentType("text/plain"));
}

void testJson()
{
    using almsivi::ErrorCode;
    using almsivi::json::find;
    using almsivi::json::parse;

    auto parsed = parse(R"json({"schema":"almsivi.health.v1","null":null,"ok":true,"sequence":7,"fraction":-1.25e+2,"text":"Morrowind ✓","escaped":"\"\\\/\b\f\n\r\t","unicode":"¢€😀","array":[false,0]})json");
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

    auto schema = almsivi::json::requireObjectWithSchema(
        R"({"schema":"almsivi.health.v1"})", "almsivi.health.v1");
    CHECK(schema && find(schema.value(), "schema") != nullptr);
    auto wrongSchema = almsivi::json::requireObjectWithSchema(
        R"({"schema":"almsivi.error.v1"})", "almsivi.health.v1");
    CHECK(!wrongSchema && wrongSchema.error().code == ErrorCode::invalid_schema);
    auto nonObject = almsivi::json::requireObjectWithSchema("[]", "almsivi.health.v1");
    CHECK(!nonObject && nonObject.error().code == ErrorCode::invalid_schema);

    auto oversized = parse(std::string(2U * 1024U * 1024U + 1U, ' '));
    CHECK(!oversized && oversized.error().code == ErrorCode::payload_too_large);
    auto invalidUtf8 = parse(std::string("\xC0\x80", 2));
    CHECK(!invalidUtf8 && invalidUtf8.error().code == ErrorCode::invalid_utf8);
    auto syntax = parse("[");
    CHECK(!syntax && syntax.error().code == ErrorCode::invalid_json);

    almsivi::json::ParseLimits limits;
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
    const almsivi::Headers jsonHeaders{{"Content-Type", "application/json; charset=utf-8"}};
    CHECK(almsivi::parseHealthResponse(R"({"schema":"almsivi.health.v1"})", jsonHeaders));
    CHECK(!almsivi::parseHealthResponse(R"({"schema":"almsivi.health.v1","extra":true})", jsonHeaders));
    CHECK(!almsivi::parseHealthResponse(R"({"schema":"almsivi.health.v1"})",
        {{"Content-Type", "application/json"}}));

    const std::string error = R"({"schema":"almsivi.error.v1","code":"rate_limited","message":"not trusted for display","correlation_id":"01900000-0000-7000-8000-000000000001","retriable":true,"retry_after_ms":500})";
    auto parsed = almsivi::parseProtocolErrorResponse(error, jsonHeaders);
    CHECK(parsed && parsed.value().code == almsivi::ErrorCode::rate_limited
        && parsed.value().retriable && parsed.value().retryAfterMs == 500);
    CHECK(!almsivi::parseProtocolErrorResponse(
        R"({"schema":"almsivi.error.v1","code":"invented","message":"x","correlation_id":"01900000-0000-7000-8000-000000000001","retriable":false})",
        jsonHeaders));
    CHECK(!almsivi::parseProtocolErrorResponse(
        R"({"schema":"almsivi.error.v1","code":"unauthorized","message":"x","correlation_id":"bad","retriable":false})",
        jsonHeaders));
    auto expandedCode = almsivi::parseProtocolErrorResponse(
        R"({"schema":"almsivi.error.v1","code":"unknown_action","message":"unknown action","correlation_id":"01900000-0000-7000-8000-000000000001","retriable":false})",
        jsonHeaders);
    CHECK(expandedCode && expandedCode.value().code == almsivi::ErrorCode::invalid_action);
    CHECK(!almsivi::parseProtocolErrorResponse(
        R"({"schema":"almsivi.error.v1","code":"internal_error","message":"","correlation_id":"01900000-0000-7000-8000-000000000001","retriable":false})",
        jsonHeaders));

    auto redirect = almsivi::validateHealthHttpResponse(302, "", {});
    CHECK(!redirect && redirect.error().code == almsivi::ErrorCode::redirect_rejected);
    auto success = almsivi::validateHealthHttpResponse(
        200, R"({"schema":"almsivi.health.v1"})", jsonHeaders);
    CHECK(success);
    auto failure = almsivi::validateHealthHttpResponse(429, error, jsonHeaders);
    CHECK(!failure && failure.error().code == almsivi::ErrorCode::rate_limited
        && failure.error().retriable && failure.error().retryAfterMs == 500
        && failure.error().message.find("not trusted") == std::string::npos);
}

void testAcceptedProtocolResponses()
{
    const almsivi::Headers jsonHeaders{{"Content-Type", "application/json; charset=utf-8"}};

    auto session = almsivi::parseSessionAcceptedResponse(
        R"({"schema":"almsivi.session.accepted.v1","message_id":"01900000-0000-7000-8000-000000000006","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"capabilities":["dialogue.text","speech.say"],"config_revision":"revision-9","client_settings":{"schema":"almsivi.client-settings.v1","behavior":{"auto_greeting":false,"rechat":false,"rechat_delay_seconds":45,"rechat_max_depth":2,"rechat_probability_percent":50,"rechat_mode":"random","rechat_strict_targeting":false,"open_rechat":true,"rechat_allow_actions":false,"end_conversation_cooldown_seconds":60,"boredom":false,"boredom_delay_seconds":180,"combat_barks":false,"combat_bark_period_seconds":20},"memory":{"recent_turn_limit":20,"knowledge_limit":5},"narrator":{"enabled":false,"name":"The Narrator","context_visibility":true,"inline_mode":"Disabled","welcome_events":false,"random_events":false,"quest_events":false,"book_events":false},"presentation":{"show_status_hud":true,"transcript_rows":8,"tts_volume_boost":3},"safety":{"actions_enabled":true,"allow_hostile":false,"allow_creatures":false}},"event_cursor":3})",
        jsonHeaders);
    CHECK(session && session.value().message == almsivi::MessageId(kMessage)
        && session.value().session == almsivi::SessionId(kSession)
        && session.value().generation == almsivi::Generation(7)
        && session.value().capabilities.size() == 2
        && session.value().configRevision == "revision-9" && session.value().eventCursor == 3);
    CHECK(!almsivi::parseSessionAcceptedResponse(
        R"({"schema":"almsivi.session.accepted.v1","message_id":"01900000-0000-7000-8000-000000000006","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"capabilities":["dialogue.text","dialogue.text"],"config_revision":"revision-9","client_settings":{"schema":"almsivi.client-settings.v1","behavior":{"auto_greeting":false,"rechat":false,"rechat_delay_seconds":45,"rechat_max_depth":2,"rechat_probability_percent":50,"rechat_mode":"random","rechat_strict_targeting":false,"open_rechat":true,"rechat_allow_actions":false,"end_conversation_cooldown_seconds":60,"boredom":false,"boredom_delay_seconds":180,"combat_barks":false,"combat_bark_period_seconds":20},"memory":{"recent_turn_limit":20,"knowledge_limit":5},"narrator":{"enabled":false,"name":"The Narrator","context_visibility":true,"inline_mode":"Disabled","welcome_events":false,"random_events":false,"quest_events":false,"book_events":false},"presentation":{"show_status_hud":true,"transcript_rows":8,"tts_volume_boost":3},"safety":{"actions_enabled":true,"allow_hostile":false,"allow_creatures":false}},"event_cursor":3})",
        jsonHeaders));
    CHECK(!almsivi::parseSessionAcceptedResponse(
        R"({"schema":"almsivi.session.accepted.v1","message_id":"01900000-0000-7000-8000-000000000006","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"capabilities":[],"config_revision":"revision-9","client_settings":{"schema":"almsivi.client-settings.v1","behavior":{"auto_greeting":false,"rechat":false,"rechat_delay_seconds":45,"rechat_max_depth":2,"rechat_probability_percent":50,"rechat_mode":"random","rechat_strict_targeting":false,"open_rechat":true,"rechat_allow_actions":false,"end_conversation_cooldown_seconds":60,"boredom":false,"boredom_delay_seconds":180,"combat_barks":false,"combat_bark_period_seconds":20},"memory":{"recent_turn_limit":20,"knowledge_limit":5},"narrator":{"enabled":false,"name":"The Narrator","context_visibility":true,"inline_mode":"Disabled","welcome_events":false,"random_events":false,"quest_events":false,"book_events":false},"presentation":{"show_status_hud":true,"transcript_rows":8,"tts_volume_boost":3},"safety":{"actions_enabled":true,"allow_hostile":false,"allow_creatures":false}},"event_cursor":3,"extra":true})",
        jsonHeaders));

    auto turn = almsivi::parseTurnAcceptedResponse(
        R"({"schema":"almsivi.turn.accepted.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"event_cursor":4})",
        jsonHeaders);
    CHECK(turn && turn.value().correlation.message == almsivi::MessageId(kMessage)
        && turn.value().correlation.request == almsivi::RequestId(kInstallation)
        && turn.value().correlation.turn == almsivi::TurnId(kTurn)
        && turn.value().correlation.session == almsivi::SessionId(kSession)
        && turn.value().correlation.generation == almsivi::Generation(7)
        && turn.value().eventCursor == 4);
    CHECK(!almsivi::parseTurnAcceptedResponse(
        R"({"schema":"almsivi.turn.accepted.v1","message_id":"BAD","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"event_cursor":4})",
        jsonHeaders));

    auto interruption = almsivi::parseInterruptionAcceptedResponse(
        R"({"schema":"almsivi.interruption.accepted.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"event_cursor":6,"duplicate":true})",
        jsonHeaders);
    CHECK(interruption && interruption.value().duplicate && interruption.value().eventCursor == 6
        && interruption.value().correlation.turn == almsivi::TurnId(kTurn));
    CHECK(!almsivi::parseInterruptionAcceptedResponse(
        R"({"schema":"almsivi.interruption.accepted.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"event_cursor":6,"duplicate":"true"})",
        jsonHeaders));

    auto action = almsivi::parseActionResultAcceptedResponse(
        R"({"schema":"almsivi.action-result.accepted.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","action_id":"01900000-0000-7000-8000-000000000007","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"status":"succeeded","duplicate":false})",
        jsonHeaders);
    CHECK(action && action.value().action == almsivi::ActionId(kAction)
        && action.value().status == almsivi::ActionTerminalStatus::succeeded
        && !action.value().duplicate && action.value().correlation.session == almsivi::SessionId(kSession));
    CHECK(!almsivi::parseActionResultAcceptedResponse(
        R"({"schema":"almsivi.action-result.accepted.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","action_id":"01900000-0000-7000-8000-000000000007","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"status":"pending","duplicate":false})",
        jsonHeaders));

    auto ended = almsivi::parseSessionEndedResponse(
        R"({"schema":"almsivi.session.ended.v1","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"ended":true})",
        jsonHeaders);
    CHECK(ended && ended.value().request == almsivi::RequestId(kInstallation)
        && ended.value().session == almsivi::SessionId(kSession)
        && ended.value().generation == almsivi::Generation(7) && ended.value().ended);
    CHECK(!almsivi::parseSessionEndedResponse(
        R"({"schema":"almsivi.session.ended.v1","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":-1,"ended":true})",
        jsonHeaders));

    auto controls = almsivi::parseControlsResponse(
        R"({"schema":"almsivi.controls.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"target":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"selected_model_slot_id":"01900000-0000-7000-8000-000000000011","selected_profile_id":null,"narrator_profile_id":"01900000-0000-7000-8000-000000000013","effective_settings":{"schema":"almsivi.effective-settings.v1","change_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","profile_id":null,"profile_revision":null,"core_profile_id":"01900000-0000-7000-8000-000000000014","core_profile_revision":1,"settings":{"behavior":{"auto_greeting":false,"rechat":false,"rechat_delay_seconds":45,"rechat_max_depth":2,"rechat_probability_percent":50,"rechat_mode":"random","rechat_strict_targeting":false,"open_rechat":true,"rechat_allow_actions":false,"end_conversation_cooldown_seconds":60,"boredom":false,"boredom_delay_seconds":180,"combat_barks":false,"combat_bark_period_seconds":20},"memory":{"recent_turn_limit":20,"knowledge_limit":5},"narrator":{"enabled":false,"name":"The Narrator","context_visibility":true,"inline_mode":"Disabled","welcome_events":false,"random_events":false,"quest_events":false,"book_events":false},"presentation":{"show_status_hud":true,"transcript_rows":8,"tts_volume_boost":3},"safety":{"actions_enabled":true,"allow_hostile":false,"allow_creatures":false}},"routing":{},"source_map":{}},"model_slots":[{"configuration_id":"01900000-0000-7000-8000-000000000011","name":"Dialogue","revision":2,"driver":"configured","model":"gpt-5-mini"}],"profiles":[{"profile_id":"01900000-0000-7000-8000-000000000012","name":"Fargoth","revision":3}]})",
        jsonHeaders);
    CHECK(controls && controls.value().request == almsivi::RequestId(kInstallation)
        && controls.value().session == almsivi::SessionId(kSession)
        && controls.value().generation == almsivi::Generation(7)
        && controls.value().target.recordId == "fargoth"
        && controls.value().selectedModelSlotId
        && *controls.value().selectedModelSlotId == "01900000-0000-7000-8000-000000000011"
        && !controls.value().selectedProfileId
        && controls.value().narratorProfileId
        && *controls.value().narratorProfileId == "01900000-0000-7000-8000-000000000013"
        && controls.value().effectiveSettings.changeToken == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        && controls.value().effectiveSettings.coreProfileRevision == 1
        && controls.value().effectiveSettings.safety.actionsEnabled
        && controls.value().modelSlots.size() == 1 && controls.value().profiles.size() == 1
        && controls.value().modelSlots[0].model == "gpt-5-mini"
        && controls.value().profiles[0].revision == 3);
    CHECK(!almsivi::parseControlsResponse(
        R"({"schema":"almsivi.controls.v1","message_id":"01900000-0000-7000-8000-000000000006","request_id":"01900000-0000-7000-8000-000000000001","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"target":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"selected_model_slot_id":"01900000-0000-7000-8000-000000000099","selected_profile_id":null,"narrator_profile_id":null,"effective_settings":{"schema":"almsivi.effective-settings.v1","change_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","profile_id":null,"profile_revision":null,"core_profile_id":"01900000-0000-7000-8000-000000000014","core_profile_revision":1,"settings":{"memory":{"recent_turn_limit":20,"knowledge_limit":5},"narrator":{"enabled":false,"name":"The Narrator","context_visibility":true,"inline_mode":"Disabled","welcome_events":false,"random_events":false,"quest_events":false,"book_events":false},"safety":{"actions_enabled":true,"allow_hostile":false,"allow_creatures":false}},"routing":{},"source_map":{}},"model_slots":[],"profiles":[]})",
        jsonHeaders));
}

void testProtocolEventResponses()
{
    const almsivi::Headers jsonHeaders{{"Content-Type", "application/json; charset=utf-8"}};
    const std::string events = R"json({
        "schema":"almsivi.events.v1",
        "session_id":"01900000-0000-7000-8000-000000000004",
        "generation":7,
        "next_after":7,
        "events":[
          {"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-18T20:00:01Z","type":"turn.accepted","payload":{"status":"accepted"}},
          {"message_id":"01900000-0000-7000-8000-000000000009","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":2,"created_at":"2026-07-18T20:00:02.123Z","type":"dialogue.complete","payload":{"speaker":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"addressee":{"kind":"player","record_id":"player","refnum":{"index":1,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"interior","name":"Seyda Neen, Census Office"},"display_name":"Player"},"text":"You have found my ring."}},
          {"message_id":"01900000-0000-7000-8000-00000000000a","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":3,"created_at":"2026-07-18T20:00:03Z","type":"action.intent","payload":{"schema":"almsivi.action-intent.v1","action_id":"01900000-0000-7000-8000-000000000007","turn_id":"01900000-0000-7000-8000-000000000005","name":"ai.follow","tier":1,"actor":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"target":{"kind":"player","record_id":"player","refnum":{"index":1,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"interior","name":"Seyda Neen, Census Office"},"display_name":"Player"},"parameters":{"distance":192},"expires_at":"2026-07-18T20:00:10Z"}},
          {"message_id":"01900000-0000-7000-8000-00000000000b","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":4,"created_at":"2026-07-18T20:00:04Z","type":"speech.ready","payload":{"media_id":"01900000-0000-7000-8000-00000000000c","dialogue_message_id":"01900000-0000-7000-8000-000000000009","sha256":"e12e115acf4552b2568b55e93cbd39394c4ef81c82447faed7738adf06e9ba61","bytes":4,"codec":"ogg","duration_ms":100,"expires_at":"2026-07-18T21:00:00Z"}},
          {"message_id":"01900000-0000-7000-8000-00000000000d","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":5,"created_at":"2026-07-18T20:00:05Z","type":"turn.failed","payload":{"code":"provider_timeout","retriable":true,"retry_after_ms":250}},
          {"message_id":"01900000-0000-7000-8000-00000000000e","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":6,"created_at":"2026-07-18T20:00:06Z","type":"turn.cancelled","payload":{"reason":"interrupted"}},
          {"message_id":"01900000-0000-7000-8000-00000000000f","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":7,"created_at":"2026-07-18T20:00:07Z","type":"turn.complete","payload":{"status":"complete"}}
        ],
        "autonomy":[
          {"schema":"almsivi.autonomy-directive.v1","schedule_id":"01900000-0000-7000-8000-000000000010","kind":"rechat","issued_at":"2026-07-18T20:00:08Z"}
        ]
    })json";
    auto parsed = almsivi::parseEventsResponse(events, jsonHeaders);
    CHECK(parsed && parsed.value().session == almsivi::SessionId(kSession)
        && parsed.value().generation == almsivi::Generation(7)
        && parsed.value().nextAfter == 7 && parsed.value().events.size() == 7
        && parsed.value().autonomy.size() == 1);
    if (parsed && parsed.value().autonomy.size() == 1) {
        CHECK(parsed.value().autonomy[0].scheduleId == "01900000-0000-7000-8000-000000000010"
            && parsed.value().autonomy[0].kind == "rechat"
            && parsed.value().autonomy[0].issuedAt == "2026-07-18T20:00:08Z");
    }
    if (parsed && parsed.value().events.size() == 7) {
        CHECK(parsed.value().events[0].type == almsivi::ProtocolEventType::turn_accepted
            && std::get_if<almsivi::TurnAcceptedEventPayload>(&parsed.value().events[0].payload));
        const auto* dialogue = std::get_if<almsivi::DialogueCompleteEventPayload>(&parsed.value().events[1].payload);
        CHECK(dialogue && dialogue->speaker.recordId == "fargoth" && dialogue->speaker.cell.gridX == -2
            && dialogue->addressee.cell.kind == almsivi::ProtocolCell::Kind::interior
            && dialogue->text == "You have found my ring.");
        const auto* intent = std::get_if<almsivi::ActionIntentEventPayload>(&parsed.value().events[2].payload);
        CHECK(intent && intent->intent.action == almsivi::ActionId(kAction)
            && intent->intent.turn == almsivi::TurnId(kTurn) && intent->intent.followDistance == 192
            && intent->intent.actor.recordId == "fargoth" && intent->intent.target.recordId == "player");
        const auto* speech = std::get_if<almsivi::SpeechReadyEventPayload>(&parsed.value().events[3].payload);
        CHECK(speech && speech->codec == almsivi::MediaCodec::ogg && speech->bytes == 4
            && speech->dialogueMessage.value() == "01900000-0000-7000-8000-000000000009"
            && speech->durationMs == 100 && speech->sha256.size() == 64);
        const auto* failed = std::get_if<almsivi::TurnFailedEventPayload>(&parsed.value().events[4].payload);
        CHECK(failed && failed->code == almsivi::ErrorCode::timeout && failed->retriable
            && failed->retryAfterMs == 250);
        const auto* cancelled = std::get_if<almsivi::TurnCancelledEventPayload>(&parsed.value().events[5].payload);
        CHECK(cancelled && cancelled->reason == "interrupted");
        CHECK(parsed.value().events[6].type == almsivi::ProtocolEventType::turn_complete
            && std::get_if<almsivi::TurnCompleteEventPayload>(&parsed.value().events[6].payload));
    }

    const std::string prefix = R"({"schema":"almsivi.events.v1","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"next_after":1,"events":[)";
    const std::string suffix = "],\"autonomy\":[]}";
    auto delta = almsivi::parseEventsResponse(prefix
        + R"({"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-18T20:00:01Z","type":"dialogue.delta","payload":{"text":"Welcome to "}})"
        + suffix, jsonHeaders);
    CHECK(delta && std::get_if<almsivi::DialogueDeltaEventPayload>(&delta.value().events[0].payload));
    CHECK(!almsivi::parseEventsResponse(prefix
        + R"({"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":8,"sequence":1,"created_at":"2026-07-18T20:00:01Z","type":"turn.accepted","payload":{"status":"accepted"}})"
        + suffix, jsonHeaders));
    CHECK(!almsivi::parseEventsResponse(prefix
        + R"({"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-18 20:00:01Z","type":"turn.accepted","payload":{"status":"accepted"}})"
        + suffix, jsonHeaders));
    CHECK(!almsivi::parseEventsResponse(prefix
        + R"({"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-02-30T20:00:01Z","type":"turn.accepted","payload":{"status":"accepted"}})"
        + suffix, jsonHeaders));
    CHECK(!almsivi::parseEventsResponse(prefix
        + R"({"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-18T20:00:01Z","type":"server.notice","payload":{}})"
        + suffix, jsonHeaders));
    CHECK(!almsivi::parseEventsResponse(prefix
        + R"({"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-18T20:00:01Z","type":"action.intent","payload":{"schema":"almsivi.action-intent.v1","action_id":"01900000-0000-7000-8000-000000000007","turn_id":"01900000-0000-7000-8000-000000000006","name":"ai.follow","tier":1,"actor":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"target":{"kind":"player","record_id":"player","refnum":{"index":1,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"interior","name":"Office"},"display_name":"Player"},"parameters":{"distance":192},"expires_at":"2026-07-18T20:00:10Z"}})"
        + suffix, jsonHeaders));
    CHECK(!almsivi::parseEventsResponse(prefix
        + R"({"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-18T20:00:01Z","type":"speech.ready","payload":{"media_id":"01900000-0000-7000-8000-00000000000c","sha256":"E12E115ACF4552B2568B55E93CBD39394C4EF81C82447FAED7738ADF06E9BA61","bytes":4,"codec":"ogg","duration_ms":100,"expires_at":"2026-07-18T21:00:00Z"}})"
        + suffix, jsonHeaders));
    auto cursorAhead = almsivi::parseEventsResponse(
        R"({"schema":"almsivi.events.v1","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"next_after":9,"events":[{"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-18T20:00:01Z","type":"turn.accepted","payload":{"status":"accepted"}}],"autonomy":[]})",
        jsonHeaders);
    CHECK(cursorAhead && cursorAhead.value().nextAfter == 9);

    auto extended = almsivi::parseEventsResponse(
        R"({"schema":"almsivi.events.v1","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"next_after":3,"events":[{"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-19T20:00:01Z","type":"stt.transcript","payload":{"text":"Hello there.","language":"en-US"}},{"message_id":"01900000-0000-7000-8000-000000000009","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":2,"created_at":"2026-07-19T20:00:02Z","type":"stt.failed","payload":{"code":"provider_timeout","retriable":true,"retry_after_ms":1000}},{"message_id":"01900000-0000-7000-8000-00000000000a","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":3,"created_at":"2026-07-19T20:00:03Z","type":"action.intent","payload":{"schema":"almsivi.action-intent.v1","action_id":"01900000-0000-7000-8000-000000000007","turn_id":"01900000-0000-7000-8000-000000000005","name":"inspect.report","tier":0,"actor":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"target":{"kind":"player","record_id":"player","refnum":{"index":1,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"interior","name":"Office"},"display_name":"Player"},"parameters":{},"expires_at":"2026-07-19T20:00:30Z"}}],"autonomy":[]})",
        jsonHeaders);
    CHECK(extended && extended.value().events.size() == 3);
    if (extended && extended.value().events.size() == 3) {
        const auto* transcript = std::get_if<almsivi::SttTranscriptEventPayload>(&extended.value().events[0].payload);
        const auto* sttFailure = std::get_if<almsivi::SttFailedEventPayload>(&extended.value().events[1].payload);
        const auto* inspect = std::get_if<almsivi::ActionIntentEventPayload>(&extended.value().events[2].payload);
        CHECK(transcript && transcript->text == "Hello there." && transcript->language == "en-US");
        CHECK(sttFailure && sttFailure->code == "provider_timeout" && sttFailure->retryAfterMs == 1000);
        CHECK(inspect && inspect->intent.kind == almsivi::ActionIntentKind::inspect_report
            && inspect->intent.followDistance == 0);
    }
    auto equipment = almsivi::parseEventsResponse(
        R"({"schema":"almsivi.events.v1","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"next_after":1,"events":[{"message_id":"01900000-0000-7000-8000-000000000008","request_id":"01900000-0000-7000-8000-000000000001","turn_id":"01900000-0000-7000-8000-000000000005","session_id":"01900000-0000-7000-8000-000000000004","generation":7,"sequence":1,"created_at":"2026-07-19T20:00:03Z","type":"action.intent","payload":{"schema":"almsivi.action-intent.v1","action_id":"01900000-0000-7000-8000-000000000007","turn_id":"01900000-0000-7000-8000-000000000005","name":"item.equip","tier":2,"actor":{"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"},"target":{"kind":"player","record_id":"player","refnum":{"index":1,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"interior","name":"Office"},"display_name":"Player"},"parameters":{"record_id":"iron dagger","slot":"carried_right"},"expires_at":"2026-07-19T20:00:30Z"}}],"autonomy":[]})",
        jsonHeaders);
    CHECK(equipment && equipment.value().events.size() == 1);
    if (equipment && equipment.value().events.size() == 1) {
        const auto* equip = std::get_if<almsivi::ActionIntentEventPayload>(&equipment.value().events[0].payload);
        CHECK(equip && equip->intent.kind == almsivi::ActionIntentKind::item_equip
            && equip->intent.stringParameter == "iron dagger"
            && equip->intent.secondaryStringParameter == "carried_right");
    }
}

void testQueue()
{
    almsivi::BoundedQueue<int> queue(5, 2);
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
    almsivi::GenerationState generations;
    CHECK(generations.current() == almsivi::Generation(0));
    CHECK(generations.invalidate() == almsivi::Generation(1));
    almsivi::GenerationState seeded(almsivi::Generation(42));
    CHECK(seeded.current() == almsivi::Generation(42));
    CHECK(seeded.invalidate() == almsivi::Generation(43));
    almsivi::CancellationRegistry registry;
    auto token = registry.registerRequest(almsivi::RequestId("a"), almsivi::Generation(1));
    CHECK(token && !token.value().stop_requested());
    CHECK(!registry.registerRequest(almsivi::RequestId("a"), almsivi::Generation(1)));
    CHECK(registry.cancel(almsivi::RequestId("a")) && token.value().stop_requested());
    registry.complete(almsivi::RequestId("a"));
    CHECK(registry.size() == 0);
}

void testEvents()
{
    almsivi::EventTracker tracker;
    const almsivi::SessionId session(kSession);
    const almsivi::MessageId message1(kMessage);
    const almsivi::MessageId message2("01900000-0000-7000-8000-000000000008");
    const almsivi::MessageId message3("01900000-0000-7000-8000-000000000009");
    CHECK(tracker.observe({session, 1, message1}).disposition == almsivi::EventDisposition::accepted);
    CHECK(tracker.observe({session, 1, message1}).disposition == almsivi::EventDisposition::duplicate);
    auto gap = tracker.observe({session, 3, message3});
    CHECK(gap.disposition == almsivi::EventDisposition::gap && gap.expectedSequence == 2);
    CHECK(tracker.observe({session, 2, message2}).disposition == almsivi::EventDisposition::accepted);
    CHECK(tracker.observe({almsivi::SessionId("bad"), 3, message3}).disposition == almsivi::EventDisposition::invalid);
    CHECK(tracker.observe({session, 3, almsivi::MessageId("BAD")}).disposition == almsivi::EventDisposition::invalid);
    CHECK(tracker.cursor(session) == 2);
}

void testActions()
{
    const auto follow = almsivi::validateAiFollow(192);
    CHECK(follow && follow.value().distance == 192);
    CHECK(!almsivi::validateAiFollow(0));
    CHECK(!almsivi::validateAiFollow(191));
    CHECK(!almsivi::validateAiFollow(193));
    CHECK(!almsivi::validateAiFollow(std::numeric_limits<std::uint32_t>::max()));
    almsivi::ActionResultRegistry registry;
    const almsivi::ActionId action(kAction);
    CHECK(!registry.registerAction(almsivi::ActionId("action"), almsivi::Generation(2)));
    CHECK(!registry.registerAction(almsivi::ActionId("01900000-0000-7000-8000-00000000000A"), almsivi::Generation(2)));
    CHECK(registry.registerAction(action, almsivi::Generation(2)));
    CHECK(registry.finish({action, almsivi::ActionTerminalStatus::succeeded, "package_started"}));
    CHECK(!registry.finish({action, almsivi::ActionTerminalStatus::failed, "duplicate"}));
    CHECK(registry.terminal(action));
}

void testPairingToken()
{
    static_assert(!std::is_copy_constructible_v<almsivi::PairingToken>);
    static_assert(!std::is_copy_assignable_v<almsivi::PairingToken>);
    static_assert(std::is_move_constructible_v<almsivi::PairingToken>);
    static_assert(std::is_constructible_v<almsivi::PairingToken, almsivi::PairingToken::Secret>);
    static_assert(!std::is_constructible_v<almsivi::PairingToken, std::string>);
    almsivi::PairingToken::Secret secret{};
    secret[0] = std::byte{0x42};
    almsivi::PairingToken token(secret);
    CHECK(!token.empty() && token.redacted() == "<redacted>");
    almsivi::PairingToken moved(std::move(token));
    CHECK(token.empty() && token.redacted() == "<unset>");
    CHECK(!moved.empty() && moved.redacted() == "<redacted>");
}

void testMedia()
{
    almsivi::MediaDescriptor descriptor;
    descriptor.id = almsivi::MediaId("01912345-6789-7abc-8def-0123456789ab");
    descriptor.bytes = 123; descriptor.expiresAt = std::chrono::system_clock::time_point(200s);
    CHECK(almsivi::validateMediaDescriptor(descriptor, {}, std::chrono::system_clock::time_point(100s)));
    const auto route = almsivi::mediaRoute(descriptor.id);
    CHECK(route && route.value() == "/media/01912345-6789-7abc-8def-0123456789ab");
    descriptor.id = almsivi::MediaId("../secret");
    CHECK(!almsivi::validateMediaDescriptor(descriptor, {}, std::chrono::system_clock::time_point(100s)));
    CHECK(!almsivi::mediaRoute(descriptor.id));
    descriptor.id = almsivi::MediaId("01912345-6789-7ABC-8def-0123456789ab");
    CHECK(!almsivi::validateMediaDescriptor(descriptor, {}, std::chrono::system_clock::time_point(100s)));
    CHECK(almsivi::resolveCachePath("cache", std::string(64, 'a'), almsivi::MediaCodec::ogg));
    CHECK(!almsivi::resolveCachePath("cache", std::string(63, 'a'), almsivi::MediaCodec::ogg));
}

void testBridgeDialogueDeliveryValidation()
{
    auto state = std::make_shared<TransportState>();
    auto clock = std::make_shared<FakeClock>();
    almsivi::BridgeService bridge(std::make_unique<FakeTransport>(state), clock);
    const auto generation = bridge.generation();
    const auto makeDelivery = [&](std::string id) {
        return almsivi::OutboundRequest{almsivi::RequestId(id), almsivi::SessionId(kSession), generation,
            almsivi::RequestKind::dialogue_delivery_result,
            almsivi::DialogueDeliveryResultRequest{almsivi::MessageId(kMessage),
                {almsivi::RequestId(id), almsivi::SessionId(kSession), generation},
                almsivi::MessageId(kAction), almsivi::TurnId(kTurn), protocolIdentity(),
                almsivi::DialogueDeliveryStatus::played, "playback_completed", "2026-07-19T20:00:02.123Z"}};
    };
    auto separatelyCorrelated = makeDelivery(uuidFor(80));
    std::get<almsivi::DialogueDeliveryResultRequest>(separatelyCorrelated.payload).correlation.request
        = almsivi::RequestId(uuidFor(79));
    CHECK(bridge.enqueue(std::move(separatelyCorrelated)));
    auto mismatchedKind = makeDelivery(uuidFor(81));
    mismatchedKind.kind = almsivi::RequestKind::turn;
    CHECK(!bridge.enqueue(std::move(mismatchedKind)));
    auto badSpeaker = makeDelivery(uuidFor(82));
    std::get<almsivi::DialogueDeliveryResultRequest>(badSpeaker.payload).serializedSpeaker = "{}";
    CHECK(!bridge.enqueue(std::move(badSpeaker)));
    auto badCorrelation = makeDelivery(uuidFor(83));
    std::get<almsivi::DialogueDeliveryResultRequest>(badCorrelation.payload).correlation.request
        = almsivi::RequestId("request");
    CHECK(!bridge.enqueue(std::move(badCorrelation)));
    auto badReason = makeDelivery(uuidFor(85));
    std::get<almsivi::DialogueDeliveryResultRequest>(badReason.payload).reasonCode = "Bad-Reason";
    CHECK(!bridge.enqueue(std::move(badReason)));
    auto badTimestamp = makeDelivery(uuidFor(86));
    std::get<almsivi::DialogueDeliveryResultRequest>(badTimestamp.payload).completedAt = "2026-02-30T20:00:02Z";
    CHECK(!bridge.enqueue(std::move(badTimestamp)));

    almsivi::EnvelopeIds sttIds{almsivi::InstallationId(kInstallation), almsivi::ProfileId(kProfile),
        almsivi::PlaythroughId(kPlaythrough), almsivi::SessionId(kSession), almsivi::RequestId(uuidFor(87)),
        almsivi::TurnId(kTurn), almsivi::MessageId(kMessage), generation};
    almsivi::OutboundRequest stt{almsivi::RequestId(uuidFor(87)), almsivi::SessionId(kSession), generation,
        almsivi::RequestKind::stt, almsivi::SttRequest{std::move(sttIds), "2026-07-19T20:00:02Z",
            "ogg", "en-US", std::string(64, 'a'), {std::byte{'O'}}}};
    CHECK(!bridge.enqueue(std::move(stt)));
    bridge.halt();
}

void testBridge()
{
    auto state = std::make_shared<TransportState>();
    auto clock = std::make_shared<FakeClock>();
    almsivi::BridgeService bridge(std::make_unique<FakeTransport>(state), clock);
    const auto generation = bridge.generation();
    CHECK(!bridge.enqueue(request("one", generation)));
    CHECK(!bridge.enqueue(request("01900000-0000-7000-8000-00000000000A", generation)));
    auto malformedSession = request(uuidFor(14), generation);
    malformedSession.session = almsivi::SessionId("session");
    CHECK(!bridge.enqueue(std::move(malformedSession)));
    auto malformedEnvelope = request(uuidFor(15), generation);
    std::get<almsivi::TurnRequest>(malformedEnvelope.payload).ids.profile = almsivi::ProfileId("PROFILE");
    CHECK(!bridge.enqueue(std::move(malformedEnvelope)));
    almsivi::EnvelopeIds initIds{almsivi::InstallationId(kInstallation), almsivi::ProfileId(kProfile),
        almsivi::PlaythroughId(kPlaythrough), {}, almsivi::RequestId(uuidFor(13)), almsivi::TurnId(kTurn),
        almsivi::MessageId(kMessage), generation};
    almsivi::OutboundRequest init{almsivi::RequestId(uuidFor(13)), {}, generation, almsivi::RequestKind::init,
        almsivi::InitRequest{std::move(initIds), {}, "sha256:test", "2026-07-18T20:00:00Z"}};
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
    CHECK(bridge.cancel(almsivi::RequestId(uuidFor(17))));
    bool sawCancelled = false;
    for (int tries = 0; tries < 10000 && !sawCancelled; ++tries) {
        for (const auto& result : bridge.poll(8))
            sawCancelled = sawCancelled || (result.request == almsivi::RequestId(uuidFor(17))
                && result.kind == almsivi::ResponseKind::cancelled);
        std::this_thread::yield();
    }
    CHECK(sawCancelled);
    state->block = true;
    CHECK(bridge.enqueue(request(uuidFor(21), generation)));
    for (int tries = 0; tries < 10000 && state->executions.load() < 4; ++tries)
        std::this_thread::yield();
    CHECK(bridge.enqueue(request(uuidFor(22), generation)));
    const auto interruptsBeforeQueuedCancel = state->interrupts.load();
    CHECK(bridge.cancel(almsivi::RequestId(uuidFor(22))));
    CHECK(state->interrupts.load() == interruptsBeforeQueuedCancel);
    state->block = false;
    auto next = bridge.cancelGeneration(generation);
    CHECK(next && next.value() == almsivi::Generation(generation.value() + 1));
    CHECK(!bridge.enqueue(request(uuidFor(18), generation)));
    CHECK(bridge.enqueue(request(uuidFor(19), bridge.generation())));
    bridge.halt();
    CHECK(bridge.halted());
    CHECK(!bridge.enqueue(request(uuidFor(20), bridge.generation())));
}

void testVoiceCapturePrimitives()
{
    const std::string abc = "abc";
    CHECK(almsivi::sha256Hex(std::as_bytes(std::span(abc.data(), abc.size())))
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    const std::array pcm{std::byte{0x00}, std::byte{0x00}, std::byte{0xff}, std::byte{0x7f}};
    const auto wav = almsivi::makePcm16MonoWav(pcm);
    CHECK(wav.size() == 48);
    CHECK(std::to_integer<char>(wav[0]) == 'R' && std::to_integer<char>(wav[8]) == 'W');
    CHECK(std::to_integer<unsigned>(wav[40]) == 4U && wav[44] == pcm[0] && wav[47] == pcm[3]);
    CHECK(almsivi::makePcm16MonoWav(std::span<const std::byte>{}).empty());
    const std::array<std::byte, 8> silence{};
    const std::array<std::byte, 8> voice{std::byte{0x00},std::byte{0x10},std::byte{0x00},std::byte{0x10},
        std::byte{0x00},std::byte{0x10},std::byte{0x00},std::byte{0x10}};
    CHECK(!almsivi::pcm16HasVoice(silence));
    CHECK(almsivi::pcm16HasVoice(voice));
#ifndef _WIN32
    auto& capture = almsivi::VoiceCaptureService::instance();
    CHECK(!capture.supported());
    CHECK(capture.state() == almsivi::VoiceCaptureState::unsupported);
    CHECK(!capture.start());
#endif
}

void testConcurrency()
{
    auto state = std::make_shared<TransportState>();
    auto clock = std::make_shared<FakeClock>();
    almsivi::BridgeService bridge(std::make_unique<FakeTransport>(state), clock);
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
