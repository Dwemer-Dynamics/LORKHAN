#ifndef MWLUA_LORKHANBINDINGS_H
#define MWLUA_LORKHANBINDINGS_H

#include <sol/forward.hpp>
#include <optional>
#include <string>
#include <cstdint>

namespace MWWorld { class Ptr; }

namespace MWLua
{
    struct Context;
    struct LorkhanObservationScope { std::string sessionId; std::uint64_t generation; };
    // Native engine hooks capture the current bridge fence; this is never exposed to Lua.
    std::optional<LorkhanObservationScope> lorkhanObservationScope();
    // Ordinary animation hooks retain the approved exact target through release.
    bool lorkhanSpellStartAllowed(const MWWorld::Ptr& actor);
    void lorkhanSpellStartResult(const MWWorld::Ptr& actor, bool success);
    int lorkhanSpellTarget(const MWWorld::Ptr& actor, MWWorld::Ptr& target);
    void lorkhanSpellFinished(const MWWorld::Ptr& actor, bool success);
    sol::object initLorkhanPackage(const Context& context);
    sol::object initLorkhanCustomPackageLoader(const Context& context);
}

#endif
