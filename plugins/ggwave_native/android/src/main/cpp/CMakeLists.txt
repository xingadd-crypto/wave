cmake_minimum_required(VERSION 3.22)

project(ggwave_native_jni LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NATIVE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../native")

add_library(ggwave_native_jni SHARED
  ggwave_jni.cpp
  "${NATIVE_DIR}/src/ggwave.cpp"
)

target_include_directories(ggwave_native_jni PRIVATE
  "${NATIVE_DIR}"
  "${NATIVE_DIR}/include"
)