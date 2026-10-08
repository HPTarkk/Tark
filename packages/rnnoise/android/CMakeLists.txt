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
