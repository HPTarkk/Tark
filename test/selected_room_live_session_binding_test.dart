import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_session.dart';
import 'package:tark/feature/room/domain/entity/transport_attachment.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/room/domain/service/selected_room_live_session_binding.dart';
import 'package:tark/feature/transfer/api/transfer_api.dart';

void main() {
  final roomId = RoomId('a' * 32);
  final memberId = RoomMemberId('b' * 24);
  final now = DateTime.utc(2026, 8, 26, 10);

  SavedRoom savedRoom() => SavedRoom(
    room: Room(
      id: roomId,
      name: 'Riders',
      createdAt: now,
      updatedAt: now,
      members: [
        RoomMember(id: memberId, displayName: 'Me', joinedAt: now),
      ],
    ),
    membership: RoomMembership(
      localMemberId: memberId,
      canManageInvites: true,
    ),
  );

  test('selected durable room follows live transport health', () async {
    final rooms = _RoomRepository(selected: roomId, saved: savedRoom());
    final transfer = _TransferRepository(role: SessionRole.host);
    final binding = SelectedRoomLiveSessionBinding(
      rooms: rooms,
      transfer: transfer,
      modeStore: _ModeStore(TransferMode.hotspot),
    );

    final runtime = await binding.open(sessionId: 'live-1');

    expect(runtime, isNotNull);
    expect(runtime!.state.roomId, roomId.value);
    expect(runtime.state.localMemberId, memberId.value);
    expect(runtime.state.attachment.kind, TransportKind.hotspot);
    expect(runtime.state.attachment.role, SessionRole.host.name);
    expect(runtime.state.attachment.phase, TransportAttachmentPhase.attaching);
    expect(transfer.connectCalls, 1);

    transfer.health.add(const ConnectionHealth.healthy());
    expect(runtime.state.phase, RoomSessionPhase.live);

    transfer.health.add(const ConnectionHealth.reconnecting());
    expect(runtime.state.phase, RoomSessionPhase.recoveringTransport);
    expect(runtime.state.roomId, roomId.value);
    expect(runtime.state.localMemberId, memberId.value);

    await binding.close();
    expect(runtime.hasLeft, isTrue);
    expect(transfer.health.hasListener, isFalse);
    await transfer.health.close();
  });

  test('no selected room preserves legacy entry without touching transport', () async {
    final transfer = _TransferRepository();
    final binding = SelectedRoomLiveSessionBinding(
      rooms: _RoomRepository(),
      transfer: transfer,
      modeStore: _ModeStore(TransferMode.wifi),
    );

    expect(await binding.open(sessionId: 'live-2'), isNull);
    expect(transfer.connectCalls, 0);
    await transfer.health.close();
  });

  test('transport mode maps without changing room identity semantics', () {
    expect(
      SelectedRoomLiveSessionBinding.transportKindFor(TransferMode.wifi),
      TransportKind.wifi,
    );
    expect(
      SelectedRoomLiveSessionBinding.transportKindFor(TransferMode.hotspot),
      TransportKind.hotspot,
    );
    expect(
      SelectedRoomLiveSessionBinding.transportKindFor(TransferMode.bluetooth),
      TransportKind.bluetooth,
    );
    expect(
      SelectedRoomLiveSessionBinding.transportKindFor(TransferMode.guest),
      TransportKind.webrtc,
    );
  });
}

class _RoomRepository implements RoomRepository {
  _RoomRepository({this.selected, this.saved});

  final RoomId? selected;
  final SavedRoom? saved;

  @override
  Future<RoomId?> selectedRoomId() async => selected;

  @override
  Future<SavedRoom?> get(RoomId id) async => id == selected ? saved : null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _TransferRepository implements TransferRepository {
  _TransferRepository({this.role = SessionRole.unknown});

  final SessionRole role;
  final StreamController<ConnectionHealth> health =
      StreamController<ConnectionHealth>.broadcast(sync: true);
  int connectCalls = 0;

  @override
  SessionRole get sessionRole => role;

  @override
  Stream<ConnectionHealth> connect() {
    connectCalls++;
    return health.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _ModeStore implements TransferModeStore {
  _ModeStore(this.current);

  final TransferMode current;

  @override
  TransferMode get mode => current;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
