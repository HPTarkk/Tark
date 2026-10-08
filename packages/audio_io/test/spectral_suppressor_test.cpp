#include "../src/spectral_suppressor.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <new>
#include <vector>

static int failures = 0;
static bool count_allocations = false;
static size_t allocations = 0;
#define CHECK(c, m) do { if (!(c)) { std::printf("FAIL: %s\n", m); ++failures; } } while (0)

void* operator new(size_t size) {
  if (count_allocations) ++allocations;
  if (void* p = std::malloc(size == 0 ? 1 : size)) return p;
  throw std::bad_alloc();
}
void* operator new[](size_t size) { return ::operator new(size); }
void operator delete(void* p) noexcept { std::free(p); }
void operator delete[](void* p) noexcept { std::free(p); }
void operator delete(void* p, size_t) noexcept { std::free(p); }
void operator delete[](void* p, size_t) noexcept { std::free(p); }

static double rms(const std::vector<double>& samples) {
  double sum = 0;
  for (double v : samples) sum += v * v;
  return std::sqrt(sum / samples.size());
}

static void stream_contract(int rate, double strength) {
  SpectralSuppressor s(rate), fresh(rate), inplace(rate);
  s.setStrength(strength);
  fresh.setStrength(strength);
  inplace.setStrength(strength);
  std::vector<double> input(65536), wet(input.size()), cold(input.size());
  for (size_t i = 0; i < input.size(); ++i)
    input[i] = 0.15 * std::sin(2.0 * 3.14159265358979323846 * 1000.0 * i / rate);
  for (size_t count : {size_t{1}, size_t{7}, size_t{63}, size_t{127}, size_t{128},
                       size_t{257}, size_t{320}, size_t{4096}, size_t{65536}}) {
    std::fill(wet.begin(), wet.end(), -9000.0);
    s.process(input.data(), count, wet.data());
    bool finite = true;
    for (size_t i = 0; i < count; ++i) finite &= std::isfinite(wet[i]);
    CHECK(finite, "all emitted samples are finite");
    CHECK(count == wet.size() || wet[count] == -9000.0,
          "spectral output does not write beyond input length");
    if (strength == 0.0)
      CHECK(std::equal(wet.begin(), wet.begin() + count, input.begin()),
            "strength zero is bit-exact bypass");
  }
  s.reset();
  s.process(input.data(), input.size(), wet.data());
  fresh.process(input.data(), input.size(), cold.data());
  CHECK(wet == cold, "reset removes the previous noise profile and FIFO state");
  auto alias = input;
  inplace.process(alias.data(), alias.size(), alias.data());
  CHECK(alias == cold, "spectral processing supports in-place input");

  s.setStrength(0.0);
  s.process(input.data(), 7, wet.data());
  s.setStrength(strength);
  fresh.reset();
  s.process(input.data(), 320, wet.data());
  fresh.process(input.data(), 320, cold.data());
  CHECK(std::equal(wet.begin(), wet.begin() + 320, cold.begin()),
        "re-enabling after bypass starts a fresh stream");

  std::fill(input.begin(), input.end(), 0.0);
  s.reset();
  s.process(input.data(), input.size(), wet.data());
  CHECK(std::all_of(wet.begin(), wet.end(), [](double v) { return v == 0.0; }),
        "silence stays exactly silent");

  // Constructor-sized rings handle arbitrary blocks without growing. This
  // includes the first wet call, many wraps, empty blocks and reset.
  count_allocations = true;
  allocations = 0;
  s.reset();
  for (int repeat = 0; repeat < 12; ++repeat)
    for (size_t count : {size_t{0}, size_t{1}, size_t{7}, size_t{320},
                         size_t{1024}, size_t{65536}})
      s.process(input.data(), count, wet.data());
  count_allocations = false;
  CHECK(allocations == 0, "spectral streaming and reset allocate no storage");
}

static void audio_quality(int rate) {
  SpectralSuppressor s(rate);
  s.setStrength(1.0);
  const size_t count = static_cast<size_t>(rate / 50);
  std::vector<double> input(count), out(count);
  unsigned int seed = 42;
  size_t at = 0;
  double noise_in = 0, noise_out = 0, speech_in = 0, speech_out = 0;
  for (int block = 0; block < 550; ++block) {
    const bool speech = block >= 150 && ((block - 150) / 10) % 2 == 0;
    for (size_t i = 0; i < count; ++i, ++at) {
      seed = seed * 1664525u + 1013904223u;
      input[i] = (static_cast<double>(seed) / 4294967296.0 * 2.0 - 1.0) * 0.1;
      if (speech)
        input[i] += 0.3 * std::sin(2.0 * 3.14159265358979323846 * 300.0 * at / rate)
                  + 0.2 * std::sin(2.0 * 3.14159265358979323846 * 1200.0 * at / rate);
    }
    s.process(input.data(), count, out.data());
    if (block >= 100 && block < 150) { noise_in += rms(input); noise_out += rms(out); }
    if (speech) { speech_in += rms(input); speech_out += rms(out); }
  }
  const double noise_db = 20 * std::log10(noise_out / noise_in);
  const double speech_db = 20 * std::log10(speech_out / speech_in);
  std::printf("%d Hz: noise %.2f dB, speech %.2f dB\n", rate, noise_db, speech_db);
  CHECK(noise_db < -15.0, "stationary noise is strongly attenuated");
  CHECK(speech_db > -6.0, "speech bursts survive suppression");
}

int main() {
  for (int rate : {16000, 24000}) {
    for (double strength : {0.0, 0.01, 0.5, 0.8, 1.0}) stream_contract(rate, strength);
    audio_quality(rate);
  }
  if (failures == 0) std::printf("All spectral suppressor tests passed.\n");
  return failures == 0 ? 0 : 1;
}
