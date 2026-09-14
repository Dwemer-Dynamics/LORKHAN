#ifndef MWLUA_LORKHANBINDINGS_H
#define MWLUA_LORKHANBINDINGS_H

#include <sol/forward.hpp>
#include <optional>
#include <string>
#include <cstdint>

namespace MWLua
{
    struct Context;
    struct LorkhanObservationScope { std::string sessionId; std::uint64_t generation; };
    // Native engine hooks capture the current bridge fence; this is never exposed to Lua.
    std::optional<LorkhanObservationScope> lorkhanObservationScope();
    sol::object initLorkhanPackage(const Context& context);
    sol::object initLorkhanCustomPackageLoader(const Context& context);
}

#endif
