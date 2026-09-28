// Behaviour tests for the received-voice queue the audio callback plays from.
//
// Each test drives VoicePlayout the way the real pipeline does: Dart writes
// 20 ms packets, the device calls render() with its own pull size. The
// assertions are about what reaches the speaker: no zeros once playing, no
// steps (clicks), and a bounded delay.
//
// Build and run:
//   g++ -std=c++14 -O2 -pthread test/voice_playout_test.cpp -o vp_test && ./vp_test
//   cl /std:c++14 /EHsc /O2 test\voice_playout_test.cpp /Fe:vp_test.exe
#include "../src/voice_playout.h"

#include <atomic>
#include <cmath>
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

static const int kRate = 48000;
static const int kPacket = 960;  // 20 ms

static void writeTone(VoicePlayout& v, int n, double level = 0.5) {
    std::vector<double> s(n, level);
    v.write(s.data(), s.size());
}

/// Simulates [ms] of real time in 1 ms steps: a packet every 20 ms, and a
/// device pull of [pull] samples every [pull] samples' worth of time.
static std::vector<float> run(VoicePlayout& v, int ms, int pull,
                              bool feed = true) {
    std::vector<float> played;
    std::vector<float> out(pull);
    const long long pullEveryUs = (long long)pull * 1000000 / kRate;
    long long nextPullUs = 0;
    for (int t = 0; t < ms; t++) {
        if (feed && t % 20 == 0) writeTone(v, kPacket);
        while (nextPullUs <= (long long)t * 1000) {
            v.render(out.data(), out.size());
            played.insert(played.end(), out.begin(), out.end());
            nextPullUs += pullEveryUs;
        }
    }
    return played;
}

static float largestStep(const std::vector<float>& s, size_t from) {
    float worst = 0;
    for (size_t i = from + 1; i < s.size(); i++) {
        const float d = std::fabs(s[i] - s[i - 1]);
        if (d > worst) worst = d;
    }
    return worst;
}

static size_t zerosFrom(const std::vector<float>& s, size_t from) {
    size_t z = 0;
    for (size_t i = from; i < s.size(); i++) if (s[i] == 0.0f) z++;
    return z;
}

// ── Tests ────────────────────────────────────────────────────────────────

static void test_silent_until_target_then_plays() {
    std::printf("silent until the target is queued, then plays\n");
    VoicePlayout v(65536, kRate);
    v.setTarget(kRate / 10);  // 100 ms
    std::vector<float> out(480);
    writeTone(v, kRate / 20);  // 50 ms
    v.render(out.data(), out.size());
    CHECK(!v.playing(), "not playing below target");
    CHECK(out[479] == 0.0f, "silence while filling");
    CHECK(v.underruns() == 0, "filling is not an underrun");
    writeTone(v, kRate / 10);
    v.render(out.data(), out.size());
    CHECK(v.playing(), "plays once target reached");
    CHECK(out[0] < 0.5f && out[479] == 0.5f, "fades in");
}

static void test_small_pulls_play_cleanly() {
    std::printf("a phone pulling 2 ms at a time plays with no gaps\n");
    VoicePlayout v(65536, kRate);
    v.setTarget(kRate * 60 / 1000);
    auto played = run(v, 3000, 96);
    CHECK(v.underruns() == 0, "no underruns");
    CHECK(zerosFrom(played, kRate / 5) == 0, "no zeros after start");
    CHECK(largestStep(played, kRate / 5) < 0.01f, "no steps");
}

static void test_big_pulls_play_cleanly() {
    std::printf("a phone pulling 100 ms at a time (Galaxy S8+) plays cleanly\n");
    VoicePlayout v(65536, kRate);
    v.setTarget(kRate * 60 / 1000);
    auto played = run(v, 4000, 4800);
    // The first pull teaches it the burst size; allow the first second.
    CHECK(v.burstFrames() == 4800, "learns the pull size");
    CHECK(zerosFrom(played, kRate) == 0, "no zeros once settled");
    CHECK(v.underruns() == 0, "no underruns");
}

static void test_underrun_decays_and_recovers() {
    std::printf("running dry decays instead of stepping, then refills\n");
    VoicePlayout v(65536, kRate);
    v.setTarget(kRate / 20);
    writeTone(v, kRate / 10);
    std::vector<float> out(480);
    std::vector<float> played;
    for (int i = 0; i < 12; i++) {
        v.render(out.data(), out.size());
        played.insert(played.end(), out.begin(), out.end());
    }
    CHECK(v.underruns() == 1, "one underrun");
    CHECK(!v.playing(), "back to filling");
    CHECK(largestStep(played, 0) < 0.01f, "no step into silence");
    CHECK(v.starvedFrames() > 0, "starvation counted");
}

static void test_big_backlog_jumps_to_live() {
    std::printf("a flushed backlog jumps back to live in one splice\n");
    VoicePlayout v(65536, kRate);
    v.setTarget(kRate / 10);
    writeTone(v, kRate * 8 / 10);  // 800 ms at once
    std::vector<float> out(480);
    v.render(out.data(), out.size());
    CHECK(v.jumps() == 1, "jumped");
    CHECK(v.queued() <= (size_t)(kRate / 10 + 480), "back to target");
}

static void test_trim_never_dips() {
    std::printf("trimming a moderate backlog never dips toward silence\n");
    VoicePlayout v(65536, kRate);
    v.setTarget(kRate / 20);  // 50 ms: 2x is 100, jump at 300
    writeTone(v, kRate * 20 / 100);  // 200 ms
    std::vector<float> out(480);
    std::vector<float> played;
    // 400 ms of 10 ms pulls, fed at the rate it plays, so the backlog stays
    // between twice the target and the jump threshold.
    for (int i = 0; i < 40; i++) {
        v.render(out.data(), out.size());
        played.insert(played.end(), out.begin(), out.end());
        writeTone(v, 480);
    }
    CHECK(v.trims() > 0, "trimmed");
    CHECK(v.jumps() == 0, "no jump");
    float lowest = 1;
    for (size_t i = 240; i < played.size(); i++) lowest = std::min(lowest, played[i]);
    CHECK(lowest > 0.45f, "no dip");
}

static void test_reset_drops_queue() {
    std::printf("reset drops everything at the next pull\n");
    VoicePlayout v(65536, kRate);
    v.setTarget(480);
    writeTone(v, kRate);
    v.requestReset();
    std::vector<float> out(480);
    v.render(out.data(), out.size());
    CHECK(v.queued() == 0, "empty");
    CHECK(out[0] == 0.0f && out[479] == 0.0f, "silent");
}

static void test_threads_stay_consistent() {
    std::printf("producer and callback on two threads stay consistent\n");
    // Fades and crossfades reshape amplitudes on purpose, so the invariant
    // here is accounting rather than order: nothing is invented, nothing is
    // out of range, and the queue never claims more than it can hold.
    VoicePlayout v(4096, kRate);
    v.setTarget(0);
    const long long total = 2000000;
    std::atomic<bool> done{false};
    std::atomic<bool> overfull{false};
    std::thread producer([&] {
        std::vector<double> chunk(160, 0.25);
        long long sent = 0;
        while (sent < total) {
            const size_t n = v.write(chunk.data(), chunk.size());
            sent += (long long)n;
            if (v.queued() > 4096) overfull = true;
            if (n < chunk.size()) std::this_thread::yield();
        }
        done = true;
    });
    std::vector<float> out(64);
    bool inRange = true;
    while (!done || v.queued() > 0) {
        v.render(out.data(), out.size());
        for (float f : out) {
            if (f < 0.0f || f > 0.25f + 1e-6f) inRange = false;
        }
    }
    producer.join();
    CHECK(inRange, "every sample within what was written");
    CHECK(!overfull, "never over capacity");
    CHECK(v.playedFrames() <= total, "never plays more than was written");
    CHECK(v.playedFrames() > total / 2, "most samples delivered");
}

int main() {
    test_silent_until_target_then_plays();
    test_small_pulls_play_cleanly();
    test_big_pulls_play_cleanly();
    test_underrun_decays_and_recovers();
    test_big_backlog_jumps_to_live();
    test_trim_never_dips();
    test_reset_drops_queue();
    test_threads_stay_consistent();
    if (g_failures == 0) {
        std::printf("All voice playout tests passed.\n");
        return 0;
    }
    std::printf("%d failure(s).\n", g_failures);
    return 1;
}
