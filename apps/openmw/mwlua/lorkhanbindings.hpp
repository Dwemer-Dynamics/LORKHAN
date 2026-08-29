#ifndef MWLUA_LORKHANBINDINGS_H
#define MWLUA_LORKHANBINDINGS_H

#include <sol/forward.hpp>

namespace MWLua
{
    struct Context;
    sol::object initLorkhanPackage(const Context& context);
    sol::object initLorkhanCustomPackageLoader(const Context& context);
}

#endif
