// Correctness tests for the lock-free SPSC ring buffer that carries audio
// between miniaudio's realtime callback and the Dart isolate.
//
// The concurrent cases are the point: memory-ordering mistakes are invisible
// in review and only show up as rare, unreproducible audio glitches. These
// run the real producer/consumer pattern on two threads with a checkable
// invariant (a strictly increasing sample sequence), so a lost, duplicated,
// or reordered sample fails loudly.
//
// Build and run (MSVC):
//   cl /std:c++14 /EHsc /O2 test\double_ring_buffer_test.cpp /Fe:drb_test.exe
//   drb_test.exe
#include "../src/double_ring_buffer.h"

#include <atomic>
#include <cstdio>
#include <thread>
#include <vector>

static int g_failures = 0;

#define CHECK(cond, msg)                                            \
    do {                                                            \
        if (!(cond)) {                                              \
            std::printf("  FAIL: %s (line %d)\n", msg, __LINE__);   \
            g_failures++;                                           \
        }                                                           \
    } while (0)

// ── Single-threaded semantics ────────────────────────────────────────────

static void test_basic_round_trip() {
    std::printf("basic round trip\n");
    DoubleRingBuffer rb(8);
    CHECK(rb.available_read() == 0, "starts empty");
    CHECK(rb.available_write() == 8, "starts with full capacity");

    const double in[4] = {1.0, 2.0, 3.0, 4.0};
    CHECK(rb.write(in, 4) == 4, "writes 4");
    CHECK(rb.available_read() == 4, "4 readable");

    double out[4] = {0, 0, 0, 0};
    CHECK(rb.read(out, 4) == 4, "reads 4");
    for (int i = 0; i < 4; i++) CHECK(out[i] == in[i], "value preserved");
    CHECK(rb.available_read() == 0, "empty again");
}

static void test_fills_to_full_capacity() {
    // The old implementation reserved a sentinel slot and could only hold
    // size-1. The monotonic-counter version uses every slot.
    std::printf("fills to full capacity\n");
    DoubleRingBuffer rb(8);
    std::vector<double> in(8);
    for (int i = 0; i < 8; i++) in[i] = i;

    CHECK(rb.write(in.data(), 8) == 8, "accepts all 8");
    CHECK(rb.available_write() == 0, "reports full");
    const double extra = 99.0;
    CHECK(rb.write(&extra, 1) == 0, "rejects overflow");

    std::vector<double> out(8, -1.0);
    CHECK(rb.read(out.data(), 8) == 8, "drains all 8");
    for (int i = 0; i < 8; i++) CHECK(out[i] == i, "order preserved when full");
}

static void test_wraparound_is_contiguous() {
    // Exercises the split-memcpy path: a write that straddles the end of the
    // backing array must reassemble in order on read.
    std::printf("wraparound stays contiguous\n");
    DoubleRingBuffer rb(8);
    double scratch[6];
    const double warm[6] = {0, 0, 0, 0, 0, 0};
    rb.write(warm, 6);
    rb.read(scratch, 6);  // read index now at 6, near the end

    const double in[6] = {10, 11, 12, 13, 14, 15};
    CHECK(rb.write(in, 6) == 6, "write straddles the wrap point");

    double out[6] = {0};
    CHECK(rb.read(out, 6) == 6, "read straddles the wrap point");
    for (int i = 0; i < 6; i++) CHECK(out[i] == in[i], "wrapped value in order");
}

static void test_partial_read_and_write() {
    std::printf("partial read/write clamps\n");
    DoubleRingBuffer rb(8);
    std::vector<double> in(16);
    for (int i = 0; i < 16; i++) in[i] = i;

    CHECK(rb.write(in.data(), 16) == 8, "clamps write to free space");
    std::vector<double> out(16, -1.0);
    CHECK(rb.read(out.data(), 16) == 8, "clamps read to available data");
    CHECK(rb.read(out.data(), 4) == 0, "reads 0 when empty");
}

static void test_float_conversion_helpers() {
    std::printf("float conversion and clamping\n");
    DoubleRingBuffer rb(8);
    const float in[4] = {0.5f, -0.25f, 0.0f, 1.0f};
    CHECK(rb.writeFromFloat(in, 4) == 4, "writeFromFloat accepts 4");
    double out[4] = {0};
    rb.read(out, 4);
    CHECK(out[0] == 0.5 && out[1] == -0.25 && out[2] == 0.0 && out[3] == 1.0,
          "float widened exactly");

    const double loud[4] = {2.5, -3.0, 0.75, -0.5};
    rb.write(loud, 4);
    float clamped[4] = {0};
    CHECK(rb.readToFloatClamped(clamped, 4) == 4, "clamped read returns 4");
    CHECK(clamped[0] == 1.0f, "clamps above +1");
    CHECK(clamped[1] == -1.0f, "clamps below -1");
    CHECK(clamped[2] == 0.75f, "passes in-range positive");
    CHECK(clamped[3] == -0.5f, "passes in-range negative");
}

static void test_counter_wraparound() {
    // Monotonic counters must survive far more traffic than they will ever
    // see in a session; push a small ring through many multiples of capacity.
    std::printf("survives sustained traffic\n");
    DoubleRingBuffer rb(8);
    double next = 0.0;
    double expect = 0.0;
    for (int round = 0; round < 100000; round++) {
        double in[3] = {next, next + 1, next + 2};
        next += 3;
        const size_t wrote = rb.write(in, 3);
        double out[3];
        const size_t got = rb.read(out, wrote);
        CHECK(got == wrote, "reads back what was written");
        for (size_t i = 0; i < got; i++) {
            if (out[i] != expect) {
                CHECK(false, "sequence intact across many wraps");
                return;
            }
            expect += 1.0;
        }
    }
}

// ── Concurrent SPSC ───────────────────────────────────────────────────────

// One producer, one consumer, exactly as the audio callback and the Dart
// isolate use it. The payload is a strictly increasing counter, so the
// consumer can assert that every sample arrives exactly once and in order.
static void test_concurrent_spsc(const char* label, size_t capacity,
                                 int producerChunk, int consumerChunk,
                                 long long total) {
    std::printf("concurrent SPSC: %s\n", label);
    DoubleRingBuffer rb(capacity);
    std::atomic<bool> mismatch(false);
    std::atomic<long long> consumed(0);

    std::thread producer([&] {
        std::vector<double> chunk(producerChunk);
        long long produced = 0;
        while (produced < total) {
            const int n = (int)std::min<long long>(producerChunk, total - produced);
            for (int i = 0; i < n; i++) chunk[i] = (double)(produced + i);
            size_t off = 0;
            while (off < (size_t)n) {
                const size_t wrote = rb.write(chunk.data() + off, n - off);
                if (wrote == 0) std::this_thread::yield();  // ring full
                off += wrote;
            }
            produced += n;
        }
    });

    std::thread consumer([&] {
        std::vector<double> chunk(consumerChunk);
        long long expect = 0;
        while (expect < total) {
            const size_t got = rb.read(chunk.data(), consumerChunk);
            if (got == 0) {
                std::this_thread::yield();  // ring empty
                continue;
            }
            for (size_t i = 0; i < got; i++) {
                if (chunk[i] != (double)(expect + (long long)i)) {
                    mismatch.store(true);
                    return;
                }
            }
            expect += (long long)got;
            consumed.store(expect);
        }
    });

    producer.join();
    consumer.join();

    CHECK(!mismatch.load(), "no lost, duplicated, or reordered samples");
    CHECK(consumed.load() == total, "every sample arrived");
}

int main() {
    test_basic_round_trip();
    test_fills_to_full_capacity();
    test_wraparound_is_contiguous();
    test_partial_read_and_write();
    test_float_conversion_helpers();
    test_counter_wraparound();

    // Capacity/chunk shapes chosen so the ring spends time both full and
    // empty, which is where ordering bugs surface.
    test_concurrent_spsc("even chunks", 8192, 480, 480, 4000000);
    test_concurrent_spsc("producer outruns consumer", 1024, 512, 64, 2000000);
    test_concurrent_spsc("consumer outruns producer", 1024, 64, 512, 2000000);
    test_concurrent_spsc("tiny ring, ragged chunks", 16, 7, 5, 1000000);

    if (g_failures == 0) {
        std::printf("\nALL PASS\n");
        return 0;
    }
    std::printf("\n%d FAILURE(S)\n", g_failures);
    return 1;
}
