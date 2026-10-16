import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/codec/transport_capability_advertisement_wire.dart';
import 'package:tark/feature/transfer/domain/entity/transport_capability_advertisement.dart';

void main() {
  const value = TransportCapabilityAdvertisement(
    canHostHotspot: true,
    bluetoothSupported: true,
    backgroundReady: false,
    batteryPercent: 73,
    prefersHotspotHost: true,
  );

  test('round trips bounded transport capability evidence', () {
    final encoded = TransportCapabilityAdvertisementWire.encode(value);

    expect(encoded, hasLength(4));
    expect(TransportCapabilityAdvertisementWire.decode(encoded, 0), value);
  });

  test('the hosting flag round trips, and is clear unless hosting', () {
    const hosting = TransportCapabilityAdvertisement(
      canHostHotspot: true,
      bluetoothSupported: true,
      backgroundReady: true,
      batteryPercent: 50,
      hostingAccessPoint: true,
    );
    final encoded = TransportCapabilityAdvertisementWire.encode(hosting);
    expect(TransportCapabilityAdvertisementWire.decode(encoded, 0), hosting);
    // Older builds reject unknown flags, so a phone that is not hosting must
    // send exactly the bytes it always did.
    expect(TransportCapabilityAdvertisementWire.encode(value)[2] & 0x10, 0);
  });

  test('the gave-up flag round trips, and is clear unless set', () {
    const gaveUp = TransportCapabilityAdvertisement(
      canHostHotspot: true,
      bluetoothSupported: true,
      backgroundReady: true,
      batteryPercent: 50,
      gaveUpMove: true,
    );
    final encoded = TransportCapabilityAdvertisementWire.encode(gaveUp);
    expect(encoded[2] & 0x20, 0x20);
    expect(TransportCapabilityAdvertisementWire.decode(encoded, 0), gaveUp);
    expect(TransportCapabilityAdvertisementWire.encode(value)[2] & 0x20, 0);
  });

  test('decodes from a trailing offset without consuming earlier bytes', () {
    final trailer = TransportCapabilityAdvertisementWire.encode(value);
    final packet = Uint8List.fromList([1, 2, 3, ...trailer, 99]);

    expect(TransportCapabilityAdvertisementWire.decode(packet, 3), value);
  });

  test('absence and every truncated trailer fail closed to unknown', () {
    final encoded = TransportCapabilityAdvertisementWire.encode(value);

    expect(
      TransportCapabilityAdvertisementWire.decode(Uint8List(0), 0),
      isNull,
    );
    for (var length = 0; length < encoded.length; length++) {
      expect(
        TransportCapabilityAdvertisementWire.decode(
          Uint8List.fromList(encoded.sublist(0, length)),
          0,
        ),
        isNull,
      );
    }
  });

  test('unknown marker or version fails closed', () {
    final encoded = TransportCapabilityAdvertisementWire.encode(value);

    final marker = Uint8List.fromList(encoded)..[0] = 0x7f;
    final version = Uint8List.fromList(encoded)..[1] = 2;

    expect(TransportCapabilityAdvertisementWire.decode(marker, 0), isNull);
    expect(TransportCapabilityAdvertisementWire.decode(version, 0), isNull);
  });

  test('unknown flag bits and invalid battery fail closed', () {
    final encoded = TransportCapabilityAdvertisementWire.encode(value);

    final flags = Uint8List.fromList(encoded)..[2] |= 0x80;
    final battery = Uint8List.fromList(encoded)..[3] = 101;

    expect(TransportCapabilityAdvertisementWire.decode(flags, 0), isNull);
    expect(TransportCapabilityAdvertisementWire.decode(battery, 0), isNull);
  });
}
