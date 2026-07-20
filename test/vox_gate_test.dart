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
