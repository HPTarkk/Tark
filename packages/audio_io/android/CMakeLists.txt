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
