import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/recovery/recovery_action.dart';
import 'package:tark/core/recovery/recovery_check.dart';
import 'package:tark/core/recovery/recovery_sheet.dart';

/// Set to a folder to also dump frames of the reading, for looking at the
/// motion rather than only asserting on it.
final _shots = Platform.environment['RECOVERY_SHOTS'];

final _boundary = GlobalKey();

Widget _app({
  required List<RecoveryCheck> initial,
  required Stream<List<RecoveryCheck>> checks,
  bool reduced = false,
  String lang = 'en',
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(fontFamily: 'Vazirmatn', brightness: Brightness.dark),
  locale: Locale(lang),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: RepaintBoundary(key: _boundary, child: child!),
  ),
  home: Builder(
    builder: (context) => Scaffold(
      backgroundColor: const Color(0xFF0B0E11),
      body: Center(
        child: ElevatedButton(
          key: const Key('open'),
          onPressed: () =>
              showRecoverySheet(context, initial: initial, checks: checks),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

Future<void> _run(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 16) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  final dir = _shots;
  if (dir == null) return;
  await tester.runAsync(() async {
    final boundary =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

/// Pumps frame by frame and dumps each one, for a filmstrip or a GIF.
Future<void> _film(WidgetTester tester, String name, int ms) async {
  if (_shots == null) return _run(tester, ms);
  var frame = 0;
  for (var t = 0; t < ms; t += 33) {
    await tester.pump(const Duration(milliseconds: 33));
    await _shot(tester, '$name/${'$frame'.padLeft(3, '0')}');
    frame++;
  }
}

/// A 390-wide phone, the size most people will open this sheet on.
void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

List<RecoveryCheck> _rows({
  required void Function() onAllow,
  RecoveryStatus mic = RecoveryStatus.bad,
  bool farsi = false,
}) => [
  RecoveryCheck(
    label: farsi ? 'میکروفن' : 'Microphone',
    detail: mic == RecoveryStatus.ok
        ? (farsi ? 'کار می‌کنه' : 'Working')
        : (farsi ? 'اجازه داده نشده' : "Tarkk isn't allowed to use it"),
    status: mic,
    actions: mic == RecoveryStatus.ok
        ? const []
        : [
            RecoveryAction(
              label: farsi ? 'اجازه بده' : 'ALLOW MIC',
              isPrimary: true,
              run: () async => onAllow(),
            ),
          ],
  ),
  RecoveryCheck(
    label: farsi ? 'شبکه' : 'Network',
    detail: farsi ? 'وصل' : 'Connected',
    status: RecoveryStatus.ok,
  ),
  RecoveryCheck(
    label: farsi ? 'بقیه' : 'Others in the channel',
    detail: farsi ? 'هنوز کسی نیومده' : 'Nobody else has joined yet',
    status: RecoveryStatus.warn,
  ),
  RecoveryCheck(
    label: farsi ? 'بلندگو' : 'Speaker',
    detail: farsi ? 'بلندگوی گوشی' : 'Phone speaker',
    status: RecoveryStatus.ok,
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final fonts = FontLoader('Vazirmatn')
      ..addFont(rootBundle.load('assets/fonts/Vazirmatn-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Vazirmatn-Bold.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Vazirmatn-Black.ttf'));
    await fonts.load();
    final iconsPath =
        '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter'}'
        '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
    if (File(iconsPath).existsSync()) {
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(ByteData.sublistView(File(iconsPath).readAsBytesSync())),
        );
      await icons.load();
    }
  });

  testWidgets('reads the rows in order before offering any fix', (
    tester,
  ) async {
    _phone(tester);
    var allowed = 0;
    await tester.pumpWidget(
      _app(
        initial: _rows(onAllow: () => allowed++),
        checks: const Stream<List<RecoveryCheck>>.empty(),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pump();
    await _film(tester, 'en-open', 300);
    await _shot(tester, 'en-1-scanning');

    // Mid-reading: the fix is laid out but cannot be pressed yet — a fix
    // offered before its problem is shown is a fix for nothing.
    await tester.tap(find.text('ALLOW MIC'), warnIfMissed: false);
    await tester.pump();
    expect(allowed, 0);

    await _film(tester, 'en-read', 1400);
    await tester.pumpAndSettle();
    await _shot(tester, 'en-2-read');

    expect(find.text("Sort out whatever's red below."), findsOneWidget);
    // Two of the four need a look: the refused mic and the empty channel.
    expect(find.text('2 / 4'), findsOneWidget);

    await tester.tap(find.text('ALLOW MIC'));
    await tester.pumpAndSettle();
    expect(allowed, 1);
  });

  testWidgets('counts the problems up as the line finds them', (tester) async {
    await tester.pumpWidget(
      _app(
        initial: _rows(onAllow: () {}),
        checks: const Stream<List<RecoveryCheck>>.empty(),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pump();
    // The sheet rises, then the line reaches the mic (row one) well before
    // the empty channel (row three).
    await _run(tester, 520);
    expect(find.text('1 / 4'), findsOneWidget);
    expect(find.text('2 / 4'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('2 / 4'), findsOneWidget);
  });

  testWidgets('a fix made while open turns the row and the verdict', (
    tester,
  ) async {
    _phone(tester);
    final haptics = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final checks = StreamController<List<RecoveryCheck>>();
    addTearDown(checks.close);
    final healthy = [
      for (final row in _rows(onAllow: () {}, mic: RecoveryStatus.ok))
        if (row.status != RecoveryStatus.warn) row,
    ];
    await tester.pumpWidget(
      _app(
        initial: [
          for (final row in _rows(onAllow: () {}))
            if (row.status != RecoveryStatus.warn) row,
        ],
        checks: checks.stream,
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);
    // Opening is not news: no buzz for the first verdict.
    expect(haptics, isEmpty);

    checks.add(healthy);
    await tester.pump();
    await _film(tester, 'en-fixed', 700);
    // The settle is the point as much as the motion: an open sheet must not
    // keep scheduling frames once the change has landed.
    await tester.pumpAndSettle();
    await _shot(tester, 'en-3-fixed');

    expect(find.text('Working'), findsOneWidget);
    expect(find.text("Tarkk isn't allowed to use it"), findsNothing);
    expect(find.textContaining('Everything checks out'), findsOneWidget);
    expect(find.text('1 / 3'), findsNothing);
    expect(find.text('ALLOW MIC'), findsNothing);
    expect(haptics, ['HapticFeedbackType.mediumImpact']);

    // And back: something breaking again pries the ring open.
    checks.add([
      for (final row in _rows(onAllow: () {}))
        if (row.status != RecoveryStatus.warn) row,
    ]);
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);
    expect(haptics.last, 'HapticFeedbackType.heavyImpact');
  });

  testWidgets('a row the stream adds later simply appears', (tester) async {
    final checks = StreamController<List<RecoveryCheck>>();
    addTearDown(checks.close);
    final initial = _rows(onAllow: () {}).take(2).toList();
    await tester.pumpWidget(_app(initial: initial, checks: checks.stream));
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    expect(find.text('Phone speaker'), findsNothing);

    checks.add(_rows(onAllow: () {}));
    await tester.pumpAndSettle();
    expect(find.text('Phone speaker'), findsOneWidget);
    expect(find.text('2 / 4'), findsOneWidget);
  });

  testWidgets('reduced motion keeps the order and drops the travel', (
    tester,
  ) async {
    _phone(tester);
    var allowed = 0;
    await tester.pumpWidget(
      _app(
        initial: _rows(onAllow: () => allowed++),
        checks: const Stream<List<RecoveryCheck>>.empty(),
        reduced: true,
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    await _shot(tester, 'en-4-reduced');

    // Nothing travels: every row sits exactly where its layout put it.
    for (final slide in tester.widgetList<SlideTransition>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(SlideTransition),
      ),
    )) {
      expect(slide.position.value, Offset.zero);
    }
    expect(find.text('2 / 4'), findsOneWidget);
    await tester.tap(find.text('ALLOW MIC'));
    await tester.pumpAndSettle();
    expect(allowed, 1);
  });

  testWidgets('reads right to left in Persian', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        initial: _rows(onAllow: () {}, farsi: true),
        checks: const Stream<List<RecoveryCheck>>.empty(),
        lang: 'fa',
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pump();
    await _film(tester, 'fa-read', 1700);
    await tester.pumpAndSettle();
    await _shot(tester, 'fa-1-read');
    expect(find.text('۲ / ۴'), findsOneWidget);
  });
}
