import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_host_name.dart';

void main() {
  test('a display name round-trips through the broadcast name', () {
    expect(encodeHostName('Pedram'), 'Tark · Pedram');
    expect(isTarkHostName(encodeHostName('Pedram')), isTrue);
    expect(decodeHostName(encodeHostName('Pedram')), 'Pedram');
  });

  test('a nameless host broadcasts the bare brand and reads back as one', () {
    expect(encodeHostName(''), 'Tark');
    expect(encodeHostName('   '), 'Tark');
    // Already the brand — no doubling into "Tark · Tark".
    expect(encodeHostName('Tark'), 'Tark');
    expect(isTarkHostName('Tark'), isTrue);
    expect(decodeHostName('Tark'), 'Tark');
  });

  test('unrelated devices in the scan are not mistaken for hosts', () {
    for (final name in ['SM-A525F', 'JBL Flip 5', 'Tarkan', "Ali's Buds"]) {
      expect(isTarkHostName(name), isFalse, reason: name);
      // …and their names are shown exactly as broadcast.
      expect(decodeHostName(name), name);
    }
  });

  test('a name that itself looks like the tag survives the round-trip', () {
    final encoded = encodeHostName('Tark · Pedram');
    expect(decodeHostName(encoded), 'Tark · Pedram');
  });
}
