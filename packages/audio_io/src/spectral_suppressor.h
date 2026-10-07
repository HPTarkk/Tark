#pragma once
#include <algorithm>
#include <cmath>
#include <complex>
#include <cstddef>
#include <vector>

// Native streaming spectral suppressor matching Tark's Dart STFT contract.
// The object is stream-owned and never shared between capture sessions.
class SpectralSuppressor {
 public:
  explicit SpectralSuppressor(int sample_rate)
      : win_(windowFor(sample_rate)), hop_(win_ / 2), bins_(win_ / 2),
        window_(win_), re_(win_), im_(win_), ola_(win_, 0.0),
        p_sm_(bins_ + 1, 0.0), noise_(bins_ + 1, 0.0),
        gain_(bins_ + 1, 0.0), gain_sm_(bins_ + 1, 0.0) {
    constexpr double pi = 3.14159265358979323846;
    for (int i = 0; i < win_; ++i)
      window_[i] = std::sqrt(0.5 * (1.0 - std::cos(2.0 * pi * i / win_)));
  }

  void setStrength(double value) {
    strength_ = std::max(0.0, std::min(1.0, value));
  }

  void reset() {
    input_.clear(); output_.clear();
    std::fill(ola_.begin(), ola_.end(), 0.0);
    std::fill(p_sm_.begin(), p_sm_.end(), 0.0);
    std::fill(noise_.begin(), noise_.end(), 0.0);
    std::fill(gain_.begin(), gain_.end(), 0.0);
    std::fill(gain_sm_.begin(), gain_sm_.end(), 0.0);
    hops_ = 0;
  }

  void process(const double* samples, size_t count, double* out) {
    if (!samples || !out) return;
    if (strength_ <= 0.0) {
      if (!input_.empty() || !output_.empty()) reset();
      std::copy(samples, samples + count, out);
      return;
    }
    input_.insert(input_.end(), samples, samples + count);
    while (input_.size() >= static_cast<size_t>(win_)) processHop();

    const size_t take = std::min(output_.size(), count);
    const size_t offset = count - take;
    std::fill(out, out + offset, 0.0);
    std::copy(output_.begin(), output_.begin() + take, out + offset);
    output_.erase(output_.begin(), output_.begin() + take);
  }

 private:
  static int windowFor(int rate) {
    const int target = rate * 16 / 1000;
    int p = 1; while (p < target) p <<= 1; return p;
  }

  void fft(bool inverse) {
    const int n = win_;
    for (int i = 1, j = 0; i < n; ++i) {
      int bit = n >> 1;
      for (; j & bit; bit >>= 1) j ^= bit;
      j ^= bit;
      if (i < j) { std::swap(re_[i], re_[j]); std::swap(im_[i], im_[j]); }
    }
    constexpr double pi = 3.14159265358979323846;
    for (int len = 2; len <= n; len <<= 1) {
      const double angle = (inverse ? 2.0 : -2.0) * pi / len;
      const double wlen_r = std::cos(angle), wlen_i = std::sin(angle);
      for (int i = 0; i < n; i += len) {
        double wr = 1.0, wi = 0.0;
        for (int j = 0; j < len / 2; ++j) {
          const int a = i + j, b = a + len / 2;
          const double vr = re_[b] * wr - im_[b] * wi;
          const double vi = re_[b] * wi + im_[b] * wr;
          const double ur = re_[a], ui = im_[a];
          re_[a] = ur + vr; im_[a] = ui + vi;
          re_[b] = ur - vr; im_[b] = ui - vi;
          const double next_wr = wr * wlen_r - wi * wlen_i;
          wi = wr * wlen_i + wi * wlen_r; wr = next_wr;
        }
      }
    }
    if (inverse) for (int i = 0; i < n; ++i) { re_[i] /= n; im_[i] /= n; }
  }

  void processHop() {
    for (int i = 0; i < win_; ++i) {
      re_[i] = input_[i] * window_[i]; im_[i] = 0.0;
    }
    input_.erase(input_.begin(), input_.begin() + hop_);
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
    output_.insert(output_.end(), ola_.begin(), ola_.begin() + hop_);
    std::move(ola_.begin() + hop_, ola_.end(), ola_.begin());
    std::fill(ola_.end() - hop_, ola_.end(), 0.0);
    ++hops_;
  }

  int win_, hop_, bins_, hops_ = 0;
  double strength_ = 0.0;
  std::vector<double> window_, re_, im_, ola_, p_sm_, noise_, gain_, gain_sm_;
  std::vector<double> input_, output_;
};
