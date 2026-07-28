# Cross-compilation toolchain for Linux targets using a Swift SDK sysroot.
#
# Usage:
#   cmake -B build \
#     -DCMAKE_TOOLCHAIN_FILE=cmake/linux.toolchain.cmake \
#     -DAPPRUNTIME_ARCH=arm64 \
#     -DCMAKE_BUILD_TYPE=Release
#
# Options:
#   APPRUNTIME_ARCH     arm64 (default) | x86_64 | armv7 | i386
#   APPRUNTIME_SYSROOT  override the sysroot path
#   APPRUNTIME_TOOLCHAIN_BIN  directory holding clang/swiftc (default: ~/.swiftly/bin)
#
# The default sysroot is the `swift-linux` Swift SDK installed with
# `swift sdk install`, which ships sysroot-<arch> trees.

set(CMAKE_SYSTEM_NAME Linux)

# CMake re-reads this file inside try_compile projects, which do not inherit
# ordinary variables. Without this the settings below would silently fall back
# to their defaults during compiler detection and mismatch the real build.
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES
    APPRUNTIME_ARCH APPRUNTIME_SYSROOT APPRUNTIME_TOOLCHAIN_BIN)

if(NOT APPRUNTIME_ARCH)
    set(APPRUNTIME_ARCH "arm64")
endif()

# Map the bundle architecture identifier to processor and triple.
if(APPRUNTIME_ARCH STREQUAL "arm64")
    set(CMAKE_SYSTEM_PROCESSOR aarch64)
    set(APPRUNTIME_TRIPLE aarch64-unknown-linux-gnu)
elseif(APPRUNTIME_ARCH STREQUAL "x86_64")
    set(CMAKE_SYSTEM_PROCESSOR x86_64)
    set(APPRUNTIME_TRIPLE x86_64-unknown-linux-gnu)
elseif(APPRUNTIME_ARCH STREQUAL "armv7")
    set(CMAKE_SYSTEM_PROCESSOR armv7l)
    set(APPRUNTIME_TRIPLE armv7-unknown-linux-gnueabihf)
elseif(APPRUNTIME_ARCH STREQUAL "i386")
    set(CMAKE_SYSTEM_PROCESSOR i686)
    set(APPRUNTIME_TRIPLE i686-unknown-linux-gnu)
else()
    message(FATAL_ERROR "unsupported APPRUNTIME_ARCH: ${APPRUNTIME_ARCH}")
endif()

if(NOT APPRUNTIME_SYSROOT)
    set(APPRUNTIME_SYSROOT
        "$ENV{HOME}/Library/org.swift.swiftpm/swift-sdks/swift-linux.artifactbundle/swift-linux/sysroot-${APPRUNTIME_ARCH}")
endif()
if(NOT EXISTS "${APPRUNTIME_SYSROOT}")
    message(FATAL_ERROR "sysroot not found: ${APPRUNTIME_SYSROOT}\n"
        "Install a Swift SDK or pass -DAPPRUNTIME_SYSROOT=<path>.")
endif()
set(CMAKE_SYSROOT "${APPRUNTIME_SYSROOT}")

if(NOT APPRUNTIME_TOOLCHAIN_BIN)
    set(APPRUNTIME_TOOLCHAIN_BIN "$ENV{HOME}/.swiftly/bin")
endif()

set(CMAKE_C_COMPILER "${APPRUNTIME_TOOLCHAIN_BIN}/clang")
set(CMAKE_C_COMPILER_TARGET ${APPRUNTIME_TRIPLE})
set(CMAKE_Swift_COMPILER "${APPRUNTIME_TOOLCHAIN_BIN}/swiftc")
set(CMAKE_Swift_COMPILER_TARGET ${APPRUNTIME_TRIPLE})

# Point the Swift compiler at the target sysroot and use lld: the host
# linker cannot produce ELF binaries. The spellings differ per driver
# (`-use-ld=` for swiftc, `-fuse-ld=` for clang), so scope by link language.
#
# `-sdk` alone is not enough: swiftc also needs the target's Swift resource
# directory (stdlib modules built for Linux) and the sysroot's library paths,
# which is what the Swift SDK's own configuration supplies.
set(APPRUNTIME_SWIFT_RESOURCE_DIR "${CMAKE_SYSROOT}/usr/lib/swift")
set(CMAKE_Swift_FLAGS_INIT
    "-sdk ${CMAKE_SYSROOT} \
-resource-dir ${APPRUNTIME_SWIFT_RESOURCE_DIR} \
-L${CMAKE_SYSROOT}/usr/lib -L${APPRUNTIME_SWIFT_RESOURCE_DIR}/linux \
-Xcc -I${CMAKE_SYSROOT}/usr/include \
-no-toolchain-stdlib-rpath \
-use-ld=lld")
add_link_options("$<$<LINK_LANGUAGE:C>:-fuse-ld=lld>")

# Keep the build host's sysroot out of the shipped binaries' RUNPATH: on the
# target the Swift runtime lives in the OS's own /usr/lib/swift/linux, found
# via the default search path. CMake otherwise records the toolchain's
# implicit link directories as an un-strippable "toolchain portion" of RPATH.
set(CMAKE_Swift_IMPLICIT_LINK_DIRECTORIES "")
set(CMAKE_C_IMPLICIT_LINK_DIRECTORIES "")

set(CMAKE_FIND_ROOT_PATH "${CMAKE_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
