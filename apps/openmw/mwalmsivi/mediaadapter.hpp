#pragma once

#include "almsivi/media.hpp"

namespace MWAlmsivi {

// Deferred exact-pin probe point. The OpenMW patch must choose one proven route:
// 1. controlled cache VFS mount that observes atomic additions, or
// 2. ALMSIVI-only decoder/resource entry point.
// This adapter must never expose host paths to Lua.
class MediaAdapter {
public:
    virtual ~MediaAdapter() = default;
    virtual almsivi::Result<void> registerVerified(const almsivi::MediaDescriptor& descriptor) = 0;
    virtual void release(const almsivi::MediaId& media) noexcept = 0;
};

} // namespace MWAlmsivi
