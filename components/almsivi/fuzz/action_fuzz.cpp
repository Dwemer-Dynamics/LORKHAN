#include "almsivi/actions.hpp"

#include <cstddef>
#include <cstdint>
#include <cstring>

extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t* data, std::size_t size)
{
    if (size < sizeof(std::uint32_t))
        return 0;
    std::uint32_t distance{};
    std::memcpy(&distance, data, sizeof(distance));
    static_cast<void>(almsivi::validateAiFollow(distance));
    return 0;
}
