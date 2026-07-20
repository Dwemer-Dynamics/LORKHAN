#pragma once

#include <memory>

namespace MWAlmsivi { class Bridge; }
namespace sol { class state_view; }

namespace MWLua {

// Narrow registration scaffold. Exact OpenMW 0.51 package/context registration is deferred
// until applied to f4bec414...; it must expose typed operations only to GLOBAL/PLAYER/CUSTOM.
// LOAD receives no package. MENU, if added, receives status-only functions.
void registerAlmsiviBindings(sol::state_view lua, std::shared_ptr<MWAlmsivi::Bridge> bridge);

} // namespace MWLua
