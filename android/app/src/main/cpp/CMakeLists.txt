cmake_minimum_required(VERSION 3.22.1)

project(fluttermodp_android LANGUAGES C CXX)

if(NOT ANDROID)
    message(FATAL_ERROR "This native build is only supported on Android.")
endif()

# Keep the third-party decoder outside either platform project. The same source
# tree can then be compiled for iOS without maintaining an Android-only copy.
get_filename_component(
    OPENMPT_ROOT
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../src/libopenmpt"
    ABSOLUTE
)

file(GLOB OPENMPT_SOURCES CONFIGURE_DEPENDS
    "${OPENMPT_ROOT}/common/*.cpp"
    "${OPENMPT_ROOT}/libopenmpt/*.cpp"
    "${OPENMPT_ROOT}/sounddsp/*.cpp"
    "${OPENMPT_ROOT}/soundlib/*.cpp"
    "${OPENMPT_ROOT}/soundlib/plugins/*.cpp"
    "${OPENMPT_ROOT}/soundlib/plugins/dmo/*.cpp"
)

add_library(openmpt SHARED ${OPENMPT_SOURCES})

set_target_properties(openmpt PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED YES
    CXX_EXTENSIONS NO
)

target_compile_definitions(openmpt PRIVATE
    LIBOPENMPT_BUILD
    LIBOPENMPT_BUILD_DLL
    MPT_WITH_ZLIB
)

target_compile_options(openmpt PRIVATE
    -fexceptions
    -frtti
    -fvisibility=hidden
    -Wall
)

target_include_directories(openmpt
    PUBLIC "${OPENMPT_ROOT}"
    PRIVATE
        "${OPENMPT_ROOT}/common"
        "${OPENMPT_ROOT}/src"
)

find_library(Z_LIBRARY z REQUIRED)
target_link_libraries(openmpt PRIVATE "${Z_LIBRARY}")
