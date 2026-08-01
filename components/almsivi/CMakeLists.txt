find_package(Threads REQUIRED)

add_library(almsivi_core STATIC
    src/actions.cpp
    src/bridge_service.cpp
    src/events.cpp
    src/json.cpp
    src/lifecycle.cpp
    src/media.cpp
    src/protocol_response.cpp
    src/validation.cpp
    src/voice_capture.cpp)
target_include_directories(almsivi_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_compile_features(almsivi_core PUBLIC cxx_std_20)
target_link_libraries(almsivi_core PUBLIC Threads::Threads)
if(WIN32)
    target_link_libraries(almsivi_core PRIVATE winmm)
    target_compile_definitions(almsivi_core PRIVATE _WIN32_WINNT=0x0A00)
endif()
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
set_tests_properties(almsivi-native PROPERTIES LABELS "native;standalone;no-engine;no-game")

option(ALMSIVI_WITH_BOOST_BEAST "Build compile-optional Beast transport scaffold" OFF)
if(ALMSIVI_WITH_BOOST_BEAST)
    find_package(Boost 1.70 REQUIRED COMPONENTS system)

    include(CheckIncludeFileCXX)
    set(_almsivi_saved_required_includes "${CMAKE_REQUIRED_INCLUDES}")
    set(CMAKE_REQUIRED_INCLUDES "${Boost_INCLUDE_DIRS}")
    check_include_file_cxx("boost/asio/connect.hpp" ALMSIVI_HAS_BOOST_ASIO)
    check_include_file_cxx("boost/beast/core.hpp" ALMSIVI_HAS_BOOST_BEAST)
    set(CMAKE_REQUIRED_INCLUDES "${_almsivi_saved_required_includes}")

    if(NOT ALMSIVI_HAS_BOOST_ASIO OR NOT ALMSIVI_HAS_BOOST_BEAST)
        if(NOT WIN32)
            message(FATAL_ERROR "Boost.Asio and Boost.Beast headers are required for the live transport")
        endif()
        include(FetchContent)
        FetchContent_Declare(almsivi_boost_asio
            URL https://github.com/boostorg/asio/archive/refs/tags/boost-1.90.0.tar.gz
            URL_HASH SHA256=d23b5f86ebf49119f2470829ba2aebdc68ddf810b29947dd0552123d00aba981
            SOURCE_SUBDIR almsivi-no-cmake-project)
        FetchContent_Declare(almsivi_boost_beast
            URL https://github.com/boostorg/beast/archive/refs/tags/boost-1.90.0.tar.gz
            URL_HASH SHA256=28abe5a52d0a8817fb7b55808da555514d098d37707eaca530e109dc9acb25fc
            SOURCE_SUBDIR almsivi-no-cmake-project)
        FetchContent_Declare(almsivi_boost_context
            URL https://github.com/boostorg/context/archive/refs/tags/boost-1.90.0.tar.gz
            URL_HASH SHA256=69272ce5694be4963798054735a81d1eb05055af0d7ec15f65dc373ccfbf4fed
            SOURCE_SUBDIR almsivi-no-cmake-project)
        FetchContent_Declare(almsivi_boost_logic
            URL https://github.com/boostorg/logic/archive/refs/tags/boost-1.90.0.tar.gz
            URL_HASH SHA256=220a4167c9e2a77d067ab4c3ced571b16ab0419c87395b004dc8c8bcac54cc91
            SOURCE_SUBDIR almsivi-no-cmake-project)
        FetchContent_Declare(almsivi_boost_static_string
            URL https://github.com/boostorg/static_string/archive/refs/tags/boost-1.90.0.tar.gz
            URL_HASH SHA256=7a9a477d9c6e57b3e16cb8ed6506c33e29c6996d459b4b0af6b15c496da3b486
            SOURCE_SUBDIR almsivi-no-cmake-project)
        FetchContent_MakeAvailable(almsivi_boost_asio almsivi_boost_beast
            almsivi_boost_context almsivi_boost_logic almsivi_boost_static_string)
        set(_almsivi_fetched_boost_include_dirs
            "${almsivi_boost_asio_SOURCE_DIR}/include"
            "${almsivi_boost_beast_SOURCE_DIR}/include"
            "${almsivi_boost_context_SOURCE_DIR}/include"
            "${almsivi_boost_logic_SOURCE_DIR}/include"
            "${almsivi_boost_static_string_SOURCE_DIR}/include")
        target_include_directories(almsivi_core SYSTEM PRIVATE
            ${_almsivi_fetched_boost_include_dirs})
    endif()

    target_sources(almsivi_core PRIVATE src/beast_transport.cpp)
    target_compile_definitions(almsivi_core PRIVATE ALMSIVI_WITH_BOOST_BEAST=1)
    target_link_libraries(almsivi_core PRIVATE Boost::system)

    add_executable(almsivi_beast_transport_tests tests/beast_transport_tests.cpp)
    target_link_libraries(almsivi_beast_transport_tests PRIVATE almsivi_core Boost::system)
    if(_almsivi_fetched_boost_include_dirs)
        target_include_directories(almsivi_beast_transport_tests SYSTEM PRIVATE
            ${_almsivi_fetched_boost_include_dirs})
    endif()
    if(MSVC)
        target_compile_options(almsivi_beast_transport_tests PRIVATE /W4 /WX /permissive-)
    else()
        target_compile_options(almsivi_beast_transport_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
    endif()
    add_test(NAME almsivi-beast-transport COMMAND almsivi_beast_transport_tests)
    set_tests_properties(almsivi-beast-transport PROPERTIES
        LABELS "native;live-wire;loopback;no-engine;no-game")
endif()

option(ALMSIVI_BUILD_FUZZERS "Build libFuzzer entrypoints (Clang only)" OFF)
if(ALMSIVI_BUILD_FUZZERS)
    if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        message(FATAL_ERROR "ALMSIVI_BUILD_FUZZERS requires Clang")
    endif()
    foreach(name IN ITEMS url header json action)
        add_executable(almsivi_fuzz_${name} fuzz/${name}_fuzz.cpp)
        target_link_libraries(almsivi_fuzz_${name} PRIVATE almsivi_core)
        target_compile_options(almsivi_fuzz_${name} PRIVATE -fsanitize=fuzzer,address,undefined)
        target_link_options(almsivi_fuzz_${name} PRIVATE -fsanitize=fuzzer,address,undefined)
    endforeach()
endif()
