#include "almsivibindings.hpp"

#include "context.hpp"

#include <components/lua/configuration.hpp>
#include <components/lua/scriptscontainer.hpp>

#include <sol/sol.hpp>

namespace MWLua
{
    namespace
    {
        sol::object makePackage(sol::state_view lua)
        {
            sol::table api(lua, sol::create);
            api["version"] = "0.1.0-foundation";
            api["capabilities"] = [lua] {
                sol::table capabilities(lua, sol::create);
                capabilities[1] = "lifecycle.generation";
                return capabilities;
            };
            return LuaUtil::makeReadOnly(api);
        }
    }

    sol::object initAlmsiviPackage(const Context& context)
    {
        if (context.mType == Context::Menu || context.mType == Context::Load)
            throw std::logic_error("openmw.almsivi is unavailable in menu and load contexts");
        return makePackage(context.sol());
    }

    sol::object initAlmsiviCustomPackageLoader(const Context& context)
    {
        if (context.mType != Context::Local)
            throw std::logic_error("openmw.almsivi custom loader requires a local context");
        return sol::make_object(context.sol(), [lua = context.mLua](sol::table hiddenData) -> sol::object {
            LuaUtil::ScriptId id = hiddenData[LuaUtil::ScriptsContainer::sScriptIdKey];
            if (!lua->getConfiguration().isCustomScript(id.mIndex))
                return sol::nil;
            return makePackage(hiddenData.lua_state());
        });
    }
}
