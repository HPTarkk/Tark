import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/account/account_session.dart';
import 'package:tark/core/account/auth_repository.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/network/service_api.dart';
import 'package:tark/core/profile/local_profile.dart';
import 'package:tark/core/settings/settings_keys.dart';
import 'package:tark/core/settings/settings_repository.dart';
import 'package:tark/core/settings/settings_repository_impl.dart';
import 'package:tark/core/widget/app_avatar.dart';
import 'package:tark/feature/settings/presentation/page/profile_page.dart';

import '../../../../core/account/account_fakes.dart';

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      SettingsKeys.userName: 'Pedi',
      SettingsKeys.avatarId: 3,
    });
    prefs = await SharedPreferences.getInstance();
    GetIt.instance.registerSingleton<SettingsRepository>(
      SettingsRepositoryImpl(prefs),
    );
  });

  tearDown(() async {
    await GetIt.instance.reset();
    LocalProfile.avatarId = null;
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: ProfilePage.buildPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  AppAvatar hero(WidgetTester tester) => tester
      .widgetList<AppAvatar>(find.byType(AppAvatar))
      .firstWhere((a) => a.size == 112);

  testWidgets('shows the saved name and face', (tester) async {
    await pumpPage(tester);
    expect(find.text('PROFILE'), findsOneWidget);
    expect(find.text('Pedi'), findsWidgets);
    expect(hero(tester).avatarId, 3);
  });

  testWidgets('picking a face saves it and updates the preview', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('avatar-8')));
    await tester.pumpAndSettle();

    expect(hero(tester).avatarId, 8);
    expect(prefs.getInt(SettingsKeys.avatarId), 8);
    expect(LocalProfile.avatarId, 8, reason: 'what presence will carry');
  });

  testWidgets('a new name is saved, a blank one is not', (tester) async {
    await pumpPage(tester);
    final field = find.byKey(const ValueKey('profile-name-field'));

    await tester.enterText(field, '   ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(prefs.getString(SettingsKeys.userName), 'Pedi');

    await tester.enterText(field, 'Falcon42');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(prefs.getString(SettingsKeys.userName), 'Falcon42');
  });

  testWidgets('no account card on builds without sign-in', (tester) async {
    await pumpPage(tester);
    expect(find.byKey(const ValueKey('account-section')), findsNothing);
  });

  group('account card', () {
    late AccountHarness account;

    setUp(() {
      account = AccountHarness();
      GetIt.instance
        ..registerSingleton<AccountSession>(account.session)
        ..registerSingleton<AuthRepository>(account.repository);
    });

    testWidgets('signed out: one optional sign-in entry', (tester) async {
      await pumpPage(tester);
      expect(find.byKey(const ValueKey('account-sign-in')), findsOneWidget);
      expect(find.byKey(const ValueKey('account-delete')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('account-sign-in')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('signin-email')), findsOneWidget);
    });

    testWidgets('signed in: read-only email, sign out and delete', (
      tester,
    ) async {
      await account.signIn();
      account.client.handler = (_) async => const ApiOk(204, {});
      await pumpPage(tester);

      expect(find.textContaining('pedi@example.com'), findsOneWidget);
      expect(find.byKey(const ValueKey('account-change-password')), findsOne);
      expect(find.byKey(const ValueKey('account-delete')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('account-sign-out')));
      await tester.pumpAndSettle();

      expect(account.client.paths, ['/auth/logout']);
      expect(account.session.isSignedIn, isFalse);
      expect(find.byKey(const ValueKey('account-sign-in')), findsOneWidget);
    });

    testWidgets('a Google-only account has no password to change', (
      tester,
    ) async {
      await account.signIn(
        session: sessionJson(profile: profileJson(methods: ['google'])),
      );
      await pumpPage(tester);
      expect(
        find.byKey(const ValueKey('account-change-password')),
        findsNothing,
      );
    });
  });
}
