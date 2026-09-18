import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/domain/vox_gate.dart';

void main() {
  group('VoxGate.advance', () {
    test('starts closed and stays closed below threshold', () {
      final gate = VoxGate();
      expect(gate.advance(0.1, 0.5), isFalse);
      expect(gate.advance(0.4, 0.5), isFalse);
    });

    test('rms equal to threshold does not open the gate (strict >)', () {
      final gate = VoxGate();
      expect(gate.advance(0.5, 0.5), isFalse);
    });

    test('opens on loud frame and stays open for hangoverFrames after', () {
      final gate = VoxGate(hangoverFrames: 3);
      expect(gate.advance(0.9, 0.5), isTrue);
      // Three silent frames ride the hangover…
      expect(gate.advance(0.0, 0.5), isTrue);
      expect(gate.advance(0.0, 0.5), isTrue);
      // …decrementing each frame: open-frame set it to 3, two silent frames
      // consumed two, the third consumes the last and closes.
      expect(gate.advance(0.0, 0.5), isFalse);
    });

    test('threshold 0 holds the gate open through exact digital silence', () {
      // The Galaxy S8+ case: platform NS hands over frames of 0.0 between
      // words, which a strict `rms > 0` reads as "stop transmitting". At 0%
      // the user has asked for no gating at all, so nothing may close it.
      final gate = VoxGate(hangoverFrames: 1);
      expect(gate.advance(0.0, 0.0), isTrue);
      expect(gate.advance(0.0, 0.0), isTrue);
      expect(gate.advance(0.0, 0.0), isTrue);
    });

    test('threshold 0 leaves no stale hangover behind for a later gate', () {
      // Raising the threshold mid-session must not inherit an open gate.
      final gate = VoxGate(hangoverFrames: 2);
      expect(gate.advance(0.0, 0.0), isTrue);
      // Quiet frames now decrement the carried hangover like any other, so it
      // drains in hangoverFrames and the gate closes.
      expect(gate.advance(0.1, 0.5), isTrue);
      expect(gate.advance(0.1, 0.5), isFalse);
    });

    test('loud frame mid-hangover re-arms the full hangover', () {
      final gate = VoxGate(hangoverFrames: 2);
      gate.advance(0.9, 0.5);
      gate.advance(0.0, 0.5); // hangover 1 left
      gate.advance(0.9, 0.5); // re-armed to 2
      expect(gate.advance(0.0, 0.5), isTrue);
      expect(gate.advance(0.0, 0.5), isFalse);
    });
  });

  group('VoxGate pre-roll', () {
    test('keeps only the newest prerollFrames frames', () {
      final gate = VoxGate(prerollFrames: 2);
      gate.bufferWhileClosed([1]);
      gate.bufferWhileClosed([2]);
      gate.bufferWhileClosed([3]);
      expect(gate.drainPreroll(), [
        [2],
        [3],
      ]);
    });

    test('drainPreroll returns oldest first and clears the buffer', () {
      final gate = VoxGate();
      gate.bufferWhileClosed([1]);
      gate.bufferWhileClosed([2]);
      expect(gate.drainPreroll(), [
        [1],
        [2],
      ]);
      expect(gate.drainPreroll(), isEmpty);
    });
  });
}
