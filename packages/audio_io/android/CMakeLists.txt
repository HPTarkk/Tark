cmake_minimum_required(VERSION 3.18)
project(audio_io)

# Add the miniaudio source
add_library(audio_io SHARED
    ../src/audio_io_miniaudio.cpp
)

# Include directories
target_include_directories(audio_io PRIVATE
    ../src
)

# Link against Android libraries
find_library(log-lib log)
find_library(android-lib android)

target_link_libraries(audio_io
    ${log-lib}
    ${android-lib}
)

# Set C++ standard
set_target_properties(audio_io PROPERTIES
    CXX_STANDARD 14
    CXX_STANDARD_REQUIRED ON
)

# 16 KB page alignment, required to load on devices with 16 KB memory pages
# (and by Google Play for apps targeting Android 15+). NDK r28 does this by
# default; NDK r27, which this project pins, does not.
# The version script keeps everything but the FFI/JNI entry points local.
target_link_options(audio_io PRIVATE
    "-Wl,-z,max-page-size=16384"
    "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/audio_io.map"
)
set_property(TARGET audio_io APPEND PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/audio_io.map")
