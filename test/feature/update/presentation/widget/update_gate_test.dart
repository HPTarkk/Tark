import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/network/api_client.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/feature/update/data/store_launcher.dart';
import 'package:tark/feature/update/data/update_checker.dart';
import 'package:tark/feature/update/domain/entity/update_feed.dart';
import 'package:tark/feature/update/presentation/widget/update_gate.dart';

class _NoApi implements ApiClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeChecker extends UpdateChecker {
  _FakeChecker(this.offer, SharedPreferences prefs) : super(_NoApi(), prefs);

  final UpdateOffer? offer;
  int snoozes = 0;

  @override
  Future<UpdateOffer?> check() async => offer;

  @override
  Future<void> snooze(UpdateOffer offer) async => snoozes++;
}

class _FakeLauncher extends StoreLauncher {
  _FakeLauncher(this.result);

  final bool result;
  final opened = <Uri>[];

  @override
  Future<bool> openListing(Uri fallback) async {
    opened.add(fallback);
    return result;
  }
}

UpdateOffer _offer(UpdateUrgency urgency) => UpdateOffer(
  urgency: urgency,
  installedVersion: '1.0.21',
  feed: UpdateFeed.fromJson({
    'android': {
      'latestVersion': '1.0.22',
      'latestBuild': 32,
      'minimumBuild': urgency == UpdateUrgency.required ? 32 : 0,
      'url': 'https://cafebazaar.ir/app/com.b1101.tark',
      'notes': {
        'en': ['Faster join', 'Clearer voice on weak links', 'Fewer drops'],
        'fa': ['اتصال سریع‌تر', 'صدای واضح‌تر روی شبکه‌ی ضعیف', 'قطعی کمتر'],
      },
    },
  }),
);

/// Set to a folder to also dump frames of the sheet's motion, for a filmstrip
/// or a GIF rather than only asserting on it.
final _shots = Platform.environment['UPDATE_SHOTS'];

final _boundary = GlobalKey();

Future<void> _shot(WidgetTester tester, String name) async {
  final dir = _shots;
  if (dir == null) return;
  await tester.runAsync(() async {
    final boundary =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

/// Pumps frame by frame for [ms], dumping each frame when shots are on.
Future<void> _film(WidgetTester tester, String name, int ms) async {
  var frame = 0;
  for (var t = 0; t < ms; t += 33) {
    await tester.pump(const Duration(milliseconds: 33));
    if (_shots != null) {
      await _shot(tester, '$name/${'$frame'.padLeft(3, '0')}');
    }
    frame++;
  }
}

/// A 390-wide phone, the size most people will see this sheet on.
void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
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
  });

  late SharedPreferences prefs;
  late ValueNotifier<String> location;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    location = ValueNotifier(AppRoutes.landingPath);
  });

  tearDown(() => GetIt.instance.reset());

  late _FakeLauncher launcher;

  Future<_FakeChecker> pumpGate(
    WidgetTester tester,
    UpdateOffer? offer, {
    bool storeOpens = true,
    String lang = 'en',
    bool reduced = false,
  }) async {
    final checker = _FakeChecker(offer, prefs);
    launcher = _FakeLauncher(storeOpens);
    GetIt.instance
      ..registerSingleton<UpdateChecker>(checker)
      ..registerSingleton<StoreLauncher>(launcher);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Vazirmatn', brightness: Brightness.dark),
        locale: Locale(lang),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: RepaintBoundary(
            key: _boundary,
            child: UpdateGate(
              location: () => location.value,
              locationChanges: location,
              child: child!,
            ),
          ),
        ),
        home: const Scaffold(body: Center(child: Text('app'))),
      ),
    );
    return checker;
  }

  // The prompts loop ambient animations, so settle with bounded pumps.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('no offer: the app is left alone', (tester) async {
    await pumpGate(tester, null);
    await settle(tester);
    expect(find.text('app'), findsOneWidget);
    expect(find.byKey(const Key('update-action')), findsNothing);
  });

  testWidgets('optional: shows on home, and Not now snoozes it', (
    tester,
  ) async {
    final checker = await pumpGate(tester, _offer(UpdateUrgency.optional));
    await settle(tester);

    expect(find.text('Tarkk 1.0.22 is on the air'), findsOneWidget);
    expect(find.text('Faster join'), findsOneWidget);
    expect(find.text('app'), findsOneWidget);

    await tester.tap(find.byKey(const Key('update-later')));
    await settle(tester);
    expect(find.byKey(const Key('update-action')), findsNothing);
    expect(checker.snoozes, 1);
  });

  testWidgets('optional: waits out a live channel, then shows on home', (
    tester,
  ) async {
    location.value = AppRoutes.walkiePath;
    await pumpGate(tester, _offer(UpdateUrgency.optional));
    await settle(tester);
    expect(find.byKey(const Key('update-action')), findsNothing);

    location.value = AppRoutes.landingPath;
    await settle(tester);
    expect(find.byKey(const Key('update-action')), findsOneWidget);
  });

  testWidgets('optional: never over the splash', (tester) async {
    location.value = AppRoutes.splashPath;
    await pumpGate(tester, _offer(UpdateUrgency.optional));
    await settle(tester);
    expect(find.byKey(const Key('update-action')), findsNothing);
  });

  testWidgets('required: covers the app and cannot be dismissed', (
    tester,
  ) async {
    location.value = AppRoutes.walkiePath;
    await pumpGate(tester, _offer(UpdateUrgency.required));
    await settle(tester);

    expect(find.text('This version is off the air'), findsOneWidget);
    expect(find.byKey(const Key('update-later')), findsNothing);
    // Once covered, the app underneath leaves the tree entirely.
    expect(find.text('app'), findsNothing);
  });

  testWidgets('required: a store that will not open says so and stays', (
    tester,
  ) async {
    await pumpGate(tester, _offer(UpdateUrgency.required), storeOpens: false);
    await settle(tester);

    await tester.tap(find.byKey(const Key('update-action')));
    await settle(tester);
    expect(find.text("Bazaar didn't open. Try once more."), findsOneWidget);
    expect(find.byKey(const Key('update-action')), findsOneWidget);
  });

  testWidgets('optional: a store that opens sends the sheet away unsnoozed', (
    tester,
  ) async {
    final checker = await pumpGate(tester, _offer(UpdateUrgency.optional));
    await settle(tester);

    await tester.tap(find.byKey(const Key('update-action')));
    await settle(tester);
    expect(launcher.opened, hasLength(1));
    expect(find.byKey(const Key('update-action')), findsNothing);
    expect(checker.snoozes, 0);
  });

  testWidgets('optional: a store that will not open says so and stays', (
    tester,
  ) async {
    _phone(tester);
    final checker = await pumpGate(
      tester,
      _offer(UpdateUrgency.optional),
      storeOpens: false,
    );
    await settle(tester);

    await tester.tap(find.byKey(const Key('update-action')));
    await settle(tester);
    expect(find.text("Bazaar didn't open. Try once more."), findsOneWidget);
    expect(find.byKey(const Key('update-later')), findsOneWidget);
    expect(checker.snoozes, 0);
  });

  testWidgets('optional: pulling the sheet down dismisses it like Not now', (
    tester,
  ) async {
    _phone(tester);
    final checker = await pumpGate(tester, _offer(UpdateUrgency.optional));
    await settle(tester);

    final sheet = find.byKey(const Key('update-sheet'));
    // The drag surface stays put; what it moves is the sheet inside it.
    final action = find.byKey(const Key('update-action'));
    final docked = tester.getTopLeft(action).dy;
    // A short tug is not a dismissal: the sheet springs back to docked.
    await tester.drag(sheet, const Offset(0, 60));
    await settle(tester);
    expect(tester.getTopLeft(action).dy, moreOrLessEquals(docked, epsilon: 1));
    expect(checker.snoozes, 0);

    // Tugging upward gives way only a little and settles back.
    final gesture = await tester.startGesture(tester.getCenter(sheet));
    await gesture.moveBy(const Offset(0, -200));
    await tester.pump();
    final lifted = docked - tester.getTopLeft(action).dy;
    expect(lifted, greaterThan(0));
    expect(lifted, lessThan(80));
    await gesture.up();
    await settle(tester);
    expect(tester.getTopLeft(action).dy, moreOrLessEquals(docked, epsilon: 1));

    await tester.fling(sheet, const Offset(0, 300), 1500);
    await settle(tester);
    expect(find.byKey(const Key('update-action')), findsNothing);
    expect(checker.snoozes, 1);
  });

  testWidgets('optional: tapping the dimmed app behind dismisses it', (
    tester,
  ) async {
    _phone(tester);
    final checker = await pumpGate(tester, _offer(UpdateUrgency.optional));
    await settle(tester);
    await tester.tapAt(const Offset(195, 20));
    await settle(tester);
    expect(find.byKey(const Key('update-action')), findsNothing);
    expect(checker.snoozes, 1);
  });

  testWidgets('optional: reduced motion arrives without travel', (
    tester,
  ) async {
    _phone(tester);
    final checker = await pumpGate(
      tester,
      _offer(UpdateUrgency.optional),
      reduced: true,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 460));
    final action = find.byKey(const Key('update-action'));
    final early = tester.getTopLeft(action).dy;
    await _film(tester, 'reduced', 1700);
    await _shot(tester, 'reduced-settled');
    // Docked from its first frame: it fades in where it stands.
    expect(tester.getTopLeft(action).dy, early);
    expect(find.text('Faster join'), findsOneWidget);

    await tester.tap(find.byKey(const Key('update-later')));
    await settle(tester);
    expect(find.byKey(const Key('update-action')), findsNothing);
    expect(checker.snoozes, 1);
  });

  for (final lang in ['en', 'fa']) {
    testWidgets('optional: plays its arrival in $lang', (tester) async {
      _phone(tester);
      await pumpGate(tester, _offer(UpdateUrgency.optional), lang: lang);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump(const Duration(milliseconds: 16));
      final action = find.byKey(const Key('update-action'));
      final rising = tester.getTopLeft(action).dy;
      await _film(tester, '$lang-arrive', 2000);
      await _shot(tester, '$lang-settled');
      // It rose into place rather than appearing there.
      expect(tester.getTopLeft(action).dy, lessThan(rising));
      expect(tester.takeException(), isNull);
      expect(
        Directionality.of(
          tester.element(find.byKey(const Key('update-later'))),
        ),
        lang == 'fa' ? TextDirection.rtl : TextDirection.ltr,
      );

      await tester.tap(find.byKey(const Key('update-later')));
      await _film(tester, '$lang-leave', 600);
      expect(find.byKey(const Key('update-action')), findsNothing);
    });
  }
}
