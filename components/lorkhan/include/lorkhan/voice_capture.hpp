#pragma once

#include "lorkhan/types.hpp"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <thread>
#include <vector>

namespace lorkhan {

struct CapturedVoice {
    std::vector<std::byte> wav;
    std::string sha256;
    std::uint64_t durationMs{};
    std::size_t pcmBytes{};
    std::uint16_t peakAmplitude{};
    std::uint16_t rmsAmplitude{};
    std::int32_t deviceId{-1};
    std::string deviceName;
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
    [[nodiscard]] Result<void> start(
        bool automatic = false, std::uint16_t rmsThreshold = 700,
        std::uint32_t trailingSilenceMs = 900, std::int32_t deviceId = -1);
    void stop() noexcept;
    void halt() noexcept;
    [[nodiscard]] VoiceCaptureState state() const noexcept;
    [[nodiscard]] std::string error() const;
    [[nodiscard]] std::size_t capturedBytes() const noexcept;
    [[nodiscard]] std::uint64_t durationMs() const noexcept;
    [[nodiscard]] bool automatic() const noexcept;
    [[nodiscard]] bool voiceDetected() const noexcept;
    [[nodiscard]] std::optional<CapturedVoice> takeReady();
    [[nodiscard]] std::size_t deviceCount() const noexcept;
    [[nodiscard]] std::int32_t deviceId() const noexcept;
    [[nodiscard]] std::string currentDeviceName(std::int32_t deviceId = -1) const;
    [[nodiscard]] std::string selectedDeviceName() const;
    [[nodiscard]] std::size_t capturedPcmBytes() const noexcept;
    [[nodiscard]] std::uint16_t peakAmplitude() const noexcept;
    [[nodiscard]] std::uint16_t rmsAmplitude() const noexcept;

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
    std::atomic<std::uint16_t> m_rmsThreshold{700};
    std::atomic<std::uint32_t> m_trailingSilenceMs{900};
    std::atomic<std::int32_t> m_deviceId{-1};
    std::atomic<std::size_t> m_capturedPcmBytes{0};
    std::atomic<std::uint16_t> m_peakAmplitude{0};
    std::atomic<std::uint16_t> m_rmsAmplitude{0};
    VoiceCaptureState m_state{
#ifdef _WIN32
        VoiceCaptureState::idle
#else
        VoiceCaptureState::unsupported
#endif
    };
    std::optional<CapturedVoice> m_ready;
    std::string m_error;
    std::string m_deviceName{"Windows default"};
};

// Stable helpers keep WAV framing and hashing independently testable without a microphone.
[[nodiscard]] std::vector<std::byte> makePcm16MonoWav(
    std::span<const std::byte> pcm, std::uint32_t sampleRate = 16000);
[[nodiscard]] std::string sha256Hex(std::span<const std::byte> bytes);
[[nodiscard]] bool pcm16HasVoice(std::span<const std::byte> pcm, std::uint16_t rmsThreshold = 700);

} // namespace lorkhan
