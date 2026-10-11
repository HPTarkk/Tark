import 'dart:convert';

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
    // The stable radio tag is decoded into the current display brand.
    expect(encodeHostName('Tarkk'), 'Tark');
    expect(decodeHostName(encodeHostName('')), 'Tarkk');
    expect(isTarkHostName('Tarkk'), isTrue);
    expect(decodeHostName('Tarkk'), 'Tarkk');
  });

  test('unrelated devices in the scan are not mistaken for hosts', () {
    for (final name in ['SM-A525F', 'JBL Flip 5', 'Tarkan', "Ali's Buds"]) {
      expect(isTarkHostName(name), isFalse, reason: name);
      // …and their names are shown exactly as broadcast.
      expect(decodeHostName(name), name);
    }
  });

  test('older Tark host labels are still discoverable and readable', () {
    expect(isTarkHostName('Tark'), isTrue);
    expect(isTarkHostName('Tark · Pedram'), isTrue);
    expect(decodeHostName('Tark'), 'Tarkk');
    expect(decodeHostName('Tark · Pedram'), 'Pedram');
    expect(decodeHostName('Tark · '), 'Tarkk');
    expect(encodeHostName('Tark'), 'Tark');
  });

  test('new spelling is readable without breaking older classic scanners', () {
    expect(isTarkHostName('Tarkk · Pedram'), isTrue);
    expect(decodeHostName('Tarkk · Pedram'), 'Pedram');
    expect(decodeHostName('Tarkk · '), 'Tarkk');
    // This predicate is the exact discovery rule used by previous builds.
    for (final name in ['', 'Tarkk', 'Pedram', 'پدرام']) {
      final wireName = encodeHostName(name);
      expect(wireName == 'Tark' || wireName.startsWith('Tark · '), isTrue);
    }
  });

  test('a name that itself looks like the tag survives the round-trip', () {
    final encoded = encodeHostName('Tarkk · Pedram');
    expect(decodeHostName(encoded), 'Tarkk · Pedram');
  });

  group('broadcast name fits the radio', () {
    // Android rejects the whole advertisement if the name overflows the scan
    // response, and the host then advertises anonymously — so a long name has
    // to be abbreviated here rather than dropped out there.
    test('a normal name is broadcast whole', () {
      expect(encodeHostName('Pedram'), 'Tark · Pedram');
      expect(
        utf8.encode(encodeHostName('Pedram')).length,
        lessThan(kMaxHostNameBytes),
      );
    });

    test('Persian names are broadcast whole and read back intact', () {
      const name = 'پدرام';
      final encoded = encodeHostName(name);
      expect(decodeHostName(encoded), name);
      expect(isTarkHostName(encoded), isTrue);
    });

    test('an over-long name is cut to the byte budget, not dropped', () {
      for (final name in [
        'Pedram with a really rather long display name',
        // Persian letters cost two bytes each, so this overflows far sooner
        // than its character count suggests.
        'پدرام با یک اسم نمایشی خیلی خیلی طولانی',
      ]) {
        final encoded = encodeHostName(name);
        expect(
          utf8.encode(encoded).length,
          lessThanOrEqualTo(kMaxHostNameBytes),
          reason: name,
        );
        // Still recognisable as a host, and still shows a readable prefix of
        // the name rather than a mojibake tail.
        expect(isTarkHostName(encoded), isTrue, reason: name);
        expect(decodeHostName(encoded), isNotEmpty, reason: name);
        expect(encoded, isNot(contains('�')), reason: name);
        expect(name, startsWith(decodeHostName(encoded)));
      }
    });
  });
}
