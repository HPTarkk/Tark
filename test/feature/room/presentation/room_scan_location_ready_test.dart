import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tark/feature/room/presentation/room_bluetooth_permissions.dart';

void main() {
  Future<bool> ready({
    TargetPlatform platform = TargetPlatform.android,
    required int sdk,
    ServiceStatus location = ServiceStatus.enabled,
  }) => roomScanLocationReady(
    platform: platform,
    sdkVersion: () async => sdk,
    locationService: () async => location,
  );

  test('Android 6-11 with Location off cannot scan', () async {
    expect(await ready(sdk: 30, location: ServiceStatus.disabled), isFalse);
    expect(await ready(sdk: 24, location: ServiceStatus.disabled), isFalse);
  });

  test('Android 6-11 with Location on can scan', () async {
    expect(await ready(sdk: 30), isTrue);
  });

  test('Android 12+ does not need Location for the scan', () async {
    expect(await ready(sdk: 31, location: ServiceStatus.disabled), isTrue);
  });

  test('an unreadable state lets the scan speak for itself', () async {
    expect(
      await roomScanLocationReady(
        platform: TargetPlatform.android,
        sdkVersion: () async => throw StateError('no channel'),
      ),
      isTrue,
    );
  });

  test('iOS is never asked', () async {
    expect(
      await ready(
        platform: TargetPlatform.iOS,
        sdk: 0,
        location: ServiceStatus.disabled,
      ),
      isTrue,
    );
  });
}
