import 'dart:typed_data';

import 'package:audio_io/audio_io.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/data/audio_playback_buffer.dart';

/// Records what reaches the native voice queue. Playback itself is native
/// (and tested in packages/audio_io/test/voice_playout_test.cpp); what is
/// tested here is the Dart half: what gets written, and how it reacts to the
/// native counters.
class _FakeVoiceQueue implements VoiceQueue {
  final List<double> written = [];
  int target = -1;
  int resets = 0;

  @override
  bool isPlaying = false;
  @override
  int underruns = 0;
  @override
  int starvedFrames = 0;
  @override
  int playedFrames = 0;
  @override
  int trims = 0;
  @override
  int jumps = 0;
  @override
  int deviceBurstFrames = 0;

  @override
  int write(Float64List samples) {
    written.addAll(samples);
    return samples.length;
  }

  @override
  int writeSilence(int count) {
    written.addAll(List<double>.filled(count, 0.0));
    return count;
  }

  @override
  set targetFrames(int frames) => target = frames;

  @override
  void reset() => resets++;

  @override
  int get queuedFrames => written.length;
}

class _NullSink implements Sink<List<double>> {
  int adds = 0;
  @override
  void add(List<double> data) => adds++;
  @override
  void close() {}
}

List<double> _tone(int n, {double level = 0.5}) =>
    List<double>.filled(n, level);

void main() {
  const rate = 48000;
  const fade = rate * 5 ~/ 1000; // held back per packet

  AudioPlaybackBuffer build(_FakeVoiceQueue q, {_NullSink? sink}) =>
      AudioPlaybackBuffer(
        output: sink ?? _NullSink(),
        sampleRate: rate,
        targetBufferMs: 100,
        voiceQueue: q,
      );

  test('pushes the depth to the native queue from the start', () {
    final q = _FakeVoiceQueue();
    final buffer = build(q);
    expect(q.target, rate * 100 ~/ 1000);
    buffer.dispose();
  });

  test('writes packets straight through, holding back only the tail', () {
    final q = _FakeVoiceQueue();
    final sink = _NullSink();
    final buffer = build(q, sink: sink);
    buffer.feed(_tone(960), 0, 'peer');
    buffer.feed(_tone(960), 1, 'peer');
    expect(q.written.length, 1920 - fade);
    expect(buffer.queuedSamples, 1920);
    expect(q.written.every((s) => s == 0.5), isTrue);
    expect(sink.adds, 0, reason: 'nothing goes through the Dart timer path');
    buffer.dispose();
  });

  test('a lost packet is ramped into and out of, with no step', () {
    final q = _FakeVoiceQueue();
    final buffer = build(q);
    buffer.feed(_tone(960), 0, 'peer');
    buffer.feed(_tone(960), 1, 'peer');
    buffer.feed(_tone(960), 3, 'peer'); // 2 lost
    buffer.feed(_tone(960), 4, 'peer');

    final s = q.written;
    expect(s.where((v) => v == 0.0).length, greaterThanOrEqualTo(960));
    var worst = 0.0;
    for (var i = 1; i < s.length; i++) {
      final d = (s[i] - s[i - 1]).abs();
      if (d > worst) worst = d;
    }
    expect(worst, lessThan(0.01));
    buffer.dispose();
  });

  test('a native underrun grows the depth and pushes it', () {
    fakeAsync((async) {
      final q = _FakeVoiceQueue();
      final buffer = build(q);
      final before = q.target;
      q.underruns = 1;
      async.elapse(const Duration(milliseconds: 60));
      expect(q.target, greaterThan(before));
      expect(buffer.targetBufferMs, greaterThan(100));
      buffer.dispose();
    });
  });

  test('isDraining follows the native queue', () {
    final q = _FakeVoiceQueue();
    final buffer = build(q);
    expect(buffer.isDraining, isFalse);
    q.isPlaying = true;
    expect(buffer.isDraining, isTrue);
    buffer.dispose();
  });

  test('reset clears the native queue and the held tail', () {
    final q = _FakeVoiceQueue();
    final buffer = build(q);
    buffer.feed(_tone(960), 0, 'peer');
    buffer.reset();
    expect(q.resets, 1);
    q.written.clear();
    expect(buffer.queuedSamples, 0);
    buffer.dispose();
  });

  test('a new talk burst drops a stale tail instead of playing it late', () {
    final q = _FakeVoiceQueue();
    final buffer = build(q);
    buffer.feed(_tone(960, level: 0.3), 0, 'peer');
    final before = q.written.length;
    // The queue ran out long ago; the next burst starts far ahead.
    buffer.feed(_tone(960), 500, 'peer');
    final added = q.written.sublist(before);
    expect(added.contains(0.3), isFalse);
    buffer.dispose();
  });

  test('the tail left at the end of a burst never leads the next one', () {
    fakeAsync((async) {
      final q = _FakeVoiceQueue();
      final buffer = build(q);
      buffer.feed(_tone(960, level: 0.3), 0, 'peer');
      // The talker pauses; the native queue has run out by now.
      async.elapse(const Duration(milliseconds: 200));
      final before = q.written.length;
      buffer.feed(_tone(960), 1, 'peer'); // numbering continues
      expect(q.written.sublist(before).contains(0.3), isFalse);
      buffer.dispose();
    });
  });
}
