import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/domain/music_ducking_envelope.dart';

void main() {
  group('MusicDuckingEnvelope speech evidence', () {
    test('short noise spike does not start ducking', () {
      final env = MusicDuckingEnvelope();

      expect(env.advance(voiceActive: true, frameDurationMs: 20), 1.0);
      expect(env.advance(voiceActive: false, frameDurationMs: 20), 1.0);
      expect(env.qualifiedVoiceActive, isFalse);
      expect(env.isDucked, isFalse);
    });

    test('sustained speech qualifies within 60ms then attacks smoothly', () {
      final env = MusicDuckingEnvelope(
        duckTarget: 0.3,
        attackMs: 120,
        hangoverMs: 0,
      );

      expect(env.advance(voiceActive: true, frameDurationMs: 20), 1.0);
      expect(env.advance(voiceActive: true, frameDurationMs: 20), 1.0);
      final qualified = env.advance(voiceActive: true, frameDurationMs: 20);

      expect(env.qualifiedVoiceActive, isTrue);
      expect(qualified, lessThan(1.0));
      expect(qualified, greaterThanOrEqualTo(0.3));
    });

    test('brief inactive threshold crossing does not chatter release', () {
      final env = MusicDuckingEnvelope(
        duckTarget: 0.3,
        attackMs: 20,
        releaseMs: 100,
        hangoverMs: 0,
      );
      for (var i = 0; i < 3; i++) {
        env.advance(voiceActive: true, frameDurationMs: 20);
      }
      expect(env.gain, closeTo(0.3, 1e-9));

      for (var i = 0; i < 11; i++) {
        expect(
          env.advance(voiceActive: false, frameDurationMs: 20),
          closeTo(0.3, 1e-9),
        );
      }
      expect(env.qualifiedVoiceActive, isTrue);

      final release = env.advance(voiceActive: false, frameDurationMs: 20);
      expect(env.qualifiedVoiceActive, isFalse);
      expect(release, greaterThan(0.3));
    });

    test('word gap stays ducked through evidence and hangover', () {
      final env = MusicDuckingEnvelope(
        duckTarget: 0.3,
        attackMs: 20,
        releaseMs: 100,
        hangoverMs: 200,
      );
      for (var i = 0; i < 3; i++) {
        env.advance(voiceActive: true, frameDurationMs: 20);
      }
      expect(env.gain, closeTo(0.3, 1e-9));

      for (var i = 0; i < 5; i++) {
        env.advance(voiceActive: false, frameDurationMs: 20);
      }
      expect(env.gain, closeTo(0.3, 1e-9));

      env.advance(voiceActive: true, frameDurationMs: 20);
      env.advance(voiceActive: true, frameDurationMs: 20);
      env.advance(voiceActive: true, frameDurationMs: 20);
      expect(env.gain, closeTo(0.3, 1e-9));
    });

    test('overlapping/continuous speakers keep qualified activity active', () {
      final env = MusicDuckingEnvelope(activeEvidenceMs: 40);
      for (var i = 0; i < 2; i++) {
        env.advance(voiceActive: true, frameDurationMs: 20);
      }
      expect(env.qualifiedVoiceActive, isTrue);

      for (var i = 0; i < 20; i++) {
        env.advance(voiceActive: true, frameDurationMs: 20);
      }
      expect(env.qualifiedVoiceActive, isTrue);
      expect(env.isDucked, isTrue);
    });

    test('reset clears qualified speech, gain and hold', () {
      final env = MusicDuckingEnvelope(
        attackMs: 20,
        activeEvidenceMs: 20,
        inactiveEvidenceMs: 240,
        hangoverMs: 500,
      );
      env.advance(voiceActive: true, frameDurationMs: 20);
      expect(env.isDucked, isTrue);
      expect(env.qualifiedVoiceActive, isTrue);

      env.reset();

      expect(env.gain, 1.0);
      expect(env.isDucked, isFalse);
      expect(env.qualifiedVoiceActive, isFalse);
      expect(env.advance(voiceActive: false, frameDurationMs: 20), 1.0);
    });
  });

  group('MusicDuckingEnvelope gain envelope', () {
    MusicDuckingEnvelope immediate({
      double duckTarget = 0.3,
      int attackMs = 100,
      int releaseMs = 100,
      int hangoverMs = 0,
    }) => MusicDuckingEnvelope(
      duckTarget: duckTarget,
      attackMs: attackMs,
      releaseMs: releaseMs,
      hangoverMs: hangoverMs,
      activeEvidenceMs: 0,
      inactiveEvidenceMs: 0,
    );

    test('ramps to duck target without overshoot', () {
      final env = immediate(attackMs: 100);
      final gains = List.generate(
        5,
        (_) => env.advance(voiceActive: true, frameDurationMs: 20),
      );
      expect(gains.last, closeTo(0.3, 1e-9));
      for (var i = 1; i < gains.length; i++) {
        expect(gains[i], lessThanOrEqualTo(gains[i - 1]));
        expect(gains[i], greaterThanOrEqualTo(0.3));
      }
    });

    test('hangover prevents syllable-gap pumping', () {
      final env = immediate(attackMs: 20, releaseMs: 100, hangoverMs: 100);
      env.advance(voiceActive: true, frameDurationMs: 20);
      expect(env.gain, closeTo(0.3, 1e-9));

      for (var i = 0; i < 4; i++) {
        expect(
          env.advance(voiceActive: false, frameDurationMs: 20),
          closeTo(0.3, 1e-9),
        );
      }
      expect(
        env.advance(voiceActive: false, frameDurationMs: 20),
        greaterThan(0.3),
      );
    });

    test('release reaches exactly full gain', () {
      final env = immediate(attackMs: 20, releaseMs: 100);
      env.advance(voiceActive: true, frameDurationMs: 20);
      final gains = List.generate(
        5,
        (_) => env.advance(voiceActive: false, frameDurationMs: 20),
      );
      expect(gains.last, closeTo(1.0, 1e-9));
      expect(env.isDucked, isFalse);
    });

    test('retrigger during release reverses toward duck target', () {
      final env = immediate(attackMs: 100, releaseMs: 100);
      for (var i = 0; i < 5; i++) {
        env.advance(voiceActive: true, frameDurationMs: 20);
      }
      final midRelease = env.advance(
        voiceActive: false,
        frameDurationMs: 20,
      );
      final retrigger = env.advance(voiceActive: true, frameDurationMs: 20);
      expect(retrigger, lessThan(midRelease));
    });

    test('large elapsed frames stay bounded', () {
      final env = immediate(attackMs: 100, releaseMs: 100);
      expect(env.advance(voiceActive: true, frameDurationMs: 5000), 0.3);
      expect(env.advance(voiceActive: false, frameDurationMs: 5000), 1.0);
    });
  });
}
