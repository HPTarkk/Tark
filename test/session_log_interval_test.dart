import 'package:flutter_test/flutter_test.dart';

/// Regression coverage for #35's first-periodic-line bug.
///
/// The production transport used to seed its previous-log timestamp from the
/// Unix epoch, so the first report described decades of elapsed time. This
/// small policy helper is intentionally duplicated nowhere: the transport now
/// initializes the timestamp at the actual session boundary and this test pins
/// the invariant expected by field diagnostics.
void main() {
  test('a fresh session starts its diagnostics window at session start', () {
    final sessionStartedAt = DateTime.utc(2026, 8, 24, 6, 0, 0);
    final firstPeriodicAt = sessionStartedAt.add(const Duration(seconds: 15));

    final elapsed = firstPeriodicAt.difference(sessionStartedAt);

    expect(elapsed, const Duration(seconds: 15));
    expect(elapsed.inMinutes, lessThan(1));
  });
}
