#pragma once
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <vector>

// Native streaming spectral suppressor matching Tark's Dart STFT contract.
// The object is stream-owned and never shared between capture sessions.
class SpectralSuppressor {
 public:
  explicit SpectralSuppressor(int sample_rate)
      : win_(windowFor(sample_rate)), hop_(win_ / 2), bins_(win_ / 2),
        window_(win_), re_(win_), im_(win_), ola_(win_, 0.0),
        bit_rev_(win_), fft_cos_(bins_), fft_sin_(bins_),
        p_sm_(bins_ + 1, 0.0), noise_(bins_ + 1, 0.0),
        gain_(bins_ + 1, 0.0), gain_sm_(bins_ + 1, 0.0),
        input_(win_), output_(hop_) {
    constexpr double pi = 3.14159265358979323846;
    for (int i = 0; i < win_; ++i)
      window_[i] = std::sqrt(0.5 * (1.0 - std::cos(2.0 * pi * i / win_)));
    for (int i = 1, j = 0; i < win_; ++i) {
      int bit = win_ >> 1;
      for (; j & bit; bit >>= 1) j ^= bit;
      j ^= bit;
      bit_rev_[i] = j;
    }
    for (int k = 0; k < bins_; ++k) {
      const double angle = -2.0 * pi * k / win_;
      fft_cos_[k] = std::cos(angle);
      fft_sin_[k] = std::sin(angle);
    }
  }

  void setStrength(double value) {
    strength_ = std::max(0.0, std::min(1.0, value));
  }

  void reset() {
    input_head_ = input_size_ = output_head_ = output_size_ = 0;
    std::fill(ola_.begin(), ola_.end(), 0.0);
    std::fill(p_sm_.begin(), p_sm_.end(), 0.0);
    std::fill(noise_.begin(), noise_.end(), 0.0);
    std::fill(gain_.begin(), gain_.end(), 0.0);
    std::fill(gain_sm_.begin(), gain_sm_.end(), 0.0);
    hops_ = 0;
  }

  void process(const double* samples, size_t count, double* out) {
    if (strength_ <= 0.0) {
      if (input_size_ != 0 || output_size_ != 0) reset();
      if (count != 0 && samples && out) std::copy(samples, samples + count, out);
      return;
    }
    if (count == 0 || !samples || !out) return;
    // FFI uses distinct buffers. Keep in-place calls valid too, reusing this
    // optional scratch after its first growth rather than allocating per hop.
    if (samples == out) {
      alias_scratch_.assign(samples, samples + count);
      samples = alias_scratch_.data();
    }
    const size_t total = input_size_ + count;
    const size_t hops = total < static_cast<size_t>(win_)
        ? 0 : 1 + (total - win_) / hop_;
    const size_t take = std::min(output_size_ + hops * hop_, count);
    const size_t offset = count - take;
    std::fill(out, out + offset, 0.0);
    size_t written = offset;
    while (output_size_ != 0 && written < count) {
      out[written++] = output_[output_head_];
      output_head_ = (output_head_ + 1) & static_cast<size_t>(hop_ - 1);
      --output_size_;
    }
    // The input ring holds one window; output left after a call is less than
    // one hop. Neither ring grows, even for a very large callback block.
    for (size_t at = 0; at < count;) {
      const size_t add = std::min(static_cast<size_t>(win_) - input_size_,
                                  count - at);
      for (size_t i = 0; i < add; ++i)
        input_[(input_head_ + input_size_ + i) & static_cast<size_t>(win_ - 1)] = samples[at + i];
      input_size_ += add;
      at += add;
      if (input_size_ == static_cast<size_t>(win_)) {
        processHop();
        for (int i = 0; i < hop_; ++i) {
          if (written < count) out[written++] = ola_[i];
          else {
            output_[(output_head_ + output_size_) & static_cast<size_t>(hop_ - 1)] = ola_[i];
            ++output_size_;
          }
        }
        std::move(ola_.begin() + hop_, ola_.end(), ola_.begin());
        std::fill(ola_.end() - hop_, ola_.end(), 0.0);
      }
    }
  }

 private:
  static int windowFor(int rate) {
    const auto target = static_cast<long long>(rate) * 16 / 1000;
    // Even a sub-audio sample rate must have a nonzero overlap hop.
    int p = 2; while (p < target) p <<= 1; return p;
  }

  void fft(bool inverse) {
    const int n = win_;
    for (int i = 0; i < n; ++i) {
      const int j = bit_rev_[i];
      if (i < j) { std::swap(re_[i], re_[j]); std::swap(im_[i], im_[j]); }
    }
    for (int len = 2; len <= n; len <<= 1) {
      const int step = n / len;
      for (int i = 0; i < n; i += len) {
        for (int j = 0; j < len / 2; ++j) {
          const double wr = fft_cos_[j * step];
          const double wi = inverse ? -fft_sin_[j * step] : fft_sin_[j * step];
          const int a = i + j, b = a + len / 2;
          const double vr = re_[b] * wr - im_[b] * wi;
          const double vi = re_[b] * wi + im_[b] * wr;
          const double ur = re_[a], ui = im_[a];
          re_[a] = ur + vr; im_[a] = ui + vi;
          re_[b] = ur - vr; im_[b] = ui - vi;
        }
      }
    }
    if (inverse) {
      const double scale = 1.0 / n;
      for (int i = 0; i < n; ++i) { re_[i] *= scale; im_[i] *= scale; }
    }
  }

  void processHop() {
    for (int i = 0; i < win_; ++i) {
      re_[i] = input_[(input_head_ + i) & static_cast<size_t>(win_ - 1)] * window_[i]; im_[i] = 0.0;
    }
    input_head_ = (input_head_ + hop_) & static_cast<size_t>(win_ - 1);
    input_size_ -= hop_;
    fft(false);
    const double beta = 2.0 + 2.0 * strength_;
    const double g_min = std::pow(10.0, -30.0 * strength_ / 20.0);
    for (int k = 0; k <= bins_; ++k) {
      const double p = re_[k] * re_[k] + im_[k] * im_[k];
      const double ps = hops_ == 0 ? p : 0.7 * p_sm_[k] + 0.3 * p;
      p_sm_[k] = ps;
      double n = noise_[k];
      if (hops_ < 30) n = hops_ == 0 ? ps : 0.9 * n + 0.1 * ps;
      else if (ps < n) n += 0.15 * (ps - n);
      else n = std::min(n * 1.012, ps);
      noise_[k] = n;
      double g = 1.0 - beta * n / (ps + 1e-12);
      g = std::max(g_min, std::min(1.0, g));
      const double prev = gain_[k];
      gain_[k] = prev + (g > prev ? 0.5 : 0.3) * (g - prev);
    }
    gain_sm_[0] = gain_[0]; gain_sm_[bins_] = gain_[bins_];
    for (int k = 1; k < bins_; ++k)
      gain_sm_[k] = 0.25 * gain_[k-1] + 0.5 * gain_[k] + 0.25 * gain_[k+1];
    for (int k = 0; k <= bins_; ++k) {
      const double g = gain_sm_[k];
      re_[k] *= g; im_[k] *= g;
      if (k > 0 && k < bins_) { re_[win_-k] *= g; im_[win_-k] *= g; }
    }
    fft(true);
    for (int i = 0; i < win_; ++i) ola_[i] += re_[i] * window_[i];
    if (hops_ < 30) ++hops_;
  }

  int win_, hop_, bins_, hops_ = 0;
  double strength_ = 0.0;
  std::vector<double> window_, re_, im_, ola_;
  std::vector<int> bit_rev_;
  std::vector<double> fft_cos_, fft_sin_, p_sm_, noise_, gain_, gain_sm_;
  std::vector<double> input_, output_, alias_scratch_;
  size_t input_head_ = 0, input_size_ = 0, output_head_ = 0, output_size_ = 0;
};
