import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/profile/local_profile.dart';
import 'package:tark/core/settings/settings_keys.dart';
import 'package:tark/core/theme/theme_service.dart';
import 'package:tark/feature/report/presentation/widget/avatar_images.dart';
import 'package:tark/feature/walkie/presentation/widget/usage_tips_scene_painter.dart';
import 'package:tark/feature/walkie/presentation/widget/usage_tips_sheet.dart';

/// Set `TIPS_SHOTS=<dir>` to write the story's frames out as PNGs, and
/// `TIPS_FRAMES=1` as well for every frame (for a GIF).
final _shots = Platform.environment['TIPS_SHOTS'];
final _everyFrame = Platform.environment['TIPS_FRAMES'] == '1';

final _boundary = GlobalKey();

Widget _app({
  bool reduced = false,
  String lang = 'en',
  Brightness brightness = Brightness.dark,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(fontFamily: 'Vazirmatn', brightness: brightness),
  locale: Locale(lang),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(disableAnimations: reduced, size: const Size(390, 844)),
    child: RepaintBoundary(key: _boundary, child: child!),
  ),
  home: Scaffold(
    backgroundColor: brightness == Brightness.dark
        ? const Color(0xFF0B0E11)
        : const Color(0xFFF4F1EC),
    body: Builder(
      builder: (context) => Center(
        child: TextButton(
          key: const Key('open'),
          onPressed: () => showUsageTipsSheet(context),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

var _frameNo = 0;
String? _reel;

/// Advances [ms] milliseconds as real frames, so springs and loops run.
Future<void> _run(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 16) {
    await tester.pump(const Duration(milliseconds: 16));
    if (_everyFrame && _reel != null && t % 48 == 0) {
      await _shot(tester, '$_reel/f${(_frameNo++).toString().padLeft(4, '0')}');
    }
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  final dir = _shots;
  if (dir == null) return;
  await tester.runAsync(() async {
    final boundary =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: _everyFrame ? 1 : 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<void> _open(
  WidgetTester tester, {
  bool reduced = false,
  String lang = 'en',
  Brightness brightness = Brightness.dark,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _app(reduced: reduced, lang: lang, brightness: brightness),
  );
  await tester.tap(find.byKey(const Key('open')));
  await tester.pump();
  // The sheet's own rise.
  await _run(tester, 500);
}

UsageTipsFrame _frame(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(
    find.byKey(const Key('usage-tips-scene')),
  );
  return (paint.painter! as UsageTipsScenePainter).frame;
}

Finder get _sheet => find.byType(UsageTipsSheet);

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
    // Decoded for real here, outside the widget tests' fake clock.
    LocalProfile.avatarId = 3;
    await AvatarImages.load(3);
  });
  tearDownAll(() => LocalProfile.avatarId = null);

  testWidgets('tells all four tips with Next, then Got it closes the sheet', (
    tester,
  ) async {
    _reel = 'reel-en';
    _frameNo = 0;
    await _open(tester);
    await _shot(tester, 'en-0-intro');

    // You pop in, then the headset drops on.
    await _run(tester, 2600);
    var frame = _frame(tester);
    expect(frame.youIn, closeTo(1, 0.01));
    expect(frame.tip, 0);
    expect(frame.arrive, 1);
    expect(find.text('Wear a headset that blocks out noise'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    await _shot(tester, 'en-1-headset');

    final titles = [
      'Always wear a proper helmet',
      'You never have to press anything to talk',
      'Keep the channel on your home screen',
    ];
    for (var i = 0; i < titles.length; i++) {
      await tester.tap(find.byKey(const Key('usage-tips-advance')));
      await _run(tester, 700);
      frame = _frame(tester);
      expect(frame.tip, i + 1, reason: 'settles on tip ${i + 1}');
      expect(frame.page, closeTo(i + 1.0, 0.001));
      await _run(tester, 2000);
      expect(_frame(tester).arrive, 1);
      await _shot(tester, 'en-${i + 2}-${UsageTip.values[i + 1].name}');
      expect(find.text(titles[i]), findsOneWidget);
    }

    // The last tip: the button says Got it, and the quiet Skip has gone.
    expect(find.text('Got it'), findsOneWidget);
    final skip = tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: find.byKey(const Key('usage-tips-skip')),
        matching: find.byType(AnimatedOpacity),
      ),
    );
    expect(skip.opacity, 0);

    await tester.tap(find.byKey(const Key('usage-tips-advance')));
    await _run(tester, 600);
    expect(_sheet, findsNothing);
    _reel = null;
  });

  testWidgets('the scene follows a swipe, both ways', (tester) async {
    await _open(tester);
    await _run(tester, 2600);

    // Mid-drag: between the first two tips, nothing settled yet.
    final pager = find.byKey(const Key('usage-tips-pager'));
    final gesture = await tester.startGesture(tester.getCenter(pager));
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump(const Duration(milliseconds: 16));
    var frame = _frame(tester);
    expect(frame.page, greaterThan(0.1));
    expect(frame.page, lessThan(0.9));
    expect(frame.tip, 0);
    await _shot(tester, 'en-swipe-mid');
    await gesture.moveBy(const Offset(-120, 0));
    await gesture.up();
    await _run(tester, 900);
    frame = _frame(tester);
    expect(frame.tip, 1);
    expect(find.text('Always wear a proper helmet'), findsOneWidget);

    await tester.fling(pager, const Offset(300, 0), 1200);
    await _run(tester, 900);
    expect(_frame(tester).tip, 0);
  });

  testWidgets('tapping a page dot tunes straight to that tip', (tester) async {
    await _open(tester);
    await _run(tester, 1200);
    final dots = find.byKey(const Key('usage-tips-dots'));
    final box = tester.getRect(dots);
    // The fourth tick, from the reading start (left in English).
    final x = box.center.dx + 1.5 * 24;
    await tester.tapAt(Offset(x, box.center.dy));
    await _run(tester, 900);
    expect(_frame(tester).tip, 3);
    expect(find.text('Got it'), findsOneWidget);
  });

  testWidgets('Skip closes the sheet from the first tip', (tester) async {
    await _open(tester);
    await _run(tester, 400);
    await tester.tap(find.byKey(const Key('usage-tips-skip')));
    await _run(tester, 600);
    expect(_sheet, findsNothing);
  });

  testWidgets('tapping you makes you jump', (tester) async {
    await _open(tester);
    await _run(tester, 2600);
    final scene = find.byKey(const Key('usage-tips-scene'));
    final rect = tester.getRect(scene);
    final scale = rect.width / UsageTipsScenePainter.stage.width;
    await tester.tapAt(rect.topLeft + UsageTipsScenePainter.youAtLtr * scale);
    await _run(tester, 200);
    expect(_frame(tester).hop, greaterThan(0));
    await _shot(tester, 'en-hop');
    await _run(tester, 800);
    expect(_frame(tester).hop, 0);
  });

  testWidgets('reduced motion: every tip in place, nothing looping', (
    tester,
  ) async {
    await _open(tester, reduced: true);
    // Nothing loops forever under reduced motion, so the sheet can settle.
    await tester.pumpAndSettle();
    var frame = _frame(tester);
    expect(frame.youIn, 1);
    expect(frame.arrive, 1);
    expect(frame.ambient, 0.25);
    await _shot(tester, 'en-reduced');

    await tester.tap(find.byKey(const Key('usage-tips-advance')));
    await tester.pumpAndSettle();
    frame = _frame(tester);
    expect(frame.tip, 1);
    expect(frame.arrive, 1);

    // A tap on you does nothing: no travel.
    final scene = find.byKey(const Key('usage-tips-scene'));
    final rect = tester.getRect(scene);
    final scale = rect.width / UsageTipsScenePainter.stage.width;
    await tester.tapAt(rect.topLeft + UsageTipsScenePainter.youAtLtr * scale);
    await tester.pump();
    expect(_frame(tester).hop, 0);
  });

  testWidgets('Persian: mirrored stage, Persian copy, swipe the other way', (
    tester,
  ) async {
    _reel = 'reel-fa';
    _frameNo = 0;
    await _open(tester, lang: 'fa');
    await _run(tester, 2600);
    expect(_frame(tester).rtl, isTrue);
    expect(find.text('هدفونی بزن که صدای اطراف رو کم می‌کنه'), findsOneWidget);
    expect(find.text('بعدی'), findsOneWidget);
    expect(find.text('رد کردن'), findsOneWidget);
    await _shot(tester, 'fa-1-headset');

    // Forward is toward the left in Persian.
    final pager = find.byKey(const Key('usage-tips-pager'));
    await tester.fling(pager, const Offset(300, 0), 1200);
    await _run(tester, 2800);
    expect(_frame(tester).tip, 1);
    await _shot(tester, 'fa-2-helmet');

    for (var i = 2; i < 4; i++) {
      await tester.tap(find.byKey(const Key('usage-tips-advance')));
      await _run(tester, 2800);
      await _shot(tester, 'fa-${i + 1}-${UsageTip.values[i].name}');
    }
    expect(find.text('فهمیدم'), findsOneWidget);
    _reel = null;
  });

  testWidgets('light theme renders the same story', (tester) async {
    SharedPreferences.setMockInitialValues({SettingsKeys.appTheme: 'light'});
    ThemeService.initialize(await SharedPreferences.getInstance());
    addTearDown(() {
      SharedPreferences.setMockInitialValues({});
      return SharedPreferences.getInstance().then(ThemeService.initialize);
    });
    await _open(tester, brightness: Brightness.light);
    await _run(tester, 2600);
    await _shot(tester, 'en-light-headset');
    expect(_frame(tester).arrive, 1);
  });
}
