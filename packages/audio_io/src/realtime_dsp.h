#pragma once
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <vector>

// Stateful realtime DSP primitives. They own their history so arbitrary device
// callback chunking is equivalent to one contiguous stream. No allocation is
// performed inside the per-sample loops; output/history storage is reused.
class RealtimeResampler {
 public:
  RealtimeResampler(double in_rate, double out_rate)
      : ratio_(in_rate / out_rate), phase_(0.0) {}

  size_t process(const double* input, size_t count, double* output,
                 size_t capacity) {
    if (!input || !output || count == 0 || capacity == 0) return 0;
    scratch_.resize(history_.size() + count);
    std::copy(history_.begin(), history_.end(), scratch_.begin());
    std::copy(input, input + count, scratch_.begin() + history_.size());

    size_t n = 0;
    double pos = phase_;
    while (n < capacity) {
      const size_t i0 = static_cast<size_t>(std::floor(pos));
      const size_t i1 = i0 + 1;
      if (i1 >= scratch_.size()) break;
      const double frac = pos - static_cast<double>(i0);
      output[n++] = scratch_[i0] + (scratch_[i1] - scratch_[i0]) * frac;
      pos += ratio_;
    }

    const size_t max_consumed = scratch_.empty() ? 0 : scratch_.size() - 1;
    const size_t consumed = std::min(static_cast<size_t>(std::floor(pos)),
                                     max_consumed);
    history_.assign(scratch_.begin() + consumed, scratch_.end());
    phase_ = pos - static_cast<double>(consumed);
    return n;
  }

  size_t outputCapacity(size_t input_count) const {
    const size_t total = history_.size() + input_count;
    if (total < 2) return 0;
    return static_cast<size_t>(
               std::ceil((static_cast<double>(total) - phase_) / ratio_)) +
           1;
  }

  void reset() {
    phase_ = 0.0;
    history_.clear();
    scratch_.clear();
  }

 private:
  double ratio_;
  double phase_;
  std::vector<double> history_;
  std::vector<double> scratch_;
};

class OnePoleLowPass {
 public:
  OnePoleLowPass(double sample_rate, double cutoff_hz)
      : alpha_(computeAlpha(sample_rate, cutoff_hz)), y_(0.0) {}

  void process(const double* input, double* output, size_t count) {
    if (!input || !output) return;
    for (size_t i = 0; i < count; ++i) {
      y_ += alpha_ * (input[i] - y_);
      output[i] = y_;
    }
  }

  void reset() { y_ = 0.0; }

 private:
  static double computeAlpha(double sample_rate, double cutoff_hz) {
    constexpr double kPi = 3.14159265358979323846;
    const double rc = 1.0 / (2.0 * kPi * cutoff_hz);
    const double dt = 1.0 / sample_rate;
    return dt / (rc + dt);
  }

  double alpha_;
  double y_;
};
