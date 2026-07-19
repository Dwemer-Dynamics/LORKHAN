#include "almsivi/media.hpp"

#include <algorithm>
#include <cctype>

namespace almsivi {

Result<void> validateMediaDescriptor(
    const MediaDescriptor& descriptor, const MediaCachePolicy& policy, std::chrono::system_clock::time_point now)
{
    if (descriptor.id.empty())
        return Result<void>::failure(makeError(ErrorCode::media_rejected, "media ID is empty"));
    if (descriptor.bytes == 0 || descriptor.bytes > policy.maximumObjectBytes || descriptor.bytes > policy.quotaBytes)
        return Result<void>::failure(makeError(ErrorCode::media_rejected, "media size is outside policy"));
    if (descriptor.expiresAt <= now)
        return Result<void>::failure(makeError(ErrorCode::media_rejected, "media descriptor is expired"));
    if (descriptor.relativeRoute.empty() || descriptor.relativeRoute.front() != '/' || descriptor.relativeRoute.find("..") != std::string::npos
        || descriptor.relativeRoute.find('\\') != std::string::npos || descriptor.relativeRoute.find('?') != std::string::npos
        || descriptor.relativeRoute.find('#') != std::string::npos || descriptor.relativeRoute.find("//") != std::string::npos)
        return Result<void>::failure(makeError(ErrorCode::media_rejected, "media route is not a safe relative route"));
    return Result<void>::success();
}

Result<std::filesystem::path> resolveCachePath(
    const std::filesystem::path& cacheRoot, std::string_view hashHex, MediaCodec codec)
{
    if (hashHex.size() != 64 || !std::ranges::all_of(hashHex, [](unsigned char c) { return std::isdigit(c) != 0 || (c >= 'a' && c <= 'f'); }))
        return Result<std::filesystem::path>::failure(makeError(ErrorCode::media_rejected, "SHA-256 must be lowercase hexadecimal"));
    if (cacheRoot.empty())
        return Result<std::filesystem::path>::failure(makeError(ErrorCode::media_rejected, "cache root is empty"));
    std::string extension;
    switch (codec) {
        case MediaCodec::wav: extension = ".wav"; break;
        case MediaCodec::ogg: extension = ".ogg"; break;
        case MediaCodec::mp3: extension = ".mp3"; break;
    }
    return Result<std::filesystem::path>::success(cacheRoot / std::string(hashHex.substr(0, 2)) / (std::string(hashHex) + extension));
}

} // namespace almsivi
