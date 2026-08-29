#include "lorkhan/validation.hpp"

#include <cstddef>
#include <cstdint>
#include <string>

extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t* data, std::size_t size)
{
    const std::string value(reinterpret_cast<const char*>(data), size);
    static_cast<void>(lorkhan::validateHeaders({{"X-Fuzz", value}}));
    static_cast<void>(lorkhan::parseContentType(value));
    return 0;
}
