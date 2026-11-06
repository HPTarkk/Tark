import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/account/account_session.dart';
import 'package:tark/core/entitlement/license_gate.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/network/api_client.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/feature/announcement/data/announcement_checker.dart';
import 'package:tark/feature/announcement/domain/entity/announcement.dart';
import 'package:tark/feature/announcement/presentation/widget/announcement_gate.dart';

class _No implements ApiClient, AccountSession, LicenseGate {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeChecker extends AnnouncementChecker {
  _FakeChecker(this.found, SharedPreferences prefs)
    : super(_No(), prefs, _No(), _No());

  final List<Announcement> found;
  final marked = <String>[];

  @override
  Future<List<Announcement>> check() async => found;

  @override
  Future<void> markSeen(Iterable<String> ids) async => marked.addAll(ids);
}

Announcement _a(
  String id,
  AnnouncementCategory category, {
  Map<String, dynamic>? action,
  Map<String, String>? highlight,
  String? en,
  String? fa,
}) => Announcement.fromJson({
  'id': id,
  'category': category.name,
  'title': {'en': en ?? 'Title $id', 'fa': fa ?? 'عنوان $id'},
  'body': {
    'en': 'Something worth knowing, said in a line or two.',
    'fa': 'یه چیزی که خوبه بدونی، توی یکی دو خط.',
  },
  'highlight': ?highlight,
  'action': ?action,
});

final _gift = _a(
  'gift',
  AnnouncementCategory.gift,
  en: 'Three months on us',
  fa: 'سه ماه مهمون ما باش',
  highlight: {'en': '3 months free', 'fa': '3 ماه رایگان'},
  action: {
    'type': 'signIn',
    'label': {'en': 'Sign up free', 'fa': 'ثبت‌نام رایگان'},
  },
);

/// Set to a folder to also dump frames, for GIFs of each category.
final _shots = Platform.environment['ANNOUNCE_SHOTS'];
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
  late ValueNotifier<bool?> updateOffered;
  late List<String> pushed;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    location = ValueNotifier(AppRoutes.landingPath);
    updateOffered = ValueNotifier(false);
    pushed = [];
  });

  tearDown(() => GetIt.instance.reset());

  Future<_FakeChecker> pumpGate(
    WidgetTester tester,
    List<Announcement> found, {
    String lang = 'en',
    bool reduced = false,
  }) async {
    final checker = _FakeChecker(found, prefs);
    GetIt.instance.registerSingleton<AnnouncementChecker>(checker);
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
            child: AnnouncementGate(
              location: () => location.value,
              locationChanges: location,
              updateOffered: updateOffered,
              navigate: pushed.add,
              child: child!,
            ),
          ),
        ),
        home: const Scaffold(
          backgroundColor: Color(0xFF0B0E11),
          body: Center(child: Text('app')),
        ),
      ),
    );
    return checker;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  final action = find.byKey(const Key('announcement-action'));
  final secondary = find.byKey(const Key('announcement-secondary'));

  testWidgets('nothing new: the app is left alone', (tester) async {
    await pumpGate(tester, const []);
    await settle(tester);
    expect(find.text('app'), findsOneWidget);
    expect(action, findsNothing);
  });

  testWidgets('waits for the update check, and yields to an update', (
    tester,
  ) async {
    updateOffered.value = null;
    await pumpGate(tester, [_gift]);
    await settle(tester);
    expect(action, findsNothing, reason: 'still asking about updates');

    updateOffered.value = true;
    await settle(tester);
    expect(action, findsNothing, reason: 'one interruption per launch');
  });

  testWidgets('shows once the update check says no', (tester) async {
    updateOffered.value = null;
    final checker = await pumpGate(tester, [_gift]);
    await settle(tester);
    updateOffered.value = false;
    await settle(tester);
    expect(find.text('Three months on us'), findsOneWidget);
    expect(find.text('3 months free'), findsOneWidget);
    expect(find.text('Sign up free'), findsOneWidget);
    expect(checker.marked, ['gift']);
  });

  testWidgets('never over a channel; comes up back home', (tester) async {
    location.value = AppRoutes.walkiePath;
    await pumpGate(tester, [_gift]);
    await settle(tester);
    expect(action, findsNothing);
    location.value = AppRoutes.roomsPath;
    await settle(tester);
    expect(action, findsOneWidget);
  });

  testWidgets('sign-up action closes the sheet, then opens sign-in', (
    tester,
  ) async {
    await pumpGate(tester, [_gift]);
    await settle(tester);
    await tester.tap(action);
    await settle(tester);
    expect(action, findsNothing);
    expect(pushed, [AppRoutes.signInName]);
  });

  testWidgets('screen action opens the named screen', (tester) async {
    await pumpGate(tester, [
      _a(
        'tip',
        AnnouncementCategory.tip,
        action: {'type': 'screen', 'screen': 'advanced'},
      ),
    ]);
    await settle(tester);
    expect(find.text('Show me'), findsOneWidget, reason: 'default label');
    await tester.tap(action);
    await settle(tester);
    expect(pushed, [AppRoutes.advancedSettingsName]);
  });

  testWidgets('Not now puts it away for good', (tester) async {
    final checker = await pumpGate(tester, [_gift]);
    await settle(tester);
    await tester.tap(secondary);
    await settle(tester);
    expect(action, findsNothing);
    expect(pushed, isEmpty);
    expect(checker.marked, ['gift']);
    // Leaving and coming back home this launch does not bring it back.
    location.value = AppRoutes.settingsPath;
    await settle(tester);
    location.value = AppRoutes.landingPath;
    await settle(tester);
    expect(action, findsNothing);
  });

  testWidgets('several: Next leafs through, each counted as it comes up', (
    tester,
  ) async {
    _phone(tester);
    final checker = await pumpGate(tester, [
      _gift,
      _a('feature', AnnouncementCategory.feature),
      _a('news', AnnouncementCategory.news),
    ]);
    await settle(tester);
    expect(checker.marked, ['gift']);
    expect(find.text('Next'), findsOneWidget);

    await tester.tap(secondary);
    await settle(tester);
    expect(find.text('Title feature').hitTestable(), findsOneWidget);
    expect(checker.marked, ['gift', 'feature']);
    // No action: the main button is Next, and Close is the way out.
    expect(find.text('Close'), findsOneWidget);
    await tester.tap(action);
    await settle(tester);
    expect(find.text('Title news').hitTestable(), findsOneWidget);
    expect(find.text('Got it'), findsOneWidget);
    expect(secondary, findsNothing);
    await tester.tap(action);
    await settle(tester);
    expect(action, findsNothing);
    expect(checker.marked, ['gift', 'feature', 'news']);
  });

  testWidgets('swiping turns pages, both ways, and resists past the end', (
    tester,
  ) async {
    _phone(tester);
    await pumpGate(tester, [
      _a('one', AnnouncementCategory.news),
      _a('two', AnnouncementCategory.tip),
    ]);
    await settle(tester);
    final title = find.text('Title one').hitTestable();
    // Back past the first page: it gives a little and springs back.
    await tester.drag(title, const Offset(300, 0));
    await settle(tester);
    expect(find.text('Title one').hitTestable(), findsOneWidget);
    await tester.fling(title, const Offset(-300, 0), 1500);
    await settle(tester);
    expect(find.text('Title two').hitTestable(), findsOneWidget);
    expect(find.text('Title one').hitTestable(), findsNothing);
    await tester.fling(
      find.text('Title two').hitTestable(),
      const Offset(300, 0),
      1500,
    );
    await settle(tester);
    expect(find.text('Title one').hitTestable(), findsOneWidget);
  });

  testWidgets('turning pages: one button, and nothing below the pages moves', (
    tester,
  ) async {
    _phone(tester);
    // A tall page (with a ticket), then a short one with no second choice.
    await pumpGate(tester, [_gift, _a('short', AnnouncementCategory.event)]);
    await settle(tester);
    final before = tester.getRect(action);
    final dotsY = tester.getCenter(find.text('Next').hitTestable()).dy;
    await tester.tap(secondary);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 33));
      expect(action, findsOneWidget, reason: 'frame $i: never two buttons');
      expect(
        tester.getRect(action).top,
        moreOrLessEquals(before.top, epsilon: 0.5),
        reason: 'frame $i: the button stays put',
      );
    }
    await settle(tester);
    expect(find.text('Got it'), findsOneWidget);
    expect(tester.getRect(action), before);
    expect(secondary, findsNothing);
    expect(dotsY, greaterThan(before.bottom));
  });

  testWidgets('in Persian, next is a swipe to the right', (tester) async {
    _phone(tester);
    await pumpGate(tester, [
      _a('one', AnnouncementCategory.news),
      _a('two', AnnouncementCategory.tip),
    ], lang: 'fa');
    await settle(tester);
    await tester.fling(
      find.text('عنوان one').hitTestable(),
      const Offset(300, 0),
      1500,
    );
    await settle(tester);
    expect(find.text('عنوان two').hitTestable(), findsOneWidget);
  });

  testWidgets('pulling the sheet down dismisses it', (tester) async {
    _phone(tester);
    await pumpGate(tester, [_gift]);
    await settle(tester);
    await tester.fling(
      find.byKey(const Key('announcement-sheet')),
      const Offset(0, 300),
      1500,
    );
    await settle(tester);
    expect(action, findsNothing);
    expect(pushed, isEmpty);
  });

  testWidgets('Persian digits in the feed text', (tester) async {
    _phone(tester);
    await pumpGate(tester, [_gift], lang: 'fa');
    await settle(tester);
    expect(find.text('۳ ماه رایگان'), findsOneWidget);
  });

  testWidgets('reduced motion: everything still arrives', (tester) async {
    _phone(tester);
    await pumpGate(tester, [_gift], reduced: true);
    await settle(tester);
    expect(find.text('Three months on us'), findsOneWidget);
    await tester.tap(secondary);
    await settle(tester);
    expect(action, findsNothing);
  });

  for (final category in AnnouncementCategory.values) {
    for (final lang in const ['en', 'fa']) {
      testWidgets('${category.name} ($lang) plays its entrance cleanly', (
        tester,
      ) async {
        _phone(tester);
        final a = category == AnnouncementCategory.gift
            ? _gift
            : _a(
                category.name,
                category,
                action: category == AnnouncementCategory.alert
                    ? null
                    : {'type': 'link', 'url': 'https://tarkk.ir'},
              );
        await pumpGate(tester, [a], lang: lang);
        await _film(tester, '${category.name}-$lang', 3200);
        expect(tester.takeException(), isNull);
        expect(action, findsOneWidget);
      });
    }
  }

  testWidgets('filmstrip: leafing through three', (tester) async {
    _phone(tester);
    await pumpGate(tester, [
      _gift,
      _a(
        'feature',
        AnnouncementCategory.feature,
        en: 'Shared Music, now in every room',
        action: {'type': 'screen', 'screen': 'rooms'},
      ),
      _a('event', AnnouncementCategory.event, en: 'Group ride on Friday'),
    ]);
    await _film(tester, 'deck-en', 2600);
    await tester.tap(secondary);
    await _film(tester, 'deck-en-2', 2400);
    final sheet = find.byKey(const Key('announcement-sheet'));
    final gesture = await tester.startGesture(
      tester.getCenter(sheet) - const Offset(0, 120),
    );
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(-28, 0));
      await tester.pump(const Duration(milliseconds: 33));
      if (_shots != null) {
        await _shot(tester, 'deck-en-3/${'$i'.padLeft(3, '0')}');
      }
    }
    await gesture.up();
    await _film(tester, 'deck-en-4', 2400);
    expect(tester.takeException(), isNull);
  });
}
