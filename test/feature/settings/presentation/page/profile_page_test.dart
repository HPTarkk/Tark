import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/account/account_session.dart';
import 'package:tark/core/account/auth_repository.dart';
import 'package:tark/core/account/profile_sync.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/network/api_failure.dart';
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

  Future<void> pumpPage(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    Size size = const Size(400, 1400),
    bool reducedMotion = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: reducedMotion),
          child: child!,
        ),
        home: ProfilePage.buildPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  AppAvatar hero(WidgetTester tester) => tester
      .widgetList<AppAvatar>(find.byType(AppAvatar))
      .firstWhere((a) => a.size == 76);

  final edit = find.byKey(const ValueKey('profile-edit'));
  final editor = find.byKey(const ValueKey('profile-editor'));
  final nameField = find.byKey(const ValueKey('profile-name-field'));
  final avatar = find.byKey(const ValueKey('avatar-8'));
  final save = find.byKey(const ValueKey('profile-save'));

  Future<void> openEditor(WidgetTester tester) async {
    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(editor, findsOneWidget);
    expect(edit, findsNothing);
  }

  testWidgets('shows the saved name and face', (tester) async {
    await pumpPage(tester);
    expect(find.text('PROFILE'), findsOneWidget);
    expect(find.text('Pedi'), findsOneWidget);
    expect(hero(tester).avatarId, 3);
    expect(edit, findsOneWidget);
    expect(nameField, findsNothing);
    expect(avatar, findsNothing);
  });

  testWidgets('the open profile reflects a name synced from the account', (
    tester,
  ) async {
    await pumpPage(tester);
    await GetIt.instance<SettingsRepository>().setMyName('Account name');
    await tester.pumpAndSettle();

    expect(find.text('Account name'), findsOneWidget);
    await openEditor(tester);
    expect(
      tester.widget<TextField>(nameField).controller!.text,
      'Account name',
    );
  });

  testWidgets(
    'the editor previews the avatar and saves both changes together',
    (tester) async {
      await pumpPage(tester);
      await openEditor(tester);
      await tester.ensureVisible(avatar);
      await tester.pumpAndSettle();
      await tester.tap(avatar);
      await tester.enterText(nameField, 'Falcon42');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final preview = find.descendant(
        of: editor,
        matching: find.byType(AppAvatar),
      );
      expect(tester.widget<AppAvatar>(preview).avatarId, 8);
      expect(prefs.getInt(SettingsKeys.avatarId), 3);
      expect(prefs.getString(SettingsKeys.userName), 'Pedi');

      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(editor, findsNothing);
      expect(hero(tester).avatarId, 8);
      expect(find.text('Falcon42'), findsOneWidget);
      expect(prefs.getString(SettingsKeys.userName), 'Falcon42');
      expect(prefs.getInt(SettingsKeys.avatarId), 8);
      expect(LocalProfile.avatarId, 8, reason: 'what presence will carry');
    },
  );

  testWidgets(
    'closing discards the draft and a blank name keeps the editor open',
    (tester) async {
      await pumpPage(tester);
      await openEditor(tester);

      await tester.enterText(nameField, '   ');
      await tester.pump();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(prefs.getString(SettingsKeys.userName), 'Pedi');
      expect(find.text('Enter a radio name.'), findsOneWidget);
      expect(editor, findsOneWidget);

      await tester.enterText(nameField, 'Draft name');
      await tester.ensureVisible(avatar);
      await tester.pumpAndSettle();
      await tester.tap(avatar);
      await tester.tap(find.byKey(const ValueKey('profile-editor-close')));
      await tester.pumpAndSettle();
      expect(editor, findsNothing);
      expect(find.text('Pedi'), findsOneWidget);
      expect(hero(tester).avatarId, 3);
      expect(prefs.getString(SettingsKeys.userName), 'Pedi');
      expect(prefs.getInt(SettingsKeys.avatarId), 3);
    },
  );

  testWidgets('save stays reachable on a narrow RTL screen with the keyboard', (
    tester,
  ) async {
    await pumpPage(
      tester,
      locale: const Locale('fa'),
      size: const Size(320, 600),
      reducedMotion: true,
    );
    await openEditor(tester);
    await tester.enterText(nameField, 'شاهین');
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(save).dy, lessThanOrEqualTo(340));
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(editor, findsNothing);
    expect(find.text('شاهین'), findsOneWidget);
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

    testWidgets('editing the radio profile never waits for the account API', (
      tester,
    ) async {
      await account.signIn(
        session: sessionJson(
          profile: profileJson(name: 'Pedi', avatarId: '3'),
        ),
      );
      final response = Completer<ApiResponse>();
      account.client.handler = (_) => response.future;
      final sync = ProfileSync(
        session: account.session,
        store: account.store,
        settings: GetIt.instance<SettingsRepository>(),
      );
      addTearDown(sync.dispose);
      await sync.start();
      await pumpPage(tester);

      await openEditor(tester);
      await tester.enterText(nameField, 'Falcon');
      await tester.pump();
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(editor, findsNothing);
      expect(find.text('Falcon'), findsOneWidget);
      expect(account.client.to('/profile'), hasLength(1));
      expect(await account.store.isProfileDirty(), isTrue);

      response.complete(
        const ApiTransportFailure(NetworkUnreachable('offline')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Falcon'), findsOneWidget);
      expect(account.session.isSignedIn, isTrue);
    });

    testWidgets('signed out: one optional sign-in entry', (tester) async {
      await pumpPage(tester);
      expect(find.byKey(const ValueKey('account-sign-in')), findsOneWidget);
      expect(find.text('You can use the radio without signing in.'), findsOne);
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
      expect(find.byKey(const ValueKey('account-delete')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('account-email')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('account-change-password')), findsOne);
      expect(find.byKey(const ValueKey('account-delete')), findsOneWidget);
      expect(find.byKey(const ValueKey('account-subscription')), findsNothing);

      // Signing out asks first; backing out keeps the account.
      await tester.tap(find.byKey(const ValueKey('account-sign-out')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-sheet-cancel')));
      await tester.pumpAndSettle();
      expect(account.client.paths, isEmpty);
      expect(account.session.isSignedIn, isTrue);

      await tester.tap(find.byKey(const ValueKey('account-sign-out')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-sheet-action')));
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
      await tester.tap(find.byKey(const ValueKey('account-email')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('account-sign-out')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('account-change-password')),
        findsNothing,
      );
    });

    testWidgets('account expands with reduced motion on a narrow RTL screen', (
      tester,
    ) async {
      await account.signIn();
      await pumpPage(
        tester,
        locale: const Locale('fa'),
        size: const Size(320, 640),
        reducedMotion: true,
      );

      final email = find.byKey(const ValueKey('account-email'));
      final delete = find.byKey(const ValueKey('account-delete'));
      await tester.tap(email);
      await tester.pumpAndSettle();
      expect(delete, findsOneWidget);

      await tester.tap(email);
      await tester.pumpAndSettle();
      expect(delete, findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
