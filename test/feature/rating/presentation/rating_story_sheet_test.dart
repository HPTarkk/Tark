import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/motion/app_motion.dart';
import 'package:tark/core/widget/sheet_shell.dart';
import 'package:tark/core/profile/local_profile.dart';
import 'package:tark/feature/rating/api/rating_api.dart';
import 'package:tark/feature/rating/data/bazaar_review_launcher.dart';
import 'package:tark/feature/report/presentation/widget/avatar_images.dart';

/// Set `RATING_SHOTS=<dir>` to write the story's frames out as PNGs, and
/// `RATING_FRAMES=1` as well to write every 40 ms of the main flows.
final _shots = Platform.environment['RATING_SHOTS'];
final _frames = Platform.environment['RATING_FRAMES'] == '1';

final _boundary = GlobalKey();

Widget _app({
  required void Function(BuildContext) open,
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
    backgroundColor: const Color(0xFF0B0E11),
    body: Builder(
      builder: (context) => Center(
        child: TextButton(
          key: const Key('open'),
          onPressed: () => open(context),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

var _frameNo = 0;
String? _frameSet;

/// Called on every frame [_run] pumps, to check something frame by frame.
void Function()? _watch;

Future<void> _run(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 16) {
    await tester.pump(const Duration(milliseconds: 16));
    _watch?.call();
    if (_frames && _frameSet != null && t % 48 == 0) {
      await _shot(
        tester,
        '$_frameSet/f${(_frameNo++).toString().padLeft(4, '0')}',
        ratio: 1,
      );
    }
  }
}

Future<void> _shot(WidgetTester tester, String name, {double ratio = 2}) async {
  final dir = _shots;
  if (dir == null) return;
  await tester.runAsync(() async {
    final boundary =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: ratio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

/// Bazaar going away and coming back, as Android reports it.
Future<void> _leaveAndReturn(WidgetTester tester) async {
  for (final state in const [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pump();
  for (final state in const [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pump();
}

Future<RatingPrompt> _prompt() async =>
    RatingPrompt(await SharedPreferences.getInstance());

Future<void> _openStory(
  WidgetTester tester, {
  required RatingPrompt prompt,
  required Future<ReviewOutcome> Function() launcher,
  bool reduced = false,
  String lang = 'en',
  Brightness brightness = Brightness.dark,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _app(
      reduced: reduced,
      lang: lang,
      brightness: brightness,
      open: (context) =>
          showRatingStory(context, prompt: prompt, launcher: launcher),
    ),
  );
  await tester.tap(find.byKey(const Key('open')));
  await tester.pump();
  await _run(tester, 600);
}

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
    LocalProfile.avatarId = 3;
    await AvatarImages.load(3);
  });
  tearDownAll(() => LocalProfile.avatarId = null);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RatingPrompt.platformOverride = true;
    _frameSet = null;
    _frameNo = 0;
    _watch = null;
  });
  tearDown(() => RatingPrompt.platformOverride = null);

  for (final lang in const ['en', 'fa']) {
    testWidgets('[$lang] stars rise, fly off to Bazaar, and come home', (
      tester,
    ) async {
      final prompt = await _prompt();
      var opened = 0;
      _frameSet = 'flow-$lang';
      await _openStory(
        tester,
        prompt: prompt,
        lang: lang,
        launcher: () async {
          opened++;
          return ReviewOutcome.bazaar;
        },
      );

      await _run(tester, 700);
      await _shot(tester, '$lang-1-intro');
      expect(find.byKey(const Key('rating-rate')), findsNothing);

      await _run(tester, 1500);
      await _shot(tester, '$lang-2-ask');
      expect(find.byKey(const Key('rating-rate')), findsOneWidget);
      expect(find.byKey(const Key('rating-not-now')), findsOneWidget);

      // From here to the thanks, the sheet keeps its height and there is
      // exactly one button, standing still, on every single frame.
      final sheet = find.byType(SheetShell);
      final buttons = find.descendant(
        of: sheet,
        matching: find.byType(PressableScale),
      );
      final height = tester.getSize(sheet).height;
      // The button, and the link chip that waits (invisible) under it.
      expect(buttons, findsNWidgets(2));
      final buttonAt = tester.getRect(buttons.first);
      var frames = 0;
      _watch = () {
        frames++;
        expect(tester.getSize(sheet).height, moreOrLessEquals(height));
        expect(buttons, findsNWidgets(2));
        expect(tester.getRect(buttons.first), buttonAt);
      };

      // A tap on your rider makes you hop; nothing else happens.
      await tester.tapAt(
        tester.getTopLeft(find.byKey(const Key('rating-scene'))) +
            Offset(
              lang == 'fa' ? 354 - 96 * 354 / 340 : 96 * 354 / 340,
              128 * 354 / 340,
            ),
      );
      await _run(tester, 300);
      await _shot(tester, '$lang-3-hop');
      await _run(tester, 600);
      expect(opened, 0);

      await tester.tap(find.byKey(const Key('rating-rate')));
      await _run(tester, 480);
      await _shot(tester, '$lang-4-gather');
      await _run(tester, 420);
      await _shot(tester, '$lang-5-comet');
      await _run(tester, 900);
      expect(opened, 1);
      expect(prompt.opened, isTrue);
      expect(find.byKey(const Key('rating-back')), findsOneWidget);
      await _shot(tester, '$lang-6-away');

      await _leaveAndReturn(tester);
      await _run(tester, 450);
      await _shot(tester, '$lang-7-homecoming');
      await _run(tester, 1500);
      await _shot(tester, '$lang-8-thanks');
      expect(find.byKey(const Key('rating-done')), findsOneWidget);
      expect(opened, 1);
      _watch = null;
      expect(frames, greaterThan(200));

      await tester.tap(find.byKey(const Key('rating-done')));
      await _run(tester, 600);
      expect(find.byKey(const Key('rating-scene')), findsNothing);
    });
  }

  testWidgets('when nothing opens, offers the link and a retry', (
    tester,
  ) async {
    final prompt = await _prompt();
    var answer = ReviewOutcome.none;
    var opened = 0;
    await _openStory(
      tester,
      prompt: prompt,
      launcher: () async {
        opened++;
        return answer;
      },
    );
    await _run(tester, 2400);
    await tester.tap(find.byKey(const Key('rating-rate')));
    await _run(tester, 1800);
    expect(opened, 1);
    expect(prompt.opened, isFalse);
    expect(find.text("Cafe Bazaar didn't open"), findsOneWidget);
    expect(find.byKey(const Key('rating-copy')), findsOneWidget);
    await _shot(tester, 'en-9-failed');

    answer = ReviewOutcome.web;
    await tester.tap(find.byKey(const Key('rating-retry')));
    await _run(tester, 1800);
    expect(opened, 2);
    expect(prompt.opened, isTrue);
    expect(find.byKey(const Key('rating-back')), findsOneWidget);

    // Back without the app ever leaving (a split screen, say): "I'm back".
    await tester.tap(find.byKey(const Key('rating-back')));
    await _run(tester, 1800);
    expect(find.byKey(const Key('rating-done')), findsOneWidget);
  });

  testWidgets('"Not now" closes without opening anything', (tester) async {
    final prompt = await _prompt();
    var opened = 0;
    await _openStory(
      tester,
      prompt: prompt,
      launcher: () async {
        opened++;
        return ReviewOutcome.bazaar;
      },
    );
    await _run(tester, 2400);
    await tester.tap(find.byKey(const Key('rating-not-now')));
    await _run(tester, 600);
    expect(find.byKey(const Key('rating-scene')), findsNothing);
    expect(opened, 0);
    expect(prompt.opened, isFalse);
  });

  testWidgets('reduced motion: same states, no travel', (tester) async {
    final prompt = await _prompt();
    await _openStory(
      tester,
      prompt: prompt,
      reduced: true,
      launcher: () async => ReviewOutcome.bazaar,
    );
    // No intro to wait through: the ask is up at once.
    expect(find.byKey(const Key('rating-rate')), findsOneWidget);
    await _shot(tester, 'en-reduced-ask');
    await tester.tap(find.byKey(const Key('rating-rate')));
    await _run(tester, 400);
    expect(find.byKey(const Key('rating-back')), findsOneWidget);
    await _leaveAndReturn(tester);
    await _run(tester, 400);
    expect(find.byKey(const Key('rating-done')), findsOneWidget);
    await _shot(tester, 'en-reduced-thanks');
  });

  testWidgets('renders under a light Material theme without errors', (
    tester,
  ) async {
    final prompt = await _prompt();
    await _openStory(
      tester,
      prompt: prompt,
      brightness: Brightness.light,
      launcher: () async => ReviewOutcome.bazaar,
    );
    await _run(tester, 2400);
    await _shot(tester, 'en-light-ask');
    expect(tester.takeException(), isNull);
  });

  group('maybeAskForRating', () {
    Future<void> pumpHome(
      WidgetTester tester,
      RatingPrompt prompt,
      Completer<void> done,
    ) async {
      await tester.pumpWidget(
        _app(
          open: (context) => unawaited(
            maybeAskForRating(
              context,
              prompt: prompt,
              launcher: () async => ReviewOutcome.bazaar,
              settle: Duration.zero,
            ).whenComplete(done.complete),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open')));
      await _run(tester, 800);
    }

    testWidgets('asks after a good ride, and counts the ask', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      await prefs.setInt(
        'rating.first_seen_at',
        now.subtract(const Duration(days: 5)).millisecondsSinceEpoch,
      );
      final prompt = RatingPrompt(prefs);
      await prompt.recordRide(const Duration(minutes: 10));
      await prompt.recordRide(const Duration(minutes: 10));
      final done = Completer<void>();
      await pumpHome(tester, prompt, done);
      expect(find.byKey(const Key('rating-scene')), findsOneWidget);
      expect(prefs.getInt('rating.asks'), 1);
      expect(prefs.getInt('rating.good_rides'), 0);
    });

    testWidgets('stays quiet without a good ride', (tester) async {
      final prompt = await _prompt();
      final done = Completer<void>();
      await pumpHome(tester, prompt, done);
      expect(find.byKey(const Key('rating-scene')), findsNothing);
      expect(done.isCompleted, isTrue);
    });
  });

  group('RateAppCard', () {
    Widget card(RatingPrompt prompt) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(child: RateAppCard(prompt: prompt)),
      ),
    );

    testWidgets('opens the story, and thanks you afterwards', (tester) async {
      final prompt = await _prompt();
      await tester.pumpWidget(card(prompt));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Rate Tarkk on Cafe Bazaar'), findsOneWidget);
      expect(find.text('Your stars help other riders find us'), findsOneWidget);
      await prompt.recordOpened();
      await tester.tap(find.byKey(const Key('settings-rate-app')));
      await _run(tester, 600);
      expect(find.byKey(const Key('rating-scene')), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await _run(tester, 800);
      expect(
        find.text('Thanks for stopping by! Update your rating any time'),
        findsOneWidget,
      );
    });

    testWidgets('is not there where there is no Bazaar', (tester) async {
      RatingPrompt.platformOverride = false;
      final prompt = await _prompt();
      await tester.pumpWidget(card(prompt));
      expect(find.byKey(const Key('settings-rate-app')), findsNothing);
    });
  });
}
