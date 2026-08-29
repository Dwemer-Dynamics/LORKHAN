#include "lorkhan/validation.hpp"

#include <algorithm>
#include <array>
#include <charconv>
#include <cctype>
#include <limits>
#include <set>

namespace lorkhan {
namespace {

bool hasControl(std::string_view value)
{
    return std::ranges::any_of(value, [](unsigned char c) { return c <= 0x1FU || c == 0x7FU; });
}

std::string lowercase(std::string_view value)
{
    std::string result(value);
    std::ranges::transform(result, result.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return result;
}

std::string trim(std::string_view value)
{
    while (!value.empty() && (value.front() == ' ' || value.front() == '\t'))
        value.remove_prefix(1);
    while (!value.empty() && (value.back() == ' ' || value.back() == '\t'))
        value.remove_suffix(1);
    return std::string(value);
}

Result<std::uint16_t> parsePort(std::string_view text)
{
    if (text.empty())
        return Result<std::uint16_t>::success(80);
    if (text.size() > 5 || !std::ranges::all_of(text, [](unsigned char c) { return std::isdigit(c) != 0; }))
        return Result<std::uint16_t>::failure(makeError(ErrorCode::invalid_url, "port must be canonical decimal"));
    if (text.size() > 1 && text.front() == '0')
        return Result<std::uint16_t>::failure(makeError(ErrorCode::invalid_url, "port must not contain leading zeroes"));
    unsigned value = 0;
    const auto parsed = std::from_chars(text.data(), text.data() + text.size(), value);
    if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size() || value == 0 || value > 65535)
        return Result<std::uint16_t>::failure(makeError(ErrorCode::invalid_url, "port is outside 1..65535"));
    return Result<std::uint16_t>::success(static_cast<std::uint16_t>(value));
}

bool validIpv4Loopback(std::string_view host)
{
    std::array<unsigned, 4> octets{};
    std::size_t start = 0;
    for (std::size_t index = 0; index < octets.size(); ++index) {
        const std::size_t end = index == 3 ? host.size() : host.find('.', start);
        if (end == std::string_view::npos || end == start)
            return false;
        const std::string_view part = host.substr(start, end - start);
        if (part.size() > 1 && part.front() == '0')
            return false;
        if (!std::ranges::all_of(part, [](unsigned char c) { return std::isdigit(c) != 0; }))
            return false;
        unsigned value = 0;
        const auto parsed = std::from_chars(part.data(), part.data() + part.size(), value);
        if (parsed.ec != std::errc{} || parsed.ptr != part.data() + part.size() || value > 255)
            return false;
        octets[index] = value;
        start = end + 1;
    }
    return start == host.size() + 1 && octets.front() == 127;
}

bool validPath(std::string_view path)
{
    if (path.empty() || path.front() != '/')
        return false;
    if (path.find("//") != std::string_view::npos || path.find('\\') != std::string_view::npos || path.find('%') != std::string_view::npos)
        return false;
    std::size_t start = 1;
    while (start <= path.size()) {
        const std::size_t end = path.find('/', start);
        const std::string_view part = path.substr(start, end == std::string_view::npos ? path.size() - start : end - start);
        if (part == "." || part == "..")
            return false;
        if (end == std::string_view::npos)
            break;
        start = end + 1;
    }
    return true;
}

} // namespace

bool isValidUtf8(std::string_view input) noexcept
{
    const auto* bytes = reinterpret_cast<const unsigned char*>(input.data());
    std::size_t i = 0;
    while (i < input.size()) {
        const unsigned char first = bytes[i++];
        if (first <= 0x7F)
            continue;
        unsigned count = 0;
        std::uint32_t code = 0;
        std::uint32_t minimum = 0;
        if (first >= 0xC2 && first <= 0xDF) { count = 1; code = first & 0x1F; minimum = 0x80; }
        else if (first >= 0xE0 && first <= 0xEF) { count = 2; code = first & 0x0F; minimum = 0x800; }
        else if (first >= 0xF0 && first <= 0xF4) { count = 3; code = first & 0x07; minimum = 0x10000; }
        else return false;
        if (i + count > input.size())
            return false;
        for (unsigned n = 0; n < count; ++n) {
            const unsigned char continuation = bytes[i++];
            if ((continuation & 0xC0) != 0x80)
                return false;
            code = (code << 6U) | (continuation & 0x3FU);
        }
        if (code < minimum || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF))
            return false;
    }
    return true;
}

Result<std::string> requireValidUtf8(std::string_view input, std::size_t maximumBytes)
{
    if (input.size() > maximumBytes)
        return Result<std::string>::failure(makeError(ErrorCode::invalid_argument, "string exceeds byte limit"));
    if (!isValidUtf8(input))
        return Result<std::string>::failure(makeError(ErrorCode::invalid_utf8, "string is not valid UTF-8"));
    return Result<std::string>::success(std::string(input));
}

bool isCanonicalUuid(std::string_view input) noexcept
{
    if (input.size() != 36)
        return false;
    for (std::size_t index = 0; index < input.size(); ++index) {
        if (index == 8 || index == 13 || index == 18 || index == 23) {
            if (input[index] != '-')
                return false;
        } else if (!std::isdigit(static_cast<unsigned char>(input[index]))
            && !(input[index] >= 'a' && input[index] <= 'f')) {
            return false;
        }
    }
    return true;
}

bool isCanonicalUtcTimestamp(std::string_view value) noexcept
{
    if (value.size() < 20 || value.size() > 30 || value[4] != '-' || value[7] != '-'
        || value[10] != 'T' || value[13] != ':' || value[16] != ':' || value.back() != 'Z')
        return false;
    const auto digit = [value](std::size_t index) { return value[index] >= '0' && value[index] <= '9'; };
    for (const auto index : std::array<std::size_t, 14>{0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18}) {
        if (!digit(index))
            return false;
    }
    const auto pair = [value](std::size_t index) {
        return static_cast<unsigned>(value[index] - '0') * 10U + static_cast<unsigned>(value[index + 1] - '0');
    };
    const unsigned year = static_cast<unsigned>(value[0] - '0') * 1000U
        + static_cast<unsigned>(value[1] - '0') * 100U
        + static_cast<unsigned>(value[2] - '0') * 10U
        + static_cast<unsigned>(value[3] - '0');
    const unsigned month = pair(5);
    const unsigned day = pair(8);
    static constexpr std::array<unsigned, 12> daysPerMonth{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    if (year == 0 || month < 1 || month > daysPerMonth.size()
        || pair(11) > 23 || pair(14) > 59 || pair(17) > 59)
        return false;
    unsigned maximumDay = daysPerMonth[month - 1];
    if (month == 2 && year % 4 == 0 && (year % 100 != 0 || year % 400 == 0))
        ++maximumDay;
    if (day < 1 || day > maximumDay)
        return false;
    if (value.size() == 20)
        return true;
    if (value[19] != '.' || value.size() < 22)
        return false;
    return std::all_of(value.begin() + 20, value.end() - 1,
        [](char character) { return character >= '0' && character <= '9'; });
}

std::string BaseUrl::authority() const
{
    const std::string renderedHost = ipv6 ? "[" + host + "]" : host;
    return renderedHost + (port == 80 ? "" : ":" + std::to_string(port));
}

Result<BaseUrl> parseLoopbackBaseUrl(std::string_view input)
{
    if (input.empty() || !isValidUtf8(input) || hasControl(input) || input.find_first_of("?#") != std::string_view::npos)
        return Result<BaseUrl>::failure(makeError(ErrorCode::invalid_url, "URL contains forbidden component"));
    constexpr std::string_view scheme = "http://";
    if (!input.starts_with(scheme))
        return Result<BaseUrl>::failure(makeError(ErrorCode::invalid_url, "only lowercase http is accepted"));
    input.remove_prefix(scheme.size());
    const std::size_t slash = input.find('/');
    const std::string_view authority = input.substr(0, slash);
    const std::string_view path = slash == std::string_view::npos ? std::string_view{"/"} : input.substr(slash);
    if (authority.empty() || authority.find('@') != std::string_view::npos || !validPath(path))
        return Result<BaseUrl>::failure(makeError(ErrorCode::invalid_url, "invalid authority or path"));

    BaseUrl result;
    std::string_view portText;
    if (authority.front() == '[') {
        const std::size_t close = authority.find(']');
        if (close == std::string_view::npos || authority.substr(1, close - 1) != "::1")
            return Result<BaseUrl>::failure(makeError(ErrorCode::invalid_url, "only canonical [::1] is accepted"));
        result.host = "::1";
        result.ipv6 = true;
        if (close + 1 < authority.size()) {
            if (authority[close + 1] != ':')
                return Result<BaseUrl>::failure(makeError(ErrorCode::invalid_url, "invalid IPv6 authority"));
            portText = authority.substr(close + 2);
        }
    } else {
        const std::size_t colon = authority.find(':');
        if (colon != std::string_view::npos && authority.find(':', colon + 1) != std::string_view::npos)
            return Result<BaseUrl>::failure(makeError(ErrorCode::invalid_url, "IPv6 literals require brackets"));
        const std::string_view host = authority.substr(0, colon);
        if (!validIpv4Loopback(host))
            return Result<BaseUrl>::failure(makeError(ErrorCode::invalid_url, "host must be canonical 127/8 literal"));
        result.host = std::string(host);
        if (colon != std::string_view::npos)
            portText = authority.substr(colon + 1);
    }
    auto port = parsePort(portText);
    if (!port)
        return Result<BaseUrl>::failure(port.error());
    result.port = port.value();
    result.basePath = std::string(path);
    if (result.basePath.size() > 1 && result.basePath.back() == '/')
        result.basePath.pop_back();
    return Result<BaseUrl>::success(std::move(result));
}

Result<void> validateHeaders(const Headers& headers)
{
    std::set<std::string> names;
    for (const auto& [rawName, rawValue] : headers) {
        if (rawName.empty() || hasControl(rawName) || hasControl(rawValue))
            return Result<void>::failure(makeError(ErrorCode::invalid_header, "header contains control byte"));
        if (!std::ranges::all_of(rawName, [](unsigned char c) {
                return std::isalnum(c) != 0 || c == '!' || c == '#' || c == '$' || c == '%' || c == '&'
                    || c == '\'' || c == '*' || c == '+' || c == '-' || c == '.' || c == '^' || c == '_'
                    || c == '`' || c == '|' || c == '~';
            }))
            return Result<void>::failure(makeError(ErrorCode::invalid_header, "invalid header name"));
        if (!isValidUtf8(rawValue))
            return Result<void>::failure(makeError(ErrorCode::invalid_utf8, "header value is not UTF-8"));
        if (!names.insert(lowercase(rawName)).second)
            return Result<void>::failure(makeError(ErrorCode::invalid_header, "duplicate header"));
    }
    return Result<void>::success();
}

Result<BodyType> parseContentType(std::string_view value, bool responseMedia)
{
    const std::string normalized = lowercase(trim(value));
    if (normalized == "application/json; charset=utf-8")
        return Result<BodyType>::success(BodyType::json);
    if (normalized == "audio/wav")
        return Result<BodyType>::success(responseMedia ? BodyType::media_wav : BodyType::wav);
    if (normalized == "audio/ogg")
        return Result<BodyType>::success(responseMedia ? BodyType::media_ogg : BodyType::ogg);
    if (!responseMedia && normalized == "audio/webm")
        return Result<BodyType>::success(BodyType::webm);
    if (responseMedia && normalized == "audio/mpeg")
        return Result<BodyType>::success(BodyType::media_mpeg);
    return Result<BodyType>::failure(makeError(ErrorCode::invalid_content_type, "content type is not allowed"));
}

Result<void> validateJsonContentType(const Headers& headers)
{
    auto valid = validateHeaders(headers);
    if (!valid)
        return valid;
    for (const auto& [name, value] : headers) {
        if (lowercase(name) == "content-type") {
            auto parsed = parseContentType(value);
            if (!parsed || parsed.value() != BodyType::json)
                return Result<void>::failure(parsed ? makeError(ErrorCode::invalid_content_type, "JSON required") : parsed.error());
            return Result<void>::success();
        }
    }
    return Result<void>::failure(makeError(ErrorCode::invalid_content_type, "Content-Type is required"));
}

} // namespace lorkhan
