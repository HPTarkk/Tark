cmake_minimum_required(VERSION 3.18)
project(rnnoise)

add_library(rnnoise SHARED
    ../src/rnnoise_stream.cpp
    ../src/denoise.c
    ../src/rnn.c
    ../src/rnn_data.c
    ../src/rnn_reader.c
    ../src/pitch.c
    ../src/kiss_fft.c
    ../src/celt_lpc.c
)

target_include_directories(rnnoise PRIVATE
    ../src
    ../include
)

target_compile_definitions(rnnoise PRIVATE RNNOISE_BUILD=1)

target_link_libraries(rnnoise
    m
)

set_target_properties(rnnoise PROPERTIES
    C_STANDARD 99
    C_STANDARD_REQUIRED ON
    CXX_STANDARD 14
    CXX_STANDARD_REQUIRED ON
)

# 16 KB page alignment, required to load on devices with 16 KB memory pages
# (and by Google Play for apps targeting Android 15+). NDK r28 does this by
# default; NDK r27, which this project pins, does not.
# The version script keeps everything but the FFI/JNI entry points local.
target_link_options(rnnoise PRIVATE
    "-Wl,-z,max-page-size=16384"
    "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/rnnoise.map"
)
set_property(TARGET rnnoise APPEND PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/rnnoise.map")
