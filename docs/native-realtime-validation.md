# Native realtime core validation

The realtime DSP and RNNoise stream APIs own their native state. Flutter keeps
configuration, session policy, routing and UI. Resampling, low-pass filtering,
spectral suppression and RNNoise frame orchestration prefer native implementations;
missing optional symbols retain the Dart fallback. RNNoise inference uses the
existing vendored model in both orchestration paths.

## Repeatable quality gate

`.github/workflows/flutter-build.yml` builds the production DSP C ABI into host
fixtures before running Flutter tests. It also builds the real RNNoise model and
a legacy library without the optional stream API. `TARK_REQUIRE_NATIVE_TESTS=1`
ensures a missing fixture cannot turn native coverage into silently skipped tests.

The workflow checks:

- Dart formatting, analysis, the complete Flutter suite and protocol compatibility.
- C++ ring-buffer, voice-playout, resampler and spectral tests; the two DSP tests
  additionally run with AddressSanitizer and UndefinedBehaviorSanitizer.
- Native/Dart output parity at 16 and 24 kHz, random chunk boundaries, long streams,
  reset, bypass, silence, in-place processing and old/partial native APIs.
- Handle ownership, reconfiguration rollback, allocation failures, concurrent
  shutdown and Android capture consent cancellation/retry.
- Real app startup, generated DI and routing, persisted audio settings, onboarding
  flows and actual UDP loopback receive/rebind with malformed/stale packets.
- A 65% global line-coverage floor and a 90% floor across the three audio domain
  DSP modules. Generated localization/serialization exclusions are unchanged;
  bootstrap, platform and fallback code are included.
- Web guest and Android debug compilation, Python utilities and generated legal
  and website output.

For local parity runs, build the fixtures using the commands in the native workflow
step, then provide all four absolute library paths:

```sh
export AUDIO_IO_TEST_LIBRARY=/path/to/libnative_dsp_test_api.so
export AUDIO_IO_TEST_INCOMPLETE_LIBRARY=/path/to/libnative_dsp_incomplete_test_api.so
export RNNOISE_LIBRARY_PATH=/path/to/librnnoise_host.so
export RNNOISE_LEGACY_LIBRARY_PATH=/path/to/librnnoise_legacy_host.so
export TARK_REQUIRE_NATIVE_TESTS=1
flutter test --coverage
python3 scripts/check_coverage.py coverage/lcov.info --minimum 65
```

Windows uses `.dll` host fixtures; production `audio_io` was also compiled with
MSVC, and the Android arm64 DSP library was cross-compiled with the NDK. The
vendored RNNoise C source uses variable-length arrays, so a Windows host test build
requires Clang with the MSVC toolchain rather than the MSVC C compiler.

## Performance and platform limits

The Windows verification with Flutter 3.47.5 passed 2,045 Flutter tests with all
native fixtures required. Its complete LCOV report measured 22,058 / 33,482 lines
(65.88%) overall and 253 / 253 lines across the three audio domain DSP modules.
Native C++ DSP and actual-model RNNoise tests also passed. CI reruns the checks
on Linux with the pinned Flutter version rather than treating these host results
as a substitute.

`scripts/bench_tx.dart` compares boxed Dart, typed Dart and the actual native FFI
DSP chain. `scripts/bench_rnnoise.dart` compares native and Dart orchestration
around the same loaded RNNoise model, including explicit bypass rows. Compile
these scripts to an executable before measuring, use Release native libraries,
and report mean and p99 alongside the machine and platform. Host measurements
show a smaller RNNoise improvement because model inference dominates; they do
not establish Android callback latency or battery use.

The spectral stream uses preallocated ring buffers and FFT tables. Its native
regression test checks zero heap allocations during normal processing and reset,
including blocks larger than a callback. Resamplers grow reusable storage when
necessary; allocation failures surface through the C ABI rather than consuming
input and reporting an empty successful output.

Android compilation verifies the plugin ABI and capture bridge, but microphone,
Bluetooth routes, screen locking and capture-consent UI still need physical-device
testing. The iOS pod includes the new stream source and shared DSP header; an
Xcode/iOS build has not been run in this Windows environment.
