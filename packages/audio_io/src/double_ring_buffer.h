#ifndef AUDIO_IO_DOUBLE_RING_BUFFER_H
#define AUDIO_IO_DOUBLE_RING_BUFFER_H

#include <atomic>
#include <algorithm>
#include <cassert>
#include <cstring>
#include <vector>

/// Lock-free single-producer / single-consumer ring buffer.
///
/// Each instance has exactly one producer thread and one consumer thread:
/// the input ring is written by miniaudio's realtime audio callback and read
/// by the Dart isolate; the output ring is the reverse. That is what makes
/// the lock-free discipline below valid — only the producer ever advances
/// `write_`, only the consumer ever advances `read_`, so neither side needs
/// to exclude the other.
///
/// This must never lock. The audio callback runs on a realtime-priority
/// thread, and a mutex shared with a normal-priority Dart isolate is a
/// priority-inversion trap: if the isolate is descheduled while holding the
/// lock, the audio thread blocks and misses its deadline, which the user
/// hears as a dropout. The same reasoning bans allocation on that thread,
/// hence the converting read/write helpers below — they let the callback
/// move f32 device frames in and out without staging them through a
/// temporary buffer.
///
/// `write_` and `read_` are monotonic counters masked down to indices, so
/// "empty" (w == r) and "full" (w - r == capacity) stay distinguishable
/// without wasting a slot, and unsigned wraparound of the counters
/// themselves is harmless because only their difference is ever used.
class DoubleRingBuffer {
private:
    std::vector<double> buffer_;
    const size_t capacity_;
    const size_t mask_;
    std::atomic<size_t> write_;
    std::atomic<size_t> read_;

public:
    explicit DoubleRingBuffer(size_t bufferSize)
        : buffer_(bufferSize), capacity_(bufferSize), mask_(bufferSize - 1),
          write_(0), read_(0) {
        // Masking only works for power-of-two capacities.
        assert(bufferSize > 0 && (bufferSize & (bufferSize - 1)) == 0);
    }

    // ── Producer side ─────────────────────────────────────────────────────

    size_t write(const double* data, size_t count) {
        const size_t w = write_.load(std::memory_order_relaxed);
        // Acquire: pair with the consumer's release store so the slots it
        // freed are visible before we overwrite them.
        const size_t r = read_.load(std::memory_order_acquire);
        count = std::min(count, capacity_ - (w - r));
        if (count == 0) return 0;

        const size_t start = w & mask_;
        const size_t first = std::min(count, capacity_ - start);
        std::memcpy(&buffer_[start], data, first * sizeof(double));
        if (count > first) {
            std::memcpy(&buffer_[0], data + first,
                        (count - first) * sizeof(double));
        }
        // Release: publish the samples before the consumer can see the index.
        write_.store(w + count, std::memory_order_release);
        return count;
    }

    /// Converting write, so the capture callback can push its f32 frames
    /// straight into the ring without a staging buffer.
    size_t writeFromFloat(const float* data, size_t count) {
        const size_t w = write_.load(std::memory_order_relaxed);
        const size_t r = read_.load(std::memory_order_acquire);
        count = std::min(count, capacity_ - (w - r));
        if (count == 0) return 0;

        size_t pos = w & mask_;
        for (size_t i = 0; i < count; i++) {
            buffer_[pos] = (double)data[i];
            pos = (pos + 1) & mask_;
        }
        write_.store(w + count, std::memory_order_release);
        return count;
    }

    // ── Consumer side ─────────────────────────────────────────────────────

    size_t read(double* data, size_t count) {
        const size_t r = read_.load(std::memory_order_relaxed);
        const size_t w = write_.load(std::memory_order_acquire);
        count = std::min(count, w - r);
        if (count == 0) return 0;

        const size_t start = r & mask_;
        const size_t first = std::min(count, capacity_ - start);
        std::memcpy(data, &buffer_[start], first * sizeof(double));
        if (count > first) {
            std::memcpy(data + first, &buffer_[0],
                        (count - first) * sizeof(double));
        }
        read_.store(r + count, std::memory_order_release);
        return count;
    }

    /// Converting + clamping read for the playback callback. Returns the
    /// number of frames actually produced; the caller silences the rest.
    size_t readToFloatClamped(float* out, size_t count) {
        const size_t r = read_.load(std::memory_order_relaxed);
        const size_t w = write_.load(std::memory_order_acquire);
        count = std::min(count, w - r);
        if (count == 0) return 0;

        size_t pos = r & mask_;
        for (size_t i = 0; i < count; i++) {
            const double sample = buffer_[pos];
            out[i] =
                (float)(sample > 1.0 ? 1.0 : (sample < -1.0 ? -1.0 : sample));
            pos = (pos + 1) & mask_;
        }
        read_.store(r + count, std::memory_order_release);
        return count;
    }

    /// Safe from either side: each load is independently atomic, and a
    /// concurrent advance by the other thread only makes the answer stale in
    /// the conservative direction.
    size_t available_read() const {
        const size_t w = write_.load(std::memory_order_acquire);
        const size_t r = read_.load(std::memory_order_acquire);
        return w - r;
    }

    size_t available_write() const {
        return capacity_ - available_read();
    }
};

#endif  // AUDIO_IO_DOUBLE_RING_BUFFER_H
