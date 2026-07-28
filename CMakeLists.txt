cmake_minimum_required(VERSION 3.26)

project(AppRuntime
    VERSION 1.0.0
    DESCRIPTION "Portable Cross-Platform Swift App Runtime"
    LANGUAGES C Swift)

include(GNUInstallDirs)

# Shared libraries by default: AppRuntime installs as libAppRuntime.so.
option(BUILD_SHARED_LIBS "Build AppRuntime as a shared library" ON)
option(APPRUNTIME_BUILD_LAUNCHER "Build and install the bundle-runtime launcher" ON)

set(CMAKE_C_STANDARD 11)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Emit .swiftmodule/.swiftinterface next to the library so the package can be
# imported by other Swift code after installation.
set(CMAKE_Swift_MODULE_DIRECTORY ${CMAKE_BINARY_DIR}/swift)
if(NOT CMAKE_Swift_COMPILER_TARGET AND CMAKE_Swift_COMPILER_TARGET_ARCHITECTURE)
    message(STATUS "Swift target: ${CMAKE_Swift_COMPILER_TARGET_ARCHITECTURE}")
endif()

# ---------------------------------------------------------------------------
# AppRuntime — the library
# ---------------------------------------------------------------------------

add_library(AppRuntime
    Sources/AppRuntime/AppBundle.swift
    Sources/AppRuntime/AppRuntime.swift
    Sources/AppRuntime/Arch.swift
    Sources/AppRuntime/ArchSelector.swift
    Sources/AppRuntime/Capability.swift
    Sources/AppRuntime/HostCapabilities.swift
    Sources/AppRuntime/Manifest.swift
    Sources/AppRuntime/SDKVersion.swift)

set_target_properties(AppRuntime PROPERTIES
    VERSION ${PROJECT_VERSION}
    SOVERSION ${PROJECT_VERSION_MAJOR}
    Swift_MODULE_NAME AppRuntime
    INSTALL_RPATH "$ORIGIN")

install(TARGETS AppRuntime
    EXPORT AppRuntimeTargets
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

# Swift module artifacts, so other Swift code can `import AppRuntime`.
install(DIRECTORY ${CMAKE_BINARY_DIR}/swift/
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/swift/AppRuntime
    FILES_MATCHING
        PATTERN "AppRuntime.swiftmodule"
        PATTERN "AppRuntime.swiftdoc"
        PATTERN "AppRuntime.swiftsourceinfo"
        PATTERN "AppRuntime.abi.json")

# ---------------------------------------------------------------------------
# bundle-runtime — the launcher (Linux only: the sandbox is Linux-specific)
# ---------------------------------------------------------------------------

if(APPRUNTIME_BUILD_LAUNCHER)
    add_library(CBundleRuntime STATIC
        Sources/CBundleRuntime/CBundleRuntime.c)
    target_include_directories(CBundleRuntime PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Sources/CBundleRuntime/include>)

    add_executable(bundle-runtime
        Sources/BundleRuntime/Container.swift
        Sources/BundleRuntime/ResourceLimits.swift
        Sources/BundleRuntime/Sandbox.swift
        Sources/BundleRuntime/main.swift)

    # Swift needs a module map to import the C shim.
    target_compile_options(bundle-runtime PRIVATE
        "SHELL:-Xcc -fmodule-map-file=${CMAKE_CURRENT_SOURCE_DIR}/Sources/CBundleRuntime/include/module.modulemap")
    target_link_libraries(bundle-runtime PRIVATE AppRuntime CBundleRuntime)

    set_target_properties(bundle-runtime PROPERTIES
        INSTALL_RPATH "$ORIGIN/../${CMAKE_INSTALL_LIBDIR}")

    install(TARGETS bundle-runtime
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
endif()

# ---------------------------------------------------------------------------
# Package config, so downstream CMake projects can find_package(AppRuntime)
# ---------------------------------------------------------------------------

include(CMakePackageConfigHelpers)
write_basic_package_version_file(
    ${CMAKE_CURRENT_BINARY_DIR}/AppRuntimeConfigVersion.cmake
    VERSION ${PROJECT_VERSION}
    COMPATIBILITY SameMajorVersion)

install(EXPORT AppRuntimeTargets
    FILE AppRuntimeTargets.cmake
    NAMESPACE AppRuntime::
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/AppRuntime)

configure_package_config_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/cmake/AppRuntimeConfig.cmake.in
    ${CMAKE_CURRENT_BINARY_DIR}/AppRuntimeConfig.cmake
    INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/AppRuntime)

install(FILES
    ${CMAKE_CURRENT_BINARY_DIR}/AppRuntimeConfig.cmake
    ${CMAKE_CURRENT_BINARY_DIR}/AppRuntimeConfigVersion.cmake
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/AppRuntime)
