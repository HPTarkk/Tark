import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/utils/fallback_display_name.dart';

/// The old default name was `User<last octet of the device's IP>` — an
/// address fragment that travelled to every peer's roster with every packet.
void main() {
  test('carries no piece of the address it was built from', () {
    const ip = '192.168.1.104';
    final name = fallbackDisplayName('Buddy', ip);

    expect(name, isNot(contains('104')));
    expect(name, isNot(contains('192')));
    expect(name, startsWith('Buddy'));
  });

  test('is stable for one device, so a peer is not renamed between sessions', () {
    expect(
      fallbackDisplayName('Buddy', '192.168.1.104'),
      fallbackDisplayName('Buddy', '192.168.1.104'),
    );
  });

  test('tells two unnamed people in a channel apart', () {
    final a = fallbackDisplayName('Buddy', '192.168.1.104');
    final b = fallbackDisplayName('Buddy', '192.168.1.105');
    expect(a, isNot(b));
  });

  test('works for a Bluetooth peer id too, not just an IP', () {
    final name = fallbackDisplayName('Buddy', '34:2D:0D:59:E1:B2');
    expect(name, startsWith('Buddy '));
    expect(name, isNot(contains(':')));
  });

  test('a device with no id yet is just the label', () {
    expect(fallbackDisplayName('Buddy', ''), 'Buddy');
  });

  test('the label is whatever the UI language uses', () {
    expect(fallbackDisplayName('رفیق', '192.168.1.104'), startsWith('رفیق '));
  });

  group('localizedFallbackDisplayName', () {
    test('uses the language the UI is running in', () {
      expect(localizedFallbackDisplayName('en', '192.168.1.104'), startsWith('Buddy'));
      expect(localizedFallbackDisplayName('fa', '192.168.1.104'), startsWith('رفیق'));
    });

    test('falls back to the default language instead of throwing', () {
      expect(
        localizedFallbackDisplayName('de', '192.168.1.104'),
        localizedFallbackDisplayName('fa', '192.168.1.104'),
      );
    });
  });
}
