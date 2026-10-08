#include "../src/realtime_dsp_api.h"

#include <cmath>
#include <cstdio>
#include <cstdint>
#include <limits>
#include <vector>

static int failures = 0;
#define CHECK(c, m) do { if (!(c)) { std::printf("FAIL: %s\n", m); ++failures; } } while (0)

static std::vector<double> resample(RealtimeResampler& r,
                                    const std::vector<double>& input) {
  std::vector<double> out(r.outputCapacity(input.size()));
  const size_t n = r.process(input.data(), input.size(), out.data(), out.size());
  CHECK(n <= out.size(), "resampler respects its advertised capacity");
  out.resize(n);
  return out;
}

static void compare(const std::vector<double>& actual,
                    const std::vector<double>& expected, double tolerance,
                    const char* message) {
  double max_error = 0.0;
  for (size_t i = 0; i < std::min(actual.size(), expected.size()); ++i)
    max_error = std::max(max_error, std::fabs(actual[i] - expected[i]));
  if (actual.size() != expected.size() || max_error > tolerance) {
    std::printf("%s: actual=%zu expected=%zu max_error=%.17g\n",
                message, actual.size(), expected.size(), max_error);
    CHECK(false, message);
  }
}

static void chunk_invariance(double in_rate, double out_rate) {
  std::vector<double> input(10007);
  for (size_t i = 0; i < input.size(); ++i)
    input[i] = 0.4 * std::sin(2.0 * 3.14159265358979323846 * 440.0 * i / in_rate)
             + 0.2 * std::sin(i * 0.091);

  RealtimeResampler whole(in_rate, out_rate);
  const auto expected = resample(whole, input);
  RealtimeResampler chunked(in_rate, out_rate);
  std::vector<double> actual;
  uint32_t seed = 1934;
  for (size_t at = 0; at < input.size();) {
    seed = seed * 1664525u + 1013904223u;
    const size_t n = std::min<size_t>(1 + seed % 379, input.size() - at);
    const std::vector<double> part(input.begin() + at, input.begin() + at + n);
    const auto got = resample(chunked, part);
    actual.insert(actual.end(), got.begin(), got.end());
    at += n;
  }
  // Fractional phase accumulation has small rounding differences at different
  // block boundaries; waveform and output length must remain stable.
  compare(actual, expected, 2e-8, "chunking preserves resampled stream");
  chunked.reset();
  compare(resample(chunked, input), expected, 0.0, "reset restores resampler state");
}

static void tiny_chunks_and_capacity() {
  RealtimeResampler r(48000, 16000);
  const double first = 0.25, second = 0.75;
  CHECK(r.outputCapacity(1) == 0, "single initial sample has no output yet");
  CHECK(r.process(&first, 1, nullptr, 0) == 0, "zero capacity retains input");
  double out[8] = {};
  CHECK(r.process(&second, 1, out, 8) == 1 && out[0] == first,
        "first sample survives a zero-output input block");

  RealtimeResampler skipping(48000, 1000);
  size_t produced = 0;
  for (size_t i = 0; i < 481; ++i) {
    const double sample = static_cast<double>(i);
    const size_t capacity = skipping.outputCapacity(1);
    CHECK(capacity < 4, "phase ahead of tiny input cannot wrap output capacity");
    const size_t n = skipping.process(&sample, 1, out, capacity);
    if (n != 0) {
      CHECK(n == 1 && out[0] == static_cast<double>(produced * 48),
            "tiny downsampled chunks preserve interpolation position");
      produced += n;
    }
  }
  CHECK(produced == 10, "lookahead keeps final sample until next input arrives");

  std::vector<double> input(200);
  for (size_t i = 0; i < input.size(); ++i) input[i] = std::sin(i * 0.1);
  RealtimeResampler whole(16000, 48000), limited(16000, 48000);
  const auto expected = resample(whole, input);
  std::vector<double> actual;
  size_t n = limited.process(input.data(), input.size(), out, 7);
  actual.insert(actual.end(), out, out + n);
  while (limited.outputCapacity(0) != 0) {
    n = limited.process(nullptr, 0, out, 7);
    CHECK(n != 0, "retained backlog can be drained without new input");
    if (n == 0) break;
    actual.insert(actual.end(), out, out + n);
  }
  compare(actual, expected, 2e-12, "small output capacity does not drop audio");
}

static void low_pass_is_stateful() {
  OnePoleLowPass f(48000, 7200);
  double a[4] = {1, 1, 1, 1}, x[4] = {}, b[4] = {}, y[4] = {};
  f.process(a, x, 4);
  f.process(b, y, 4);
  CHECK(x[0] > 0 && x[0] < 1, "filter smooths onset");
  CHECK(y[0] > 0 && y[0] < x[3], "filter carries state across chunks");
  f.reset();
  f.process(a, y, 4);
  for (size_t i = 0; i < 4; ++i)
    CHECK(y[i] == x[i], "filter reset reproduces cold start");
  double inplace[4] = {1, 1, 1, 1};
  f.reset();
  f.process(inplace, inplace, 4);
  for (size_t i = 0; i < 4; ++i)
    CHECK(inplace[i] == x[i], "filter supports in-place processing");
}

static void abi_guards_and_stream_state() {
  const double nan = std::numeric_limits<double>::quiet_NaN();
  const double inf = std::numeric_limits<double>::infinity();
  CHECK(audio_io_resampler_create(nan, 16000) == nullptr, "ABI rejects NaN rate");
  CHECK(audio_io_resampler_create(48000, inf) == nullptr, "ABI rejects infinite rate");
  CHECK(audio_io_resampler_create(-1, 16000) == nullptr, "ABI rejects negative rate");
  CHECK(audio_io_low_pass_create(48000, nan) == nullptr, "ABI rejects NaN cutoff");
  CHECK(audio_io_low_pass_create(0, 7200) == nullptr, "ABI rejects zero rate");
  CHECK(audio_io_spectral_create(0) == nullptr, "ABI rejects zero spectral rate");
  CHECK(audio_io_resampler_output_capacity(nullptr, 7) == 0, "null capacity handle");
  audio_io_resampler_destroy(nullptr);
  audio_io_low_pass_destroy(nullptr);
  audio_io_spectral_destroy(nullptr);

  void* r = audio_io_resampler_create(48000, 16000);
  const double first = 0.25, second = 0.75;
  double output[4] = {};
  CHECK(audio_io_resampler_process(r, &first, 1, nullptr, 0) == 0,
        "ABI ingests a block with no output capacity");
  CHECK(audio_io_resampler_process(r, &second, 1, output, 4) == 1 && output[0] == first,
        "ABI keeps one-sample history");
  audio_io_resampler_reset(r);
  CHECK(audio_io_resampler_output_capacity(r, 1) == 0, "ABI reset clears history");
  audio_io_resampler_destroy(r);
}

static void low_pass_extreme_finite_parameters() {
  const double smallest = std::numeric_limits<double>::denorm_min();
  const double largest = std::numeric_limits<double>::max();
  for (double rate : {smallest, 1e-300, 48000.0, largest}) {
    for (double cutoff : {smallest, 1.0, 7200.0, largest}) {
      void* handle = audio_io_low_pass_create(rate, cutoff);
      CHECK(handle != nullptr, "positive finite filter parameters are accepted");
      double input[4] = {1.0, -1.0, 0.5, 0.0}, output[4] = {};
      audio_io_low_pass_process(handle, input, output, 4);
      for (double value : output)
        CHECK(std::isfinite(value) && value >= -1.0 && value <= 1.0,
              "all positive finite filter parameters produce bounded finite output");
      audio_io_low_pass_destroy(handle);
    }
  }
  // Preserve the conventional one-pole coefficient at actual device rates.
  constexpr double pi = 3.14159265358979323846;
  for (double rate : {16000.0, 24000.0, 44100.0, 48000.0}) {
    const double dt = 1.0 / rate, rc = 1.0 / (2.0 * pi * 7200.0);
    const double expected = dt / (rc + dt);
    OnePoleLowPass filter(rate, 7200.0);
    double input = 1.0, output = 0.0;
    filter.process(&input, &output, 1);
    CHECK(std::fabs(output - expected) <= 2e-16,
          "stable coefficient preserves ordinary audio-rate response");
  }
}

int main() {
  for (const auto& rates : {std::pair<double, double>{48000, 16000},
       {48000, 24000}, {16000, 48000}, {24000, 48000}, {44100, 16000},
       {44100, 24000}, {48000, 44100}, {24000, 44100}, {16000, 16000}})
    chunk_invariance(rates.first, rates.second);
  tiny_chunks_and_capacity();
  low_pass_is_stateful();
  abi_guards_and_stream_state();
  low_pass_extreme_finite_parameters();
  if (failures == 0) {
    std::printf("All realtime DSP tests passed.\n");
    return 0;
  }
  std::printf("%d failure(s).\n", failures);
  return 1;
}
