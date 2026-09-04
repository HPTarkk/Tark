import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/motion/app_motion.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/walkie/domain/entity/channel_user.dart';
import 'package:tark/feature/walkie/presentation/manager/walkie_talkie_cubit.dart';
import 'package:tark/feature/walkie/presentation/widget/user_list.dart';

/// R32. Adding someone to a room you are already riding in happens once a ride
/// at most, and it was holding the trailing edge of the one screen a rider
/// looks at for the whole trip.
///
/// The point of moving it into the members card is not that the card had room.
/// It is that the card knows the answer to "is anybody here", and that answer
/// is exactly what decides whether inviting is the thing to press — which is
/// something a header pill could never express. So these test the *weight*,
/// not the placement.
void main() {
  const primary = Key('channel-invite-primary');
  const quiet = Key('channel-invite-quiet');

  late SharedPreferencesRoomRepository rooms;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    rooms = SharedPreferencesRoomRepository();
  });

  tearDown(() async => GetIt.instance.reset());

  /// The card builds its action with no seam, resolving the canonical
  /// registration — so the composition is what is under test here, not a
  /// widget handed a repository by hand.
  void register() => GetIt.instance.registerSingleton<RoomRepository>(rooms);

  Future<void> selectARoom() async {
    final created = await rooms.create(
      name: 'Night ride',
      localDisplayName: 'Pedram',
    );
    await rooms.select(created.room.id);
  }

  Future<void> pump(
    WidgetTester tester, {
    required List<ChannelUser> users,
    Locale locale = const Locale('en'),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider<WalkieTalkieCubit>(
          create: (_) => _StubWalkieCubit(
            WalkieTalkieState.initial().copyWith(activeUsers: users),
          ),
          child: const Scaffold(body: SingleChildScrollView(child: UserList())),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('an empty channel makes inviting the lit control', (
    tester,
  ) async {
    register();
    await selectARoom();
    await pump(tester, users: const []);

    expect(find.byKey(primary), findsOneWidget);
    expect(find.byKey(quiet), findsNothing);

    // "Exactly one control glows" is the whole reason the variant exists, so
    // read the glow rather than trusting the key.
    final glow = tester.widget<PulseGlow>(
      find.descendant(
        of: find.byKey(primary),
        matching: find.byType(PulseGlow),
      ),
    );
    expect(glow.enabled, isTrue);
  });

  testWidgets('somebody else here makes it a quiet control under the list', (
    tester,
  ) async {
    register();
    await selectARoom();
    await pump(tester, users: [_rider()]);

    expect(find.byKey(quiet), findsOneWidget);
    expect(find.byKey(primary), findsNothing);

    // The screen's attention belongs to the mic once the channel is real.
    final glow = tester.widget<PulseGlow>(
      find.descendant(of: find.byKey(quiet), matching: find.byType(PulseGlow)),
    );
    expect(glow.enabled, isFalse);
  });

  testWidgets('no Room means no invite, in either weight', (tester) async {
    // A plain channel with no durable Room has nothing to invite anyone into,
    // and a control that opens a sheet only to explain why it cannot help is
    // worse than no control.
    register();
    await pump(tester, users: const []);
    expect(find.byKey(primary), findsNothing);
    expect(find.byKey(quiet), findsNothing);

    await pump(tester, users: [_rider()]);
    expect(find.byKey(quiet), findsNothing);
  });

  testWidgets('the empty card still says what it always said', (tester) async {
    // Without a Room the callout keeps its heading and simply stops one line
    // earlier, which is exactly the card this replaced.
    register();
    await pump(tester, users: const []);

    expect(find.text('Nobody else here yet'), findsOneWidget);
    expect(find.byIcon(Icons.wifi_tethering_off_rounded), findsNothing);
  });

  testWidgets('it follows storage, not the tap that changed it', (
    tester,
  ) async {
    register();
    await pump(tester, users: const []);
    expect(find.byKey(primary), findsNothing);

    // A room can be selected while this card is already on screen, and a
    // covered route is never rebuilt — storage is the only thing that knows
    // the answer changed (R23).
    await selectARoom();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(primary), findsOneWidget);
  });

  testWidgets('Persian keeps its own copy at 320', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    register();
    await selectARoom();
    await pump(tester, users: const [], locale: const Locale('fa'));

    expect(find.byKey(primary), findsOneWidget);
    expect(find.text('دعوت کنید'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

ChannelUser _rider() => ChannelUser(
  id: '10.0.0.2',
  name: 'Rider B',
  isTalking: false,
  lastSeen: DateTime.utc(2026, 9, 2),
);

class _StubWalkieCubit extends Cubit<WalkieTalkieState>
    implements WalkieTalkieCubit {
  _StubWalkieCubit(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
