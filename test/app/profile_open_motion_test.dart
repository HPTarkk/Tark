import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/app/router/app_router.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/profile/local_profile.dart';
import 'package:tark/core/settings/settings_keys.dart';
import 'package:tark/core/settings/settings_repository.dart';
import 'package:tark/core/settings/settings_repository_impl.dart';
import 'package:tark/core/theme/app_theme.dart';
import 'package:tark/feature/landing/presentation/manager/landing_cubit.dart';
import 'package:tark/feature/settings/presentation/page/profile_page.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';

class _Landing extends Cubit<LandingState> implements LandingCubit {
  _Landing()
    : super(
        const LandingState(
          localIp: '',
          myName: 'Pedi',
          isLoading: false,
          transferMode: TransferMode.bluetooth,
          pinnedMode: null,
        ),
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Every screen moves in with the app's one page transition, and Profile
/// opens out of Home's profile chip.
///
/// go_router 18 only gives a `builder:` route a Material page when it finds
/// *material_ui*'s MaterialApp above it. The app runs Flutter's MaterialApp,
/// so a `builder:` route silently got a zero-length NoTransitionPage: no
/// slide, and no face-and-name flight into Profile. These tests run the real
/// route table.
void main() {
  test('every route builds its own page, so none falls back to no motion', () {
    final routes = <GoRoute>[];
    void walk(List<RouteBase> list) {
      for (final route in list) {
        if (route is GoRoute) routes.add(route);
        walk(route.routes);
      }
    }

    walk(AppRouter.router.configuration.routes);
    expect(routes, isNotEmpty);
    for (final route in routes) {
      expect(
        route.pageBuilder,
        isNotNull,
        reason:
            '${route.path} uses `builder:`; go_router 18 gives it no '
            'transition. Use `pageBuilder: … AppRouter.pageFor(…)`.',
      );
    }
  });

  group('opening Profile from Home', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({
        SettingsKeys.userName: 'Pedi',
        SettingsKeys.avatarId: 3,
      });
      final prefs = await SharedPreferences.getInstance();
      GetIt.instance
        ..registerFactory<LandingCubit>(_Landing.new)
        ..registerSingleton<SettingsRepository>(SettingsRepositoryImpl(prefs));
      PackageInfo.setMockInitialValues(
        appName: 'Tarkk',
        packageName: 'tark',
        version: '1.1.0',
        buildNumber: '1',
        buildSignature: 'test',
      );
    });
    tearDown(() async {
      await GetIt.instance.reset();
      LocalProfile.avatarId = null;
    });

    Future<void> openProfile(
      WidgetTester tester, {
      bool reduced = false,
    }) async {
      tester.view.physicalSize = const Size(400, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = AppRouter.router;
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          theme: buildAppTheme(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: child!,
          ),
        ),
      );
      // Let Home's own entrance finish so the chip is where it rests.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.byKey(const ValueKey('landing-identity')));
      await tester.pump();
    }

    Finder flying() => find.descendant(
      of: find.byType(Overlay),
      matching: find.byWidgetPredicate(
        (w) => w.runtimeType.toString().contains('Flight'),
      ),
    );

    testWidgets('the page slides in and the face and name fly into it', (
      tester,
    ) async {
      await openProfile(tester);
      final route = ModalRoute.of(
        tester.element(find.byType(ProfilePage, skipOffstage: false)),
      )!;
      expect(route.transitionDuration, greaterThan(Duration.zero));

      await tester.pump(const Duration(milliseconds: 120));
      expect(route.animation!.value, inExclusiveRange(0, 1));
      expect(
        tester.getTopLeft(find.byType(ProfilePage)).dx,
        greaterThan(0),
        reason: 'Profile is still sliding in from the trailing edge',
      );
      expect(flying(), findsWidgets);

      await tester.pump(const Duration(seconds: 1));
      expect(tester.getTopLeft(find.byType(ProfilePage)).dx, 0);
      expect(flying(), findsNothing);
      expect(tester.takeException(), isNull);
      AppRouter.router.pop();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('reduced motion fades Profile in without travel', (
      tester,
    ) async {
      await openProfile(tester, reduced: true);
      await tester.pump(const Duration(milliseconds: 120));
      expect(tester.getTopLeft(find.byType(ProfilePage)).dx, 0);
      expect(flying(), findsNothing);
      final fade = tester
          .widgetList<FadeTransition>(
            find.ancestor(
              of: find.byType(ProfilePage),
              matching: find.byType(FadeTransition),
            ),
          )
          .map((f) => f.opacity.value);
      expect(fade.any((o) => o > 0 && o < 1), isTrue);
      await tester.pump(const Duration(seconds: 1));
      AppRouter.router.pop();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
