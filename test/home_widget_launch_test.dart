import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/home_widget/home_widget_launch.dart';

void main() {
  group('HomeWidgetLaunch.parse', () {
    test('reads the intent and nonce out of a widget URI', () {
      final launch = HomeWidgetLaunch.parse(Uri.parse('tark://widget/goLive?n=1700000000000'));
      expect(launch, isNotNull);
      expect(launch!.intent, HomeWidgetIntent.goLive);
      expect(launch.nonce, '1700000000000');
    });

    test('accepts every intent the widgets can fire', () {
      for (final intent in HomeWidgetIntent.values) {
        final uri = Uri.parse(HomeWidgetLaunch.uriFor(intent, '42'));
        expect(HomeWidgetLaunch.parse(uri)?.intent, intent, reason: intent.name);
      }
    });

    test("tolerates iOS's extra homeWidget marker query item", () {
      // The plugin's iOS side only treats a URL as a widget launch when it
      // carries this, so the real URIs always have it (see TarkWidget.swift).
      final launch = HomeWidgetLaunch.parse(
        Uri.parse('tark://widget/goLive?n=99&homeWidget=true'),
      );
      expect(launch?.intent, HomeWidgetIntent.goLive);
      expect(launch?.nonce, '99');
    });

    test('rejects anything that is not a widget tap', () {
      // A nonce-less URI is the important one: without it there is nothing to
      // consume, so the sticky Android launch intent would replay forever and
      // goLive would reopen the mic on every cold start.
      expect(HomeWidgetLaunch.parse(Uri.parse('tark://widget/goLive')), isNull);
      expect(HomeWidgetLaunch.parse(Uri.parse('tark://widget/goLive?n=')), isNull);
      expect(HomeWidgetLaunch.parse(null), isNull);
      expect(HomeWidgetLaunch.parse(Uri.parse('https://widget/goLive?n=1')), isNull);
      expect(HomeWidgetLaunch.parse(Uri.parse('tark://other/goLive?n=1')), isNull);
      expect(HomeWidgetLaunch.parse(Uri.parse('tark://widget/nonsense?n=1')), isNull);
      expect(HomeWidgetLaunch.parse(Uri.parse('tark://widget?n=1')), isNull);
    });

    test('round-trips the URI format the native widgets build by hand', () {
      expect(
        HomeWidgetLaunch.uriFor(HomeWidgetIntent.goLive, '1700000000000'),
        'tark://widget/goLive?n=1700000000000',
      );
      expect(
        HomeWidgetLaunch.uriFor(HomeWidgetIntent.setup, '7'),
        'tark://widget/setup?n=7',
      );
    });
  });
}
