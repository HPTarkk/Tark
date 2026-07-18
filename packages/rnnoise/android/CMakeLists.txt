cmake_minimum_required(VERSION 3.18)
project(rnnoise)

add_library(rnnoise SHARED
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

target_link_libraries(rnnoise
    m
)

set_target_properties(rnnoise PROPERTIES
    C_STANDARD 99
    C_STANDARD_REQUIRED ON
)
