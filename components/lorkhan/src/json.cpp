#include "lorkhan/json.hpp"

#include "lorkhan/validation.hpp"

#include <charconv>
#include <cmath>
#include <system_error>

namespace lorkhan::json {
namespace {

class Parser {
public:
    Parser(std::string_view input, ParseLimits limits) : m_input(input), m_limits(limits) {}

    Result<Value> run()
    {
        if (m_input.size() > m_limits.maximumBytes)
            return Result<Value>::failure(makeError(ErrorCode::payload_too_large, "JSON exceeds byte limit"));
        if (m_input.empty())
            return fail("JSON is empty");
        if (!isValidUtf8(m_input))
            return Result<Value>::failure(makeError(ErrorCode::invalid_utf8, "JSON is not valid UTF-8"));
        auto value = parseValue(0);
        if (!value)
            return value;
        skipWhitespace();
        if (m_position != m_input.size())
            return fail("JSON contains trailing data");
        return value;
    }

private:
    Result<Value> fail(std::string message) const
    {
        return Result<Value>::failure(makeError(ErrorCode::invalid_json, std::move(message)));
    }

    void skipWhitespace()
    {
        while (m_position < m_input.size()) {
            const char c = m_input[m_position];
            if (c != ' ' && c != '\t' && c != '\r' && c != '\n')
                break;
            ++m_position;
        }
    }

    Result<Value> parseValue(std::size_t depth)
    {
        skipWhitespace();
        if (depth > m_limits.maximumDepth)
            return Result<Value>::failure(makeError(ErrorCode::payload_too_large, "JSON nesting depth exceeds limit"));
        if (m_position >= m_input.size())
            return fail("JSON value expected");
        if (m_values >= m_limits.maximumValues)
            return Result<Value>::failure(makeError(ErrorCode::payload_too_large, "JSON value count exceeds limit"));
        ++m_values;
        switch (m_input[m_position]) {
            case '{':
                if (depth >= m_limits.maximumDepth)
                    return Result<Value>::failure(makeError(ErrorCode::payload_too_large, "JSON nesting depth exceeds limit"));
                return parseObject(depth + 1);
            case '[':
                if (depth >= m_limits.maximumDepth)
                    return Result<Value>::failure(makeError(ErrorCode::payload_too_large, "JSON nesting depth exceeds limit"));
                return parseArray(depth + 1);
            case '"': {
                auto value = parseString();
                if (!value) return Result<Value>::failure(value.error());
                return Result<Value>::success(Value{std::move(value).value()});
            }
            case 't': return parseLiteral("true", Value{true});
            case 'f': return parseLiteral("false", Value{false});
            case 'n': return parseLiteral("null", Value{nullptr});
            default: return parseNumber();
        }
    }

    Result<Value> parseLiteral(std::string_view literal, Value value)
    {
        if (m_input.substr(m_position, literal.size()) != literal)
            return fail("invalid JSON literal");
        m_position += literal.size();
        return Result<Value>::success(std::move(value));
    }

    Result<std::string> parseString()
    {
        if (m_input[m_position++] != '"')
            return Result<std::string>::failure(makeError(ErrorCode::invalid_json, "JSON string expected"));
        std::string output;
        while (m_position < m_input.size()) {
            const unsigned char c = static_cast<unsigned char>(m_input[m_position++]);
            if (c == '"') {
                if (output.size() > m_limits.maximumStringBytes || !isValidUtf8(output))
                    return Result<std::string>::failure(makeError(ErrorCode::payload_too_large, "JSON string exceeds byte limit"));
                return Result<std::string>::success(std::move(output));
            }
            if (c < 0x20)
                return Result<std::string>::failure(makeError(ErrorCode::invalid_json, "unescaped JSON control byte"));
            if (c != '\\') {
                output.push_back(static_cast<char>(c));
                continue;
            }
            if (m_position >= m_input.size())
                return Result<std::string>::failure(makeError(ErrorCode::invalid_json, "truncated JSON escape"));
            const char escaped = m_input[m_position++];
            switch (escaped) {
                case '"': output.push_back('"'); break;
                case '\\': output.push_back('\\'); break;
                case '/': output.push_back('/'); break;
                case 'b': output.push_back('\b'); break;
                case 'f': output.push_back('\f'); break;
                case 'n': output.push_back('\n'); break;
                case 'r': output.push_back('\r'); break;
                case 't': output.push_back('\t'); break;
                case 'u': {
                    auto code = parseHexCodeUnit();
                    if (!code) return Result<std::string>::failure(code.error());
                    std::uint32_t scalar = code.value();
                    if (scalar >= 0xD800 && scalar <= 0xDBFF) {
                        if (m_position + 2 > m_input.size() || m_input.substr(m_position, 2) != "\\u")
                            return Result<std::string>::failure(makeError(ErrorCode::invalid_json, "unpaired high surrogate"));
                        m_position += 2;
                        auto low = parseHexCodeUnit();
                        if (!low || low.value() < 0xDC00 || low.value() > 0xDFFF)
                            return Result<std::string>::failure(makeError(ErrorCode::invalid_json, "invalid low surrogate"));
                        scalar = 0x10000U + ((scalar - 0xD800U) << 10U) + (low.value() - 0xDC00U);
                    } else if (scalar >= 0xDC00 && scalar <= 0xDFFF) {
                        return Result<std::string>::failure(makeError(ErrorCode::invalid_json, "unpaired low surrogate"));
                    }
                    appendUtf8(output, scalar);
                    break;
                }
                default: return Result<std::string>::failure(makeError(ErrorCode::invalid_json, "unknown JSON escape"));
            }
            if (output.size() > m_limits.maximumStringBytes)
                return Result<std::string>::failure(makeError(ErrorCode::payload_too_large, "JSON string exceeds byte limit"));
        }
        return Result<std::string>::failure(makeError(ErrorCode::invalid_json, "unterminated JSON string"));
    }

    Result<std::uint32_t> parseHexCodeUnit()
    {
        if (m_position + 4 > m_input.size())
            return Result<std::uint32_t>::failure(makeError(ErrorCode::invalid_json, "truncated unicode escape"));
        std::uint32_t value = 0;
        for (int i = 0; i < 4; ++i) {
            const char c = m_input[m_position++];
            value <<= 4U;
            if (c >= '0' && c <= '9') value |= static_cast<std::uint32_t>(c - '0');
            else if (c >= 'a' && c <= 'f') value |= static_cast<std::uint32_t>(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') value |= static_cast<std::uint32_t>(c - 'A' + 10);
            else return Result<std::uint32_t>::failure(makeError(ErrorCode::invalid_json, "invalid unicode escape"));
        }
        return Result<std::uint32_t>::success(value);
    }

    static void appendUtf8(std::string& output, std::uint32_t scalar)
    {
        if (scalar <= 0x7F) output.push_back(static_cast<char>(scalar));
        else if (scalar <= 0x7FF) {
            output.push_back(static_cast<char>(0xC0U | (scalar >> 6U)));
            output.push_back(static_cast<char>(0x80U | (scalar & 0x3FU)));
        } else if (scalar <= 0xFFFF) {
            output.push_back(static_cast<char>(0xE0U | (scalar >> 12U)));
            output.push_back(static_cast<char>(0x80U | ((scalar >> 6U) & 0x3FU)));
            output.push_back(static_cast<char>(0x80U | (scalar & 0x3FU)));
        } else {
            output.push_back(static_cast<char>(0xF0U | (scalar >> 18U)));
            output.push_back(static_cast<char>(0x80U | ((scalar >> 12U) & 0x3FU)));
            output.push_back(static_cast<char>(0x80U | ((scalar >> 6U) & 0x3FU)));
            output.push_back(static_cast<char>(0x80U | (scalar & 0x3FU)));
        }
    }

    Result<Value> parseObject(std::size_t depth)
    {
        ++m_position;
        Object object;
        skipWhitespace();
        if (m_position < m_input.size() && m_input[m_position] == '}') {
            ++m_position;
            return Result<Value>::success(Value{std::move(object)});
        }
        while (true) {
            skipWhitespace();
            if (m_position >= m_input.size() || m_input[m_position] != '"')
                return fail("JSON object key expected");
            auto key = parseString();
            if (!key) return Result<Value>::failure(key.error());
            skipWhitespace();
            if (m_position >= m_input.size() || m_input[m_position++] != ':')
                return fail("JSON object colon expected");
            auto value = parseValue(depth);
            if (!value) return value;
            if (!object.emplace(std::move(key).value(), std::move(value).value()).second)
                return fail("duplicate JSON object key");
            skipWhitespace();
            if (m_position >= m_input.size()) return fail("unterminated JSON object");
            const char separator = m_input[m_position++];
            if (separator == '}') break;
            if (separator != ',') return fail("JSON object comma expected");
        }
        return Result<Value>::success(Value{std::move(object)});
    }

    Result<Value> parseArray(std::size_t depth)
    {
        ++m_position;
        Array array;
        skipWhitespace();
        if (m_position < m_input.size() && m_input[m_position] == ']') {
            ++m_position;
            return Result<Value>::success(Value{std::move(array)});
        }
        while (true) {
            auto value = parseValue(depth);
            if (!value) return value;
            array.emplace_back(std::move(value).value());
            skipWhitespace();
            if (m_position >= m_input.size()) return fail("unterminated JSON array");
            const char separator = m_input[m_position++];
            if (separator == ']') break;
            if (separator != ',') return fail("JSON array comma expected");
        }
        return Result<Value>::success(Value{std::move(array)});
    }

    Result<Value> parseNumber()
    {
        const std::size_t start = m_position;
        if (m_position < m_input.size() && m_input[m_position] == '-') ++m_position;
        if (m_position >= m_input.size()) return fail("truncated JSON number");
        if (m_input[m_position] == '0') ++m_position;
        else {
            if (m_input[m_position] < '1' || m_input[m_position] > '9') return fail("invalid JSON number");
            while (m_position < m_input.size() && m_input[m_position] >= '0' && m_input[m_position] <= '9') ++m_position;
        }
        bool integral = true;
        if (m_position < m_input.size() && m_input[m_position] == '.') {
            integral = false; ++m_position;
            const std::size_t fraction = m_position;
            while (m_position < m_input.size() && m_input[m_position] >= '0' && m_input[m_position] <= '9') ++m_position;
            if (fraction == m_position) return fail("invalid JSON fraction");
        }
        if (m_position < m_input.size() && (m_input[m_position] == 'e' || m_input[m_position] == 'E')) {
            integral = false; ++m_position;
            if (m_position < m_input.size() && (m_input[m_position] == '+' || m_input[m_position] == '-')) ++m_position;
            const std::size_t exponent = m_position;
            while (m_position < m_input.size() && m_input[m_position] >= '0' && m_input[m_position] <= '9') ++m_position;
            if (exponent == m_position) return fail("invalid JSON exponent");
        }
        const std::string_view text = m_input.substr(start, m_position - start);
        if (integral) {
            std::int64_t value{};
            const auto parsed = std::from_chars(text.data(), text.data() + text.size(), value);
            if (parsed.ec == std::errc{} && parsed.ptr == text.data() + text.size())
                return Result<Value>::success(Value{value});
            return fail("JSON integer is outside signed 64-bit range");
        }
        double value{};
        const auto parsed = std::from_chars(text.data(), text.data() + text.size(), value, std::chars_format::general);
        if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size() || !std::isfinite(value))
            return fail("JSON number is outside finite range");
        return Result<Value>::success(Value{value});
    }

    std::string_view m_input;
    ParseLimits m_limits;
    std::size_t m_position{};
    std::size_t m_values{};
};

} // namespace

Result<Value> parse(std::string_view input, ParseLimits limits)
{
    return Parser(input, limits).run();
}

const Value* find(const Object& object, std::string_view key) noexcept
{
    const auto found = object.find(key);
    return found == object.end() ? nullptr : &found->second;
}

Result<Object> requireObjectWithSchema(std::string_view input, std::string_view schema, ParseLimits limits)
{
    auto parsed = parse(input, limits);
    if (!parsed)
        return Result<Object>::failure(parsed.error());
    const Object* object = parsed.value().object();
    if (!object)
        return Result<Object>::failure(makeError(ErrorCode::invalid_schema, "JSON root must be an object"));
    const Value* schemaValue = find(*object, "schema");
    if (!schemaValue || !schemaValue->string() || *schemaValue->string() != schema)
        return Result<Object>::failure(makeError(ErrorCode::invalid_schema, "JSON schema discriminator mismatch"));
    return Result<Object>::success(*object);
}

} // namespace lorkhan::json
