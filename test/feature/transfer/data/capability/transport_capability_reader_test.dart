import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/capability/transport_capability_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  group('the advertised hosting preference', () {
    const channel = MethodChannel('tark/transport_capabilities');
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => <String, Object?>{
              'canHostHotspot': true,
              'bluetoothSupported': true,
              'backgroundReady': false,
              'batteryPercent': 64,
            },
          );
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TransportCapabilityReader.hostingPreference = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('the heartbeat sends the answer this phone votes with', () async {
      TransportCapabilityReader.hostingPreference = () async => true;
      final sent = await TransportCapabilityReader.current();
      expect(sent?.prefersHotspotHost, isTrue);
    });

    test('an explicit answer still wins', () async {
      TransportCapabilityReader.hostingPreference = () async => true;
      final sent = await TransportCapabilityReader.current(
        prefersHotspotHost: false,
      );
      expect(sent?.prefersHotspotHost, isFalse);
    });

    test('a preference that cannot be read is a no', () async {
      TransportCapabilityReader.hostingPreference = () async =>
          throw StateError('no radio');
      final sent = await TransportCapabilityReader.current();
      expect(sent?.prefersHotspotHost, isFalse);
    });
  });
}
