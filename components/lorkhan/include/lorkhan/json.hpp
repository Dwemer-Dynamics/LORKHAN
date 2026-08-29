#pragma once

#include "lorkhan/result.hpp"

#include <cstddef>
#include <cstdint>
#include <map>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

namespace lorkhan::json {

struct Value;
using Array = std::vector<Value>;
using Object = std::map<std::string, Value, std::less<>>;

struct Value {
    using Storage = std::variant<std::nullptr_t, bool, std::int64_t, double, std::string, Array, Object>;
    Storage storage;

    [[nodiscard]] bool isNull() const noexcept { return std::holds_alternative<std::nullptr_t>(storage); }
    [[nodiscard]] const bool* boolean() const noexcept { return std::get_if<bool>(&storage); }
    [[nodiscard]] const std::int64_t* integer() const noexcept { return std::get_if<std::int64_t>(&storage); }
    [[nodiscard]] const double* number() const noexcept { return std::get_if<double>(&storage); }
    [[nodiscard]] const std::string* string() const noexcept { return std::get_if<std::string>(&storage); }
    [[nodiscard]] const Array* array() const noexcept { return std::get_if<Array>(&storage); }
    [[nodiscard]] const Object* object() const noexcept { return std::get_if<Object>(&storage); }
};

struct ParseLimits {
    std::size_t maximumBytes{2U * 1024U * 1024U};
    std::size_t maximumDepth{32};
    std::size_t maximumValues{65536};
    std::size_t maximumStringBytes{512U * 1024U};
};

[[nodiscard]] Result<Value> parse(std::string_view input, ParseLimits limits = {});
[[nodiscard]] Result<Object> requireObjectWithSchema(
    std::string_view input, std::string_view schema, ParseLimits limits = {});
[[nodiscard]] const Value* find(const Object& object, std::string_view key) noexcept;

} // namespace lorkhan::json
