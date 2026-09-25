import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/walkie/domain/service/music_cast_watch.dart';

void main() {
  final t0 = DateTime.utc(2026, 9, 25, 12);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));
  const quiet = 0.0;
  const loud = MusicCastWatch.audibleLevel;

  test('suspects a block only after eight silent seconds', () {
    final w = MusicCastWatch()..started(t0);
    w.noteChunk(quiet, at(1));
    expect(w.shouldSuspectBlocked(at(7)), isFalse);
    expect(w.shouldSuspectBlocked(at(8)), isTrue);
  });

  test('a cast that was ever audible is never the blocked case', () {
    final w = MusicCastWatch()..started(t0);
    w.noteChunk(loud, at(1));
    w.noteChunk(quiet, at(2));
    expect(w.everAudible, isTrue);
    expect(w.shouldSuspectBlocked(at(60)), isFalse);
  });

  test('says it once per cast, and a new cast starts clean', () {
    final w = MusicCastWatch()..started(t0);
    expect(w.shouldSuspectBlocked(at(8)), isTrue);
    w.markBlockedReported();
    expect(w.shouldSuspectBlocked(at(20)), isFalse);

    w
      ..stopped()
      ..started(at(30));
    expect(w.shouldSuspectBlocked(at(37)), isFalse);
    expect(w.shouldSuspectBlocked(at(38)), isTrue);
  });

  test('nothing to suspect when no cast is running', () {
    final w = MusicCastWatch();
    expect(w.shouldSuspectBlocked(at(60)), isFalse);
  });

  test('counters are reported only when one moves', () {
    final w = MusicCastWatch();
    expect(w.countersMoved(dropouts: 0, trims: 0, floods: 0), isFalse);
    expect(w.countersMoved(dropouts: 1, trims: 0, floods: 0), isTrue);
    expect(w.countersMoved(dropouts: 1, trims: 0, floods: 0), isFalse);
    expect(w.countersMoved(dropouts: 1, trims: 0, floods: 2), isTrue);
  });
}
