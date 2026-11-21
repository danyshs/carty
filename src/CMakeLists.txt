# CMakeLists.txt — Android/NDK build entry for the Carty FFI plugin.
#
# This is the build the Flutter tooling invokes (via android/build.gradle's
# externalNativeBuild) to cross-compile the native bridge for each Android ABI
# and package it into the APK as `libcarty.so`.
#
# It does NOT redeclare the bridge sources: the single source of truth for the
# C ABI is ../native (the bridge header lives at
# native/include/carty_bridge.h). The host unit-test build (../native/
# CMakeLists.txt) compiles the SAME translation unit for fast `ctest`.
#
# The Flutter tooling requires CMake 3.10+. Do not raise this minimum, or the
# plugin will fail to compile for some clients.
cmake_minimum_required(VERSION 3.10)

# CXX: the bridge is C++ with an `extern "C"` ABI (../native/src/carty_bridge.cpp).
project(carty_library VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Resolve the bridge sources relative to this file so the host and Android
# builds stay in lockstep on one set of sources.
get_filename_component(CARTY_NATIVE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../native" ABSOLUTE)

# Output name MUST be `carty` so the Dart side opens `libcarty.so` (see
# lib/carty.dart `_libName`).
add_library(carty SHARED
  "${CARTY_NATIVE_DIR}/src/carty_bridge.cpp"
)

target_include_directories(carty PUBLIC "${CARTY_NATIVE_DIR}/include")

set_target_properties(carty PROPERTIES
  PUBLIC_HEADER "${CARTY_NATIVE_DIR}/include/carty_bridge.h"
  OUTPUT_NAME "carty"
)

# Marks the build as the dynamically-linked Dart FFI target.
target_compile_definitions(carty PUBLIC DART_SHARED_LIB)

# Zero-warnings quality gate: warnings are build-breaking.
target_compile_options(carty PRIVATE -Wall -Wextra -Wpedantic -Werror)

if (ANDROID)
  # Support Android 15's 16 KB page size.
  target_link_options(carty PRIVATE "-Wl,-z,max-page-size=16384")
endif()
