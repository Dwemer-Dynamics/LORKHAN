#include "almsivi/actions.hpp"

#include <bit>
#include <cstddef>
#include <cstdint>
#include <cstring>

extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t* data, std::size_t size)
{
    if (size < sizeof(double) + sizeof(std::uint32_t))
        return 0;
    double distance{};
    std::uint32_t duration{};
    std::memcpy(&distance, data, sizeof(distance));
    std::memcpy(&duration, data + sizeof(distance), sizeof(duration));
    static_cast<void>(almsivi::validateAiFollow(distance, duration));
    return 0;
}
