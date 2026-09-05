import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/core/widget/qr_scanner_surface.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_accepted_join_snapshot.dart';
import 'package:tark/feature/room/domain/entity/room_direct_join_bundle.dart';
import 'package:tark/feature/room/domain/entity/room_scan_invite.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';
import 'package:tark/feature/room/presentation/manager/room_list_cubit.dart';
import 'package:tark/feature/room/presentation/page/room_qr_join_page.dart';

void main() {
  testWidgets('membership is imported before one-scan network setup opens', (
    tester,
  ) async {
    final events = <String>[];
    final handed = <Object?>[];
    final cubit = _AcceptingRoomList(onJoin: () => events.add('membership'));
    final router = _router(
      cubit: cubit,
      onConnect: (extra) {
        events.add('transport');
        handed.add(extra);
      },
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(_app(router));
    await tester.pump(const Duration(milliseconds: 100));
    final surface = tester.widget<QrScannerSurface>(find.byType(QrScannerSurface));
    const bootstrap = 'WIFI:S:Tark-Ride;T:WPA;P:secret123;;';
    final encoded = RoomScanInvite(
      bundle: _fixture(),
      transportBootstrap: bootstrap,
    ).encode();

    expect(await surface.onCode(encoded), isTrue);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(events, ['membership', 'transport']);
    expect(cubit.joined, hasLength(1));
    expect(handed, [bootstrap]);
    expect(find.byKey(const Key('connect-page')), findsOneWidget);
  });

  testWidgets('direct invite still joins the Room and opens its lobby', (
    tester,
  ) async {
    final cubit = _AcceptingRoomList();
    final router = _router(cubit: cubit);
    addTearDown(router.dispose);

    await tester.pumpWidget(_app(router));
    await tester.pump(const Duration(milliseconds: 100));
    final surface = tester.widget<QrScannerSurface>(find.byType(QrScannerSurface));

    expect(await surface.onCode(_fixture().encode()), isTrue);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(cubit.joined, hasLength(1));
    expect(find.byKey(const Key('walkie-page')), findsOneWidget);
  });

  testWidgets('invalid bootstrap never prevents durable Room join', (
    tester,
  ) async {
    final events = <String>[];
    final cubit = _AcceptingRoomList(onJoin: () => events.add('membership'));
    final router = _router(
      cubit: cubit,
      onConnect: (_) => events.add('transport'),
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(_app(router));
    await tester.pump(const Duration(milliseconds: 100));
    final surface = tester.widget<QrScannerSurface>(find.byType(QrScannerSurface));
    final encoded = RoomScanInvite(
      bundle: _fixture(),
      transportBootstrap: 'not-a-network-payload',
    ).encode();

    expect(await surface.onCode(encoded), isTrue);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(events, ['membership']);
    expect(cubit.joined, hasLength(1));
    expect(find.byKey(const Key('walkie-page')), findsOneWidget);
  });
}

Widget _app(GoRouter router) => MaterialApp.router(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  routerConfig: router,
);

GoRouter _router({
  required _AcceptingRoomList cubit,
  ValueChanged<Object?>? onConnect,
}) => GoRouter(
  initialLocation: AppRoutes.roomQrJoinPath,
  routes: [
    GoRoute(
      path: AppRoutes.roomQrJoinPath,
      builder: (_, _) => RoomQrJoinPage(cubit: cubit),
    ),
    GoRoute(
      path: AppRoutes.wifiHotspotPath,
      builder: (_, state) {
        onConnect?.call(state.extra);
        return const Scaffold(
          key: Key('connect-page'),
          body: SizedBox.shrink(),
        );
      },
    ),
    GoRoute(
      path: AppRoutes.walkiePath,
      builder: (_, _) => const Scaffold(
        key: Key('walkie-page'),
        body: SizedBox.shrink(),
      ),
    ),
  ],
);

class _AcceptingRoomList implements RoomListCubit {
  _AcceptingRoomList({this.onJoin});

  final VoidCallback? onJoin;
  final List<RoomDirectJoinBundle> joined = [];

  @override
  Future<bool> joinDirect(
    RoomDirectJoinBundle bundle, {
    String? localDisplayName,
  }) async {
    joined.add(bundle);
    onJoin?.call();
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

const _roomId = RoomId('abababababababababababababababab');
const _ownerId = RoomMemberId('111111111111111111111111');
const _joinerId = RoomMemberId('222222222222222222222222');
final _createdAt = DateTime.utc(2026, 9, 5, 1, 0);

List<int> _filled(int length, int seed) =>
    List<int>.generate(length, (i) => (i * 7 + seed) & 0xff, growable: false);

RoomDirectJoinBundle _fixture() {
  final keyPair = RoomMemberTransportKeyPair(
    privateKey: _filled(32, 3),
    publicKey: _filled(32, 11),
  );
  return RoomDirectJoinBundle(
    memberId: _joinerId,
    snapshot: RoomAcceptedJoinSnapshot(
      roomId: _roomId,
      roomName: 'Ride',
      roomCreatedAt: _createdAt,
      roomUpdatedAt: _createdAt,
      members: [
        RoomAcceptedJoinMember(
          memberId: _ownerId,
          displayName: 'Host',
          joinedAt: _createdAt,
          kind: RoomMemberKind.member,
        ),
        RoomAcceptedJoinMember(
          memberId: _joinerId,
          displayName: 'Open seat',
          joinedAt: _createdAt,
          kind: RoomMemberKind.member,
        ),
      ],
      grantsInviteManagement: false,
    ),
    memberKeyPair: keyPair,
    certificate: RoomMemberTransportCertificate(
      roomId: _roomId,
      memberId: _joinerId,
      memberPublicKey: keyPair.publicKey,
      issuerPublicKey: _filled(32, 29),
      issuerSignature: _filled(64, 47),
    ),
    expiresAt: DateTime.utc(2099),
  );
}
