#ifndef AUDIO_IO_VOICE_PLAYOUT_H
#define AUDIO_IO_VOICE_PLAYOUT_H

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstring>
#include <vector>

/// Received-voice jitter queue, played straight from the audio callback.
///
/// This replaces a Dart timer that pushed 10 ms slices into the output ring.
/// That timer ran on the UI isolate, so every late tick was either a gap at
/// the speaker (a click) or, once measured and topped up, a cushion that had
/// to be guessed per phone. Here the device itself asks for exactly the
/// samples it needs, exactly when it needs them, so there is nothing to keep
/// in step and no cushion beyond the jitter target itself.
///
/// Threads: Dart is the only producer (write, writeZeros, setTarget,
/// requestReset) and the realtime audio callback is the only consumer
/// (render). Same lock-free discipline as DoubleRingBuffer: the producer
/// advances write_, the consumer advances read_. The consumer may also
/// rewrite samples between read_ and write_ during a trim; the producer never
/// touches anything below write_, so those slots are the consumer's alone.
///
/// What stays in Dart: packet order, loss, duplicates and the adaptive depth
/// (it pushes the depth here with setTarget). What lives here: when playback
/// starts, the trim and the jump back to live, and what happens when the
/// queue runs dry — the decisions that depend on when the device actually
/// pulls.
class VoicePlayout {
public:
    VoicePlayout(size_t capacity, int sampleRate)
        : buf_(capacity), mask_(capacity - 1), write_(0), read_(0) {
        configure(sampleRate);
    }

    /// Sizes the fades and thresholds for [sampleRate]. Call only while the
    /// device is stopped (the consumer reads these without synchronisation).
    void configure(int sampleRate) {
        rate_ = sampleRate > 0 ? sampleRate : 48000;
        fadeIn_ = ms(3);
        splice_ = ms(5);
        trimStep_ = ms(10);
        trimEvery_ = ms(200);
        jumpSlack_ = ms(250);
        target_.store(ms(100), std::memory_order_relaxed);
    }

    // ── Producer (Dart isolate) ───────────────────────────────────────────

    /// Appends samples. Returns how many fit; the rest are dropped (the queue
    /// only fills up if the device has stopped pulling altogether).
    size_t write(const double* data, size_t count) {
        const size_t w = write_.load(std::memory_order_relaxed);
        const size_t r = read_.load(std::memory_order_acquire);
        count = std::min(count, buf_.size() - (w - r));
        for (size_t i = 0; i < count; i++) buf_[(w + i) & mask_] = data[i];
        write_.store(w + count, std::memory_order_release);
        return count;
    }

    size_t writeZeros(size_t count) {
        const size_t w = write_.load(std::memory_order_relaxed);
        const size_t r = read_.load(std::memory_order_acquire);
        count = std::min(count, buf_.size() - (w - r));
        for (size_t i = 0; i < count; i++) buf_[(w + i) & mask_] = 0.0;
        write_.store(w + count, std::memory_order_release);
        return count;
    }

    /// Depth, in samples, the queue fills to before playing and is trimmed
    /// back toward. The device's own pull size is added on top here.
    void setTarget(int samples) {
        target_.store(samples > 0 ? samples : 0, std::memory_order_relaxed);
    }

    /// Drops everything queued at the consumer's next pull. Samples written
    /// after this call and before that pull are dropped with the rest.
    void requestReset() { resetRequested_.store(true, std::memory_order_release); }

    // ── Either side (diagnostics) ─────────────────────────────────────────

    size_t queued() const {
        return write_.load(std::memory_order_acquire) -
               read_.load(std::memory_order_acquire);
    }
    bool playing() const { return playing_.load(std::memory_order_relaxed); }
    long long underruns() const { return underruns_.load(std::memory_order_relaxed); }
    long long starvedFrames() const { return starved_.load(std::memory_order_relaxed); }
    long long playedFrames() const { return played_.load(std::memory_order_relaxed); }
    long long trims() const { return trims_.load(std::memory_order_relaxed); }
    long long jumps() const { return jumps_.load(std::memory_order_relaxed); }
    int burstFrames() const { return burst_.load(std::memory_order_relaxed); }

    // ── Consumer (realtime audio callback) ────────────────────────────────

    /// Writes [n] voice samples to [out], overwriting it: silence while
    /// filling or idle. No allocation, no locks.
    void render(float* out, size_t n) {
        if (resetRequested_.exchange(false, std::memory_order_acq_rel)) {
            read_.store(write_.load(std::memory_order_acquire),
                        std::memory_order_release);
            playing_.store(false, std::memory_order_relaxed);
            sinceTrim_ = 0;
        }

        // The device's pull size is part of the depth: a phone that takes
        // 100 ms per callback needs 100 ms queued on top of the jitter margin
        // or it runs dry mid-pull every time.
        if ((int)n > burst_.load(std::memory_order_relaxed)) {
            burst_.store((int)n, std::memory_order_relaxed);
        }
        const size_t target =
            (size_t)target_.load(std::memory_order_relaxed) +
            (size_t)burst_.load(std::memory_order_relaxed);

        size_t avail = queued();
        if (!playing_.load(std::memory_order_relaxed)) {
            if (avail == 0 || avail < target) {
                std::memset(out, 0, n * sizeof(float));
                return;
            }
            playing_.store(true, std::memory_order_relaxed);
            fadeRemaining_ = fadeIn_;
            sinceTrim_ = 0;
        }

        // Far behind live: cut straight back to target in one crossfade.
        // A lost word beats a conversation that lags for the next twenty
        // seconds. Mildly behind: walk back 10 ms every 200 ms.
        if (avail > target + jumpSlack_) {
            if (splice(avail - target)) jumps_.fetch_add(1, std::memory_order_relaxed);
            sinceTrim_ = 0;
        } else if (avail > target * 2) {
            sinceTrim_ += n;
            if (sinceTrim_ >= trimEvery_) {
                sinceTrim_ = 0;
                if (splice(std::min(avail - target, trimStep_))) {
                    trims_.fetch_add(1, std::memory_order_relaxed);
                }
            }
        } else {
            sinceTrim_ = 0;
        }
        avail = queued();

        size_t r = read_.load(std::memory_order_relaxed);
        const size_t k = std::min(n, avail);
        for (size_t i = 0; i < k; i++) {
            double s = buf_[(r + i) & mask_];
            if (fadeRemaining_ > 0) {
                s *= (double)(fadeIn_ - fadeRemaining_ + 1) / (double)fadeIn_;
                fadeRemaining_--;
            }
            out[i] = (float)(s > 1.0 ? 1.0 : (s < -1.0 ? -1.0 : s));
        }
        if (k > 0) last_ = out[k - 1];
        read_.store(r + k, std::memory_order_release);
        played_.fetch_add((long long)k, std::memory_order_relaxed);

        if (k < n) {
            // Ran dry mid-pull. Decay from the last level rather than step to
            // silence (a step is a click), then refill to target before
            // playing again.
            const size_t decay = std::min(n - k, splice_);
            for (size_t i = 0; i < decay; i++) {
                out[k + i] = (float)(last_ * (1.0 - (double)(i + 1) / (double)decay));
            }
            std::memset(out + k + decay, 0, (n - k - decay) * sizeof(float));
            last_ = 0.0;
            playing_.store(false, std::memory_order_relaxed);
            underruns_.fetch_add(1, std::memory_order_relaxed);
            starved_.fetch_add((long long)(n - k), std::memory_order_relaxed);
        }
    }

private:
    size_t ms(int millis) const { return (size_t)rate_ * (size_t)millis / 1000; }

    /// Removes about [step] samples from the head, crossfading the two sides
    /// of the cut. The overlap itself removes [splice_], so only the rest is
    /// cut outright. Returns false when the queue is too short to splice.
    bool splice(size_t step) {
        const size_t fade = splice_;
        const size_t cut = step > fade ? step - fade : 0;
        if (queued() < fade + cut + fade) return false;
        const size_t r = read_.load(std::memory_order_relaxed);
        const size_t after = r + fade + cut;
        for (size_t i = 0; i < fade; i++) {
            const double w = (double)(i + 1) / (double)(fade + 1);
            double& slot = buf_[(after + i) & mask_];
            slot = buf_[(r + i) & mask_] * (1.0 - w) + slot * w;
        }
        read_.store(r + fade + cut, std::memory_order_release);
        return true;
    }

    std::vector<double> buf_;
    const size_t mask_;
    std::atomic<size_t> write_;
    std::atomic<size_t> read_;

    int rate_ = 48000;
    size_t fadeIn_ = 0;
    size_t splice_ = 0;
    size_t trimStep_ = 0;
    size_t trimEvery_ = 0;
    size_t jumpSlack_ = 0;

    std::atomic<int> target_{0};
    std::atomic<bool> resetRequested_{false};
    std::atomic<bool> playing_{false};
    std::atomic<int> burst_{0};

    // Consumer-only state.
    size_t fadeRemaining_ = 0;
    size_t sinceTrim_ = 0;
    double last_ = 0.0;

    std::atomic<long long> underruns_{0};
    std::atomic<long long> starved_{0};
    std::atomic<long long> played_{0};
    std::atomic<long long> trims_{0};
    std::atomic<long long> jumps_{0};
};

#endif  // AUDIO_IO_VOICE_PLAYOUT_H
