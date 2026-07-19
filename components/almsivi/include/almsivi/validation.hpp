#pragma once

#include "almsivi/result.hpp"

#include <cstdint>
#include <map>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace almsivi {

[[nodiscard]] bool isValidUtf8(std::string_view input) noexcept;
[[nodiscard]] Result<std::string> requireValidUtf8(std::string_view input, std::size_t maximumBytes);
// Protocol IDs use canonical lowercase RFC 4122 text: 8-4-4-4-12 hexadecimal digits.
[[nodiscard]] bool isCanonicalUuid(std::string_view input) noexcept;

struct BaseUrl {
    std::string host;
    std::uint16_t port{};
    std::string basePath;
    bool ipv6{};

    [[nodiscard]] std::string authority() const;
};

[[nodiscard]] Result<BaseUrl> parseLoopbackBaseUrl(std::string_view input);

using Headers = std::vector<std::pair<std::string, std::string>>;

enum class BodyType { json, wav, ogg, webm, media_wav, media_ogg, media_mpeg };

[[nodiscard]] Result<void> validateHeaders(const Headers& headers);
[[nodiscard]] Result<BodyType> parseContentType(std::string_view value, bool responseMedia = false);
[[nodiscard]] Result<void> validateJsonContentType(const Headers& headers);

} // namespace almsivi
