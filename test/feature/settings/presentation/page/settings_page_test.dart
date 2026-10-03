import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/home_widget/home_widget_service.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/profile/local_profile.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/core/settings/settings_keys.dart';
import 'package:tark/core/settings/settings_repository.dart';
import 'package:tark/core/settings/settings_repository_impl.dart';
import 'package:tark/feature/settings/presentation/page/profile_page.dart';
import 'package:tark/feature/settings/presentation/page/settings_page.dart';

/// A launcher that cannot pin widgets; nothing else is used here.
class _HomeWidgets implements HomeWidgetService {
  @override
  Future<bool> canPin() async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      SettingsKeys.userName: 'Pedi',
      SettingsKeys.avatarId: 3,
    });
    final prefs = await SharedPreferences.getInstance();
    GetIt.instance
      ..registerSingleton<SettingsRepository>(SettingsRepositoryImpl(prefs))
      ..registerSingleton<HomeWidgetService>(_HomeWidgets());
  });

  tearDown(() async {
    await GetIt.instance.reset();
    LocalProfile.avatarId = null;
  });

  testWidgets('the profile card at the top opens Profile', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: AppRoutes.settingsPath,
      routes: [
        GoRoute(
          path: AppRoutes.settingsPath,
          builder: (_, _) => SettingsPage.buildPage(),
        ),
        GoRoute(
          path: AppRoutes.profilePath,
          name: AppRoutes.profileName,
          builder: (_, _) => ProfilePage.buildPage(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        routerConfig: router,
      ),
    );
    // Settings has looping touches, so settle by time.
    await settle(tester);

    final card = find.byKey(const ValueKey('settings-profile'));
    expect(card, findsOneWidget);
    expect(find.text('Pedi'), findsOneWidget);
    expect(find.text('Change your name and face'), findsOneWidget);

    // The arrow is the one every row uses, which turns itself around in
    // Persian; picking a direction by hand flips it the wrong way.
    final arrow = tester.widget<Icon>(
      find.descendant(of: card, matching: find.byType(Icon)).last,
    );
    expect(arrow.icon, Icons.chevron_right_rounded);
    expect(arrow.icon!.matchTextDirection, isTrue);

    await tester.tap(card);
    await settle(tester);
    expect(find.text('PROFILE'), findsOneWidget);
  });
}
