#pragma once

#include "lorkhan/media.hpp"

namespace MWLorkhan {

// Deferred exact-pin probe point. The OpenMW patch must choose one proven route:
// 1. controlled cache VFS mount that observes atomic additions, or
// 2. LORKHAN-only decoder/resource entry point.
// This adapter must never expose host paths to Lua.
class MediaAdapter {
public:
    virtual ~MediaAdapter() = default;
    virtual lorkhan::Result<void> registerVerified(const lorkhan::MediaDescriptor& descriptor) = 0;
    virtual void release(const lorkhan::MediaId& media) noexcept = 0;
};

} // namespace MWLorkhan
