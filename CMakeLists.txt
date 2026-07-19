cmake_minimum_required(VERSION 3.25)
project(ALMSIVIClientFoundation VERSION 0.1.0 LANGUAGES CXX)

find_package(Python3 3.10 REQUIRED COMPONENTS Interpreter)
enable_testing()
add_subdirectory(components/almsivi)
add_test(NAME foundation-unit
  COMMAND "${Python3_EXECUTABLE}" -m unittest discover -s "${CMAKE_SOURCE_DIR}/tests" -v)
add_test(NAME protocol-contract-harness
  COMMAND "${Python3_EXECUTABLE}" -m unittest discover -s "${CMAKE_SOURCE_DIR}/almsivi/tests" -v)
add_test(NAME evidence-validation
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/scripts/evidence/validate.py")
set_tests_properties(foundation-unit protocol-contract-harness evidence-validation PROPERTIES
  ENVIRONMENT "PYTHONDONTWRITEBYTECODE=1")
add_test(NAME almsivi-lua-structural
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/almsivi/tests/run.py")
find_program(ALMSIVI_LUA_EXECUTABLE NAMES lua lua5.4 lua5.3 luajit)
if(ALMSIVI_LUA_EXECUTABLE)
  add_test(NAME almsivi-lua-runtime
    COMMAND "${ALMSIVI_LUA_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/almsivi/files/scripts/ALMSIVI/tests/run.lua")
endif()
add_custom_target(check
  COMMAND "${CMAKE_CTEST_COMMAND}" --test-dir "${CMAKE_BINARY_DIR}" --output-on-failure
  USES_TERMINAL)
