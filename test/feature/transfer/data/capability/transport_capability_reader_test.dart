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

  group('carries the Room on its access point', () {
    test('when hosting and on no other Wi-Fi', () {
      expect(
        TransportCapabilityReader.carriesOnAccessPoint(
          hosting: true,
          station: null,
          peers: const [],
        ),
        isTrue,
      );
    });

    test('when also on a router but the peer is heard on the hotspot', () {
      // 2026-10-16: the host rejoined the home Wi-Fi 30 s into the call while
      // the other phone stayed on its access point.
      expect(
        TransportCapabilityReader.carriesOnAccessPoint(
          hosting: true,
          station: '192.168.8.107',
          peers: const ['10.14.189.134'],
        ),
        isTrue,
      );
    });

    test('not when the peer is heard only over the router', () {
      expect(
        TransportCapabilityReader.carriesOnAccessPoint(
          hosting: true,
          station: '192.168.8.107',
          peers: const ['192.168.8.155'],
        ),
        isFalse,
      );
      expect(
        TransportCapabilityReader.carriesOnAccessPoint(
          hosting: true,
          station: '192.168.8.107',
          peers: const [],
        ),
        isFalse,
      );
    });

    test('never when not hosting', () {
      expect(
        TransportCapabilityReader.carriesOnAccessPoint(
          hosting: false,
          station: null,
          peers: const ['10.14.189.134'],
        ),
        isFalse,
      );
    });
  });

  group('gave up on a move', () {
    tearDown(TransportCapabilityReader.clearGaveUpMove);

    test('said for a few seconds, then cleared by the next attempt', () {
      expect(TransportCapabilityReader.gaveUpMove, isFalse);
      TransportCapabilityReader.signalGaveUpMove();
      expect(TransportCapabilityReader.gaveUpMove, isTrue);
      TransportCapabilityReader.clearGaveUpMove();
      expect(TransportCapabilityReader.gaveUpMove, isFalse);
    });
  });
}
