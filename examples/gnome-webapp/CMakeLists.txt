cmake_minimum_required(VERSION 3.16)

project(gnome-webapp
    VERSION 1.0.0
    DESCRIPTION "GNOME-style single-site web application"
    LANGUAGES C)

include(GNUInstallDirs)

# GNOME ships pkg-config files, not CMake package configs: GTK and GLib
# build with Meson and provide no *Config.cmake, and CMake's bundled
# FindGTK modules only cover GTK 2. pkg-config is the supported
# integration point for consumers of any build system.
#
# For cross builds, point pkg-config at the target sysroot:
#   PKG_CONFIG_SYSROOT_DIR=<sysroot>
#   PKG_CONFIG_LIBDIR=<sysroot>/usr/lib/pkgconfig:<sysroot>/usr/share/pkgconfig
find_package(PkgConfig REQUIRED)
pkg_check_modules(GNOME REQUIRED IMPORTED_TARGET gtk4 webkitgtk-6.0)

# Baked in at build time so the bundle carries no configuration of its own.
set(APP_URL "https://www.gnome.org/" CACHE STRING "Site the web app opens")
set(APP_NAME "GNOME Web App" CACHE STRING "Window title and display name")
set(APP_ID "org.gnome.Webapp" CACHE STRING "Bundle identifier")

add_executable(gnome-webapp src/main.c)

target_compile_definitions(gnome-webapp PRIVATE
    APP_URL="${APP_URL}"
    APP_NAME="${APP_NAME}"
    APP_ID="${APP_ID}")

target_compile_options(gnome-webapp PRIVATE -Wall -Wextra)
target_link_libraries(gnome-webapp PRIVATE PkgConfig::GNOME)

# Installs into the bundle layout: bin/<arch>/<executable>.
set(APPRUNTIME_ARCH "arm64" CACHE STRING "Bundle architecture directory")
install(TARGETS gnome-webapp
    RUNTIME DESTINATION bin/${APPRUNTIME_ARCH})
