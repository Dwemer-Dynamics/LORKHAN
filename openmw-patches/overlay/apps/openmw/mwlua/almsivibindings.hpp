#ifndef MWLUA_ALMSIVIBINDINGS_H
#define MWLUA_ALMSIVIBINDINGS_H

#include <sol/forward.hpp>

namespace MWLua
{
    struct Context;
    sol::object initAlmsiviPackage(const Context& context);
    sol::object initAlmsiviCustomPackageLoader(const Context& context);
}

#endif
