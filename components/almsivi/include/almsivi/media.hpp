#pragma once

#include "almsivi/types.hpp"

#include <array>
#include <chrono>
#include <cstddef>
#include <filesystem>
#include <span>
#include <string>

namespace almsivi {

struct MediaCachePolicy {
    std::size_t maximumObjectBytes{kMaxMediaBytes};
    std::size_t quotaBytes{512U * 1024U * 1024U};
    bool rejectSymlinks{true};
};

[[nodiscard]] Result<void> validateMediaDescriptor(
    const MediaDescriptor& descriptor, const MediaCachePolicy& policy, std::chrono::system_clock::time_point now);
// The media route is always constructed natively; server DTOs and Lua never supply a path or URL.
[[nodiscard]] Result<std::string> mediaRoute(const MediaId& media);
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
