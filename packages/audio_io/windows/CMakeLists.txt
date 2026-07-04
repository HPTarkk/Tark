cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "audio_io")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "audio_io_plugin")

add_library(${PLUGIN_NAME} SHARED
  "${PLUGIN_NAME}.cpp"
)

# Build the shared library for miniaudio
add_library(audio_io SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/audio_io_miniaudio.cpp"
)

# Set include directories for miniaudio
target_include_directories(audio_io PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../src"
)

# Apply standard settings
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# Windows-specific libraries for miniaudio
target_link_libraries(audio_io PRIVATE winmm)
target_link_libraries(audio_io PRIVATE ole32)

# Set C++ standard
set_target_properties(audio_io PROPERTIES
  CXX_STANDARD 14
  CXX_STANDARD_REQUIRED ON
  CXX_EXTENSIONS OFF
)

# List of absolute paths to libraries that should be bundled with the plugin
set(audio_io_bundled_libraries
  "$<TARGET_FILE:audio_io>"
  PARENT_SCOPE
)
