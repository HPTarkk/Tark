import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/account/presentation/widget/auth_widgets.dart';
import 'package:tark/feature/account/presentation/widget/code_input.dart';

void main() {
  testWidgets(
    'Persian: a name reads in Persian digits, identifiers keep what was typed',
    (tester) async {
      final name = TextEditingController();
      final email = TextEditingController();
      final password = TextEditingController();
      addTearDown(name.dispose);
      addTearDown(email.dispose);
      addTearDown(password.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('fa'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Column(
              children: [
                AuthTextField(
                  controller: name,
                  hint: 'name',
                  fieldKey: const Key('name'),
                ),
                AuthTextField(
                  controller: email,
                  hint: 'email',
                  ltr: true,
                  fieldKey: const Key('email'),
                ),
                AuthTextField(
                  controller: password,
                  hint: 'password',
                  ltr: true,
                  obscure: true,
                  fieldKey: const Key('password'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.enterText(find.byKey(const Key('name')), 'علی 7');
      await tester.enterText(find.byKey(const Key('email')), 'ali7@x.io');
      await tester.enterText(find.byKey(const Key('password')), 'pass۱2');
      await tester.pump();
      expect(name.text, 'علی ۷');
      expect(email.text, 'ali7@x.io');
      expect(password.text, 'pass۱2');
    },
  );

  testWidgets('the account code takes a Persian keypad, holds ASCII, shows '
      'Persian', (tester) async {
    final code = TextEditingController();
    addTearDown(code.dispose);
    String? completed;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('fa'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: CodeInput(
            controller: code,
            length: 6,
            onCompleted: (value) => completed = value,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('code-field')), '۱۲٣4۵۶');
    await tester.pump();
    expect(code.text, '123456');
    expect(completed, '123456');
    expect(find.text('۱'), findsOneWidget);
    expect(find.text('۴'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
  });
}
