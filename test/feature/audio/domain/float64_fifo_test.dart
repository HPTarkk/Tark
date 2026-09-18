import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/domain/float64_fifo.dart';

void main() {
  test('preserves FIFO order across add and take', () {
    final fifo = Float64Fifo(4);
    fifo.addAll([1.0, 2.0, 3.0]);
    expect(fifo.length, 3);
    expect(fifo.takeFirst(2), [1.0, 2.0]);
    expect(fifo.length, 1);
    expect(fifo.takeFirst(1), [3.0]);
    expect(fifo.isEmpty, isTrue);
  });

  test('wraps around the ring without corrupting order', () {
    final fifo = Float64Fifo(4); // capacity 4
    fifo.addAll([1.0, 2.0, 3.0]);
    fifo.discardFirst(2); // head now mid-buffer
    fifo.addAll([4.0, 5.0, 6.0]); // writes wrap past the end
    expect(fifo.takeFirst(4), [3.0, 4.0, 5.0, 6.0]);
  });

  test('grows past initial capacity, including from a wrapped state', () {
    final fifo = Float64Fifo(4);
    fifo.addAll([1.0, 2.0, 3.0, 4.0]);
    fifo.discardFirst(3);
    fifo.addAll(List<double>.generate(100, (i) => i.toDouble()));
    expect(fifo.length, 101);
    expect(fifo[0], 4.0);
    expect(fifo[1], 0.0);
    expect(fifo[100], 99.0);
    final out = fifo.takeFirst(101);
    expect(out.first, 4.0);
    expect(out.last, 99.0);
    expect(fifo.isEmpty, isTrue);
  });

  test('addZeros appends silence', () {
    final fifo = Float64Fifo(4);
    fifo.addAll([1.0]);
    fifo.addZeros(3);
    expect(fifo.takeFirst(4), [1.0, 0.0, 0.0, 0.0]);
  });

  test('indexed reads see the logical order', () {
    final fifo = Float64Fifo(4);
    fifo.addAll([1.0, 2.0, 3.0, 4.0]);
    fifo.discardFirst(2);
    fifo.addAll([5.0, 6.0]); // wrapped
    for (var i = 0; i < fifo.length; i++) {
      expect(fifo[i], (i + 3).toDouble());
    }
  });

  test('clear empties without breaking subsequent use', () {
    final fifo = Float64Fifo(4);
    fifo.addAll([1.0, 2.0, 3.0]);
    fifo.clear();
    expect(fifo.isEmpty, isTrue);
    fifo.addAll([7.0, 8.0]);
    expect(fifo.takeFirst(2), [7.0, 8.0]);
  });
}
