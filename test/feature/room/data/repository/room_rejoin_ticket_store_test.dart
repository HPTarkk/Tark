import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/room/data/repository/room_rejoin_ticket_store.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';

void main() {
  const room = RoomId('0123456789abcdef0123456789abcdef');
  const network = HotspotCredentials(ssid: 'DIRECT-ab', passphrase: 'p:a;ss');

  late _MemorySecrets secrets;
  late RoomRejoinTicketStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secrets = _MemorySecrets();
    store = RoomRejoinTicketStore(secrets: secrets);
  });

  test('a joiner on a shared connection gets its network back', () async {
    final at = DateTime(2026, 10, 2, 19);
    await store.save(
      RoomRejoinTicket(
        roomId: room,
        mode: TransferMode.hotspot,
        side: SessionRole.joiner,
        at: at,
        credentials: network,
      ),
    );

    final ticket = await store.read();
    expect(ticket, isNotNull);
    expect(ticket!.roomId, room);
    expect(ticket.mode, TransferMode.hotspot);
    expect(ticket.side, SessionRole.joiner);
    expect(ticket.at, at);
    expect(ticket.credentials, network);
    expect(RoomRejoinTicketStore.savedThisRun, isTrue);
  });

  test('the network never goes into preferences', () async {
    await store.save(
      RoomRejoinTicket(
        roomId: room,
        mode: TransferMode.hotspot,
        side: SessionRole.joiner,
        at: DateTime(2026, 10, 2),
        credentials: network,
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      final value = '${prefs.get(key)}';
      expect(value, isNot(contains(network.ssid)));
      expect(value, isNot(contains(network.passphrase)));
    }
    expect(secrets.stored, network);
  });

  test('the phone that shared keeps no network', () async {
    secrets.stored = network;
    await store.save(
      RoomRejoinTicket(
        roomId: room,
        mode: TransferMode.hotspot,
        side: SessionRole.host,
        at: DateTime(2026, 10, 2),
      ),
    );

    final ticket = await store.read();
    expect(ticket!.side, SessionRole.host);
    expect(ticket.credentials, isNull);
    expect(secrets.stored, isNull);
  });

  test('clear removes both halves', () async {
    await store.save(
      RoomRejoinTicket(
        roomId: room,
        mode: TransferMode.hotspot,
        side: SessionRole.joiner,
        at: DateTime(2026, 10, 2),
        credentials: network,
      ),
    );
    await store.clear();

    expect(await store.read(), isNull);
    expect(secrets.stored, isNull);
  });

  test('a ticket goes stale after its window', () {
    final at = DateTime(2026, 10, 2, 19);
    final ticket = RoomRejoinTicket(
      roomId: room,
      mode: TransferMode.wifi,
      side: SessionRole.peer,
      at: at,
    );
    expect(ticket.isFresh(at.add(const Duration(minutes: 5))), isTrue);
    expect(ticket.isFresh(at.add(RoomRejoinTicket.maxAge)), isFalse);
  });

  test('unreadable storage reads as no ticket', () async {
    SharedPreferences.setMockInitialValues({'room_rejoin_ticket': 'not json'});
    expect(await RoomRejoinTicketStore(secrets: secrets).read(), isNull);
  });
}

class _MemorySecrets implements RoomRejoinSecrets {
  HotspotCredentials? stored;

  @override
  Future<void> delete() async => stored = null;

  @override
  Future<HotspotCredentials?> read() async => stored;

  @override
  Future<void> write(HotspotCredentials credentials) async =>
      stored = credentials;
}
