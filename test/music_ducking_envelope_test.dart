import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/domain/music_ducking_envelope.dart';

void main() {
  group('MusicDuckingEnvelope.advance', () {
    test('starts at full volume, not ducked', () {
      final env = MusicDuckingEnvelope();
      expect(env.gain, 1.0);
      expect(env.isDucked, isFalse);
    });

    test('stays at full volume while voice is never active', () {
      final env = MusicDuckingEnvelope();
      for (var i = 0; i < 10; i++) {
        expect(
          env.advance(voiceActive: false, frameDurationMs: 20),
          1.0,
        );
      }
      expect(env.isDucked, isFalse);
    });

    test('ramps down to duckTarget over attackMs once voice starts', () {
      final env = MusicDuckingEnvelope(
        duckTarget: 0.3,
        attackMs: 100,
        releaseMs: 800,
        hangoverMs: 0,
      );
      // 100 ms attack at 20 ms/frame = 5 frames from 1.0 to 0.3.
      final gains = List.generate(
        5,
        (_) => env.advance(voiceActive: true, frameDurationMs: 20),
      );
      expect(gains.last, closeTo(0.3, 1e-9));
      // Monotonically decreasing, no overshoot below the target.
      for (var i = 1; i < gains.length; i++) {
        expect(gains[i], lessThanOrEqualTo(gains[i - 1]));
        expect(gains[i], greaterThanOrEqualTo(0.3));
      }
      expect(env.isDucked, isTrue);
    });

    test('holds at duckTarget exactly, never overshoots past it', () {
      final env = MusicDuckingEnvelope(
        duckTarget: 0.3,
        attackMs: 100,
        hangoverMs: 0,
      );
      for (var i = 0; i < 20; i++) {
        env.advance(voiceActive: true, frameDurationMs: 20);
      }
      expect(env.gain, 0.3);
    });

    test('holds ducked through hangoverMs after voice activity stops', () {
      final env = MusicDuckingEnvelope(
        duckTarget: 0.3,
        attackMs: 20,
        releaseMs: 100,
        hangoverMs: 100,
      );
      // Fully ducked in one 20 ms frame.
      env.advance(voiceActive: true, frameDurationMs: 20);
      expect(env.gain, closeTo(0.3, 1e-9));

      // Voice drops out; the 100 ms hold covers 4 full silent frames at
      // 20 ms each — same "consume, then check" pattern as [VoxGate]'s own
      // hangover, so the 5th call is the one whose decrement empties the
      // hold and immediately starts the release ramp within that call.
      for (var i = 0; i < 4; i++) {
        expect(
          env.advance(voiceActive: false, frameDurationMs: 20),
          closeTo(0.3, 1e-9),
        );
      }
      final next = env.advance(voiceActive: false, frameDurationMs: 20);
      expect(next, greaterThan(0.3));
    });

    test('a short gap between words never starts the release ramp', () {
      // Regression: a naive "voice inactive this frame -> release" model
      // would pump audibly on every syllable boundary.
      final env = MusicDuckingEnvelope(
        duckTarget: 0.3,
        attackMs: 20,
        releaseMs: 100,
        hangoverMs: 200,
      );
      env.advance(voiceActive: true, frameDurationMs: 20);
      expect(env.gain, closeTo(0.3, 1e-9));

      // 60 ms gap (well inside the 200 ms hangover), then speech resumes.
      env.advance(voiceActive: false, frameDurationMs: 20);
      env.advance(voiceActive: false, frameDurationMs: 20);
      env.advance(voiceActive: false, frameDurationMs: 20);
      expect(env.gain, closeTo(0.3, 1e-9));

      env.advance(voiceActive: true, frameDurationMs: 20);
      expect(env.gain, closeTo(0.3, 1e-9));
    });

    test('releases back to exactly 1.0 over releaseMs after the hold', () {
      final env = MusicDuckingEnvelope(
        duckTarget: 0.3,
        attackMs: 20,
        releaseMs: 100,
        hangoverMs: 0,
      );
      env.advance(voiceActive: true, frameDurationMs: 20);
      expect(env.gain, closeTo(0.3, 1e-9));

      // 100 ms release at 20 ms/frame = 5 frames from 0.3 back to 1.0.
      final gains = List.generate(
        5,
        (_) => env.advance(voiceActive: false, frameDurationMs: 20),
      );
      expect(gains.last, closeTo(1.0, 1e-9));
      for (var i = 1; i < gains.length; i++) {
        expect(gains[i], greaterThanOrEqualTo(gains[i - 1]));
        expect(gains[i], lessThanOrEqualTo(1.0));
      }
      expect(env.isDucked, isFalse);
    });

    test('re-triggering mid-release reverses back toward duckTarget', () {
      final env = MusicDuckingEnvelope(
        duckTarget: 0.3,
        attackMs: 100,
        releaseMs: 100,
        hangoverMs: 0,
      );
      env.advance(voiceActive: true, frameDurationMs: 20);
      env.advance(voiceActive: true, frameDurationMs: 20);
      env.advance(voiceActive: true, frameDurationMs: 20);
      env.advance(voiceActive: true, frameDurationMs: 20);
      env.advance(voiceActive: true, frameDurationMs: 20);
      expect(env.gain, closeTo(0.3, 1e-9));

      // Partway through release…
      final midRelease = env.advance(voiceActive: false, frameDurationMs: 20);
      expect(midRelease, greaterThan(0.3));
      expect(midRelease, lessThan(1.0));

      // …voice resumes: gain must move back down, not continue up.
      final afterRetrigger = env.advance(
        voiceActive: true,
        frameDurationMs: 20,
      );
      expect(afterRetrigger, lessThan(midRelease));
    });

    test('never produces gain outside [duckTarget, 1.0]', () {
      final env = MusicDuckingEnvelope(
        duckTarget: 0.25,
        attackMs: 37,
        releaseMs: 53,
        hangoverMs: 11,
      );
      final active = [
        true, true, false, true, false, false, false, true, true, false,
        false, false, false, false, true, false, false, false, false, false,
      ];
      for (final voiceActive in active) {
        final g = env.advance(voiceActive: voiceActive, frameDurationMs: 20);
        expect(g, greaterThanOrEqualTo(0.25));
        expect(g, lessThanOrEqualTo(1.0));
      }
    });

    test('duckTarget of 1.0 means the envelope never audibly moves', () {
      final env = MusicDuckingEnvelope(duckTarget: 1.0);
      for (var i = 0; i < 5; i++) {
        expect(env.advance(voiceActive: true, frameDurationMs: 20), 1.0);
      }
    });

    test('reset returns to full volume immediately with no ramp', () {
      final env = MusicDuckingEnvelope(duckTarget: 0.3, hangoverMs: 500);
      env.advance(voiceActive: true, frameDurationMs: 20);
      expect(env.gain, lessThan(1.0));

      env.reset();
      expect(env.gain, 1.0);
      expect(env.isDucked, isFalse);

      // The hold must be cleared too — a stale hangover surviving reset
      // would re-duck on the very next silent frame.
      expect(env.advance(voiceActive: false, frameDurationMs: 20), 1.0);
    });

    test('a large frame duration cannot overshoot past the target', () {
      // Backgrounding/resume can hand this a much larger elapsed duration
      // than the steady-state 20 ms media frame.
      final env = MusicDuckingEnvelope(
        duckTarget: 0.3,
        attackMs: 100,
        releaseMs: 100,
      );
      expect(env.advance(voiceActive: true, frameDurationMs: 5000), 0.3);
      expect(env.advance(voiceActive: false, frameDurationMs: 5000), 1.0);
    });
  });
}
