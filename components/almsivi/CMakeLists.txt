add_library(almsivi_core STATIC
    src/actions.cpp
    src/bridge_service.cpp
    src/events.cpp
    src/lifecycle.cpp
    src/media.cpp
    src/validation.cpp)
target_include_directories(almsivi_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_compile_features(almsivi_core PUBLIC cxx_std_20)
set_target_properties(almsivi_core PROPERTIES CXX_EXTENSIONS OFF)

if(MSVC)
    target_compile_options(almsivi_core PRIVATE /W4 /WX /permissive-)
else()
    target_compile_options(almsivi_core PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()

add_executable(almsivi_native_tests tests/native_tests.cpp)
target_link_libraries(almsivi_native_tests PRIVATE almsivi_core)
if(NOT MSVC)
    target_compile_options(almsivi_native_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()
add_test(NAME almsivi-native COMMAND almsivi_native_tests)

option(ALMSIVI_WITH_BOOST_BEAST "Build compile-optional Beast transport scaffold" OFF)
if(ALMSIVI_WITH_BOOST_BEAST)
    find_package(Boost 1.70 REQUIRED COMPONENTS system)
    target_sources(almsivi_core PRIVATE src/beast_transport.cpp)
    target_compile_definitions(almsivi_core PUBLIC ALMSIVI_WITH_BOOST_BEAST=1)
    target_link_libraries(almsivi_core PRIVATE Boost::system)
endif()

option(ALMSIVI_BUILD_FUZZERS "Build libFuzzer entrypoints (Clang only)" OFF)
if(ALMSIVI_BUILD_FUZZERS)
    if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        message(FATAL_ERROR "ALMSIVI_BUILD_FUZZERS requires Clang")
    endif()
    foreach(name IN ITEMS url header action)
        add_executable(almsivi_fuzz_${name} fuzz/${name}_fuzz.cpp)
        target_link_libraries(almsivi_fuzz_${name} PRIVATE almsivi_core)
        target_compile_options(almsivi_fuzz_${name} PRIVATE -fsanitize=fuzzer,address,undefined)
        target_link_options(almsivi_fuzz_${name} PRIVATE -fsanitize=fuzzer,address,undefined)
    endforeach()
endif()
