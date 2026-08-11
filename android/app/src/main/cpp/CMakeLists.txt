cmake_minimum_required(VERSION 3.22.1)

project(fluttermodp_android LANGUAGES C)

if(NOT ANDROID)
    message(FATAL_ERROR "This native build is only supported on Android.")
endif()

set(OPENMPT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/libopenmpt")
set(OPENMPT_ANDROID_MK "${OPENMPT_ROOT}/build/android_ndk/Android.mk")
set(OPENMPT_APPLICATION_MK "${OPENMPT_ROOT}/build/android_ndk/Application.mk")
set(OPENMPT_NDK_OUT "${CMAKE_CURRENT_BINARY_DIR}/libopenmpt/obj")
set(OPENMPT_LIBS_OUT "${CMAKE_CURRENT_BINARY_DIR}/libopenmpt/libs")
set(OPENMPT_LIBRARY "${OPENMPT_LIBS_OUT}/${ANDROID_ABI}/libopenmpt.so")

# libopenmpt ships an Android NDK Makefile. Keep that build authoritative and
# invoke it from CMake so a normal Flutter/Gradle build also builds libopenmpt.
file(GLOB_RECURSE OPENMPT_BUILD_INPUTS CONFIGURE_DEPENDS
    "${OPENMPT_ROOT}/*.c"
    "${OPENMPT_ROOT}/*.cpp"
    "${OPENMPT_ROOT}/*.h"
    "${OPENMPT_ROOT}/*.hpp"
    "${OPENMPT_ROOT}/*.inc"
)

add_custom_command(
    OUTPUT "${OPENMPT_LIBRARY}"
    COMMAND "${ANDROID_NDK}/ndk-build"
        -j4
        "NDK_PROJECT_PATH=${OPENMPT_ROOT}"
        "APP_BUILD_SCRIPT=${OPENMPT_ANDROID_MK}"
        "NDK_APPLICATION_MK=${OPENMPT_APPLICATION_MK}"
        "NDK_OUT=${OPENMPT_NDK_OUT}"
        "NDK_LIBS_OUT=${OPENMPT_LIBS_OUT}"
        "APP_ABI=${ANDROID_ABI}"
        "APP_PLATFORM=${ANDROID_PLATFORM}"
        "LOCAL_PATH=${OPENMPT_ROOT}"
    WORKING_DIRECTORY "${OPENMPT_ROOT}"
    DEPENDS
        "${OPENMPT_ANDROID_MK}"
        "${OPENMPT_APPLICATION_MK}"
        ${OPENMPT_BUILD_INPUTS}
    COMMENT "Building libopenmpt with its Android NDK Makefile (${ANDROID_ABI})"
    VERBATIM
)

add_custom_target(openmpt_make DEPENDS "${OPENMPT_LIBRARY}")

add_library(openmpt SHARED IMPORTED GLOBAL)
set_target_properties(openmpt PROPERTIES
    IMPORTED_LOCATION "${OPENMPT_LIBRARY}"
)

add_library(openmpt_bridge SHARED openmpt_bridge.c)
add_dependencies(openmpt_bridge openmpt_make)
target_include_directories(openmpt_bridge PRIVATE "${OPENMPT_ROOT}")
target_link_libraries(openmpt_bridge PRIVATE openmpt log)
