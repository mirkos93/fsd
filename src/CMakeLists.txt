# stable-diffusion.cpp itself requires CMake >= 3.12 (and ggml inside it
# wants 3.14+ in places), so we bump above the Flutter scaffold default of
# 3.10. The Android Gradle Plugin ships 3.22+ by default, which is fine.
cmake_minimum_required(VERSION 3.22)

project(fsd_library VERSION 0.0.1 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ---- stable-diffusion.cpp configuration ----
# Backends always-off: never used in F2.x.
set(SD_CUDA            OFF CACHE BOOL "" FORCE)
set(SD_HIPBLAS         OFF CACHE BOOL "" FORCE)
set(SD_OPENCL          OFF CACHE BOOL "" FORCE)
set(SD_SYCL            OFF CACHE BOOL "" FORCE)
set(SD_MUSA            OFF CACHE BOOL "" FORCE)
set(SD_BUILD_EXAMPLES  OFF CACHE BOOL "" FORCE)
set(SD_BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
# Image I/O extras we don't want on mobile (we encode to PNG ourselves):
set(SD_WEBP            OFF CACHE BOOL "" FORCE)
set(SD_WEBM            OFF CACHE BOOL "" FORCE)

# Backends that depend on the platform (Metal on iOS, Vulkan as opt-in toggle):
# leave SD_METAL / SD_VULKAN to whatever the caller passed via -D, defaulting
# to OFF if not set. This lets tool/build_ios_xcframework.sh switch Metal on
# without editing this file, and gradle.properties (fsdVulkan=true) wire
# Vulkan ON for Android builds via android/build.gradle.
if(NOT DEFINED SD_METAL)
    set(SD_METAL OFF CACHE BOOL "" FORCE)
endif()
if(NOT DEFINED SD_VULKAN)
    set(SD_VULKAN OFF CACHE BOOL "" FORCE)
endif()

# When building Vulkan on Android, ggml-vulkan/CMakeLists does
# `find_package(Vulkan COMPONENTS glslc REQUIRED)`. The NDK ships glslc under
# $NDK/shader-tools/<host-arch>/, but find_package doesn't search there by
# default. Hint it explicitly so the build doesn't fail with
# "Could NOT find Vulkan (missing: glslc)" on machines that don't have a
# system-wide Vulkan SDK installed.
if (SD_VULKAN AND ANDROID AND DEFINED ANDROID_NDK)
    if (CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
        set(_fsd_ndk_shader_host "linux-x86_64")
    elseif (CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
        set(_fsd_ndk_shader_host "darwin-x86_64")
    elseif (CMAKE_HOST_SYSTEM_NAME STREQUAL "Windows")
        set(_fsd_ndk_shader_host "windows-x86_64")
    endif()
    if (DEFINED _fsd_ndk_shader_host)
        set(_fsd_ndk_glslc "${ANDROID_NDK}/shader-tools/${_fsd_ndk_shader_host}/glslc")
        if (EXISTS "${_fsd_ndk_glslc}")
            set(Vulkan_GLSLC_EXECUTABLE "${_fsd_ndk_glslc}" CACHE FILEPATH "" FORCE)
            message(STATUS "fsd: using NDK-bundled glslc: ${_fsd_ndk_glslc}")
        endif()
    endif()

    # ggml-vulkan/ggml-vulkan.cpp #include's <vulkan/vulkan.hpp>, the C++
    # Vulkan-Hpp wrapper from KhronosGroup. The Android NDK r27 ships
    # <vulkan/vulkan.h> at VK_HEADER_VERSION=275; the matching vulkan.hpp
    # (and the *current* C headers) live in Vulkan-Hpp's bundled
    # Vulkan-Headers submodule. We need BOTH to be from the same revision —
    # mixing the NDK's stale C headers with a fresh vulkan.hpp produces
    # "VK_HEADER_VERSION mismatch" static-asserts, so we point the include
    # path at Vulkan-Headers' include/ directory ahead of the NDK sysroot.
    #
    # Vendor on demand: clone https://github.com/KhronosGroup/Vulkan-Hpp.git
    # (with --recurse-submodules) into fsd/third_party/Vulkan-Hpp/. We *only*
    # use the headers; nothing is built from this checkout.
    set(_fsd_vkhdr_include
        "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/Vulkan-Hpp/Vulkan-Headers/include")
    if (EXISTS "${_fsd_vkhdr_include}/vulkan/vulkan.hpp")
        message(STATUS "fsd: using vendored Vulkan-Headers at ${_fsd_vkhdr_include}")
        include_directories(BEFORE "${_fsd_vkhdr_include}")
    else()
        message(FATAL_ERROR
            "SD_VULKAN=ON requires Vulkan-Hpp + matching Vulkan-Headers, which "
            "the Android NDK does NOT bundle (only stale C headers ship in the "
            "sysroot). Vendor them at fsd/third_party/Vulkan-Hpp/ — e.g.:\n"
            "  git -C fsd/third_party clone --depth 1 --recurse-submodules \\\n"
            "    https://github.com/KhronosGroup/Vulkan-Hpp.git\n"
            "Then re-run the build. The path is checked in src/CMakeLists.txt; "
            "no other change required. Note: the clone is ~400 MB (mostly "
            "submodules we don't actually compile from).")
    endif()
endif()

# ggml settings
set(GGML_LLAMAFILE     OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP        OFF CACHE BOOL "" FORCE)  # NDK toolchain doesn't bundle libomp by default
set(GGML_NATIVE        OFF CACHE BOOL "" FORCE)  # don't auto-detect host arch (mobile cross-compile)
# K-quants stay ON: they're the default in upstream, do not touch.

if (ANDROID)
    message(STATUS "fsd: Android build, ABI=${CMAKE_ANDROID_ARCH_ABI}")
    if (CMAKE_ANDROID_ARCH_ABI STREQUAL "arm64-v8a")
        # ARMv8.2-A + dotprod is supported by every Android device shipped after
        # 2017 (Cortex-A75/A55 onward). Cuts inference time meaningfully.
        set(CMAKE_C_FLAGS   "${CMAKE_C_FLAGS} -march=armv8.2-a+dotprod")
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -march=armv8.2-a+dotprod")
    endif()
endif()

# Optimisation flags. -ffast-math gives a small lift in matmul-heavy paths;
# pair with -fno-finite-math-only so NaN/Inf checks in ggml still work.
add_compile_options(-O3 -ffast-math -fno-finite-math-only -fvisibility=hidden)

# Pull in upstream stable-diffusion.cpp. The plugin scaffold lives in
# fsd/src/, while the submodule is at fsd/third_party/stable-diffusion.cpp.
add_subdirectory(
    "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/stable-diffusion.cpp"
    "${CMAKE_BINARY_DIR}/sdcpp"
    EXCLUDE_FROM_ALL
)

# ---- our shim ----
# Android: shared lib loaded via DynamicLibrary.open('libfsd.so').
# iOS:     static lib merged into the xcframework, then linked into Runner.app
#          (consumer Dart uses DynamicLibrary.process()). Selected via the
#          FSD_IOS_STATIC flag set by tool/build_ios_xcframework.sh.
if(IOS OR FSD_IOS_STATIC)
    add_library(fsd STATIC fsd.cpp)
else()
    add_library(fsd SHARED fsd.cpp)
endif()

set_target_properties(fsd PROPERTIES
    OUTPUT_NAME "fsd"
)

target_include_directories(fsd PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/stable-diffusion.cpp/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/stable-diffusion.cpp/thirdparty"
)

target_link_libraries(fsd PRIVATE
    stable-diffusion
)

target_compile_definitions(fsd PUBLIC DART_SHARED_LIB)

# When SD_VULKAN is on, expose FSD_HAVE_VULKAN to fsd.cpp so the runtime probe
# (fsd_gpu_available) is compiled in. We deliberately do NOT link libvulkan
# directly into libfsd.so — ggml-vulkan brings it in for itself, and the probe
# uses dlopen() so the library still loads on devices without a Vulkan ICD.
if (SD_VULKAN)
    target_compile_definitions(fsd PRIVATE FSD_HAVE_VULKAN=1)
    message(STATUS "fsd: Vulkan probe compiled in (fsd_gpu_available will report runtime device count)")
endif()

if (ANDROID)
    # Android 15 16k page size + log lib
    target_link_options(fsd PRIVATE "-Wl,-z,max-page-size=16384")
    target_link_libraries(fsd PRIVATE log)
    # dlfcn (dlopen / dlsym) is in libc on bionic; nothing extra to link.
endif()

if (APPLE)
    # Metal / MetalKit / Foundation / Accelerate are pulled in transitively
    # by the sd.cpp + ggml targets when SD_METAL=ON. We just need to make
    # sure the static archive includes everything under -ObjC paths.
    target_link_options(fsd PRIVATE "-Wl,-force_load,$<TARGET_FILE:stable-diffusion>")
endif()

if (UNIX AND NOT APPLE AND NOT ANDROID AND SD_VULKAN)
    # Desktop linux dev: dl is its own lib here.
    target_link_libraries(fsd PRIVATE dl)
endif()
