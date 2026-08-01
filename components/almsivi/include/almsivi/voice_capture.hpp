#pragma once

#include "almsivi/types.hpp"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <thread>
#include <vector>

namespace almsivi {

struct CapturedVoice {
    std::vector<std::byte> wav;
    std::string sha256;
    std::uint64_t durationMs{};
};

enum class VoiceCaptureState { unsupported, idle, recording, ready, failed };

// Owns the single operating-system microphone stream used by push-to-talk and opt-in VAD capture.
class VoiceCaptureService final {
public:
    static VoiceCaptureService& instance();

    VoiceCaptureService(const VoiceCaptureService&) = delete;
    VoiceCaptureService& operator=(const VoiceCaptureService&) = delete;

    ~VoiceCaptureService();
    [[nodiscard]] bool supported() const noexcept;
    [[nodiscard]] Result<void> start(bool automatic = false);
    void stop() noexcept;
    void halt() noexcept;
    [[nodiscard]] VoiceCaptureState state() const noexcept;
    [[nodiscard]] std::string error() const;
    [[nodiscard]] std::size_t capturedBytes() const noexcept;
    [[nodiscard]] std::uint64_t durationMs() const noexcept;
    [[nodiscard]] bool automatic() const noexcept;
    [[nodiscard]] bool voiceDetected() const noexcept;
    [[nodiscard]] std::optional<CapturedVoice> takeReady();

private:
    VoiceCaptureService() = default;
    void capture();
    void publish(CapturedVoice result);
    void fail(std::string reason);

    mutable std::mutex m_mutex;
    std::thread m_worker;
    std::atomic_bool m_stop{false};
    std::atomic_bool m_automatic{false};
    std::atomic_bool m_voiceDetected{false};
    VoiceCaptureState m_state{
#ifdef _WIN32
        VoiceCaptureState::idle
#else
        VoiceCaptureState::unsupported
#endif
    };
    std::optional<CapturedVoice> m_ready;
    std::string m_error;
};

// Stable helpers keep WAV framing and hashing independently testable without a microphone.
[[nodiscard]] std::vector<std::byte> makePcm16MonoWav(
    std::span<const std::byte> pcm, std::uint32_t sampleRate = 16000);
[[nodiscard]] std::string sha256Hex(std::span<const std::byte> bytes);
[[nodiscard]] bool pcm16HasVoice(std::span<const std::byte> pcm, std::uint16_t rmsThreshold = 700);

} // namespace almsivi
