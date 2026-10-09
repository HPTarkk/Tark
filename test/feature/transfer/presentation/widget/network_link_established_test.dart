import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';
import 'package:tark/feature/transfer/presentation/widget/network_link_established.dart';

Widget _app(
  Widget child, {
  bool reduced = false,
  double scale = 1,
  String lang = 'en',
  GlobalKey? boundary,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(fontFamily: 'Vazirmatn'),
  locale: Locale(lang),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduced,
      textScaler: TextScaler.linear(scale),
    ),
    child: child!,
  ),
  home: RepaintBoundary(
    key: boundary,
    child: Scaffold(backgroundColor: const Color(0xFF0B0E11), body: child),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fonts = FontLoader('Vazirmatn')
      ..addFont(rootBundle.load('assets/fonts/Vazirmatn-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Vazirmatn-Bold.ttf'));
    await fonts.load();
  });
  testWidgets(
    'network arrival reveals the same live state after the full beat',
    (tester) async {
      var mounts = 0, taps = 0;
      await tester.pumpWidget(
        _app(
          NetworkConnectionArrival(
            mode: TransferMode.wifi,
            roomName: 'North',
            child: _Live(onMount: () => mounts++, onTap: () => taps++),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('network-connection-success')),
        findsOneWidget,
      );
      await tester.tap(find.text('live action'), warnIfMissed: false);
      expect(taps, 0);
      await tester.pump(const Duration(milliseconds: 900));
      expect(
        find.byKey(const Key('network-connection-success')),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 210));
      expect(find.byKey(const Key('network-connection-success')), findsNothing);
      expect(mounts, 1);
      await tester.tap(find.text('live action'));
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced motion shows a settled acknowledgement and returns promptly',
    (tester) async {
      var completed = 0;
      await tester.pumpWidget(
        _app(
          NetworkLinkEstablished(hotspot: true, onComplete: () => completed++),
          reduced: true,
        ),
      );
      await tester.pump();
      expect(find.text('Your hotspot link is ready'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 460));
      expect(completed, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(completed, 1);
    },
  );

  testWidgets(
    'leaving during connection acknowledgement cancels its completion',
    (tester) async {
      var completed = 0;
      await tester.pumpWidget(
        _app(
          NetworkLinkEstablished(hotspot: false, onComplete: () => completed++),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      expect(completed, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final hotspot in [false, true]) {
    for (final lang in ['en', 'fa']) {
      testWidgets(
        '${hotspot ? 'hotspot' : 'wifi'} success fits $lang large text at 320px',
        (tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final boundary = GlobalKey();
          await tester.pumpWidget(
            _app(
              SizedBox.expand(
                child: NetworkLinkEstablished(
                  hotspot: hotspot,
                  roomName: lang == 'fa' ? 'جادهٔ شمال' : 'Northbound',
                ),
              ),
              scale: 1.5,
              lang: lang,
              boundary: boundary,
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 1000));
          await tester.pump(const Duration(milliseconds: 210));
          expect(
            find.byKey(
              ValueKey(
                hotspot ? 'hotspot-link-topology' : 'wifi-link-topology',
              ),
            ),
            findsOneWidget,
          );
          expect(
            find.text(lang == 'fa' ? 'جادهٔ شمال' : 'Northbound'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          const previewDir = String.fromEnvironment('NETWORK_PREVIEW_DIR');
          if (previewDir.isNotEmpty) {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final image = await render.toImage(pixelRatio: 2);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '$previewDir/network-${hotspot ? 'hotspot' : 'wifi'}-$lang.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}

class _Live extends StatefulWidget {
  const _Live({required this.onMount, required this.onTap});
  final VoidCallback onMount, onTap;
  @override
  State<_Live> createState() => _LiveState();
}

class _LiveState extends State<_Live> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => Center(
    child: TextButton(
      onPressed: widget.onTap,
      child: const Text('live action'),
    ),
  );
}
