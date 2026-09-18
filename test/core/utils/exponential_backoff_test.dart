import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/utils/exponential_backoff.dart';

void main() {
  test('first delay is the initial, then doubles', () {
    final b = ExponentialBackoff(
      initial: const Duration(seconds: 4),
      factor: 2,
      max: const Duration(seconds: 64),
    );
    expect(b.next(), const Duration(seconds: 4));
    expect(b.next(), const Duration(seconds: 8));
    expect(b.next(), const Duration(seconds: 16));
    expect(b.next(), const Duration(seconds: 32));
  });

  test('caps at max and stays there', () {
    final b = ExponentialBackoff(
      initial: const Duration(seconds: 4),
      factor: 2,
      max: const Duration(seconds: 64),
    );
    // 4, 8, 16, 32, 64, then clamped.
    final seen = [for (var i = 0; i < 7; i++) b.next().inSeconds];
    expect(seen, [4, 8, 16, 32, 64, 64, 64]);
  });

  test('reset returns to the initial delay', () {
    final b = ExponentialBackoff(initial: const Duration(seconds: 4));
    b.next();
    b.next();
    b.next();
    b.reset();
    expect(b.next(), const Duration(seconds: 4));
    expect(b.next(), const Duration(seconds: 8));
  });

  test('peek does not advance', () {
    final b = ExponentialBackoff(initial: const Duration(seconds: 4));
    expect(b.peek(), const Duration(seconds: 4));
    expect(b.peek(), const Duration(seconds: 4));
    expect(b.next(), const Duration(seconds: 4));
    expect(b.peek(), const Duration(seconds: 8));
  });
}
