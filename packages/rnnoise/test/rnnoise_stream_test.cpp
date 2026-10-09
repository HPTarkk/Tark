#include "rnnoise_stream.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <deque>
#include <random>
#include <vector>

namespace {
// Independent transcription of the previous Dart orchestration. This uses
// linear histories/deques and deliberately does not reuse native DSP classes.
class ReferenceResampler {
 public:
  ReferenceResampler(double input_rate, double output_rate)
      : ratio_(input_rate / output_rate) {}
  std::vector<double> process(const std::vector<double>& input) {
    if (input.empty()) return {};
    std::vector<double> samples(history_);
    samples.insert(samples.end(), input.begin(), input.end());
    std::vector<double> output;
    double position = phase_;
    while (true) {
      const size_t low = static_cast<size_t>(std::floor(position));
      if (low + 1 >= samples.size()) break;
      output.push_back(samples[low] + (samples[low + 1] - samples[low]) *
                                     (position - low));
      position += ratio_;
    }
    const size_t consumed = std::min(static_cast<size_t>(std::floor(position)),
                                     samples.size() - 1);
    history_.assign(samples.begin() + consumed, samples.end());
    phase_ = position - consumed;
    return output;
  }
  void reset() { history_.clear(); phase_ = 0.0; }
 private:
  double ratio_;
  double phase_ = 0;
  std::vector<double> history_;
};

class ReferenceStream {
 public:
  explicit ReferenceStream(int rate) : up_(rate, 48000), down_(48000, rate),
                                       state_(rnnoise_create(nullptr)) {}
  ~ReferenceStream() { rnnoise_destroy(state_); }
  std::vector<double> process(const std::vector<double>& input, double strength) {
    if (strength <= 0) {
      if (!rnn_.empty() || !wet_.empty() || !dry_.empty()) clear();
      return input;
    }
    if (input.empty()) return {};
    dry_.insert(dry_.end(), input.begin(), input.end());
    const auto upsampled = up_.process(input);
    rnn_.insert(rnn_.end(), upsampled.begin(), upsampled.end());
    const size_t frame_size = rnnoise_get_frame_size();
    while (rnn_.size() >= frame_size) {
      std::vector<float> frame(frame_size), denoised(frame_size);
      std::vector<double> dry(frame_size);
      for (size_t i = 0; i < frame_size; ++i) {
        dry[i] = rnn_.front();
        frame[i] = static_cast<float>(dry[i] * 32768.0);
        rnn_.pop_front();
      }
      rnnoise_process_frame(state_, denoised.data(), frame.data());
      // RNNoise answers with the previous frame, so that frame's dry share
      // is mixed in here, before the shared downsampler.
      if (prev_.size() != frame_size) prev_.assign(frame_size, 0.0);
      std::vector<double> scaled(frame_size);
      for (size_t i = 0; i < frame_size; ++i) {
        const double wet = denoised[i] / 32768.0;
        scaled[i] = prev_[i] + (wet - prev_[i]) * std::min(strength, 1.0);
        prev_[i] = dry[i];
      }
      const auto downsampled = down_.process(scaled);
      wet_.insert(wet_.end(), downsampled.begin(), downsampled.end());
    }
    const size_t take = std::min(wet_.size(), input.size());
    const size_t offset = input.size() - take;
    std::vector<double> output(input.size());
    for (size_t i = 0; i < offset; ++i) output[i] = dry_[i];
    for (size_t i = 0; i < take; ++i) output[offset + i] = wet_[i];
    for (size_t i = 0; i < input.size(); ++i) dry_.pop_front();
    for (size_t i = 0; i < take; ++i) wet_.pop_front();
    return output;
  }
  void reset() {
    clear();
    rnnoise_destroy(state_);
    state_ = rnnoise_create(nullptr);
  }
 private:
  void clear() {
    up_.reset(); down_.reset(); rnn_.clear(); wet_.clear(); dry_.clear();
    prev_.assign(prev_.size(), 0.0);
  }
  ReferenceResampler up_;
  ReferenceResampler down_;
  DenoiseState* state_;
  std::deque<double> rnn_, wet_, dry_;
  std::vector<double> prev_;
};

void parity(int rate, double strength) {
  void* stream = rnnoise_stream_create(rate);
  assert(stream != nullptr);
  ReferenceStream reference(rate);
  std::mt19937 random(324);
  std::uniform_real_distribution<double> noise(-0.06, 0.06);
  std::vector<double> source(rate * 3);
  for (size_t i = 0; i < source.size(); ++i) {
    source[i] = i < 300 ? 0.0 :
        0.2 * std::sin(6.283185307179586 * 190.0 * i / rate) + noise(random);
  }
  source[300] = 0.9;
  size_t start = 0, blocks = 0;
  while (start < source.size()) {
    const size_t count = std::min<size_t>(1 + random() % 513, source.size() - start);
    std::vector<double> input(source.begin() + start, source.begin() + start + count);
    std::vector<double> output(count);
    // Vary strength and bypass midstream with partial RNNoise frames buffered.
    const double mix = blocks % 29 == 17 ? 0.0 : strength;
    const auto expected = reference.process(input, mix);
    assert(rnnoise_stream_process(stream, input.data(), output.data(),
                                  static_cast<int>(count), mix) == count);
    for (size_t i = 0; i < count; ++i) {
      assert(std::isfinite(output[i]));
      assert(std::abs(output[i] - expected[i]) < 2e-9);
    }
    if (blocks % 37 == 13) {
      assert(rnnoise_stream_process(stream, nullptr, nullptr, 0, mix) == 0);
    }
    if (blocks == 47) {
      reference.reset();
      assert(rnnoise_stream_reset(stream) == 0);
    }
    start += count;
    ++blocks;
  }
  rnnoise_stream_destroy(stream);
}
// At partial strength the dry share must line up with the denoised share.
// RNNoise all but removes white noise, so with strength 0.5 the output is
// about half the dry signal: it has to arrive at the pipeline's own delay
// (where the denoised share is), never undelayed. An undelayed copy plus a
// delayed one is a comb filter, heard as a hollow, phasey voice.
void dryAndWetAreAligned(int rate) {
  std::mt19937 random(7);
  std::normal_distribution<double> noise(0.0, 0.1);
  std::vector<double> x(rate * 3);
  for (auto& v : x) v = noise(random);
  auto run = [&](double strength) {
    void* stream = rnnoise_stream_create(rate);
    std::vector<double> y(x.size());
    for (size_t i = 0; i < x.size(); i += 160) {
      const size_t n = std::min<size_t>(160, x.size() - i);
      assert(rnnoise_stream_process(stream, &x[i], &y[i], static_cast<int>(n), strength) == static_cast<int>(n));
    }
    rnnoise_stream_destroy(stream);
    return y;
  };
  auto correlation = [&](const std::vector<double>& y, size_t lag) {
    double xy = 0, xx = 0;
    for (size_t n = static_cast<size_t>(rate); n < x.size(); ++n) {
      xy += y[n] * x[n - lag];
      xx += x[n - lag] * x[n - lag];
    }
    return xy / xx;
  };
  const auto half = run(0.5);
  size_t best = 0;
  double bestValue = 0;
  for (size_t lag = 0; lag <= 1000; ++lag) {
    const double c = std::abs(correlation(half, lag));
    if (c > bestValue) { bestValue = c; best = lag; }
  }
  assert(std::abs(correlation(half, 0)) < 0.05);  // no undelayed copy
  assert(bestValue > 0.4 && bestValue < 0.6);     // one dry copy, at half level
  // ...at exactly the delay the fully denoised path has.
  const auto full = run(1.0);
  size_t fullBest = 0;
  double fullValue = 0;
  for (size_t lag = 0; lag <= 1000; ++lag) {
    const double c = std::abs(correlation(full, lag));
    if (c > fullValue) { fullValue = c; fullBest = lag; }
  }
  assert(best == fullBest);
}
}  // namespace

int main() {
  assert(rnnoise_stream_create(0) == nullptr);
  assert(rnnoise_stream_create(-16000) == nullptr);
  assert(rnnoise_stream_reset(nullptr) == -1);
  assert(rnnoise_stream_process(nullptr, nullptr, nullptr, 0, 1.0) == -1);
  rnnoise_stream_destroy(nullptr);
  for (int rate : {16000, 24000}) {
    for (double strength : {0.0, 0.25, 0.5, 1.0, 1.5}) parity(rate, strength);
    dryAndWetAreAligned(rate);
    for (int i = 0; i < 100; ++i) {
      void* stream = rnnoise_stream_create(rate);
      double input = 0.5, output = 0;
      assert(rnnoise_stream_process(stream, &input, &output, 1, 1.0) == 1);
      assert(output == input);  // one sample is dry during startup
      assert(rnnoise_stream_process(stream, &input, &output, -1, 1.0) == -1);
      assert(rnnoise_stream_process(stream, nullptr, &output, 1, 1.0) == -1);
      assert(rnnoise_stream_reset(stream) == 0);
      rnnoise_stream_destroy(stream);
    }
  }
  std::puts("RNNoise stream native/reference parity and lifecycle passed");
}
