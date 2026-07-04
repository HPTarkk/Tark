#!/bin/bash

# Build script for compiling miniaudio to WebAssembly
# Requires Emscripten SDK (emsdk) to be installed and activated

echo "Building miniaudio for WebAssembly..."

# Create build directory
mkdir -p build

# Compile with Emscripten
emcc ../src/audio_io_miniaudio.cpp \
  -o build/audio_io.js \
  -s WASM=1 \
  -s EXPORTED_FUNCTIONS='["_audio_io_create","_audio_io_destroy","_audio_io_start","_audio_io_stop","_audio_io_read","_audio_io_write","_audio_io_get_sample_rate","_audio_io_get_channels","_audio_io_get_available_read_frames","_audio_io_get_available_write_space"]' \
  -s EXPORTED_RUNTIME_METHODS='["ccall","cwrap","getValue","setValue"]' \
  -s ALLOW_MEMORY_GROWTH=1 \
  -s AUDIO_WORKLET=1 \
  -s WASM_ASYNC_COMPILATION=1 \
  -s SINGLE_FILE=1 \
  -O3 \
  -std=c++14 \
  -I../src

echo "Build complete! Output in web/build/"
