# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "ggwave_native")
project(${PROJECT_NAME} LANGUAGES CXX)

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed. The Flutter tooling links against "${plugin}_plugin".
set(PLUGIN_NAME "ggwave_native_plugin")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "ggwave_native_plugin.cpp"
  "ggwave_native_plugin.h"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  "include/ggwave_native/ggwave_native_plugin_c_api.h"
  "ggwave_native_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
  "${CMAKE_CURRENT_SOURCE_DIR}/../native/src/ggwave.cpp"
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# ggwave's vendored DSP code produces many benign MSVC level-4 warnings
# (narrowing conversions). Never promote them to errors for this target.
if(MSVC)
  target_compile_options(${PLUGIN_NAME} PRIVATE /W0)
else()
  target_compile_options(${PLUGIN_NAME} PRIVATE -w)
endif()

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# The interface include dir exposes this plugin's C API header to the Flutter
# runner's generated_plugin_registrant.cc. The remaining paths are private.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../native"
  "${CMAKE_CURRENT_SOURCE_DIR}/../native/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(ggwave_native_bundled_libraries
  ""
  PARENT_SCOPE
)