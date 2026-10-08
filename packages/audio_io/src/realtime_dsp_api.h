#pragma once

#include <cmath>
#include <limits>
#include <new>

#include "realtime_dsp.h"
#include "spectral_suppressor.h"

// Included once by the device library and by the device-free ABI test library.
// Sharing these definitions makes parity tests exercise the production guards
// and signatures as well as the DSP implementation.
#ifndef AUDIO_IO_DSP_EXPORT
#define AUDIO_IO_DSP_EXPORT
#endif
#ifndef AUDIO_IO_DSP_HANDLE_CREATED
#define AUDIO_IO_DSP_HANDLE_CREATED(kind)
#define AUDIO_IO_DSP_HANDLE_DESTROYED(kind)
#endif

extern "C" {

AUDIO_IO_DSP_EXPORT void* audio_io_resampler_create(double inRate,
                                                   double outRate) {
  const double ratio = inRate / outRate;
  if (!std::isfinite(inRate) || !std::isfinite(outRate) ||
      inRate <= 0.0 || outRate <= 0.0 || !std::isfinite(ratio) || ratio <= 0.0)
    return nullptr;
  try {
    auto* handle = new RealtimeResampler(inRate, outRate);
    AUDIO_IO_DSP_HANDLE_CREATED(0);
    return handle;
  } catch (...) { return nullptr; }
}

AUDIO_IO_DSP_EXPORT void audio_io_resampler_destroy(void* handle) {
  if (handle) {
    delete static_cast<RealtimeResampler*>(handle);
    AUDIO_IO_DSP_HANDLE_DESTROYED(0);
  }
}

AUDIO_IO_DSP_EXPORT int audio_io_resampler_output_capacity(void* handle,
                                                         int inputFrames) {
  if (!handle || inputFrames < 0) return 0;
  const size_t capacity = static_cast<RealtimeResampler*>(handle)
      ->outputCapacity(static_cast<size_t>(inputFrames));
  return static_cast<int>(std::min(capacity,
      static_cast<size_t>(std::numeric_limits<int>::max())));
}

AUDIO_IO_DSP_EXPORT int audio_io_resampler_process(void* handle,
    const double* input, int inputFrames, double* output, int outputCapacity) {
  if (!handle || inputFrames < 0 || outputCapacity < 0 ||
      (inputFrames != 0 && !input) || (outputCapacity != 0 && !output)) return 0;
  try {
    return static_cast<int>(static_cast<RealtimeResampler*>(handle)->process(
        input, static_cast<size_t>(inputFrames), output,
        static_cast<size_t>(outputCapacity)));
  } catch (...) { return -1; }
}

AUDIO_IO_DSP_EXPORT void audio_io_resampler_reset(void* handle) {
  if (handle) static_cast<RealtimeResampler*>(handle)->reset();
}

AUDIO_IO_DSP_EXPORT void* audio_io_low_pass_create(double sampleRate,
                                                 double cutoffHz) {
  if (!std::isfinite(sampleRate) || !std::isfinite(cutoffHz) ||
      sampleRate <= 0.0 || cutoffHz <= 0.0) return nullptr;
  try {
    auto* handle = new OnePoleLowPass(sampleRate, cutoffHz);
    AUDIO_IO_DSP_HANDLE_CREATED(1);
    return handle;
  } catch (...) { return nullptr; }
}

AUDIO_IO_DSP_EXPORT void audio_io_low_pass_destroy(void* handle) {
  if (handle) {
    delete static_cast<OnePoleLowPass*>(handle);
    AUDIO_IO_DSP_HANDLE_DESTROYED(1);
  }
}

AUDIO_IO_DSP_EXPORT void audio_io_low_pass_process(void* handle,
    const double* input, double* output, int frames) {
  if (!handle || !input || !output || frames <= 0) return;
  static_cast<OnePoleLowPass*>(handle)->process(
      input, output, static_cast<size_t>(frames));
}

AUDIO_IO_DSP_EXPORT void audio_io_low_pass_reset(void* handle) {
  if (handle) static_cast<OnePoleLowPass*>(handle)->reset();
}

AUDIO_IO_DSP_EXPORT void* audio_io_spectral_create(int sampleRate) {
  if (sampleRate <= 0) return nullptr;
  try {
    auto* handle = new SpectralSuppressor(sampleRate);
    AUDIO_IO_DSP_HANDLE_CREATED(2);
    return handle;
  } catch (...) { return nullptr; }
}

AUDIO_IO_DSP_EXPORT void audio_io_spectral_destroy(void* handle) {
  if (handle) {
    delete static_cast<SpectralSuppressor*>(handle);
    AUDIO_IO_DSP_HANDLE_DESTROYED(2);
  }
}

AUDIO_IO_DSP_EXPORT void audio_io_spectral_set_strength(void* handle,
                                                       double strength) {
  if (handle && std::isfinite(strength))
    static_cast<SpectralSuppressor*>(handle)->setStrength(strength);
}

AUDIO_IO_DSP_EXPORT void audio_io_spectral_process(void* handle,
    const double* input, double* output, int frames) {
  if (!handle || frames < 0 || (frames != 0 && (!input || !output))) return;
  try {
    static_cast<SpectralSuppressor*>(handle)->process(
        input, static_cast<size_t>(frames), output);
  } catch (...) { std::copy(input, input + frames, output); }
}

#ifndef AUDIO_IO_TEST_OMIT_SPECTRAL_RESET
AUDIO_IO_DSP_EXPORT void audio_io_spectral_reset(void* handle) {
  if (handle) static_cast<SpectralSuppressor*>(handle)->reset();
}
#endif

}  // extern "C"
