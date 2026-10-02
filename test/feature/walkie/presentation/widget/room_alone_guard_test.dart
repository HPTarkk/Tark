import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/walkie/domain/entity/channel_user.dart';
import 'package:tark/feature/walkie/presentation/manager/walkie_talkie_cubit.dart';
import 'package:tark/feature/walkie/presentation/widget/room_alone_guard.dart';

void main() {
  const limit = RoomAloneGuard.defaultAloneLimit;
  const countdown = RoomAloneGuard.defaultCountdown;
  final someone = ChannelUser(
    id: 'ali',
    name: 'Ali',
    isTalking: false,
    lastSeen: DateTime(2026, 10, 2),
  );

  late _StubWalkieCubit cubit;
  late int leaves;

  Future<void> pump(
    WidgetTester tester, {
    required List<ChannelUser> users,
    bool inRoom = true,
    Locale locale = const Locale('en'),
  }) async {
    cubit = _StubWalkieCubit(
      WalkieTalkieState.initial().copyWith(activeUsers: users),
    );
    addTearDown(cubit.close);
    leaves = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        builder: (context, app) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.35)),
          child: app!,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider<WalkieTalkieCubit>.value(
          value: cubit,
          child: Scaffold(
            body: RoomAloneGuard(onLeave: () => leaves++, inRoom: inRoom),
          ),
        ),
      ),
    );
  }

  Finder overlay() => find.byKey(const Key('room-alone-countdown'));

  testWidgets('alone for nine minutes: the countdown takes the screen', (
    tester,
  ) async {
    await pump(tester, users: const []);
    await tester.pump(limit - countdown - const Duration(seconds: 1));
    expect(overlay(), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(overlay(), findsOneWidget);
    expect(find.text('60'), findsOneWidget);
    expect(find.text('Stay longer'), findsOneWidget);
  });

  testWidgets('the count runs out: the call ends by itself', (tester) async {
    await pump(tester, users: const []);
    await tester.pump(limit - countdown);
    for (var i = 0; i < 59; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(leaves, 0);
    expect(find.text('1'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(leaves, 1);
  });

  testWidgets('stay longer starts the whole wait over', (tester) async {
    await pump(tester, users: const []);
    await tester.pump(limit - countdown);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('room-alone-stay')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(overlay(), findsNothing);

    await tester.pump(countdown);
    expect(leaves, 0);
    await tester.pump(limit - countdown - countdown);
    await tester.pump(const Duration(milliseconds: 400));
    expect(overlay(), findsOneWidget);
    expect(leaves, 0);
  });

  testWidgets('someone coming back closes it', (tester) async {
    await pump(tester, users: const []);
    await tester.pump(limit - countdown);
    await tester.pump(const Duration(milliseconds: 400));
    expect(overlay(), findsOneWidget);

    cubit.emit(cubit.state.copyWith(activeUsers: [someone]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(overlay(), findsNothing);
    await tester.pump(countdown);
    expect(leaves, 0);
  });

  testWidgets('fits a small phone in Persian at large text', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pump(tester, users: const [], locale: const Locale('fa'));
    await tester.pump(limit - countdown);
    await tester.pump(const Duration(milliseconds: 400));
    expect(overlay(), findsOneWidget);
    expect(find.text('۶۰'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('not alone: nothing happens', (tester) async {
    await pump(tester, users: [someone]);
    await tester.pump(limit * 2);
    expect(overlay(), findsNothing);
    expect(leaves, 0);
  });

  testWidgets('outside a Room it never counts', (tester) async {
    await pump(tester, users: const [], inRoom: false);
    await tester.pump(limit * 2);
    expect(overlay(), findsNothing);
    expect(leaves, 0);
  });
}

class _StubWalkieCubit extends Cubit<WalkieTalkieState>
    implements WalkieTalkieCubit {
  _StubWalkieCubit(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
