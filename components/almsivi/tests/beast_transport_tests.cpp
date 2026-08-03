#include "almsivi/beast_transport.hpp"
#include "almsivi/protocol_response.hpp"

#include <boost/asio/ip/tcp.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>

#include <array>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iomanip>
#include <iostream>
#include <optional>
#include <sstream>
#include <stop_token>
#include <string>
#include <thread>
#include <utility>

using namespace std::chrono_literals;

namespace {

namespace asio = boost::asio;
namespace beast = boost::beast;
namespace http = beast::http;
using tcp = asio::ip::tcp;

int failures = 0;
#define CHECK(expression) do { if (!(expression)) { std::cerr << __FILE__ << ':' << __LINE__ << ": CHECK failed: " #expression "\n"; ++failures; } } while (false)

constexpr const char* kInstallation = "01900000-0000-7000-8000-000000000001";
constexpr const char* kProfile = "01900000-0000-7000-8000-000000000002";
constexpr const char* kPlaythrough = "01900000-0000-7000-8000-000000000003";
constexpr const char* kSession = "01900000-0000-7000-8000-000000000004";
constexpr const char* kTurn = "01900000-0000-7000-8000-000000000005";
constexpr const char* kMessage = "01900000-0000-7000-8000-000000000006";
constexpr const char* kAction = "01900000-0000-7000-8000-000000000007";
constexpr const char* kRequest = "01900000-0000-7000-8000-000000000008";
constexpr const char* kEndRequest = "01900000-0000-7000-8000-000000000009";
constexpr std::string_view kBasePath = "/ALMSIVIserver/api/v1";

struct CapturedRequest {
    http::verb method{};
    std::string target;
    std::string authorization;
    std::string idempotency;
    std::string contentType;
    std::string sttSchema;
    std::string sttMessage;
    std::string sttRequest;
    std::string sttTurn;
    std::string sttSession;
    std::string sttGeneration;
    std::string sttCreatedAt;
    std::string sttCodec;
    std::string sttLanguage;
    std::string sttAudioBytes;
    std::string sttSha256;
    std::string body;
};

class OneShotServer {
public:
    using Handler = std::function<void(const CapturedRequest&, tcp::socket&)>;

    explicit OneShotServer(Handler handler)
        : m_acceptor(m_context, tcp::endpoint(asio::ip::make_address("127.0.0.1"), 0))
        , m_port(m_acceptor.local_endpoint().port())
        , m_thread([this, handler = std::move(handler)]() mutable {
            boost::system::error_code error;
            tcp::socket socket(m_context);
            m_acceptor.accept(socket, error);
            if (error)
                return;
            beast::flat_buffer buffer;
            http::request_parser<http::string_body> parser;
            parser.body_limit(almsivi::kMaxJsonBytes);
            http::read(socket, buffer, parser, error);
            if (error)
                return;
            const auto& request = parser.get();
            CapturedRequest captured{request.method(), std::string(request.target()),
                std::string(request[http::field::authorization]), std::string(request["Idempotency-Key"]),
                std::string(request[http::field::content_type]), std::string(request["X-ALMSIVI-Schema"]),
                std::string(request["X-ALMSIVI-Message-Id"]), std::string(request["X-ALMSIVI-Request-Id"]),
                std::string(request["X-ALMSIVI-Turn-Id"]), std::string(request["X-ALMSIVI-Session-Id"]),
                std::string(request["X-ALMSIVI-Generation"]), std::string(request["X-ALMSIVI-Created-At"]),
                std::string(request["X-ALMSIVI-Codec"]), std::string(request["X-ALMSIVI-Language"]),
                std::string(request["X-ALMSIVI-Audio-Bytes"]), std::string(request["X-ALMSIVI-Sha256"]),
                request.body()};
            handler(captured, socket);
        })
    {
    }

    ~OneShotServer()
    {
        boost::system::error_code ignored;
        m_acceptor.close(ignored);
    }

    std::uint16_t port() const noexcept { return m_port; }

private:
    asio::io_context m_context;
    tcp::acceptor m_acceptor;
    std::uint16_t m_port;
    std::jthread m_thread;
};

void sendRaw(tcp::socket& socket, std::string response)
{
    boost::system::error_code ignored;
    asio::write(socket, asio::buffer(response), ignored);
    socket.shutdown(tcp::socket::shutdown_both, ignored);
}

void sendJson(tcp::socket& socket, unsigned status, std::string body,
    std::string_view contentType = "application/json; charset=utf-8")
{
    http::response<http::string_body> response{static_cast<http::status>(status), 11};
    response.set(http::field::content_type, std::string(contentType));
    response.set(http::field::connection, "close");
    response.body() = std::move(body);
    response.prepare_payload();
    boost::system::error_code ignored;
    http::write(socket, response, ignored);
    socket.shutdown(tcp::socket::shutdown_both, ignored);
}

almsivi::MediaPrepareRequest mediaPayload()
{
    almsivi::MediaDescriptor descriptor;
    descriptor.id = almsivi::MediaId("01900000-0000-7000-8000-000000000013");
    const std::array<unsigned char, 32> hash{0x68,0xd9,0xed,0x2a,0xdb,0x24,0x45,0x8f,
        0xf1,0x73,0xdb,0x06,0xb4,0x1b,0x9d,0x1b,0x6e,0x22,0x87,0x64,0xc4,0x57,0x03,0x0d,
        0x63,0xfa,0xd1,0x1b,0x02,0xbf,0xae,0x1e};
    for (std::size_t index = 0; index < hash.size(); ++index)
        descriptor.sha256[index] = std::byte(hash[index]);
    descriptor.bytes = 4;
    descriptor.codec = almsivi::MediaCodec::ogg;
    descriptor.expiresAt = std::chrono::system_clock::now() + 1h;
    return {{almsivi::RequestId(kRequest), almsivi::SessionId(kSession), almsivi::Generation(7)}, descriptor};
}

almsivi::OutboundRequest mediaRequest()
{
    return {almsivi::RequestId(kRequest), almsivi::SessionId(kSession), almsivi::Generation(7),
        almsivi::RequestKind::media, mediaPayload()};
}

almsivi::PairingToken token()
{
    return almsivi::PairingToken(almsivi::PairingToken::Secret{});
}

almsivi::BaseUrl url(std::uint16_t port)
{
    return {"127.0.0.1", port, std::string(kBasePath), false};
}

std::filesystem::path cacheRoot()
{
    const auto root = std::filesystem::temp_directory_path() / "almsivi-beast-media-tests";
    std::filesystem::create_directories(root);
    return root;
}

almsivi::EnvelopeIds ids()
{
    return {almsivi::InstallationId(kInstallation), almsivi::ProfileId(kProfile),
        almsivi::PlaythroughId(kPlaythrough), almsivi::SessionId(kSession), almsivi::RequestId(kRequest),
        almsivi::TurnId(kTurn), almsivi::MessageId(kMessage), almsivi::Generation(7)};
}

almsivi::RuntimeInfo runtime()
{
    almsivi::RuntimeInfo result;
    result.platform = "test-x86_64";
    result.capabilities = {"dialogue.text", "action.ai.follow"};
    return result;
}

almsivi::OutboundRequest health()
{
    return {almsivi::RequestId(kRequest), {}, almsivi::Generation(7),
        almsivi::RequestKind::health, almsivi::HealthRequest{}};
}

almsivi::OutboundRequest init()
{
    auto envelope = ids();
    envelope.session = {};
    envelope.request = almsivi::RequestId(kRequest);
    return {almsivi::RequestId(kRequest), {}, almsivi::Generation(7), almsivi::RequestKind::init,
        almsivi::InitRequest{std::move(envelope), runtime(),
            "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "2026-07-18T20:00:00Z"}};
}

almsivi::OutboundRequest turn()
{
    return {almsivi::RequestId(kRequest), almsivi::SessionId(kSession), almsivi::Generation(7),
        almsivi::RequestKind::turn, almsivi::TurnRequest{ids(), runtime(),
            "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "2026-07-18T20:00:00Z", "{}"}};
}

std::string liveUuid(std::uint64_t run, std::uint16_t suffix)
{
    std::ostringstream stream;
    stream << std::hex << std::setfill('0') << std::setw(8) << static_cast<std::uint32_t>(run)
           << "-0000-4000-8000-" << std::setw(12) << suffix;
    return stream.str();
}

struct LiveIds {
    std::string installation;
    std::string profile;
    std::string playthrough;
    std::string sessionMessage;
    std::string followMessage;
    std::string followRequest;
    std::string followTurn;
    std::string actionResultMessage;
    std::string actionResultRequest;
    std::string blockedMessage;
    std::string blockedRequest;
    std::string blockedTurn;
    std::string interruptMessage;
    std::string failureMessage;
    std::string failureRequest;
    std::string failureTurn;
    std::string slowMessage;
    std::string slowRequest;
    std::string slowTurn;
    std::string recoveredMessage;
    std::string recoveredRequest;
    std::string recoveredTurn;
    std::string endRequest;
};

LiveIds makeLiveIds()
{
    const auto tick = static_cast<std::uint64_t>(
        std::chrono::steady_clock::now().time_since_epoch().count()) & 0xffffffffULL;
    std::uint16_t suffix = 1;
    const auto next = [&] { return liveUuid(tick, suffix++); };
    return {next(), next(), next(), next(), next(), next(), next(), next(), next(), next(), next(), next(),
        next(), next(), next(), next(), next(), next(), next(), next(), next(), next(), next()};
}

almsivi::RuntimeInfo liveRuntime()
{
    auto result = runtime();
    result.capabilities = {"dialogue.text", "action.ai.follow"};
    return result;
}

std::string livePayload(std::string_view input)
{
    return std::string(R"({"audience":[{"cell":{"grid_x":-2,"grid_y":-9,"kind":"exterior"},"content_file":"Morrowind.esm","display_name":"Fargoth","kind":"npc","record_id":"fargoth","refnum":{"content_file":0,"index":112}}],"context":{"truncated":false},"input":{"kind":"text","language":"en-US","text":")")
        + std::string(input)
        + R"("},"recent_action_results":[],"speaker":{"cell":{"name":"Balmora, Guild of Mages","kind":"interior"},"content_file":"Morrowind.esm","display_name":"Player","kind":"player","record_id":"player","refnum":{"content_file":0,"index":0}},"target":{"cell":{"grid_x":-2,"grid_y":-9,"kind":"exterior"},"content_file":"Morrowind.esm","display_name":"Fargoth","kind":"npc","record_id":"fargoth","refnum":{"content_file":0,"index":112}},"ui_source":"text"})";
}

almsivi::OutboundRequest liveTurn(const LiveIds& live, const almsivi::SessionId& session,
    std::string message, std::string request, std::string turnId, std::string input)
{
    almsivi::EnvelopeIds envelope{almsivi::InstallationId(live.installation), almsivi::ProfileId(live.profile),
        almsivi::PlaythroughId(live.playthrough), session, almsivi::RequestId(request), almsivi::TurnId(turnId),
        almsivi::MessageId(message), almsivi::Generation(7)};
    return {almsivi::RequestId(request), session, almsivi::Generation(7), almsivi::RequestKind::turn,
        almsivi::TurnRequest{std::move(envelope), liveRuntime(),
            "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "2026-07-19T20:00:00Z", livePayload(input)}};
}

almsivi::Result<almsivi::EventsResponse> pollEvents(almsivi::BeastTransport& transport,
    const almsivi::SessionId& session, std::uint64_t after, std::uint32_t waitMs = 0)
{
    almsivi::OutboundRequest request{almsivi::RequestId(liveUuid(static_cast<std::uint64_t>(after + 1), 99)),
        session, almsivi::Generation(7), almsivi::RequestKind::event_poll,
        almsivi::EventPollRequest{session, almsivi::Generation(7), after, waitMs}};
    auto response = transport.execute(request, {});
    if (!response)
        return almsivi::Result<almsivi::EventsResponse>::failure(response.error());
    return almsivi::parseEventsResponse(response.value().payload,
        {{"Content-Type", "application/json; charset=utf-8"}});
}

bool waitForFile(const std::filesystem::path& path, std::chrono::milliseconds timeout)
{
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (std::chrono::steady_clock::now() < deadline) {
        if (std::filesystem::is_regular_file(path))
            return true;
        std::this_thread::sleep_for(5ms);
    }
    return std::filesystem::is_regular_file(path);
}

std::string utcNow()
{
    const std::time_t current = std::time(nullptr);
    std::tm value{};
#ifdef _WIN32
    gmtime_s(&value, &current);
#else
    gmtime_r(&current, &value);
#endif
    std::ostringstream stream;
    stream << std::put_time(&value, "%Y-%m-%dT%H:%M:%SZ");
    return stream.str();
}

void testHealthAndWirePolicy()
{
    OneShotServer server([](const CapturedRequest& request, tcp::socket& socket) {
        CHECK(request.method == http::verb::get);
        CHECK(request.target == std::string(kBasePath) + "/health");
        CHECK(request.authorization.empty());
        CHECK(request.idempotency.empty());
        CHECK(request.contentType.empty());
        sendJson(socket, 200, R"({"schema":"almsivi.health.v1"})");
    });
    almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
    auto result = transport.execute(health(), {});
    CHECK(result && result.value().kind == almsivi::ResponseKind::status);
}

void testSessionTurnAndCorrelation()
{
    {
        OneShotServer server([](const CapturedRequest& request, tcp::socket& socket) {
            CHECK(request.method == http::verb::post);
            CHECK(request.target == std::string(kBasePath) + "/sessions");
            CHECK(request.idempotency == kMessage);
            CHECK(request.contentType == "application/json; charset=utf-8");
            CHECK(request.body.find("\"schema\":\"almsivi.session.init.v1\"") != std::string::npos);
            CHECK(request.body.find("\"created_at\":\"2026-07-18T20:00:00Z\"") != std::string::npos);
            sendJson(socket, 201, std::string(R"({"schema":"almsivi.session.accepted.v1","message_id":")")
                + kMessage + R"(","session_id":")" + kSession
                + R"(","generation":7,"capabilities":["dialogue.text"],"config_revision":"test","event_cursor":0})");
        });
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        auto result = transport.execute(init(), {});
        CHECK(result && result.value().session == almsivi::SessionId(kSession));
    }
    {
        OneShotServer server([](const CapturedRequest& request, tcp::socket& socket) {
            CHECK(request.target == std::string(kBasePath) + "/turns");
            CHECK(request.idempotency == kMessage);
            CHECK(request.body.find("\"payload\":{}") != std::string::npos);
            sendJson(socket, 202, std::string(R"({"schema":"almsivi.turn.accepted.v1","message_id":")")
                + kMessage + R"(","request_id":")" + kRequest + R"(","turn_id":")" + kTurn
                + R"(","session_id":")" + kSession + R"(","generation":7,"event_cursor":1})");
        });
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        CHECK(transport.execute(turn(), {}));
    }
    {
        OneShotServer server([](const CapturedRequest&, tcp::socket& socket) {
            sendJson(socket, 202, std::string(R"({"schema":"almsivi.turn.accepted.v1","message_id":")")
                + kMessage + R"(","request_id":"01900000-0000-7000-8000-000000000099","turn_id":")"
                + kTurn + R"(","session_id":")" + kSession + R"(","generation":7,"event_cursor":1})");
        });
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        auto result = transport.execute(turn(), {});
        CHECK(!result && result.error().code == almsivi::ErrorCode::transport_failure);
    }
}

void testEventsInterruptionActionAndDelete()
{
    {
        OneShotServer server([](const CapturedRequest& request, tcp::socket& socket) {
            CHECK(request.target == std::string(kBasePath) + "/events?session_id=" + kSession
                + "&generation=7&after=3&wait_ms=15000");
            sendJson(socket, 200, std::string(R"({"schema":"almsivi.events.v1","session_id":")")
                + kSession + R"(","generation":7,"next_after":3,"events":[],"autonomy":[]})");
        });
        almsivi::OutboundRequest request{almsivi::RequestId(kRequest), almsivi::SessionId(kSession),
            almsivi::Generation(7), almsivi::RequestKind::event_poll,
            almsivi::EventPollRequest{almsivi::SessionId(kSession), almsivi::Generation(7), 3, 15000}};
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        auto result = transport.execute(request, {});
        CHECK(result && result.value().kind == almsivi::ResponseKind::event);
    }
    {
        OneShotServer server([](const CapturedRequest& request, tcp::socket& socket) {
            CHECK(request.target == std::string(kBasePath) + "/interruptions");
            CHECK(request.idempotency == kMessage);
            sendJson(socket, 202, std::string(R"({"schema":"almsivi.interruption.accepted.v1","message_id":")")
                + kMessage + R"(","request_id":")" + kRequest + R"(","turn_id":")" + kTurn
                + R"(","session_id":")" + kSession + R"(","generation":7,"event_cursor":2,"duplicate":false})");
        });
        almsivi::OutboundRequest request{almsivi::RequestId(kRequest), almsivi::SessionId(kSession),
            almsivi::Generation(7), almsivi::RequestKind::interruption,
            almsivi::InterruptionRequest{almsivi::MessageId(kMessage), almsivi::RequestId(kRequest),
                almsivi::TurnId(kTurn), almsivi::SessionId(kSession), almsivi::Generation(7),
                "2026-07-18T20:00:03Z", "player"}};
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        CHECK(transport.execute(request, {}));
    }
    {
        OneShotServer server([](const CapturedRequest& request, tcp::socket& socket) {
            CHECK(request.target == std::string(kBasePath) + "/action-results");
            CHECK(request.idempotency == kMessage);
            CHECK(request.body.find("\"observed\":{\"package\":\"Follow\"}") != std::string::npos);
            sendJson(socket, 200, std::string(R"({"schema":"almsivi.action-result.accepted.v1","message_id":")")
                + kMessage + R"(","request_id":")" + kRequest + R"(","action_id":")" + kAction
                + R"(","turn_id":")" + kTurn + R"(","session_id":")" + kSession
                + R"(","generation":7,"status":"succeeded","duplicate":false})");
        });
        almsivi::OutboundRequest request{almsivi::RequestId(kRequest), almsivi::SessionId(kSession),
            almsivi::Generation(7), almsivi::RequestKind::action_result,
            almsivi::ActionResultRequest{almsivi::MessageId(kMessage),
                {almsivi::RequestId(kRequest), almsivi::SessionId(kSession), almsivi::Generation(7)},
                almsivi::ActionId(kAction), almsivi::TurnId(kTurn),
                almsivi::ActionTerminalStatus::succeeded, "package_started", "{\"package\":\"Follow\"}",
                "2026-07-18T20:00:04Z"}};
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        auto result = transport.execute(request, {});
        CHECK(result && result.value().kind == almsivi::ResponseKind::completed);
    }
    {
        OneShotServer server([](const CapturedRequest& request, tcp::socket& socket) {
            CHECK(request.method == http::verb::delete_);
            CHECK(request.target == std::string(kBasePath) + "/sessions/" + kSession);
            CHECK(request.idempotency == kEndRequest);
            sendJson(socket, 200, std::string(R"({"schema":"almsivi.session.ended.v1","request_id":")")
                + kEndRequest + R"(","session_id":")" + kSession
                + R"(","generation":7,"ended":true})");
        });
        almsivi::OutboundRequest request{almsivi::RequestId(kEndRequest), almsivi::SessionId(kSession),
            almsivi::Generation(7), almsivi::RequestKind::session_end,
            almsivi::SessionEndRequest{almsivi::RequestId(kEndRequest), almsivi::SessionId(kSession),
                almsivi::Generation(7)}};
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        CHECK(transport.execute(request, {}));
    }
}

void testSttAndDialogueDelivery()
{
    constexpr std::string_view hash = "a40ff3d5900fb7698b8c865041347cb49eccedc8f93945f89629ad104aaecce4";
    {
        OneShotServer server([hash](const CapturedRequest& request, tcp::socket& socket) {
            CHECK(request.method == http::verb::post);
            CHECK(request.target == std::string(kBasePath) + "/stt");
            CHECK(request.contentType == "application/octet-stream");
            CHECK(request.idempotency == kMessage);
            CHECK(request.sttSchema == "almsivi.stt.request.v1");
            CHECK(request.sttMessage == kMessage);
            CHECK(request.sttRequest == kRequest);
            CHECK(request.sttTurn == kTurn);
            CHECK(request.sttSession == kSession);
            CHECK(request.sttGeneration == "7");
            CHECK(request.sttCreatedAt == "2026-07-19T20:00:00Z");
            CHECK(request.sttCodec == "wav");
            CHECK(request.sttLanguage == "en-US");
            CHECK(request.sttAudioBytes == "4");
            CHECK(request.sttSha256 == hash);
            CHECK(request.body == "RIFF");
            sendJson(socket, 202, std::string(R"({"schema":"almsivi.stt.accepted.v1","message_id":")")
                + kMessage + R"(","request_id":")" + kRequest + R"(","turn_id":")" + kTurn
                + R"(","session_id":")" + kSession + R"(","generation":7,"event_cursor":8,"duplicate":false})");
        });
        std::vector<std::byte> audio{std::byte{'R'}, std::byte{'I'}, std::byte{'F'}, std::byte{'F'}};
        almsivi::OutboundRequest request{almsivi::RequestId(kRequest), almsivi::SessionId(kSession),
            almsivi::Generation(7), almsivi::RequestKind::stt,
            almsivi::SttRequest{ids(), "2026-07-19T20:00:00Z", "wav", "en-US",
                std::string(hash), std::move(audio)}};
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        CHECK(transport.execute(request, {}));
    }
    {
        OneShotServer server([](const CapturedRequest& request, tcp::socket& socket) {
            CHECK(request.target == std::string(kBasePath) + "/dialogue-delivery-results");
            CHECK(request.idempotency == kMessage);
            CHECK(request.body.find("\"schema\":\"almsivi.dialogue-delivery-result.v1\"") != std::string::npos);
            CHECK(request.body.find("\"status\":\"played\"") != std::string::npos);
            CHECK(request.body.find("\"speaker\":{\"kind\":\"npc\"") != std::string::npos);
            sendJson(socket, 200, std::string(R"({"schema":"almsivi.dialogue-delivery-result.accepted.v1","message_id":")")
                + kMessage + R"(","request_id":")" + kRequest + R"(","dialogue_message_id":")" + kAction
                + R"(","turn_id":")" + kTurn + R"(","session_id":")" + kSession
                + R"(","generation":7,"status":"played","duplicate":false})");
        });
        almsivi::OutboundRequest request{almsivi::RequestId(kRequest), almsivi::SessionId(kSession),
            almsivi::Generation(7), almsivi::RequestKind::dialogue_delivery_result,
            almsivi::DialogueDeliveryResultRequest{almsivi::MessageId(kMessage),
                {almsivi::RequestId(kRequest), almsivi::SessionId(kSession), almsivi::Generation(7)},
                almsivi::MessageId(kAction), almsivi::TurnId(kTurn),
                R"({"kind":"npc","record_id":"fargoth","refnum":{"index":112,"content_file":0},"content_file":"Morrowind.esm","cell":{"kind":"exterior","grid_x":-2,"grid_y":-9},"display_name":"Fargoth"})",
                almsivi::DialogueDeliveryStatus::played, "playback_completed", "2026-07-19T20:00:02Z"}};
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        auto result = transport.execute(request, {});
        CHECK(result && result.value().kind == almsivi::ResponseKind::completed);
    }
}

void testAuthenticatedVerifiedMedia()
{
    const auto finalPath = cacheRoot() / "68" / "68d9ed2adb24458ff173db06b41b9d1b6e228764c457030d63fad11b02bfae1e.ogg";
    std::error_code ignored;
    std::filesystem::remove(finalPath, ignored);
    {
        OneShotServer server([](const CapturedRequest& request, tcp::socket& socket) {
            CHECK(request.method == http::verb::get);
            CHECK(request.target == std::string(kBasePath) + "/media/01900000-0000-7000-8000-000000000013");
            CHECK(request.authorization.empty());
            sendJson(socket, 200, "OggS", "audio/ogg");
        });
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        auto result = transport.execute(mediaRequest(), {});
        CHECK(result && result.value().kind == almsivi::ResponseKind::media_ready);
        CHECK(std::filesystem::is_regular_file(finalPath));
        CHECK(!std::filesystem::exists(finalPath.string() + ".tmp-01900000-0000-7000-8000-000000000013"));
    }
    std::filesystem::remove(finalPath, ignored);
    {
        OneShotServer server([](const CapturedRequest&, tcp::socket& socket) {
            sendJson(socket, 200, "BAD!", "audio/ogg");
        });
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        auto result = transport.execute(mediaRequest(), {});
        CHECK(!result && result.error().code == almsivi::ErrorCode::media_rejected);
        CHECK(!std::filesystem::exists(finalPath));
    }
    {
        OneShotServer server([](const CapturedRequest&, tcp::socket& socket) {
            sendJson(socket, 200, "OggS", "audio/wav");
        });
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        auto result = transport.execute(mediaRequest(), {});
        CHECK(!result && result.error().code == almsivi::ErrorCode::invalid_content_type);
        CHECK(!std::filesystem::exists(finalPath));
    }
    {
        OneShotServer server([](const CapturedRequest&, tcp::socket& socket) {
            sendJson(socket, 200, "Ogg", "audio/ogg");
        });
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        auto result = transport.execute(mediaRequest(), {});
        CHECK(!result && result.error().code == almsivi::ErrorCode::media_rejected);
        CHECK(!std::filesystem::exists(finalPath));
    }
    {
        std::filesystem::create_directories(finalPath.parent_path());
        std::ofstream(finalPath, std::ios::binary | std::ios::trunc) << "BAD!";
        OneShotServer server([](const CapturedRequest&, tcp::socket& socket) {
            sendJson(socket, 200, "OggS", "audio/ogg");
        });
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        auto result = transport.execute(mediaRequest(), {});
        CHECK(result && result.value().kind == almsivi::ResponseKind::media_ready);
        std::ifstream repaired(finalPath, std::ios::binary);
        CHECK(std::string(std::istreambuf_iterator<char>(repaired), {}) == "OggS");
    }
    std::filesystem::remove(finalPath, ignored);
    {
        OneShotServer server([](const CapturedRequest&, tcp::socket& socket) {
            sendJson(socket, 302, "", "application/json; charset=utf-8");
        });
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        auto result = transport.execute(mediaRequest(), {});
        CHECK(!result && result.error().code == almsivi::ErrorCode::redirect_rejected);
        CHECK(!std::filesystem::exists(finalPath));
    }
    {
        OneShotServer server([](const CapturedRequest&, tcp::socket& socket) {
            sendJson(socket, 404, std::string(R"({"schema":"almsivi.error.v1","code":"media_unavailable","message":"missing","correlation_id":")")
                + kRequest + R"(","retriable":false})");
        });
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        auto result = transport.execute(mediaRequest(), {});
        CHECK(!result && result.error().code == almsivi::ErrorCode::media_rejected
            && result.error().correlationId == std::optional<std::string>(kRequest));
        CHECK(!std::filesystem::exists(finalPath));
    }
#ifndef _WIN32
    {
        std::filesystem::create_directories(finalPath.parent_path());
        const auto target = finalPath.string() + ".target";
        std::ofstream(target, std::ios::binary | std::ios::trunc) << "OggS";
        std::filesystem::create_symlink(target, finalPath);
        OneShotServer server([](const CapturedRequest&, tcp::socket& socket) {
            sendJson(socket, 200, "OggS", "audio/ogg");
        });
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        auto result = transport.execute(mediaRequest(), {});
        CHECK(!result && result.error().code == almsivi::ErrorCode::media_rejected);
        std::filesystem::remove(finalPath, ignored);
        std::filesystem::remove(target, ignored);
    }
#endif
}

void testResponseFailures()
{
    {
        OneShotServer server([](const CapturedRequest&, tcp::socket& socket) {
            sendRaw(socket, "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1/elsewhere\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        });
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        auto result = transport.execute(health(), {});
        CHECK(!result && result.error().code == almsivi::ErrorCode::redirect_rejected);
    }
    {
        OneShotServer server([](const CapturedRequest&, tcp::socket& socket) {
            sendJson(socket, 200, R"({"schema":"almsivi.health.v1"})", "text/plain");
        });
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        auto result = transport.execute(health(), {});
        CHECK(!result && result.error().code == almsivi::ErrorCode::invalid_content_type);
    }
    {
        OneShotServer server([](const CapturedRequest&, tcp::socket& socket) {
            sendJson(socket, 401, std::string(R"({"schema":"almsivi.error.v1","code":"unauthorized","message":"secret detail","correlation_id":")")
                + kRequest + R"(","retriable":false})");
        });
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        auto result = transport.execute(turn(), {});
        CHECK(!result && result.error().code == almsivi::ErrorCode::unauthorized);
        CHECK(result.error().message.find("secret") == std::string::npos);
    }
    {
        OneShotServer server([](const CapturedRequest&, tcp::socket& socket) {
            sendJson(socket, 401, R"({"schema":"almsivi.error.v1","code":"unauthorized","message":"wrong request","correlation_id":"01900000-0000-7000-8000-000000000010","retriable":false})");
        });
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        auto result = transport.execute(turn(), {});
        CHECK(!result && result.error().code == almsivi::ErrorCode::transport_failure
            && !result.error().correlationId);
    }
    {
        OneShotServer server([](const CapturedRequest&, tcp::socket& socket) {
            sendRaw(socket, "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n24\r\n{\"schema\":\"almsivi.health.v1\"}\r\n0\r\n\r\n");
        });
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        auto result = transport.execute(health(), {});
        CHECK(!result && result.error().code == almsivi::ErrorCode::transport_failure);
    }
    {
        OneShotServer server([](const CapturedRequest&, tcp::socket& socket) {
            sendRaw(socket, "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nConnection: close\r\n\r\n{\"schema\":\"almsivi.health.v1\"}");
        });
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        auto result = transport.execute(health(), {});
        CHECK(!result && result.error().code == almsivi::ErrorCode::transport_failure);
    }
}

void testDeadlineAndCancellation()
{
    {
        OneShotServer server([](const CapturedRequest&, tcp::socket&) { std::this_thread::sleep_for(150ms); });
        almsivi::BeastTransport::Deadlines deadlines;
        deadlines.firstByte = 20ms;
        deadlines.total = 100ms;
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot(), deadlines);
        auto result = transport.execute(health(), {});
        CHECK(!result && result.error().code == almsivi::ErrorCode::timeout);
    }
    {
        OneShotServer server([](const CapturedRequest&, tcp::socket&) { std::this_thread::sleep_for(150ms); });
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        std::stop_source source;
        std::optional<almsivi::Result<almsivi::InboundResult>> result;
        std::jthread worker([&] { result.emplace(transport.execute(health(), source.get_token())); });
        std::this_thread::sleep_for(20ms);
        source.request_stop();
        worker.join();
        CHECK(result && !*result && result->error().code == almsivi::ErrorCode::cancelled);
    }
    {
        OneShotServer server([](const CapturedRequest&, tcp::socket& socket) {
            std::this_thread::sleep_for(80ms);
            sendJson(socket, 200, R"({"schema":"almsivi.health.v1"})");
        });
        almsivi::BeastTransport transport(url(server.port()), almsivi::InstallationId(kInstallation), token(), cacheRoot());
        transport.interrupt(almsivi::RequestId("01900000-0000-7000-8000-000000000099"));
        auto result = transport.execute(health(), {});
        CHECK(result && result.value().kind == almsivi::ResponseKind::status);
    }
}

} // namespace

int main(int argc, char** argv)
{
    if (argc >= 3 && std::string_view(argv[1]) == "--live-url") {
        auto parsed = almsivi::parseLoopbackBaseUrl(argv[2]);
        if (!parsed) {
            std::cerr << "invalid live-server URL\n";
            return EXIT_FAILURE;
        }
        std::filesystem::path controlDirectory;
        if (argc == 5 && std::string_view(argv[3]) == "--control-dir")
            controlDirectory = argv[4];
        else if (argc != 3) {
            std::cerr << "usage: --live-url URL [--control-dir DIR]\n";
            return EXIT_FAILURE;
        }
        const almsivi::BaseUrl baseUrl = parsed.value();
        const LiveIds live = makeLiveIds();
        almsivi::BeastTransport transport(baseUrl, almsivi::InstallationId(live.installation), token(), cacheRoot());
        const auto require = [](bool condition, std::string_view message) {
            if (!condition) std::cerr << "live-server " << message << "\n";
            return condition;
        };
        if (!require(static_cast<bool>(transport.execute(health(), {})), "health failed"))
            return EXIT_FAILURE;

        almsivi::EnvelopeIds initIds{almsivi::InstallationId(live.installation), almsivi::ProfileId(live.profile),
            almsivi::PlaythroughId(live.playthrough), {}, almsivi::RequestId(live.sessionMessage), {},
            almsivi::MessageId(live.sessionMessage), almsivi::Generation(7)};
        almsivi::OutboundRequest initRequest{almsivi::RequestId(live.sessionMessage), {}, almsivi::Generation(7),
            almsivi::RequestKind::init, almsivi::InitRequest{std::move(initIds), liveRuntime(),
                "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "2026-07-19T20:00:00Z"}};
        auto sessionResponse = transport.execute(initRequest, {});
        if (!sessionResponse) {
            std::cerr << "live-server session failed with code " << static_cast<int>(sessionResponse.error().code)
                      << " message " << sessionResponse.error().message << "\n";
            return EXIT_FAILURE;
        }
        if (!require(!sessionResponse.value().session.empty(), "session response omitted session id"))
            return EXIT_FAILURE;
        const almsivi::SessionId liveSession = sessionResponse.value().session;

        auto follow = liveTurn(live, liveSession, live.followMessage, live.followRequest, live.followTurn,
            "Please follow me.");
        if (!require(static_cast<bool>(transport.execute(follow, {})), "follow turn failed"))
            return EXIT_FAILURE;
        std::optional<almsivi::ActionIntent> action;
        bool followComplete = false;
        std::uint64_t cursor = 0;
        for (int attempt = 0; attempt < 20 && (!action || !followComplete); ++attempt) {
            auto followEvents = pollEvents(transport, liveSession, cursor, 100);
            if (!require(static_cast<bool>(followEvents), "follow event poll failed"))
                return EXIT_FAILURE;
            cursor = followEvents.value().nextAfter;
            for (const auto& event : followEvents.value().events) {
                if (event.type == almsivi::ProtocolEventType::action_intent)
                    action = std::get<almsivi::ActionIntentEventPayload>(event.payload).intent;
                if (event.type == almsivi::ProtocolEventType::turn_complete)
                    followComplete = true;
            }
        }
        if (!require(action.has_value() && followComplete && action->followDistance == 192,
                "dynamic ai.follow event missing"))
            return EXIT_FAILURE;

        almsivi::OutboundRequest resultRequest{almsivi::RequestId(live.actionResultRequest), liveSession,
            almsivi::Generation(7), almsivi::RequestKind::action_result,
            almsivi::ActionResultRequest{almsivi::MessageId(live.actionResultMessage),
                {almsivi::RequestId(live.actionResultRequest), liveSession, almsivi::Generation(7)}, action->action,
                almsivi::TurnId(live.followTurn), almsivi::ActionTerminalStatus::succeeded, "package_started",
                R"({"package":"Follow"})", utcNow()}};
        auto firstResult = transport.execute(resultRequest, {});
        auto replayResult = transport.execute(resultRequest, {});
        if (!require(firstResult && replayResult, "action-result submission/replay failed"))
            return EXIT_FAILURE;
        auto firstAccepted = almsivi::parseActionResultAcceptedResponse(firstResult.value().payload,
            {{"Content-Type", "application/json; charset=utf-8"}});
        auto replayAccepted = almsivi::parseActionResultAcceptedResponse(replayResult.value().payload,
            {{"Content-Type", "application/json; charset=utf-8"}});
        if (!require(firstAccepted && replayAccepted && !firstAccepted.value().duplicate
                && replayAccepted.value().duplicate, "action-result duplicate markers were incoherent"))
            return EXIT_FAILURE;

        if (!controlDirectory.empty()) {
            std::ofstream(controlDirectory / "server-restart.ready") << "ready\n";
            if (!require(waitForFile(controlDirectory / "server-restart.release", 10s),
                    "HTTP server restart coordination timed out"))
                return EXIT_FAILURE;
            if (!require(static_cast<bool>(transport.execute(health(), {})),
                    "health failed after HTTP server restart"))
                return EXIT_FAILURE;
            auto restartReplay = transport.execute(resultRequest, {});
            auto restartAccepted = restartReplay
                ? almsivi::parseActionResultAcceptedResponse(restartReplay.value().payload,
                    {{"Content-Type", "application/json; charset=utf-8"}})
                : almsivi::Result<almsivi::ActionResultAcceptedResponse>::failure(restartReplay.error());
            if (!require(restartAccepted && restartAccepted.value().duplicate,
                    "durable action-result replay failed after HTTP server restart"))
                return EXIT_FAILURE;
        }

        if (!controlDirectory.empty()) {
            auto blocked = liveTurn(live, liveSession, live.blockedMessage, live.blockedRequest, live.blockedTurn,
                "[provider-block] please wait");
            std::optional<almsivi::Result<almsivi::InboundResult>> blockedResponse;
            std::jthread blockedThread([&] { blockedResponse.emplace(transport.execute(blocked, {})); });
            const auto ready = controlDirectory / (live.blockedTurn + ".ready");
            if (!require(waitForFile(ready, 2s), "controllable provider did not block")) {
                std::ofstream(controlDirectory / (live.blockedTurn + ".release"));
                blockedThread.join();
                return EXIT_FAILURE;
            }
            almsivi::BeastTransport interruptTransport(baseUrl, almsivi::InstallationId(live.installation), token(), cacheRoot());
            almsivi::OutboundRequest interruption{almsivi::RequestId(live.blockedRequest), liveSession,
                almsivi::Generation(7), almsivi::RequestKind::interruption,
                almsivi::InterruptionRequest{almsivi::MessageId(live.interruptMessage),
                    almsivi::RequestId(live.blockedRequest), almsivi::TurnId(live.blockedTurn), liveSession,
                    almsivi::Generation(7), "2026-07-19T20:00:02Z", "player"}};
            auto interrupted = interruptTransport.execute(interruption, {});
            std::ofstream(controlDirectory / (live.blockedTurn + ".release")) << "release\n";
            blockedThread.join();
            if (!require(interrupted && blockedResponse && *blockedResponse, "real HTTP interruption failed"))
                return EXIT_FAILURE;
            bool cancelledSeen = false;
            for (int attempt = 0; attempt < 20 && !cancelledSeen; ++attempt) {
                auto cancelledEvents = pollEvents(interruptTransport, liveSession, cursor, 100);
                if (!require(static_cast<bool>(cancelledEvents), "interruption event poll failed"))
                    return EXIT_FAILURE;
                cursor = cancelledEvents.value().nextAfter;
                for (const auto& event : cancelledEvents.value().events)
                    cancelledSeen = cancelledSeen || event.type == almsivi::ProtocolEventType::turn_cancelled;
            }
            if (!require(cancelledSeen, "interruption did not persist turn.cancelled"))
                return EXIT_FAILURE;
        }

        auto failed = liveTurn(live, liveSession, live.failureMessage, live.failureRequest, live.failureTurn,
            "[provider-fail]");
        if (!require(static_cast<bool>(transport.execute(failed, {})), "provider-failure turn was not accepted"))
            return EXIT_FAILURE;
        bool failureSeen = false;
        for (int attempt = 0; attempt < 20 && !failureSeen; ++attempt) {
            auto failedEvents = pollEvents(transport, liveSession, cursor, 100);
            if (!require(static_cast<bool>(failedEvents), "provider failure event poll failed"))
                return EXIT_FAILURE;
            cursor = failedEvents.value().nextAfter;
            for (const auto& event : failedEvents.value().events)
                failureSeen = failureSeen || event.type == almsivi::ProtocolEventType::turn_failed;
        }
        if (!require(failureSeen, "provider failure event missing"))
            return EXIT_FAILURE;

        almsivi::BeastTransport::Deadlines shortDeadlines;
        shortDeadlines.firstByte = 100ms;
        shortDeadlines.total = 100ms;
        almsivi::BeastTransport shortTransport(baseUrl, almsivi::InstallationId(live.installation), token(), cacheRoot(), shortDeadlines);
        auto slow = liveTurn(live, liveSession, live.slowMessage, live.slowRequest, live.slowTurn,
            "[provider-slow]");
        auto timeout = shortTransport.execute(slow, {});
        if (!timeout) {
            if (!require(timeout.error().code == almsivi::ErrorCode::timeout,
                    "real provider deadline returned wrong error"))
                return EXIT_FAILURE;
        }
        bool slowTerminalSeen = false;
        for (int attempt = 0; attempt < 20 && !slowTerminalSeen; ++attempt) {
            auto slowEvents = pollEvents(transport, liveSession, cursor, 100);
            if (!require(static_cast<bool>(slowEvents), "deadline-disconnected event poll failed"))
                return EXIT_FAILURE;
            cursor = slowEvents.value().nextAfter;
            for (const auto& event : slowEvents.value().events)
                slowTerminalSeen = slowTerminalSeen || event.type == almsivi::ProtocolEventType::turn_complete
                    || event.type == almsivi::ProtocolEventType::turn_failed;
        }
        if (!require(slowTerminalSeen, "server did not finish deadline-disconnected turn"))
            return EXIT_FAILURE;

        almsivi::OutboundRequest longPollRequest{almsivi::RequestId(liveUuid(1, 98)), liveSession,
            almsivi::Generation(7), almsivi::RequestKind::event_poll,
            almsivi::EventPollRequest{liveSession, almsivi::Generation(7), cursor, 5000}};
        std::stop_source stop;
        std::optional<almsivi::Result<almsivi::InboundResult>> pollResult;
        std::jthread pollThread([&] { pollResult.emplace(transport.execute(longPollRequest, stop.get_token())); });
        std::this_thread::sleep_for(50ms);
        stop.request_stop();
        pollThread.join();
        if (!require(pollResult && !*pollResult && pollResult->error().code == almsivi::ErrorCode::cancelled,
                "real long-poll cancellation failed"))
            return EXIT_FAILURE;
        if (!require(static_cast<bool>(transport.execute(health(), {})), "transport was not reusable after cancellation"))
            return EXIT_FAILURE;

        auto recovered = liveTurn(live, liveSession, live.recoveredMessage, live.recoveredRequest,
            live.recoveredTurn, "Recovered after cancellation.");
        if (!require(static_cast<bool>(transport.execute(recovered, {})), "post-cancellation turn failed"))
            return EXIT_FAILURE;

        almsivi::OutboundRequest endRequest{almsivi::RequestId(live.endRequest), liveSession,
            almsivi::Generation(7), almsivi::RequestKind::session_end,
            almsivi::SessionEndRequest{almsivi::RequestId(live.endRequest), liveSession, almsivi::Generation(7)}};
        auto ended = transport.execute(endRequest, {});
        auto endedReplay = transport.execute(endRequest, {});
        if (!require(ended && endedReplay, "session deletion/replay failed"))
            return EXIT_FAILURE;
        auto stale = liveTurn(live, liveSession, liveUuid(2, 91), liveUuid(2, 92), liveUuid(2, 93),
            "This should be rejected after deletion.");
        auto staleResponse = transport.execute(stale, {});
        if (!require(!staleResponse && staleResponse.error().code == almsivi::ErrorCode::unknown_session,
                "ended session remained usable"))
            return EXIT_FAILURE;

        std::cout << "real ALMSIVIserver full transport acceptance passed\n";
        return EXIT_SUCCESS;
    }

    testHealthAndWirePolicy();
    testSessionTurnAndCorrelation();
    testEventsInterruptionActionAndDelete();
    testSttAndDialogueDelivery();
    testAuthenticatedVerifiedMedia();
    testResponseFailures();
    testDeadlineAndCancellation();
    if (failures != 0) {
        std::cerr << failures << " Beast transport test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all Beast loopback transport tests passed\n";
    return EXIT_SUCCESS;
}
