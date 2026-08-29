cmake_minimum_required(VERSION 3.25)
project(LORKHANClientFoundation VERSION 0.1.0 LANGUAGES CXX)

find_package(Python3 3.10 REQUIRED COMPONENTS Interpreter)
enable_testing()
add_subdirectory(components/lorkhan)
add_test(NAME foundation-unit
  COMMAND "${Python3_EXECUTABLE}" -m unittest discover -s "${CMAKE_SOURCE_DIR}/tests" -v)
add_test(NAME protocol-contract-harness
  COMMAND "${Python3_EXECUTABLE}" -m unittest discover -s "${CMAKE_SOURCE_DIR}/lorkhan/tests" -v)
add_test(NAME evidence-validation
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/scripts/evidence/validate.py")
set_tests_properties(foundation-unit protocol-contract-harness evidence-validation PROPERTIES
  ENVIRONMENT "PYTHONDONTWRITEBYTECODE=1")
set_tests_properties(foundation-unit PROPERTIES LABELS "foundation;python;no-game")
set_tests_properties(protocol-contract-harness PROPERTIES LABELS "contract;fake-server;no-game")
set_tests_properties(evidence-validation PROPERTIES LABELS "evidence;structural;no-game")
add_test(NAME lorkhan-lua-structural
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/lorkhan/tests/run.py")
set_tests_properties(lorkhan-lua-structural PROPERTIES LABELS "lua;structural;no-runtime;no-game")
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
