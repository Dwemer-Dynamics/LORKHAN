#pragma once

#include "almsivi/types.hpp"

#include <array>
#include <chrono>
#include <cstddef>
#include <filesystem>
#include <span>
#include <string>

namespace almsivi {

enum class MediaCodec { wav, ogg, mp3 };

struct MediaDescriptor {
    MediaId id;
    std::string relativeRoute;
    std::array<std::byte, 32> sha256{};
    std::size_t bytes{};
    MediaCodec codec{MediaCodec::wav};
    std::chrono::system_clock::time_point expiresAt;
};

struct MediaCachePolicy {
    std::size_t maximumObjectBytes{kMaxMediaBytes};
    std::size_t quotaBytes{512U * 1024U * 1024U};
    bool rejectSymlinks{true};
};

[[nodiscard]] Result<void> validateMediaDescriptor(
    const MediaDescriptor& descriptor, const MediaCachePolicy& policy, std::chrono::system_clock::time_point now);
[[nodiscard]] Result<std::filesystem::path> resolveCachePath(
    const std::filesystem::path& cacheRoot, std::string_view hashHex, MediaCodec codec);

class IMediaSink {
public:
    virtual ~IMediaSink() = default;
    virtual Result<void> begin(const MediaDescriptor& descriptor) = 0;
    virtual Result<void> write(std::span<const std::byte> bytes) = 0;
    virtual Result<void> commit() = 0;
    virtual void abort() noexcept = 0;
};

class IMediaCache {
public:
    virtual ~IMediaCache() = default;
    virtual Result<void> reserve(const MediaDescriptor& descriptor) = 0;
    virtual void release(const MediaId& media) noexcept = 0;
    virtual void evictExpired(std::chrono::system_clock::time_point now) = 0;
};

} // namespace almsivi
