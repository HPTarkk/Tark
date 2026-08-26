import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/presentation/widget/in_room_invite_button.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<SharedPreferencesRoomRepository> repositoryWithSelectedRoom() async {
    final repository = SharedPreferencesRoomRepository();
    final saved = await repository.create(
      name: 'Night ride',
      localDisplayName: 'Rider A',
    );
    await repository.select(saved.room.id);
    return repository;
  }

  Widget app({
    required SharedPreferencesRoomRepository repository,
    required Locale locale,
  }) => MediaQuery(
    data: const MediaQueryData(size: Size(320, 640)),
    child: MaterialApp(
      locale: locale,
      supportedLocales: const [Locale('en'), Locale('fa')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(
        body: SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: InRoomInviteButton(repository: repository),
          ),
        ),
      ),
    ),
  );

  testWidgets('issues canonical Room invite and fits 320px', (tester) async {
    final repository = await repositoryWithSelectedRoom();
    await tester.pumpWidget(
      app(repository: repository, locale: const Locale('en')),
    );

    await tester.tap(find.byKey(const Key('in-room-add-rider')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('room-invite-dialog')), findsOneWidget);
    expect(find.byKey(const Key('room-invite-qr')), findsOneWidget);
    expect(find.text('Night ride'), findsOneWidget);
    expect(find.byKey(const Key('room-invite-display-code')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Persian invite entry and sheet preserve RTL at 320px', (
    tester,
  ) async {
    final repository = await repositoryWithSelectedRoom();
    await tester.pumpWidget(
      app(repository: repository, locale: const Locale('fa')),
    );

    expect(
      tester
          .widget<Directionality>(find.byType(Directionality).first)
          .textDirection,
      TextDirection.rtl,
    );
    expect(find.bySemanticsLabel('افزودن همراه'), findsOneWidget);

    await tester.tap(find.byKey(const Key('in-room-add-rider')));
    await tester.pumpAndSettle();

    expect(find.text('دعوت به اتاق'), findsOneWidget);
    expect(
      find.text('این کد فقط برای بررسی است و به‌تنهایی اجازه ورود نمی‌دهد.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('no selected Room fails closed without issuing an invite', (
    tester,
  ) async {
    final repository = SharedPreferencesRoomRepository();
    await tester.pumpWidget(
      app(repository: repository, locale: const Locale('en')),
    );

    await tester.tap(find.byKey(const Key('in-room-add-rider')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('room-invite-dialog')), findsNothing);
    expect(
      find.text('Select an active Room where you can manage invites first.'),
      findsOneWidget,
    );
  });
}
