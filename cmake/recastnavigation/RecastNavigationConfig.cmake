# Compatibility package for OpenMW's pinned RecastNavigation dependency on distributions whose
# development package installs libraries and headers without an upstream CMake config file.

include(CMakeFindDependencyMacro)

find_path(RecastNavigation_INCLUDE_DIR
    NAMES Recast.h
    PATH_SUFFIXES recastnavigation
    REQUIRED)

foreach(component IN ITEMS DebugUtils Detour Recast)
    find_library(RecastNavigation_${component}_LIBRARY
        NAMES ${component}
        REQUIRED)
    if(NOT TARGET RecastNavigation::${component})
        add_library(RecastNavigation::${component} UNKNOWN IMPORTED)
        set_target_properties(RecastNavigation::${component} PROPERTIES
            IMPORTED_LOCATION "${RecastNavigation_${component}_LIBRARY}"
            INTERFACE_INCLUDE_DIRECTORIES "${RecastNavigation_INCLUDE_DIR}")
    endif()
endforeach()

set(RecastNavigation_LIBRARIES
    RecastNavigation::DebugUtils
    RecastNavigation::Detour
    RecastNavigation::Recast)
set(RecastNavigation_FOUND TRUE)
