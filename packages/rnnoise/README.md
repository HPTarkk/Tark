# rnnoise

Dart FFI binding to [RNNoise](https://gitlab.xiph.org/xiph/rnnoise), Xiph.Org's
recurrent-neural-network speech denoiser. Vendored from the `0.1.x` branch
(commit `6cbfd53eb348a8d394e0757b4025c6ded34eb2b6`), the lightweight/classic
model — not the newer full-band rewrite, whose model table alone is tens of
megabytes and unsuitable for a mobile app.

RNNoise operates on 480-sample (10 ms) frames of 48 kHz mono float PCM. It has
no runtime parameters beyond the frame in/out buffers; suppression strength in
this package's Dart wrapper (`RnnoiseSuppressor` in the main app) is a wet/dry
mix applied on top, not a native RNNoise concept.

License: BSD (see LICENSE), copyright Mozilla / Jean-Marc Valin / Xiph.Org
Foundation / Mark Borgerding.

## Platforms

- Android: builds via CMake/NDK (`ffiPlugin: true`), same pattern as this
  repo's `audio_io` package.
- iOS: podspec/source wiring is in place but has not been built or tested —
  this repo's toolchain has no Xcode. Build and verify on macOS before
  shipping the iOS side.
