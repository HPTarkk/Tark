import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/domain/speech_activity_evidence_gate.dart';

void main() {
  SpeechActivityEvidenceGate build() =>
      SpeechActivityEvidenceGate(activeEvidenceMs: 60, inactiveEvidenceMs: 240);

  test('short wind-like spikes never activate ducking', () {
    final gate = build();

    expect(gate.advance(voiceEvidence: true, elapsedMs: 20), isFalse);
    expect(gate.advance(voiceEvidence: false, elapsedMs: 20), isFalse);
    expect(gate.advance(voiceEvidence: true, elapsedMs: 20), isFalse);
    expect(gate.advance(voiceEvidence: false, elapsedMs: 20), isFalse);
  });

  test('sustained speech activates inside the explicit 60ms budget', () {
    final gate = build();

    expect(gate.advance(voiceEvidence: true, elapsedMs: 20), isFalse);
    expect(gate.advance(voiceEvidence: true, elapsedMs: 20), isFalse);
    expect(gate.advance(voiceEvidence: true, elapsedMs: 20), isTrue);
  });

  test('word gaps do not release and retrigger repeatedly', () {
    final gate = build();
    gate.advance(voiceEvidence: true, elapsedMs: 60);

    expect(gate.advance(voiceEvidence: false, elapsedMs: 100), isTrue);
    expect(gate.advance(voiceEvidence: true, elapsedMs: 20), isTrue);
    expect(gate.advance(voiceEvidence: false, elapsedMs: 100), isTrue);
  });

  test('sustained quiet eventually releases', () {
    final gate = build();
    gate.advance(voiceEvidence: true, elapsedMs: 60);

    expect(gate.advance(voiceEvidence: false, elapsedMs: 120), isTrue);
    expect(gate.advance(voiceEvidence: false, elapsedMs: 120), isFalse);
  });

  test('overlapping evidence remains active until all evidence is quiet', () {
    final gate = build();
    gate.advance(voiceEvidence: true, elapsedMs: 60);

    // The caller ORs local + remote talker evidence before the gate; repeated
    // true frames model overlap without needing speaker counts in this class.
    expect(gate.advance(voiceEvidence: true, elapsedMs: 200), isTrue);
    expect(gate.advance(voiceEvidence: false, elapsedMs: 239), isTrue);
    expect(gate.advance(voiceEvidence: false, elapsedMs: 1), isFalse);
  });

  test(
    'engine-like alternating low evidence cannot accumulate across quiet',
    () {
      final gate = build();

      for (var i = 0; i < 20; i++) {
        expect(gate.advance(voiceEvidence: true, elapsedMs: 20), isFalse);
        expect(gate.advance(voiceEvidence: false, elapsedMs: 20), isFalse);
      }
    },
  );

  test('reset clears active and banked evidence for reconnect', () {
    final gate = build();
    gate.advance(voiceEvidence: true, elapsedMs: 60);
    expect(gate.isActive, isTrue);

    gate.reset();

    expect(gate.isActive, isFalse);
    expect(gate.advance(voiceEvidence: true, elapsedMs: 20), isFalse);
  });
}
