import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:tark/core/account/auth_repository.dart';
import 'package:tark/core/account/auth_result.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/theme/app_colors.dart';
import 'package:tark/feature/account/api/account_api.dart';
import 'package:tark/feature/account/presentation/widget/auth_motion.dart';
import 'package:tark/feature/account/presentation/widget/auth_widgets.dart';

import '../../core/account/account_fakes.dart';

/// The account flow's motion: one glyph carried from screen to screen, a
/// button that becomes its own progress, and fields that answer the thumb.
void main() {
  Widget app(Widget home, {bool reduced = false}) => MaterialApp(
    locale: const Locale('en'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: child!,
    ),
    home: home,
  );

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  group('which field a refusal is about', () {
    const signIn = [(AuthField.email, 'a@b.co'), (AuthField.password, '')];
    test('nothing typed points at the first empty field', () {
      expect(
        authErrorField(const AuthError(AuthErrorKind.incomplete), signIn),
        AuthField.password,
      );
      expect(
        authErrorField(const AuthError(AuthErrorKind.incomplete), const [
          (AuthField.name, ''),
          (AuthField.email, ''),
        ]),
        AuthField.name,
      );
    });

    test('an address problem points at the email field', () {
      for (final kind in [
        AuthErrorKind.emailInvalid,
        AuthErrorKind.emailAlreadyRegistered,
      ]) {
        expect(authErrorField(AuthError(kind), signIn), AuthField.email);
      }
    });

    test('a wrong password points at the password, a weak one at the new', () {
      expect(
        authErrorField(
          const AuthError(AuthErrorKind.invalidCredentials),
          signIn,
        ),
        AuthField.password,
      );
      const change = [
        (AuthField.password, 'old'),
        (AuthField.newPassword, 'short'),
      ];
      expect(
        authErrorField(const AuthError(AuthErrorKind.passwordTooShort), change),
        AuthField.newPassword,
      );
      expect(
        authErrorField(
          const AuthError(AuthErrorKind.invalidRequest, field: 'name'),
          const [(AuthField.name, 'x')],
        ),
        AuthField.name,
      );
    });

    test('a refusal about no one field points at none', () {
      for (final kind in [
        AuthErrorKind.offline,
        AuthErrorKind.rateLimited,
        AuthErrorKind.accountDisabled,
      ]) {
        expect(authErrorField(AuthError(kind), signIn), isNull);
      }
      expect(authErrorField(null, signIn), isNull);
      // A field the screen does not have is never pointed at.
      expect(
        authErrorField(const AuthError(AuthErrorKind.emailInvalid), const [
          (AuthField.newPassword, ''),
        ]),
        isNull,
      );
    });
  });

  group('the glyph carries over', () {
    late AccountHarness h;
    setUp(() {
      h = AccountHarness();
      GetIt.instance.registerSingleton<AuthRepository>(h.repository);
    });
    tearDown(() => GetIt.instance.reset());

    Widget launcher() => Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: GestureDetector(
            onTap: () => pushAuthPage(
              context,
              SignInPage.routeName,
              (_) => SignInPage.buildPage(),
            ),
            child: AuthHero(
              icon: Icons.login_rounded,
              color: AppColors.amber,
              look: AuthHeroLook.badge(AppColors.amber),
              child: const SizedBox.square(
                dimension: 42,
                child: Icon(Icons.login_rounded),
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets('from the account card into sign-in, and on to sign-up', (
      tester,
    ) async {
      phone(tester);
      await tester.pumpWidget(app(launcher()));
      await tester.tap(find.byIcon(Icons.login_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byKey(const ValueKey('auth-hero-flight')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('auth-hero-flight')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('signin-register')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byKey(const ValueKey('auth-hero-flight')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('register-name')), findsOneWidget);

      // And back the same way.
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byKey(const ValueKey('auth-hero-flight')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('signin-email')), findsOneWidget);
    });

    testWidgets('reduced motion: nothing flies', (tester) async {
      phone(tester);
      await tester.pumpWidget(app(launcher(), reduced: true));
      await tester.tap(find.byIcon(Icons.login_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byKey(const ValueKey('auth-hero-flight')), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('signin-email')), findsOneWidget);
    });
  });

  group('the main button', () {
    Widget button({required bool busy, bool done = false}) => Scaffold(
      body: Center(
        child: SizedBox(
          width: 300,
          child: AuthPrimaryButton(
            buttonKey: const ValueKey('b'),
            label: 'SIGN IN',
            busyLabel: 'SIGNING IN',
            busy: busy,
            done: done,
            onTap: () {},
          ),
        ),
      ),
    );

    double width(WidgetTester tester) =>
        tester.getSize(find.byKey(const ValueKey('b'))).width;

    testWidgets('hands its label over vertically to what it is doing', (
      tester,
    ) async {
      await tester.pumpWidget(app(button(busy: false)));
      final rest = tester.getCenter(find.text('SIGN IN')).dy;
      await tester.pumpWidget(app(button(busy: true)));
      await tester.pump(const Duration(milliseconds: 90));
      // Mid hand-over: the label is lifting away, the busy line rising in
      // from below. No sideways travel, no change of shape.
      expect(tester.getCenter(find.text('SIGN IN')).dy, lessThan(rest));
      expect(
        tester.getCenter(find.text('SIGNING IN')).dy,
        greaterThan(rest - 1),
      );
      expect(width(tester), 300);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('SIGN IN'), findsNothing);
      expect(find.text('SIGNING IN'), findsOneWidget);
      expect(find.text('SIGNING IN...'), findsNothing);
      expect(find.byType(AuthOrbitIndicator), findsOneWidget);
      expect(width(tester), 300);

      await tester.pumpWidget(app(button(busy: false, done: true)));
      await tester.pumpAndSettle();
      expect(find.byType(AuthOrbitIndicator), findsNothing);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    Finder orbitRotation() => find.descendant(
      of: find.byType(AuthOrbitIndicator),
      matching: find.byType(RotationTransition),
    );

    testWidgets('the orbit turns continuously through a full loop', (
      tester,
    ) async {
      await tester.pumpWidget(app(button(busy: true)));
      final turns = tester.widget<RotationTransition>(orbitRotation()).turns;
      final start = turns.value;

      for (var i = 0; i < 4; i++) {
        final before = turns.value;
        await tester.pump(const Duration(milliseconds: 275));
        expect((turns.value - before) % 1, closeTo(0.25, 0.001));
      }
      expect(turns.value, closeTo(start, 0.001));
    });

    testWidgets('reduced motion: words still change, orbit holds still', (
      tester,
    ) async {
      await tester.pumpWidget(app(button(busy: true), reduced: true));
      await tester.pumpAndSettle();
      expect(find.text('SIGNING IN'), findsOneWidget);
      expect(tester.widget<RotationTransition>(orbitRotation()).turns.value, 0);
      expect(width(tester), 300);
    });
  });

  group('fields', () {
    testWidgets('a new password fills its meter and ticks once long enough', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        app(
          Scaffold(
            body: AuthTextField(
              fieldKey: const ValueKey('f'),
              controller: controller,
              hint: 'New password',
              obscure: true,
              minLength: 8,
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('f')), 'abc');
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.circle_outlined), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('f')), 'abcdefgh');
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    });

    testWidgets('the field a refusal is about shakes', (tester) async {
      final controller = TextEditingController(text: 'x');
      addTearDown(controller.dispose);
      Widget field(Object? nudge) => app(
        Scaffold(
          body: Center(
            child: AuthTextField(
              fieldKey: const ValueKey('f'),
              controller: controller,
              hint: 'Email',
              nudge: nudge,
            ),
          ),
        ),
      );
      double dx() => tester.getTopLeft(find.byKey(const ValueKey('f'))).dx;
      await tester.pumpWidget(field(null));
      final rest = dx();
      await tester.pumpWidget(
        field(const AuthError(AuthErrorKind.emailInvalid)),
      );
      await tester.pump(const Duration(milliseconds: 40));
      expect(dx(), isNot(rest));
      await tester.pumpAndSettle();
      expect(dx(), rest);
    });
  });
}
