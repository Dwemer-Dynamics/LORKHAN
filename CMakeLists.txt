cmake_minimum_required(VERSION 3.25)
project(LORKHANClientFoundation VERSION 0.5.0 LANGUAGES CXX)

enable_testing()
add_subdirectory(components/lorkhan)
find_program(LORKHAN_LUA_EXECUTABLE NAMES luajit lua5.4 lua54 lua5.3 lua)
if(LORKHAN_LUA_EXECUTABLE)
  add_test(NAME lorkhan-lua-runtime
    COMMAND "${LORKHAN_LUA_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/lorkhan/files/scripts/LORKHAN/tests/run.lua")
  set_tests_properties(lorkhan-lua-runtime PROPERTIES
    LABELS "lua;standalone-runtime;fake-openmw;no-engine;no-game")
endif()
add_custom_target(check
  COMMAND "${CMAKE_CTEST_COMMAND}" --test-dir "${CMAKE_BINARY_DIR}" --output-on-failure
  USES_TERMINAL
  DEPENDS lorkhan_native_tests)
if(TARGET lorkhan_beast_transport_tests)
  add_dependencies(check lorkhan_beast_transport_tests)
endif()
