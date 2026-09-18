import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/capability/transport_capability_reader.dart';

void main() {
  test('decodes complete proven capability snapshot', () {
    final value = TransportCapabilityReader.decodeSnapshot(<Object?, Object?>{
      'canHostHotspot': true,
      'bluetoothSupported': true,
      'backgroundReady': true,
      'batteryPercent': 73,
    }, prefersHotspotHost: true);

    expect(value, isNotNull);
    expect(value!.canHostHotspot, isTrue);
    expect(value.bluetoothSupported, isTrue);
    expect(value.backgroundReady, isTrue);
    expect(value.batteryPercent, 73);
    expect(value.prefersHotspotHost, isTrue);
  });

  test('missing or malformed evidence fails closed', () {
    expect(TransportCapabilityReader.decodeSnapshot(null), isNull);
    expect(
      TransportCapabilityReader.decodeSnapshot(<Object?, Object?>{
        'canHostHotspot': true,
        'bluetoothSupported': true,
        'backgroundReady': true,
      }),
      isNull,
    );
    expect(
      TransportCapabilityReader.decodeSnapshot(<Object?, Object?>{
        'canHostHotspot': true,
        'bluetoothSupported': true,
        'backgroundReady': 'yes',
        'batteryPercent': 50,
      }),
      isNull,
    );
    expect(
      TransportCapabilityReader.decodeSnapshot(<Object?, Object?>{
        'canHostHotspot': true,
        'bluetoothSupported': true,
        'backgroundReady': true,
        'batteryPercent': 101,
      }),
      isNull,
    );
  });

  test('preference is policy input, never supplied by platform snapshot', () {
    final raw = <Object?, Object?>{
      'canHostHotspot': true,
      'bluetoothSupported': false,
      'backgroundReady': true,
      'batteryPercent': 45,
      'prefersHotspotHost': true,
    };

    final withoutPreference = TransportCapabilityReader.decodeSnapshot(raw);
    final withPreference = TransportCapabilityReader.decodeSnapshot(
      raw,
      prefersHotspotHost: true,
    );

    expect(withoutPreference?.prefersHotspotHost, isFalse);
    expect(withPreference?.prefersHotspotHost, isTrue);
  });
}
