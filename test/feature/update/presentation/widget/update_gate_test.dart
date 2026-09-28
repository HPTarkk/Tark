import 'package:flutter/material.dart';
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
        'en': ['Faster join'],
      },
    },
  }),
);

void main() {
  late SharedPreferences prefs;
  late ValueNotifier<String> location;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    location = ValueNotifier(AppRoutes.landingPath);
  });

  tearDown(() => GetIt.instance.reset());

  Future<_FakeChecker> pumpGate(
    WidgetTester tester,
    UpdateOffer? offer, {
    bool storeOpens = true,
  }) async {
    final checker = _FakeChecker(offer, prefs);
    GetIt.instance
      ..registerSingleton<UpdateChecker>(checker)
      ..registerSingleton<StoreLauncher>(_FakeLauncher(storeOpens));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => UpdateGate(
          location: () => location.value,
          locationChanges: location,
          child: child!,
        ),
        home: const Scaffold(body: Text('app')),
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

    expect(find.text('Tark 1.0.22 is on the air'), findsOneWidget);
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
}
