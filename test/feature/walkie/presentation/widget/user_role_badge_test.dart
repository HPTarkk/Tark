import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/walkie/domain/entity/channel_user.dart';
import 'package:tark/feature/walkie/presentation/widget/user_list.dart';

ChannelUser member(
  SessionRole role, {
  String name = 'Falcon',
  bool isTalking = false,
}) => ChannelUser(
  id: 'a1b2c3',
  name: name,
  isTalking: isTalking,
  lastSeen: DateTime.now(),
  role: role,
);

Widget wrap(Widget child, {double width = 360}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  home: Scaffold(body: Center(child: SizedBox(width: width, child: child))),
);

void main() {
  testWidgets('a member tile names the part that member announced', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(UserTile(user: member(SessionRole.host))));

    expect(find.text('Falcon'), findsOneWidget);
    expect(find.text('Base Station'), findsOneWidget);
  });

  testWidgets('a member on a build without roles is left unlabelled', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(UserTile(user: member(SessionRole.unknown))));

    expect(find.text('Falcon'), findsOneWidget);
    expect(find.text('Base Station'), findsNothing);
    expect(find.text('Field Unit'), findsNothing);
    expect(find.text('Open Air'), findsNothing);
  });

  testWidgets('a long name, a role and the talking badges share a narrow tile', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        UserTile(
          user: member(
            SessionRole.joiner,
            name: 'Bahman on the long ride home',
            isTalking: true,
          ),
        ),
        width: 240,
      ),
    );
    // Not settled on purpose: the waveform next to a talker animates forever.
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(find.text('Field Unit'), findsOneWidget);
  });
}
