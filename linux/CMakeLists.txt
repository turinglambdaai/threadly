cmake_minimum_required(VERSION 3.24)
project(rivet-linux-host LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Release artifacts must not embed developer-machine library search paths;
# every linked library (GTK4, GIO, libsecret, curses, LZ4, zlib) is a system
# dependency resolved by the normal loader search on the target machine.
set(CMAKE_SKIP_RPATH TRUE)

# RIVET_ROOT points at the installed Rivet package. `raco rivet build` sets
# it; manual builds may export it themselves.
if(NOT DEFINED ENV{RIVET_ROOT})
  message(FATAL_ERROR "RIVET_ROOT is not set. Export RIVET_ROOT to a Rivet checkout.")
endif()
set(RIVET_ROOT "$ENV{RIVET_ROOT}")

# The Rivet platform (backend, system services, theme, update handoff,
# protocol) is consumed as a package library target (project constraint,
# rivet#238): hosts never compile Rivet sources into their own executable
# lists — rivet adding a translation unit needs no downstream change. The
# target publicly carries GTK4/GLIO/libsecret/curses/LZ4/zlib and the
# Racket include dir.
add_subdirectory("${RIVET_ROOT}/platform/linux"
                 "${CMAKE_BINARY_DIR}/rivet-platform-build")

# The reader pane renders the forum's cooked HTML in WebKitGTK — the GTK4
# build is the webkitgtk-6.0 pkg-config module (libsoup3). rivet::platform
# does not carry WebKit.
find_package(PkgConfig REQUIRED)
pkg_check_modules(WEBKIT REQUIRED IMPORTED_TARGET webkitgtk-6.0)
message(STATUS "WebKitGTK include dirs: ${WEBKIT_INCLUDE_DIRS}")

add_executable(RivetHost
  src/main.cpp
)

target_include_directories(RivetHost PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  ${WEBKIT_INCLUDE_DIRS}
)

target_link_libraries(RivetHost PRIVATE
  rivet::platform
  PkgConfig::WEBKIT
)

target_compile_options(RivetHost PRIVATE -Wall -Wextra -Wpedantic)
