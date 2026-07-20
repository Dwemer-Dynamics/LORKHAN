# Included only by the pinned OpenMW integration patch, never by almsivi_core.
# Exact OpenMW target wiring and media dependencies are deferred to the f4bec414 probe.
set(ALMSIVI_OPENMW_ADAPTER_SOURCES
    ${CMAKE_CURRENT_LIST_DIR}/bridge.cpp
    ${CMAKE_CURRENT_LIST_DIR}/bridge.hpp
    ${CMAKE_CURRENT_LIST_DIR}/mediaadapter.hpp
    PARENT_SCOPE)
