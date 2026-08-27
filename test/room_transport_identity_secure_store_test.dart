import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/data/security/room_transport_identity_secure_store.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('tark/room_identity_secure_storage_test');
  final roomId = RoomId('a' * 32);
  const memberId = RoomMemberId('bbbbbbbbbbbbbbbbbbbbbbbb');
  const otherMemberId = RoomMemberId('cccccccccccccccccccccccc');
  final crypto = RoomMemberTransportIdentityCrypto();

  Future<RoomTransportIdentityMaterial> material() async {
    final issuer = await crypto.generateKeyPair();
    final member = await crypto.generateKeyPair();
    final certificate = await crypto.issueCertificate(
      roomId: roomId,
      memberId: memberId,
      memberPublicKey: member.publicKey,
      issuer: issuer,
    );
    return RoomTransportIdentityMaterial(
      memberKeyPair: member,
      certificate: certificate,
      issuerKeyPair: issuer,
    );
  }

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('write/read/delete keeps one scoped identity round trip', () async {
    Map<Object?, Object?>? persisted;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map<Object?, Object?>;
          expect(args['roomId'], roomId.value);
          expect(args['memberId'], memberId.value);
          switch (call.method) {
            case 'write':
              persisted = Map<Object?, Object?>.from(
                args['material']! as Map<Object?, Object?>,
              );
              return null;
            case 'read':
              return persisted;
            case 'delete':
              persisted = null;
              return null;
          }
          throw MissingPluginException();
        });

    final store = PlatformRoomTransportIdentitySecureStore(channel: channel);
    final value = await material();
    await store.write(roomId: roomId, memberId: memberId, material: value);

    final restored = await store.read(roomId: roomId, memberId: memberId);
    expect(restored, isNotNull);
    expect(restored!.memberKeyPair.privateKey, value.memberKeyPair.privateKey);
    expect(restored.memberKeyPair.publicKey, value.memberKeyPair.publicKey);
    expect(restored.certificate.encode(), value.certificate.encode());
    expect(restored.issuerKeyPair?.privateKey, value.issuerKeyPair?.privateKey);

    await store.delete(roomId: roomId, memberId: memberId);
    expect(await store.read(roomId: roomId, memberId: memberId), isNull);
  });

  test('write rejects material stored under the wrong member scope', () async {
    final store = PlatformRoomTransportIdentitySecureStore(channel: channel);
    final value = await material();

    expect(
      () =>
          store.write(roomId: roomId, memberId: otherMemberId, material: value),
      throwsArgumentError,
    );
  });

  test('read fails closed when persisted certificate scope is wrong', () async {
    final value = await material();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'read') return null;
          return value.toMap();
        });
    final store = PlatformRoomTransportIdentitySecureStore(channel: channel);

    expect(
      () => store.read(roomId: roomId, memberId: otherMemberId),
      throwsFormatException,
    );
  });

  test('read fails closed for corrupt material', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'read') return null;
          return <String, Object?>{
            'memberPrivateKey': 'broken',
            'memberPublicKey': 'broken',
            'certificate': 'broken',
          };
        });
    final store = PlatformRoomTransportIdentitySecureStore(channel: channel);

    expect(
      () => store.read(roomId: roomId, memberId: memberId),
      throwsFormatException,
    );
  });

  test('missing material returns null', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    final store = PlatformRoomTransportIdentitySecureStore(channel: channel);

    expect(await store.read(roomId: roomId, memberId: memberId), isNull);
  });

  test(
    'unsupported platform does not fall back to plaintext storage',
    () async {
      final store = PlatformRoomTransportIdentitySecureStore(channel: channel);
      final value = await material();

      expect(
        () => store.write(roomId: roomId, memberId: memberId, material: value),
        throwsA(isA<MissingPluginException>()),
      );
    },
  );
}
