import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/data/security/room_transport_identity_secure_store.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/room_identity_secure_store');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final crypto = RoomMemberTransportIdentityCrypto();
  final roomId = RoomId('a' * 32);
  const memberId = RoomMemberId('bbbbbbbbbbbbbbbbbbbbbbbb');

  Future<RoomStoredTransportIdentity> identity() async {
    final issuer = await crypto.generateKeyPair();
    final member = await crypto.generateKeyPair();
    final certificate = await crypto.issueCertificate(
      roomId: roomId,
      memberId: memberId,
      memberPublicKey: member.publicKey,
      issuer: issuer,
    );
    return RoomStoredTransportIdentity(
      keyPair: member,
      certificate: certificate,
    );
  }

  tearDown(() async {
    await messenger.setMockMethodCallHandler(channel, null);
  });

  test('write read and delete keep private identity behind platform boundary', () async {
    final values = <String, String>{};
    await messenger.setMockMethodCallHandler(channel, (call) async {
      final arguments = Map<String, Object?>.from(call.arguments as Map);
      final key = '${arguments['roomId']}:${arguments['memberId']}';
      switch (call.method) {
        case 'write':
          values[key] = arguments['secret']! as String;
          return null;
        case 'read':
          return values[key];
        case 'delete':
          values.remove(key);
          return null;
      }
      throw PlatformException(code: 'unexpected_method');
    });
    final store = RoomTransportIdentitySecureStore(channel: channel);
    final original = await identity();

    expect(
      await store.write(
        roomId: roomId,
        memberId: memberId,
        identity: original,
      ),
      isTrue,
    );
    final restored = await store.read(roomId: roomId, memberId: memberId);
    expect(restored, isNotNull);
    expect(restored!.keyPair.privateKey, original.keyPair.privateKey);
    expect(restored.keyPair.publicKey, original.keyPair.publicKey);
    expect(restored.certificate.encode(), original.certificate.encode());

    expect(await store.delete(roomId: roomId, memberId: memberId), isTrue);
    expect(await store.read(roomId: roomId, memberId: memberId), isNull);
  });

  test('wrong Room or member scope rejects a returned secret', () async {
    String? captured;
    await messenger.setMockMethodCallHandler(channel, (call) async {
      final arguments = Map<String, Object?>.from(call.arguments as Map);
      if (call.method == 'write') {
        captured = arguments['secret']! as String;
        return null;
      }
      if (call.method == 'read') return captured;
      return null;
    });
    final store = RoomTransportIdentitySecureStore(channel: channel);
    final original = await identity();
    expect(
      await store.write(
        roomId: roomId,
        memberId: memberId,
        identity: original,
      ),
      isTrue,
    );

    final otherRoom = RoomId('c' * 32);
    expect(
      await store.read(roomId: otherRoom, memberId: memberId),
      isNull,
    );
    expect(
      await store.read(
        roomId: roomId,
        memberId: const RoomMemberId('dddddddddddddddddddddddd'),
      ),
      isNull,
    );
  });

  test('corrupt or unavailable secure storage fails closed', () async {
    await messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'read') return '{not-valid-json';
      throw PlatformException(code: 'secure_store_unavailable');
    });
    final store = RoomTransportIdentitySecureStore(channel: channel);
    final original = await identity();

    expect(await store.read(roomId: roomId, memberId: memberId), isNull);
    expect(
      await store.write(
        roomId: roomId,
        memberId: memberId,
        identity: original,
      ),
      isFalse,
    );
    expect(await store.delete(roomId: roomId, memberId: memberId), isFalse);
  });

  test('identity cannot be written into a different durable member scope', () async {
    var calls = 0;
    await messenger.setMockMethodCallHandler(channel, (call) async {
      calls += 1;
      return null;
    });
    final store = RoomTransportIdentitySecureStore(channel: channel);
    final original = await identity();

    expect(
      await store.write(
        roomId: roomId,
        memberId: const RoomMemberId('eeeeeeeeeeeeeeeeeeeeeeee'),
        identity: original,
      ),
      isFalse,
    );
    expect(calls, 0);
  });
}
