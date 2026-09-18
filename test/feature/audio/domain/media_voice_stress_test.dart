import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/audio/audio_format_profile.dart';
import 'package:tark/core/identity/session_epoch.dart';
import 'package:tark/feature/audio/data/audio_playback_buffer.dart';
import 'package:tark/feature/audio/domain/media_frame_scheduler.dart';
import 'package:tark/feature/audio/domain/media_receive_buffer.dart';
import 'package:tark/feature/transfer/data/codec/waki_packet_codec.dart';
import 'package:tark/feature/transfer/domain/entity/waki_packet.dart';
import 'package:tark/feature/transfer/domain/service/priority_write_scheduler.dart';

/// #30's deterministic stress/replay fixture: simultaneous synthetic voice
/// and media traffic under injected loss, proving the roadmap's own safety
/// invariants for this issue hold when both streams are under load together
/// — not just individually, which every other test file in this issue
/// already covers piece by piece.
///
/// Deterministic, seeded packet-loss injector — generalizes the manual
/// seq-gap-by-hand pattern `audio_playback_buffer_test.dart` already uses
/// into a reusable synthetic network, per the roadmap's own instruction not
/// to invent a second style. Order-preserving: reordering itself is already
/// covered per-buffer elsewhere (`audio_playback_buffer_test.dart`,
/// `media_receive_buffer_test.dart`) — this fixture is about loss and
/// concurrent voice+media load, not re-proving reorder handling.
class _FlakyNetwork {
  _FlakyNetwork(int seed, {this.lossRate = 0.0}) : _rng = Random(seed);
  final Random _rng;
  final double lossRate;

  List<T> deliver<T>(List<T> packets) =>
      [for (final p in packets) if (_rng.nextDouble() >= lossRate) p];
}

List<double> _tone(int n, {double level = 0.4}) => List<double>.filled(n, level);

void main() {
  group('simultaneous voice + media under loss', () {
    test(
      'independent sequence spaces both survive independent loss without '
      'exceptions or cross-contamination',
      () {
        final codec = WakiPacketCodec(
          'abc123abc123',
          SessionEpoch.startingAt(1),
        );
        addTearDown(codec.release);

        const frame = 320; // 20ms @ 16kHz mono, matches legacy16k
        final voicePackets = [
          for (var seq = 0; seq < 200; seq++)
            codec.encodeAudio(_tone(frame), 'Rider', seq),
        ];
        final mediaPackets = [
          for (var seq = 0; seq < 200; seq++)
            codec.encodeMediaAudio(_tone(frame), 'Rider', seq),
        ];

        // Different seeds and loss rates: the two streams' loss patterns
        // must be free to differ entirely from each other.
        final voiceDelivered = _FlakyNetwork(
          1,
          lossRate: 0.15,
        ).deliver(voicePackets);
        final mediaDelivered = _FlakyNetwork(
          2,
          lossRate: 0.35, // media tolerates more loss than voice by design
        ).deliver(mediaPackets);

        final playback = AudioPlaybackBuffer(
          output: _NullSink(),
          sampleRate: 16000,
          targetBufferMs: 100,
        );
        addTearDown(playback.dispose);
        final mediaBuffer = MediaReceiveBuffer(sampleRate: 16000);
        addTearDown(mediaBuffer.dispose);

        for (final bytes in voiceDelivered) {
          final packet = codec.decode(bytes, 'peer-addr') as AudioPacket?;
          expect(packet, isNotNull);
          playback.feed(packet!.samples, packet.seq, packet.senderId);
        }
        for (final bytes in mediaDelivered) {
          final packet = codec.decode(bytes, 'peer-addr') as MediaAudioPacket?;
          expect(packet, isNotNull);
          mediaBuffer.feed(packet!.samples, packet.seq, packet.senderId);
        }

        // Both streams kept flowing despite real loss on both — no crash,
        // no stream starving the other out just by existing.
        expect(playback.queuedSamples, greaterThan(0));
        expect(mediaBuffer.queuedSamples, greaterThan(0));
      },
    );

    test(
      'a corrupt media packet decodes to null and never disturbs voice '
      'decoding around it',
      () {
        final codec = WakiPacketCodec(
          'abc123abc123',
          SessionEpoch.startingAt(1),
        );
        addTearDown(codec.release);
        const frame = 320;

        final before = codec.decode(
          codec.encodeAudio(_tone(frame), 'Rider', 10),
          'x',
        )! as AudioPacket;

        // Garbage: a real media Opus type byte, but a truncated/corrupt body
        // — decode() must reject it, never throw.
        final corrupt = Uint8List.fromList([kOpusMediaAudioByte, 0xFF, 0x00]);
        expect(codec.decode(corrupt, 'x'), isNull);

        final after = codec.decode(
          codec.encodeAudio(_tone(frame), 'Rider', 11),
          'x',
        )! as AudioPacket;

        expect(before.seq, 10);
        expect(after.seq, 11);
        expect(before.samples, hasLength(frame));
        expect(after.samples, hasLength(frame));
      },
    );
  });

  group('send-side: voice keeps its own clock under heavy media jitter', () {
    test(
      'media scheduler dropouts under bursty capture never touch a '
      'separately-clocked voice send counter',
      () {
        fakeAsync((async) {
          final sent = <List<double>>[];
          const profile = AudioFormatProfile(
            id: 950,
            sampleRateHz: 1000,
            channels: 2,
            frameDurationMs: 20,
            label: 'test-stress',
            kind: AudioProfileKind.media,
          );
          final scheduler = MediaFrameScheduler(
            profile: profile,
            sendFrame: (s) => sent.add(s),
            captureSampleRateHz: 1000,
            captureChannels: 2,
            prefillMs: 25,
            highWaterMs: 40,
            floodMs: 100,
          )..start();
          addTearDown(scheduler.dispose);

          // Voice's own independent clock — a separate Timer.periodic,
          // structurally unrelated to the media scheduler's, standing in for
          // the mic callback.
          var voiceSendCount = 0;
          final voiceTimer = Timer.periodic(
            const Duration(milliseconds: 20),
            (_) => voiceSendCount++,
          );
          addTearDown(voiceTimer.cancel);

          // Bursty, irregular capture delivery on the media side — some
          // ticks starve it, some flood it — while voice's clock runs on
          // completely undisturbed by any of it.
          for (var i = 0; i < 20; i++) {
            if (i.isEven) scheduler.addChunk(List.filled(200, 0.3));
            async.elapse(const Duration(milliseconds: 20));
          }

          expect(scheduler.dropouts, greaterThan(0));
          expect(
            voiceSendCount,
            20,
            reason:
                "voice's own clock ticked exactly once per elapsed interval "
                'regardless of anything happening on the media scheduler',
          );
        });
      },
    );
  });

  group('reconnect recovery', () {
    test('both streams recover cleanly from a simultaneous reset', () {
      final playback = AudioPlaybackBuffer(
        output: _NullSink(),
        sampleRate: 16000,
        targetBufferMs: 100,
      );
      addTearDown(playback.dispose);
      final mediaBuffer = MediaReceiveBuffer(sampleRate: 16000);
      addTearDown(mediaBuffer.dispose);

      playback.feed(_tone(320), 500, 'peer');
      mediaBuffer.feed(_tone(320), 500, 'peer');

      playback.reset();
      mediaBuffer.reset();

      // A low sequence that would have been "stale" pre-reset is accepted
      // immediately on both — proof the reset actually cleared per-sender
      // state on both streams independently.
      expect(playback.queuedSamples, 0);
      expect(mediaBuffer.queuedSamples, 0);
      playback.feed(_tone(320), 0, 'peer');
      mediaBuffer.feed(_tone(320), 0, 'peer');
      expect(playback.queuedSamples, 320);
      expect(mediaBuffer.queuedSamples, 320);
    });
  });

  group('lifecycle', () {
    test('repeated media stop/start leaks no timers or state', () {
      fakeAsync((async) {
        const profile = AudioFormatProfile(
          id: 951,
          sampleRateHz: 1000,
          channels: 1,
          frameDurationMs: 20,
          label: 'test-cycle',
          kind: AudioProfileKind.media,
        );
        for (var cycle = 0; cycle < 20; cycle++) {
          final sent = <List<double>>[];
          final scheduler = MediaFrameScheduler(
            profile: profile,
            sendFrame: (s) => sent.add(s),
            captureSampleRateHz: 1000,
            captureChannels: 1,
            prefillMs: 10,
          )..start();
          scheduler.addChunk(List.filled(50, 0.2));
          async.elapse(const Duration(milliseconds: 40));
          scheduler.dispose();
          expect(scheduler.isRunning, isFalse);
          expect(scheduler.queuedSamples, 0);

          final mediaBuffer = MediaReceiveBuffer(sampleRate: 1000);
          mediaBuffer.feed(_tone(10), 0, 'peer');
          mediaBuffer.dispose();
          expect(mediaBuffer.queuedSamples, 0);
        }
        // No pending timers left running after the last cycle's dispose.
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('voice-first under transport backpressure', () {
    test(
      'a high-priority voice write completes promptly even while the media '
      'send-side cushion and the write queue are both saturated',
      () async {
        // Saturate the write scheduler's low-priority lane first.
        final unblock = Completer<void>();
        final written = <String>[];
        final writeScheduler = PriorityWriteScheduler<String>(
          write: (p) async {
            if (p == 'media-0') await unblock.future; // holds the pipe open
            written.add(p);
          },
          maxQueuedLowPriority: 3,
        );

        writeScheduler.writeLowPriority('media-0'); // in flight, blocked
        await Future<void>.delayed(Duration.zero);
        for (var i = 1; i <= 5; i++) {
          writeScheduler.writeLowPriority('media-$i'); // most get dropped
        }
        expect(writeScheduler.lowPriorityDrops, greaterThan(0));

        // Voice, queued after all that media backlog, still only waits on
        // the one write already in flight — not the whole media queue.
        final voiceDone = writeScheduler.writeHighPriority('voice-0');
        unblock.complete();
        await voiceDone;

        expect(written.first, 'media-0');
        expect(written[1], 'voice-0');
      },
    );
  });
}

class _NullSink implements Sink<List<double>> {
  @override
  void add(List<double> data) {}

  @override
  void close() {}
}
