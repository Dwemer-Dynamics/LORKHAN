#include "almsivi/actions.hpp"
#include "almsivi/bridge_service.hpp"
#include "almsivi/events.hpp"
#include "almsivi/media.hpp"
#include "almsivi/queues.hpp"
#include "almsivi/validation.hpp"

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace std::chrono_literals;

namespace {

int failures = 0;
#define CHECK(expression) do { if (!(expression)) { std::cerr << __FILE__ << ':' << __LINE__ << ": CHECK failed: " #expression "\n"; ++failures; } } while (false)

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
    void interrupt() noexcept override { ++m_state->interrupts; m_state->block = false; }
private:
    std::shared_ptr<TransportState> m_state;
};

almsivi::OutboundRequest request(std::string id, almsivi::Generation generation)
{
    return {almsivi::RequestId(std::move(id)), almsivi::SessionId("session"), generation,
        almsivi::RequestKind::turn,
        almsivi::TurnRequest{almsivi::EnvelopeIds{{}, {}, {}, {}, {}, {}, {}, generation}, "{}"}};
}

void testUtf8()
{
    CHECK(almsivi::isValidUtf8("plain"));
    CHECK(almsivi::isValidUtf8("Morrowind \xE2\x9C\x93"));
    CHECK(!almsivi::isValidUtf8(std::string("\xC0\x80", 2)));
    CHECK(!almsivi::isValidUtf8(std::string("\xED\xA0\x80", 3)));
    CHECK(!almsivi::isValidUtf8(std::string("\xF4\x90\x80\x80", 4)));
    CHECK(!almsivi::requireValidUtf8("abcd", 3));
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
    const almsivi::SessionId session("s");
    CHECK(tracker.observe({session, 1, almsivi::MessageId("m1")}).disposition == almsivi::EventDisposition::accepted);
    CHECK(tracker.observe({session, 1, almsivi::MessageId("m1")}).disposition == almsivi::EventDisposition::duplicate);
    auto gap = tracker.observe({session, 3, almsivi::MessageId("m3")});
    CHECK(gap.disposition == almsivi::EventDisposition::gap && gap.expectedSequence == 2);
    CHECK(tracker.observe({session, 2, almsivi::MessageId("m2")}).disposition == almsivi::EventDisposition::accepted);
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
    const almsivi::ActionId action("action");
    CHECK(registry.registerAction(action, almsivi::Generation(2)));
    CHECK(registry.finish({action, almsivi::ActionTerminalStatus::succeeded, "package_started"}));
    CHECK(!registry.finish({action, almsivi::ActionTerminalStatus::failed, "duplicate"}));
    CHECK(registry.terminal(action));
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

void testBridge()
{
    auto state = std::make_shared<TransportState>();
    auto clock = std::make_shared<FakeClock>();
    almsivi::BridgeService bridge(std::make_unique<FakeTransport>(state), clock);
    const auto generation = bridge.generation();
    CHECK(bridge.enqueue(request("one", generation)));
    CHECK(!bridge.enqueue(request("one", generation)));
    for (int tries = 0; tries < 1000 && bridge.poll(1).empty(); ++tries)
        std::this_thread::yield();
    CHECK(state->executions == 1);
    state->block = true;
    CHECK(bridge.enqueue(request("cancel-me", generation)));
    for (int tries = 0; tries < 10000 && state->executions.load() < 2; ++tries)
        std::this_thread::yield();
    CHECK(bridge.cancel(almsivi::RequestId("cancel-me")));
    bool sawCancelled = false;
    for (int tries = 0; tries < 10000 && !sawCancelled; ++tries) {
        for (const auto& result : bridge.poll(8))
            sawCancelled = sawCancelled || (result.request == almsivi::RequestId("cancel-me")
                && result.kind == almsivi::ResponseKind::cancelled);
        std::this_thread::yield();
    }
    CHECK(sawCancelled);
    auto next = bridge.cancelGeneration(generation);
    CHECK(next && next.value() == almsivi::Generation(generation.value() + 1));
    CHECK(!bridge.enqueue(request("stale", generation)));
    CHECK(bridge.enqueue(request("current", bridge.generation())));
    bridge.halt();
    CHECK(bridge.halted());
    CHECK(!bridge.enqueue(request("after", bridge.generation())));
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
                if (bridge.enqueue(request(std::to_string(thread) + "-" + std::to_string(i), generation)))
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
    testUtf8(); testUrls(); testHeaders(); testQueue(); testLifecycleAndCancellation();
    testEvents(); testActions(); testMedia(); testBridge(); testConcurrency();
    if (failures != 0) {
        std::cerr << failures << " test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all native bridge tests passed\n";
    return EXIT_SUCCESS;
}
