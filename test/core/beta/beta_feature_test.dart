import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/beta/beta_badge.dart';
import 'package:tark/core/beta/beta_feature.dart';
import 'package:tark/core/beta/beta_intro.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/l10n/app_localizations_en.dart';
import 'package:tark/core/settings/settings_keys.dart';
import 'package:tark/core/settings/settings_repository.dart';
import 'package:tark/core/settings/settings_repository_impl.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';

void main() {
  group('classification', () {
    test('only Guest is beta, and Guest is not premium', () {
      expect(TransferMode.guest.betaFeature, BetaFeature.guestConnection);
      expect(TransferMode.guest.requiresPremium, isFalse);
      for (final mode in [
        TransferMode.wifi,
        TransferMode.hotspot,
        TransferMode.bluetooth,
      ]) {
        expect(mode.betaFeature, isNull, reason: mode.key);
      }
    });

    test('beta keys are stable persistence ids', () {
      expect(BetaFeature.guestConnection.key, 'guest_connection');
    });

    test('the intro flag round-trips through SettingsRepository', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final repo = SettingsRepositoryImpl(prefs);
      expect(await repo.getBetaIntroSeen(BetaFeature.guestConnection), isFalse);
      await repo.setBetaIntroSeen(BetaFeature.guestConnection, true);
      expect(await repo.getBetaIntroSeen(BetaFeature.guestConnection), isTrue);
      expect(
        prefs.getBool('${SettingsKeys.betaIntroSeenPrefix}guest_connection'),
        isTrue,
      );
    });
  });

  group('BetaIntroGate', () {
    Future<void> pumpGate(
      WidgetTester tester,
      _MemorySettings settings, {
      bool asPushedRoute = false,
    }) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gate = BetaIntroGate(
        feature: BetaFeature.guestConnection,
        repository: settings,
        child: const Scaffold(body: Text('beta-page')),
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          // Reduced motion, so the sheet's ambient emblem rests and the
          // tester can settle.
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: asPushedRoute
              ? Builder(
                  builder: (context) => Scaffold(
                    body: Column(
                      children: [
                        const Text('origin'),
                        TextButton(
                          onPressed: () => Navigator.of(
                            context,
                          ).push(MaterialPageRoute<void>(builder: (_) => gate)),
                          child: const Text('open'),
                        ),
                      ],
                    ),
                  ),
                )
              : gate,
        ),
      );
      if (asPushedRoute) {
        await tester.tap(find.text('open'));
      }
      await tester.pumpAndSettle();
      // The gate waits a beat after the route lands before raising the sheet.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
    }

    final en = AppLocalizationsEn();

    testWidgets('shows once on first entry and remembers "Got it"', (
      tester,
    ) async {
      final settings = _MemorySettings();
      await pumpGate(tester, settings);

      expect(find.byType(BetaIntroSheet), findsOneWidget);
      expect(find.text(en.beta_intro_title), findsOneWidget);
      expect(find.text(en.beta_guest_intro_steadier), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('beta-intro-proceed')));
      await tester.tap(find.byKey(const Key('beta-intro-proceed')));
      await tester.pumpAndSettle();
      expect(find.byType(BetaIntroSheet), findsNothing);
      expect(find.text('beta-page'), findsOneWidget);
      expect(settings.seen, {BetaFeature.guestConnection});

      // A second visit is quiet.
      await tester.pumpWidget(const SizedBox());
      await pumpGate(tester, settings);
      expect(find.byType(BetaIntroSheet), findsNothing);
    });

    testWidgets('"Not now" leaves the page and asks again next time', (
      tester,
    ) async {
      final settings = _MemorySettings();
      await pumpGate(tester, settings, asPushedRoute: true);
      expect(find.byType(BetaIntroSheet), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('beta-intro-back')));
      await tester.tap(find.byKey(const Key('beta-intro-back')));
      await tester.pumpAndSettle();
      expect(find.text('beta-page'), findsNothing);
      expect(find.text('origin'), findsOneWidget);
      expect(settings.seen, isEmpty);
    });

    testWidgets('is transparent with no settings repository', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const BetaIntroGate(
            feature: BetaFeature.guestConnection,
            child: Scaffold(body: Text('beta-page')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(BetaIntroSheet), findsNothing);
      expect(find.text('beta-page'), findsOneWidget);
    });
  });

  group('badges', () {
    Future<void> pumpFamily(
      WidgetTester tester, {
      required Locale locale,
      bool reduced = false,
    }) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: child!,
          ),
          home: const Scaffold(
            body: Column(
              children: [
                BetaBadge(),
                BetaPill(),
                BetaMark(),
                BetaNotice(
                  feature: BetaFeature.guestConnection,
                  message: 'note',
                ),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('render in both languages and label themselves', (
      tester,
    ) async {
      for (final locale in const [Locale('fa'), Locale('en')]) {
        await pumpFamily(tester, locale: locale);
        await tester.pump(const Duration(seconds: 5));
        expect(tester.takeException(), isNull);
      }
      expect(
        find.bySemanticsLabel(AppLocalizationsEn().beta_semantics),
        findsNWidgets(4),
      );
    });

    testWidgets('reduced motion stops the ambient loop', (tester) async {
      await pumpFamily(tester, locale: const Locale('en'), reduced: true);
      // Settles: nothing is left ticking once the entrance has played.
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('"What\'s that?" re-opens the intro without a back option', (
      tester,
    ) async {
      await pumpFamily(tester, locale: const Locale('en'), reduced: true);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('beta-notice-more')));
      await tester.pumpAndSettle();
      expect(find.byType(BetaIntroSheet), findsOneWidget);
      expect(find.byKey(const Key('beta-intro-back')), findsNothing);
    });
  });
}

class _MemorySettings implements SettingsRepository {
  final Set<BetaFeature> seen = {};

  @override
  Future<bool> getBetaIntroSeen(BetaFeature feature) async =>
      seen.contains(feature);

  @override
  Future<void> setBetaIntroSeen(BetaFeature feature, bool value) async {
    value ? seen.add(feature) : seen.remove(feature);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
