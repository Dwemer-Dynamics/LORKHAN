cmake_minimum_required(VERSION 3.25)
project(ALMSIVIClientFoundation VERSION 0.1.0 LANGUAGES NONE)

find_package(Python3 3.10 REQUIRED COMPONENTS Interpreter)
enable_testing()
add_test(NAME foundation-unit
  COMMAND "${Python3_EXECUTABLE}" -m unittest discover -s "${CMAKE_SOURCE_DIR}/tests" -v)
set_tests_properties(foundation-unit PROPERTIES
  ENVIRONMENT "PYTHONDONTWRITEBYTECODE=1")
add_custom_target(check
  COMMAND "${CMAKE_CTEST_COMMAND}" --test-dir "${CMAKE_BINARY_DIR}" --output-on-failure
  USES_TERMINAL)
