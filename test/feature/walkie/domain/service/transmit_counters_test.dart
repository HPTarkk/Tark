import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/walkie/domain/service/transmit_counters.dart';

void main() {
  final t0 = DateTime.utc(2026, 9, 25, 12);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  TransmitCounters started() {
    final c = TransmitCounters();
    // The first window starts at the epoch; taking it opens a real one.
    c.takeWindow(t0);
    return c;
  }

  test('reports the counts once the window is long enough', () {
    final c = started()
      ..frameSeen()
      ..frameSeen()
      ..frameSeen()
      ..frameSent()
      ..frameGated()
      ..frameGated()
      ..prerollFlushed(4);
    expect(c.takeWindow(at(14)), isNull);
    expect(
      c.takeWindow(at(15)),
      '15s window — frames=3 sent=1 gated=2 preroll=4/1bursts',
    );
    // And starts over.
    c.frameSeen();
    expect(
      c.takeWindow(at(30)),
      '15s window — frames=1 sent=0 gated=0 preroll=0/0bursts',
    );
  });

  test('says nothing for a window with no frames', () {
    final c = started();
    expect(c.takeWindow(at(20)), isNull);
  });

  test('drops a window longer than a minute, and its counts', () {
    final c = started()..frameSeen();
    expect(c.takeWindow(at(61)), isNull);
    c.frameSeen();
    expect(
      c.takeWindow(at(76)),
      '15s window — frames=1 sent=0 gated=0 preroll=0/0bursts',
    );
  });
}
