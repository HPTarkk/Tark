import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:tark/core/account/account_models.dart';
import 'package:tark/core/account/auth_repository.dart';
import 'package:tark/core/account/email_link.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/network/service_api.dart';
import 'package:tark/feature/account/api/account_api.dart';

import '../../core/account/account_fakes.dart';

void main() {
  late AccountHarness h;

  setUp(() {
    h = AccountHarness();
    GetIt.instance.registerSingleton<AuthRepository>(h.repository);
  });

  tearDown(() => GetIt.instance.reset());

  /// Pumps a launcher page that pushes [page] and records how it popped.
  Future<List<bool?>> pump(WidgetTester tester, WidgetBuilder page) async {
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final results = <bool?>[];
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => results.add(
                  await Navigator.of(
                    context,
                  ).push<bool>(MaterialPageRoute(builder: page)),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return results;
  }

  group('SignInPage', () {
    testWidgets('signs in with email and password and pops true', (
      tester,
    ) async {
      h.client.handler = (_) async => ApiOk(200, sessionJson());
      final results = await pump(tester, (_) => SignInPage.buildPage());

      await tester.enterText(
        find.byKey(const ValueKey('signin-email')),
        'pedi@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('signin-password')),
        'secret pass',
      );
      await tester.tap(find.byKey(const ValueKey('signin-submit')));
      await tester.pumpAndSettle();

      expect(h.client.requests.single.path, '/auth/login');
      expect(results, [true]);
      expect(h.session.isSignedIn, isTrue);
    });

    testWidgets('a refusal is shown in plain words, never the detail', (
      tester,
    ) async {
      h.client.handler = (_) async =>
          const ApiProblem(401, 'invalid_credentials');
      final results = await pump(tester, (_) => SignInPage.buildPage());
      await tester.enterText(
        find.byKey(const ValueKey('signin-email')),
        'pedi@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('signin-password')),
        'wrong',
      );
      await tester.tap(find.byKey(const ValueKey('signin-submit')));
      await tester.pumpAndSettle();

      expect(
        find.text("That email and password don't match an account."),
        findsOneWidget,
      );
      expect(results, isEmpty);
    });

    testWidgets('a code this build does not know shows the server\'s words', (
      tester,
    ) async {
      h.client.handler = (_) async => const ApiProblem(
        403,
        'brand_new_code',
        fields: {'message': 'Sign-in is paused for maintenance.'},
      );
      await pump(tester, (_) => SignInPage.buildPage());
      await tester.enterText(
        find.byKey(const ValueKey('signin-email')),
        'pedi@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('signin-password')),
        'secret pass',
      );
      await tester.tap(find.byKey(const ValueKey('signin-submit')));
      await tester.pumpAndSettle();

      expect(find.text('Sign-in is paused for maintenance.'), findsOneWidget);
    });

    testWidgets('an incomplete address is caught before sending', (
      tester,
    ) async {
      await pump(tester, (_) => SignInPage.buildPage());
      await tester.enterText(
        find.byKey(const ValueKey('signin-email')),
        'pedi@',
      );
      await tester.enterText(
        find.byKey(const ValueKey('signin-password')),
        'x',
      );
      await tester.tap(find.byKey(const ValueKey('signin-submit')));
      await tester.pumpAndSettle();
      expect(
        find.text("That email address doesn't look complete."),
        findsOneWidget,
      );
      expect(h.client.requests, isEmpty);
    });

    testWidgets('Google shows only when a client is configured', (
      tester,
    ) async {
      h.google.available = false;
      await pump(tester, (_) => SignInPage.buildPage());
      expect(find.byKey(const ValueKey('signin-google')), findsNothing);
    });

    testWidgets('Google link-required asks for the existing password', (
      tester,
    ) async {
      h.client.handler = (r) async => switch (r.path) {
        '/auth/google/nonce' => const ApiOk(200, {
          'nonce': 'n',
          'expiresAt': farFuture,
        }),
        '/auth/google' => const ApiProblem(
          409,
          'link_required',
          fields: {'ticket': 't', 'email': 'pe•••@gmail.com'},
        ),
        '/auth/google/link' => ApiOk(200, sessionJson()),
        _ => const ApiProblem(404, 'not_found'),
      };
      final results = await pump(tester, (_) => SignInPage.buildPage());
      await tester.tap(find.byKey(const ValueKey('signin-google')));
      await tester.pumpAndSettle();

      expect(find.text('You already have an account'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('google-link-password')),
        'old password',
      );
      await tester.tap(find.byKey(const ValueKey('google-link-submit')));
      await tester.pumpAndSettle();

      expect(h.client.paths.last, '/auth/google/link');
      expect(results, [true]);
    });

    testWidgets('create account → code → signed in, back to the start', (
      tester,
    ) async {
      h.client.handler = (r) async => switch (r.path) {
        '/auth/register' => ApiOk(202, flowJson()),
        '/auth/register/verify' => ApiOk(200, sessionJson()),
        _ => const ApiProblem(404, 'not_found'),
      };
      final results = await pump(tester, (_) => SignInPage.buildPage());
      await tester.tap(find.byKey(const ValueKey('signin-register')));
      await tester.pumpAndSettle();

      // The name starts as the radio name this phone already uses.
      expect(find.text('Pedi'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('register-email')),
        'new@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('register-password')),
        'long enough',
      );
      await tester.tap(find.byKey(const ValueKey('register-submit')));
      await tester.pumpAndSettle();

      expect(find.text('Check your email'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('code-field')),
        '123456',
      );
      await tester.pumpAndSettle();

      expect(h.client.requests.last.body, {
        'flowId': 'flow-1',
        'code': '123456',
      });
      expect(results, [true]);
    });
  });

  group('CodeEntryPage', () {
    testWidgets('a wrong code is cleared and says how many tries are left', (
      tester,
    ) async {
      await h.store.writeFlow(
        PendingFlow.fromResponse(FlowKind.register, 'a@b.co', flowJson())!,
      );
      h.client.handler = (_) async =>
          const ApiProblem(422, 'code_invalid', fields: {'attemptsLeft': 3});
      await pump(
        tester,
        (_) => CodeEntryPage.buildPage(kind: FlowKind.register),
      );
      await tester.enterText(
        find.byKey(const ValueKey('code-field')),
        '000000',
      );
      await tester.pumpAndSettle();

      expect(
        find.text("That code doesn't match. 3 tries left."),
        findsOneWidget,
      );
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('code-field')),
      );
      expect(field.controller!.text, isEmpty);
    });

    testWidgets('a link for a flow this phone did not start: type the code', (
      tester,
    ) async {
      final results = await pump(
        tester,
        (_) => CodeEntryPage.buildForLink(
          const EmailLink(segment: 'register', token: 'tok'),
        ),
      );
      expect(find.text('Type the code instead'), findsOneWidget);
      expect(h.client.requests, isEmpty);
      await tester.tap(find.byKey(const ValueKey('code-close')));
      await tester.pumpAndSettle();
      expect(results, [false]);
    });

    testWidgets('an email link arriving while open finishes the flow', (
      tester,
    ) async {
      final dispatcher = EmailLinkDispatcher();
      GetIt.instance.registerSingleton<EmailLinkDispatcher>(dispatcher);
      await h.store.writeFlow(
        PendingFlow.fromResponse(FlowKind.register, 'a@b.co', flowJson())!,
      );
      h.client.handler = (_) async => ApiOk(200, sessionJson());
      final results = await pump(
        tester,
        (_) => CodeEntryPage.buildPage(kind: FlowKind.register),
      );

      dispatcher.dispatch(const EmailLink(segment: 'register', token: 'tok'));
      await tester.pumpAndSettle();

      expect(h.client.requests.single.body!['linkToken'], 'tok');
      expect(results, [true]);
    });
  });

  group('DeleteAccountPage', () {
    testWidgets('confirms, then asks to acknowledge a running subscription', (
      tester,
    ) async {
      await h.signIn();
      h.client.handler = (r) async =>
          r.body!['subscriptionAcknowledged'] == true
          ? const ApiOk(204, {})
          : const ApiProblem(
              409,
              'subscription_active',
              fields: {'autoRenewing': true},
            );
      final results = await pump(
        tester,
        (_) => DeleteAccountPage.buildPage(profile: h.session.current!),
      );

      await tester.enterText(
        find.byKey(const ValueKey('delete-email')),
        'pedi@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('delete-password')),
        'pw',
      );
      await tester.tap(find.byKey(const ValueKey('delete-submit')));
      await tester.pumpAndSettle();
      // The last "are you sure" sheet.
      expect(find.text('Delete your account for good?'), findsOneWidget);
      await tester.tap(find.text('DELETE MY ACCOUNT').last);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('delete-subscription-notice')),
        findsOneWidget,
      );
      expect(results, isEmpty);

      await tester.tap(find.byKey(const ValueKey('delete-subscription-ack')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('DELETE MY ACCOUNT').last);
      await tester.pumpAndSettle();

      expect(results, [true]);
      expect(h.session.isSignedIn, isFalse);
    });
  });

  group('Persian layout', () {
    Future<void> pumpFa(WidgetTester tester, Widget page) async {
      tester.view.physicalSize = const Size(420, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('fa'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: page,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('an email field types left to right but sits right to left', (
      tester,
    ) async {
      await pumpFa(tester, SignInPage.buildPage());
      final email = find.byKey(const ValueKey('signin-email'));

      // What is typed is an address, so it runs left to right…
      expect(tester.widget<TextField>(email).textDirection, TextDirection.ltr);
      // …while its icon and label follow the page, starting on the right.
      final field = tester.getRect(email);
      final icon = tester.getCenter(
        find.descendant(
          of: email,
          matching: find.byIcon(Icons.alternate_email_rounded),
        ),
      );
      expect(icon.dx, greaterThan(field.center.dx));
      final label = tester.getCenter(
        find.descendant(of: email, matching: find.text('آدرس ایمیل')),
      );
      expect(label.dx, greaterThan(field.center.dx));
    });

    testWidgets('the show-password button sits on the left', (tester) async {
      await pumpFa(tester, SignInPage.buildPage());
      final password = find.byKey(const ValueKey('signin-password'));
      final eye = tester.getCenter(
        find.descendant(
          of: password,
          matching: find.byIcon(Icons.visibility_outlined),
        ),
      );
      expect(eye.dx, lessThan(tester.getRect(password).center.dx));
    });

    testWidgets('Persian button labels keep their letters joined', (
      tester,
    ) async {
      await pumpFa(tester, SignInPage.buildPage());
      final label = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('signin-submit')),
          matching: find.byType(Text),
        ),
      );
      expect(label.style?.letterSpacing, 0);
    });
  });

  testWidgets('signing in shows the check mark before the screen leaves', (
    tester,
  ) async {
    h.client.handler = (_) async => ApiOk(200, sessionJson());
    final results = await pump(tester, (_) => SignInPage.buildPage());
    await tester.enterText(
      find.byKey(const ValueKey('signin-email')),
      'pedi@example.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('signin-password')),
      'secret pass',
    );
    await tester.tap(find.byKey(const ValueKey('signin-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byIcon(Icons.check_rounded), findsWidgets);
    expect(results, isEmpty);

    await tester.pumpAndSettle();
    expect(results, [true]);
  });
}
