#include "../src/realtime_dsp.h"

#include <cmath>
#include <cstdio>
#include <vector>

static int failures = 0;
#define CHECK(c, m) do { if (!(c)) { std::printf("FAIL: %s\n", m); ++failures; } } while (0)

static std::vector<double> resample(RealtimeResampler& r,
                                    const std::vector<double>& input) {
  std::vector<double> out(r.outputCapacity(input.size()));
  const size_t n = r.process(input.data(), input.size(), out.data(), out.size());
  out.resize(n);
  return out;
}

static void chunk_invariance() {
  std::vector<double> input(4800);
  for (size_t i = 0; i < input.size(); ++i)
    input[i] = std::sin(2.0 * 3.14159265358979323846 * 440.0 * i / 48000.0);

  RealtimeResampler whole(48000, 16000);
  const auto expected = resample(whole, input);

  RealtimeResampler chunked(48000, 16000);
  std::vector<double> actual;
  for (size_t at = 0; at < input.size();) {
    const size_t n = std::min<size_t>(137, input.size() - at);
    std::vector<double> part(input.begin() + at, input.begin() + at + n);
    const auto got = resample(chunked, part);
    actual.insert(actual.end(), got.begin(), got.end());
    at += n;
  }
  CHECK(actual.size() == expected.size(), "chunking preserves output length");
  const size_t n = std::min(actual.size(), expected.size());
  for (size_t i = 0; i < n; ++i)
    CHECK(std::fabs(actual[i] - expected[i]) < 1e-12,
          "chunking preserves sample values");
}

static void low_pass_is_stateful() {
  OnePoleLowPass f(48000, 7200);
  double a[4] = {1, 1, 1, 1}, x[4] = {}, b[4] = {}, y[4] = {};
  f.process(a, x, 4);
  f.process(b, y, 4);
  CHECK(x[0] > 0 && x[0] < 1, "filter smooths onset");
  CHECK(y[0] > 0 && y[0] < x[3], "filter carries state across chunks");
}

int main() {
  chunk_invariance();
  low_pass_is_stateful();
  if (failures == 0) {
    std::printf("All realtime DSP tests passed.\n");
    return 0;
  }
  std::printf("%d failure(s).\n", failures);
  return 1;
}
