import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/domain/media_receive_buffer.dart';

void main() {
  test('sustained 48 kHz stream stays bounded with measured runtime/RSS', () {
    const sampleRate = 48000;
    const frameMs = 20;
    const frameSamples = sampleRate * frameMs ~/ 1000;
    const simulatedMinutes = 3;
    const frameCount = simulatedMinutes * 60 * 1000 ~/ frameMs;

    final buffer = MediaReceiveBuffer(sampleRate: sampleRate);
    addTearDown(buffer.dispose);

    // Reuse the captured frame allocation just as a native/capture bridge can;
    // the buffer must not retain caller-owned lists merely to maintain jitter.
    final frame = List<double>.filled(frameSamples, 0.125);
    final rssBefore = ProcessInfo.currentRss;
    final stopwatch = Stopwatch()..start();

    var playedFrames = 0;
    var maxQueuedMs = 0;
    for (var seq = 0; seq < frameCount; seq++) {
      buffer.feed(frame, seq, 'peer');
      final output = buffer.pullFrame(frameSamples);
      if (output != null) playedFrames++;
      if (buffer.queuedMs > maxQueuedMs) maxQueuedMs = buffer.queuedMs;
    }

    stopwatch.stop();
    final rssDeltaBytes = ProcessInfo.currentRss - rssBefore;

    // These prints are measurement evidence, not fragile performance gates:
    // CI/desktop hardware varies, while the behavioral memory/latency bound is
    // deterministic and asserted below.
    // ignore: avoid_print
    print(
      'media-rx sustained: ${stopwatch.elapsedMilliseconds}ms CPU-wall, '
      'rssDelta=${rssDeltaBytes ~/ 1024}KiB, maxQueue=${maxQueuedMs}ms, '
      'played=$playedFrames/$frameCount',
    );

    expect(maxQueuedMs, lessThanOrEqualTo(MediaReceiveBuffer.kDefaultMaxQueueMs));
    expect(buffer.overflowDrops, 0);
    expect(buffer.staleDrops, 0);
    expect(buffer.resyncs, 0);
    expect(playedFrames, greaterThan(frameCount - 10));
  });
}
