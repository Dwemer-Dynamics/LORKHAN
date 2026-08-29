#include "lorkhan/json.hpp"

#include <cstddef>
#include <cstdint>
#include <string_view>

extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t* data, std::size_t size)
{
    static_cast<void>(lorkhan::json::parse(
        std::string_view(reinterpret_cast<const char*>(data), size)));
    return 0;
}
