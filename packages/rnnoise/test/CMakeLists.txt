cmake_minimum_required(VERSION 3.18)
project(rnnoise_stream_tests LANGUAGES C CXX)

set(RNNOISE_SOURCES
    ../src/denoise.c ../src/rnn.c ../src/rnn_data.c ../src/rnn_reader.c
    ../src/pitch.c ../src/kiss_fft.c ../src/celt_lpc.c)

add_library(rnnoise_host SHARED ${RNNOISE_SOURCES} ../src/rnnoise_stream.cpp)
# A real old ABI binary verifies that optional stream lookup does not break the
# already-shipped frame API, rather than mocking a null library in Dart.
add_library(rnnoise_legacy_host SHARED ${RNNOISE_SOURCES})
foreach(target rnnoise_host rnnoise_legacy_host)
  target_include_directories(${target} PRIVATE ../include ../src)
  target_compile_definitions(${target} PRIVATE RNNOISE_BUILD=1 DLL_EXPORT=1)
  if(WIN32)
    target_compile_definitions(${target} PRIVATE WIN32=1 _USE_MATH_DEFINES=1
                               _CRT_SECURE_NO_WARNINGS=1)
  endif()
  set_target_properties(${target} PROPERTIES C_STANDARD 99 C_STANDARD_REQUIRED ON
                        CXX_STANDARD 14 CXX_STANDARD_REQUIRED ON)
  if(NOT WIN32)
    target_link_libraries(${target} PRIVATE m)
  endif()
endforeach()

add_executable(rnnoise_stream_test rnnoise_stream_test.cpp)
target_include_directories(rnnoise_stream_test PRIVATE ../include)
target_link_libraries(rnnoise_stream_test PRIVATE rnnoise_host)
target_compile_features(rnnoise_stream_test PRIVATE cxx_std_14)
enable_testing()
add_test(NAME rnnoise_stream_test COMMAND rnnoise_stream_test)
