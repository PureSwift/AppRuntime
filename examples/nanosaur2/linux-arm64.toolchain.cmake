# CMake toolchain: cross-compile for Linux arm64 using the swift-linux
# Swift SDK's sysroot and the swiftly toolchain's clang + lld.
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(SWIFT_SDK_ROOT "$ENV{HOME}/Library/org.swift.swiftpm/swift-sdks/swift-linux.artifactbundle/swift-linux")
set(CMAKE_SYSROOT "${SWIFT_SDK_ROOT}/sysroot-arm64")

set(CMAKE_C_COMPILER "$ENV{HOME}/.swiftly/bin/clang")
set(CMAKE_CXX_COMPILER "$ENV{HOME}/.swiftly/bin/clang++")
set(CMAKE_C_COMPILER_TARGET aarch64-unknown-linux-gnu)
set(CMAKE_CXX_COMPILER_TARGET aarch64-unknown-linux-gnu)

add_link_options(-fuse-ld=lld)

set(CMAKE_FIND_ROOT_PATH "${CMAKE_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
