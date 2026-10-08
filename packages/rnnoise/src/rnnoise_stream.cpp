#include "rnnoise_stream.h"

#include <algorithm>
#include <cmath>
#include <memory>
#include <stdexcept>
#include <vector>

// Shared converter, compiled into this library alongside the existing RNNoise
// inference code. No audio_io library dependency or Dart frame callback needed.
#include "../../audio_io/src/realtime_dsp.h"

namespace {
class SampleFifo {
 public:
  SampleFifo() : storage_(4096) {}

  size_t size() const { return length_; }
  double operator[](size_t index) const {
    return storage_[(head_ + index) & (storage_.size() - 1)];
  }
  void append(const double* values, size_t count) {
    reserve(length_ + count);
    for (size_t i = 0; i < count; ++i) {
      storage_[(head_ + length_ + i) & (storage_.size() - 1)] = values[i];
    }
    length_ += count;
  }
  void discard(size_t count) {
    head_ = (head_ + count) & (storage_.size() - 1);
    length_ -= count;
  }
  void clear() { head_ = length_ = 0; }

 private:
  void reserve(size_t required) {
    if (required <= storage_.size()) return;
    size_t capacity = storage_.size();
    while (capacity < required) capacity *= 2;
    std::vector<double> next(capacity);
    for (size_t i = 0; i < length_; ++i) next[i] = (*this)[i];
    storage_.swap(next);
    head_ = 0;
  }
  std::vector<double> storage_;
  size_t head_ = 0;
  size_t length_ = 0;
};

struct StateDestroy {
  void operator()(DenoiseState* state) const { rnnoise_destroy(state); }
};

class RnnoiseStream {
 public:
  explicit RnnoiseStream(int sample_rate)
      : up_(sample_rate, 48000), down_(48000, sample_rate),
        state_(rnnoise_create(nullptr)), frame_size_(rnnoise_get_frame_size()),
        frame_in_(frame_size_), frame_out_(frame_size_), scaled_(frame_size_) {
    if (!state_) throw std::bad_alloc();
  }

  void process(const double* input, double* output, size_t count,
               double strength) {
    if (strength <= 0.0) {
      if (rnn_input_.size() || wet_output_.size() || dry_input_.size()) clear();
      if (count > 0) std::copy(input, input + count, output);
      return;
    }
    if (count == 0) return;
    dry_input_.append(input, count);
    // A capacity of one also lets the converter retain the very first sample
    // when there is no pair available for interpolation yet.
    up_output_.resize(std::max<size_t>(1, up_.outputCapacity(count)));
    const size_t up_count = up_.process(input, count, up_output_.data(),
                                        up_output_.size());
    rnn_input_.append(up_output_.data(), up_count);

    while (rnn_input_.size() >= frame_size_) {
      for (size_t i = 0; i < frame_size_; ++i) {
        frame_in_[i] = static_cast<float>(rnn_input_[i] * 32768.0);
      }
      rnn_input_.discard(frame_size_);
      rnnoise_process_frame(state_.get(), frame_out_.data(), frame_in_.data());
      for (size_t i = 0; i < frame_size_; ++i) {
        scaled_[i] = static_cast<double>(frame_out_[i]) / 32768.0;
      }
      down_output_.resize(std::max<size_t>(1, down_.outputCapacity(frame_size_)));
      const size_t down_count = down_.process(scaled_.data(), frame_size_,
                                              down_output_.data(),
                                              down_output_.size());
      wet_output_.append(down_output_.data(), down_count);
    }

    const size_t take = std::min(wet_output_.size(), count);
    const size_t offset = count - take;
    for (size_t i = 0; i < offset; ++i) output[i] = dry_input_[i];
    for (size_t i = 0; i < take; ++i) {
      const double dry = dry_input_[offset + i];
      output[offset + i] = dry + (wet_output_[i] - dry) * strength;
    }
    dry_input_.discard(count);
    wet_output_.discard(take);
  }

  void reset() {
    std::unique_ptr<DenoiseState, StateDestroy> fresh(rnnoise_create(nullptr));
    if (!fresh) throw std::bad_alloc();
    state_.swap(fresh);
    clear();
  }

 private:
  void clear() {
    up_.reset();
    down_.reset();
    rnn_input_.clear();
    wet_output_.clear();
    dry_input_.clear();
  }

  RealtimeResampler up_;
  RealtimeResampler down_;
  std::unique_ptr<DenoiseState, StateDestroy> state_;
  const size_t frame_size_;
  SampleFifo rnn_input_;
  SampleFifo wet_output_;
  SampleFifo dry_input_;
  std::vector<float> frame_in_;
  std::vector<float> frame_out_;
  std::vector<double> scaled_;
  std::vector<double> up_output_;
  std::vector<double> down_output_;
};
}  // namespace

extern "C" {
void* rnnoise_stream_create(int sample_rate) {
  if (sample_rate <= 0) return nullptr;
  try {
    return new RnnoiseStream(sample_rate);
  } catch (...) {
    return nullptr;
  }
}

void rnnoise_stream_destroy(void* stream) {
  delete static_cast<RnnoiseStream*>(stream);
}

int rnnoise_stream_process(void* stream, const double* input, double* output,
                          int count, double strength) {
  if (!stream || count < 0 || !std::isfinite(strength) ||
      (count > 0 && (!input || !output))) return -1;
  try {
    static_cast<RnnoiseStream*>(stream)->process(input, output, count, strength);
    return count;
  } catch (...) {
    return -1;
  }
}

int rnnoise_stream_reset(void* stream) {
  if (!stream) return -1;
  try {
    static_cast<RnnoiseStream*>(stream)->reset();
    return 0;
  } catch (...) {
    return -1;
  }
}
}
