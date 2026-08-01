#include "almsivi/voice_capture.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <limits>
#include <string_view>
#include <tuple>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>
#include <mmsystem.h>
#endif

namespace almsivi {
namespace {

using namespace std::chrono_literals;

void append16(std::vector<std::byte>& output, std::uint16_t value)
{
    output.push_back(std::byte(value & 0xffU));
    output.push_back(std::byte((value >> 8U) & 0xffU));
}

void append32(std::vector<std::byte>& output, std::uint32_t value)
{
    for (unsigned shift = 0; shift < 32; shift += 8)
        output.push_back(std::byte((value >> shift) & 0xffU));
}

class Sha256 final {
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

    static std::uint32_t rotate(std::uint32_t value, unsigned bits)
    {
        return (value >> bits) | (value << (32U - bits));
    }

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

} // namespace

std::vector<std::byte> makePcm16MonoWav(std::span<const std::byte> pcm, std::uint32_t sampleRate)
{
    if (sampleRate < 8000 || sampleRate > 192000 || pcm.empty() || pcm.size() % 2 != 0
        || pcm.size() > std::numeric_limits<std::uint32_t>::max() - 36U)
        return {};
    std::vector<std::byte> output;
    output.reserve(44 + pcm.size());
    for (char value : std::string_view("RIFF", 4)) output.push_back(std::byte(value));
    append32(output, static_cast<std::uint32_t>(36 + pcm.size()));
    for (char value : std::string_view("WAVEfmt ", 8)) output.push_back(std::byte(value));
    append32(output, 16); append16(output, 1); append16(output, 1);
    append32(output, sampleRate); append32(output, sampleRate * 2U); append16(output, 2); append16(output, 16);
    for (char value : std::string_view("data", 4)) output.push_back(std::byte(value));
    append32(output, static_cast<std::uint32_t>(pcm.size()));
    output.insert(output.end(), pcm.begin(), pcm.end());
    return output;
}

std::string sha256Hex(std::span<const std::byte> bytes)
{
    Sha256 digest;
    digest.update(bytes);
    const auto hash = digest.finish();
    static constexpr char alphabet[] = "0123456789abcdef";
    std::string output(64, '0');
    for (std::size_t index = 0; index < hash.size(); ++index) {
        const auto value = std::to_integer<unsigned char>(hash[index]);
        output[index * 2] = alphabet[value >> 4U];
        output[index * 2 + 1] = alphabet[value & 0x0fU];
    }
    return output;
}

bool pcm16HasVoice(std::span<const std::byte> pcm, std::uint16_t rmsThreshold)
{
    if (pcm.size() < 2 || pcm.size() % 2 != 0 || rmsThreshold == 0) return false;
    std::uint64_t squares = 0;
    const std::size_t samples = pcm.size() / 2;
    for (std::size_t index = 0; index < pcm.size(); index += 2) {
        const auto raw = static_cast<std::uint16_t>(std::to_integer<std::uint8_t>(pcm[index]))
            | static_cast<std::uint16_t>(std::to_integer<std::uint8_t>(pcm[index + 1])) << 8U;
        const std::int64_t sample = static_cast<std::int16_t>(raw);
        squares += static_cast<std::uint64_t>(sample * sample);
    }
    return squares / samples >= static_cast<std::uint64_t>(rmsThreshold) * rmsThreshold;
}

VoiceCaptureService& VoiceCaptureService::instance()
{
    static VoiceCaptureService service;
    return service;
}

VoiceCaptureService::~VoiceCaptureService()
{
    halt();
}

bool VoiceCaptureService::supported() const noexcept
{
#ifdef _WIN32
    return true;
#else
    return false;
#endif
}

Result<void> VoiceCaptureService::start(bool automatic)
{
    if (!supported())
        return Result<void>::failure(makeError(ErrorCode::invalid_argument, "voice capture is available only on Windows"));
    std::thread finished;
    {
        std::lock_guard lock(m_mutex);
        if (m_state == VoiceCaptureState::recording)
            return Result<void>::failure(makeError(ErrorCode::invalid_argument, "voice capture is already recording"));
        if (m_worker.joinable()) finished = std::move(m_worker);
    }
    if (finished.joinable()) finished.join();
    {
        std::lock_guard lock(m_mutex);
        m_stop.store(false, std::memory_order_release);
        m_automatic.store(automatic, std::memory_order_release);
        m_voiceDetected.store(false, std::memory_order_release);
        m_ready.reset();
        m_error.clear();
        m_state = VoiceCaptureState::recording;
        m_worker = std::thread([this] { capture(); });
    }
    return Result<void>::success();
}

void VoiceCaptureService::stop() noexcept
{
    m_stop.store(true, std::memory_order_release);
}

void VoiceCaptureService::halt() noexcept
{
    stop();
    std::thread worker;
    {
        std::lock_guard lock(m_mutex);
        if (m_worker.joinable()) worker = std::move(m_worker);
    }
    if (worker.joinable()) worker.join();
    std::lock_guard lock(m_mutex);
    m_ready.reset();
    m_error.clear();
    m_automatic.store(false, std::memory_order_release);
    m_voiceDetected.store(false, std::memory_order_release);
    m_state = supported() ? VoiceCaptureState::idle : VoiceCaptureState::unsupported;
}

VoiceCaptureState VoiceCaptureService::state() const noexcept
{
    std::lock_guard lock(m_mutex);
    return m_state;
}

std::string VoiceCaptureService::error() const
{
    std::lock_guard lock(m_mutex);
    return m_error;
}

std::size_t VoiceCaptureService::capturedBytes() const noexcept
{
    std::lock_guard lock(m_mutex);
    return m_ready ? m_ready->wav.size() : 0;
}

std::uint64_t VoiceCaptureService::durationMs() const noexcept
{
    std::lock_guard lock(m_mutex);
    return m_ready ? m_ready->durationMs : 0;
}

bool VoiceCaptureService::automatic() const noexcept
{
    return m_automatic.load(std::memory_order_acquire);
}

bool VoiceCaptureService::voiceDetected() const noexcept
{
    return m_voiceDetected.load(std::memory_order_acquire);
}

std::optional<CapturedVoice> VoiceCaptureService::takeReady()
{
    std::thread finished;
    std::optional<CapturedVoice> result;
    {
        std::lock_guard lock(m_mutex);
        if (m_state != VoiceCaptureState::ready || !m_ready) return std::nullopt;
        result = std::move(m_ready);
        m_ready.reset();
        m_state = VoiceCaptureState::idle;
        if (m_worker.joinable()) finished = std::move(m_worker);
    }
    if (finished.joinable()) finished.join();
    return result;
}

void VoiceCaptureService::publish(CapturedVoice result)
{
    std::lock_guard lock(m_mutex);
    m_ready = std::move(result);
    m_error.clear();
    m_state = VoiceCaptureState::ready;
}

void VoiceCaptureService::fail(std::string reason)
{
    std::lock_guard lock(m_mutex);
    m_ready.reset();
    m_error = std::move(reason);
    m_state = VoiceCaptureState::failed;
}

void VoiceCaptureService::capture()
{
#ifdef _WIN32
    constexpr std::uint32_t sampleRate = 16000;
    constexpr std::size_t bufferCount = 4;
    constexpr std::size_t bufferBytes = sampleRate * 2U / 10U;
    constexpr std::size_t minimumPcmBytes = sampleRate * 2U / 10U;
    constexpr auto maximumDuration = 30s;
    constexpr auto voiceTimeout = 15s;
    constexpr auto trailingSilence = 900ms;
    constexpr std::size_t preRollBytes = sampleRate * 2U * 300U / 1000U;

    WAVEFORMATEX format{};
    format.wFormatTag = WAVE_FORMAT_PCM;
    format.nChannels = 1;
    format.nSamplesPerSec = sampleRate;
    format.wBitsPerSample = 16;
    format.nBlockAlign = 2;
    format.nAvgBytesPerSec = sampleRate * format.nBlockAlign;
    format.cbSize = 0;

    HWAVEIN input = nullptr;
    if (waveInOpen(&input, WAVE_MAPPER, &format, 0, 0, CALLBACK_NULL) != MMSYSERR_NOERROR) {
        fail("microphone_open_failed");
        return;
    }

    std::array<std::array<char, bufferBytes>, bufferCount> storage{};
    std::array<WAVEHDR, bufferCount> headers{};
    bool setupFailed = false;
    for (std::size_t index = 0; index < bufferCount; ++index) {
        headers[index].lpData = storage[index].data();
        headers[index].dwBufferLength = static_cast<DWORD>(storage[index].size());
        if (waveInPrepareHeader(input, &headers[index], sizeof(WAVEHDR)) != MMSYSERR_NOERROR
            || waveInAddBuffer(input, &headers[index], sizeof(WAVEHDR)) != MMSYSERR_NOERROR) {
            setupFailed = true;
            break;
        }
    }
    if (!setupFailed && waveInStart(input) != MMSYSERR_NOERROR) setupFailed = true;
    if (setupFailed) {
        waveInReset(input);
        for (auto& header : headers)
            if ((header.dwFlags & WHDR_PREPARED) != 0) waveInUnprepareHeader(input, &header, sizeof(WAVEHDR));
        waveInClose(input);
        fail("microphone_start_failed");
        return;
    }

    std::vector<std::byte> pcm;
    pcm.reserve(sampleRate * 2U * 10U);
    const auto started = std::chrono::steady_clock::now();
    const bool automaticCapture = m_automatic.load(std::memory_order_acquire);
    bool heardVoice = false;
    unsigned voicedBuffers = 0;
    std::size_t speechStart = 0;
    auto lastVoice = started;
    while (!m_stop.load(std::memory_order_acquire) && std::chrono::steady_clock::now() - started < maximumDuration) {
        for (auto& header : headers) {
            if ((header.dwFlags & WHDR_DONE) == 0) continue;
            const auto* first = reinterpret_cast<const std::byte*>(header.lpData);
            const std::span<const std::byte> chunk(first, header.dwBytesRecorded);
            if (automaticCapture && pcm16HasVoice(chunk)) {
                if (!heardVoice) speechStart = pcm.size() > preRollBytes ? pcm.size() - preRollBytes : 0;
                heardVoice = true;
                ++voicedBuffers;
                m_voiceDetected.store(true, std::memory_order_release);
                lastVoice = std::chrono::steady_clock::now();
            }
            pcm.insert(pcm.end(), first, first + header.dwBytesRecorded);
            header.dwBytesRecorded = 0;
            if (!m_stop.load(std::memory_order_acquire)
                && waveInAddBuffer(input, &header, sizeof(WAVEHDR)) != MMSYSERR_NOERROR) {
                m_stop.store(true, std::memory_order_release);
                break;
            }
        }
        const auto now = std::chrono::steady_clock::now();
        if (automaticCapture && heardVoice && voicedBuffers >= 2 && now - lastVoice >= trailingSilence) break;
        if (automaticCapture && !heardVoice && now - started >= voiceTimeout) break;
        std::this_thread::sleep_for(5ms);
    }

    waveInStop(input);
    waveInReset(input);
    for (auto& header : headers) {
        if ((header.dwFlags & WHDR_DONE) != 0 && header.dwBytesRecorded > 0) {
            const auto* first = reinterpret_cast<const std::byte*>(header.lpData);
            pcm.insert(pcm.end(), first, first + header.dwBytesRecorded);
        }
        if ((header.dwFlags & WHDR_PREPARED) != 0) waveInUnprepareHeader(input, &header, sizeof(WAVEHDR));
    }
    waveInClose(input);

    if (automaticCapture && !heardVoice) {
        fail("voice_not_detected");
        return;
    }
    if (automaticCapture && speechStart < pcm.size())
        pcm.erase(pcm.begin(), pcm.begin() + static_cast<std::ptrdiff_t>(speechStart));
    if (pcm.size() < minimumPcmBytes) {
        fail("captured_audio_too_short");
        return;
    }
    if (pcm.size() % 2 != 0) pcm.pop_back();
    CapturedVoice result;
    result.durationMs = static_cast<std::uint64_t>(pcm.size()) * 1000U / (sampleRate * 2U);
    result.wav = makePcm16MonoWav(pcm, sampleRate);
    result.sha256 = sha256Hex(result.wav);
    publish(std::move(result));
#else
    fail("voice_capture_unsupported");
#endif
}

} // namespace almsivi
