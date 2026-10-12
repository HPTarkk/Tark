import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:tark/core/identity/channel_id.dart';
import 'package:tark/core/widget/qr_brand_plan.dart';
import 'package:tark/core/widget/qr_widgets.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_accepted_join_snapshot.dart';
import 'package:tark/feature/room/domain/entity/room_direct_join_bundle.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';

import 'qr_damage_model.dart';

/// Every Tarkk QR carries the brand mark in its centre, and the mark punches
/// a hole in the code. These tests are what stands between that design and a
/// code that will not scan in the field: they re-derive, from the encoder's own
/// module placement and Reed-Solomon block table, how much of every block the
/// hole destroys, for every version the app can draw and for the longest
/// payloads the app really produces.
void main() {
  /// Share of a block's correction capacity the mark may use. The rest is for
  /// the camera: glare, blur, moiré off another phone's screen.
  const maxBlockLoad = 0.5;

  group('the damage model', () {
    test(
      'reproduces the encoder bit for bit, so its verdicts can be trusted',
      () {
        for (final version in [1, 4, 7, 12, 21, 30, 34, 40]) {
          for (final level in [QrErrorCorrectLevel.M, QrErrorCorrectLevel.Q]) {
            final code = QrCode(version, level)..addData('tarkk-$version');
            expect(
              QrDamageModel(version, level).reproduces(code),
              isTrue,
              reason: 'v$version ${QrErrorCorrectLevel.getName(level)}',
            );
          }
        }
      },
    );
  });

  group('the safe-mark tables', () {
    for (final level in [QrErrorCorrectLevel.M, QrErrorCorrectLevel.Q]) {
      final name = QrErrorCorrectLevel.getName(level);
      test(
        '$name: every version keeps the mark within half of every block',
        () {
          final table = QrBrandPlan.safeMarkTable(level);
          expect(table, hasLength(40));
          for (var version = 1; version <= 40; version += 1) {
            final mark = table[version - 1];
            expect(mark.isOdd, isTrue, reason: 'v$version centres on the grid');
            final load = QrDamageModel(version, level).worstBlockLoad(mark);
            expect(
              load,
              lessThanOrEqualTo(maxBlockLoad),
              reason: '$name v$version: a $mark-module mark',
            );
          }
        },
      );
    }
  });

  /// What the plan does with a payload, checked end to end against the model.
  void expectSafelyBranded(
    String payload, {
    required double size,
    required double minPitch,
  }) {
    final plan = QrBrandPlan.of(payload, size: size);
    expect(plan.branded, isTrue, reason: 'every Tarkk code carries the mark');
    expect(plan.errorCorrectLevel, isNot(QrErrorCorrectLevel.L));
    // The plan's version really holds the payload at its level.
    final code = QrCode(plan.version, plan.errorCorrectLevel)..addData(payload);
    expect(() => QrImage(code), returnsNormally);
    expect(
      QrDamageModel(
        plan.version,
        plan.errorCorrectLevel,
      ).worstBlockLoad(plan.markModules),
      lessThanOrEqualTo(maxBlockLoad),
    );
    expect(plan.markModules / plan.moduleCount, inInclusiveRange(0.19, 0.24));
    expect(
      plan.quietZoneModules(size),
      greaterThanOrEqualTo(QrBrandPlan.quietModules),
    );
    expect(plan.modulePitch(size), greaterThanOrEqualTo(minPitch));
  }

  // One-scan invite sheet: up to 270, grown towards what the sheet leaves
  // (412 − 2·18 sheet padding − the card's frame) when the code is dense.
  const phone = 412.0 - 36 - 54;
  const narrowPhone = 360.0 - 36 - 54;

  group('real payloads', () {
    test('a typical hotspot code is roomy and at level Q', () {
      const creds = HotspotCredentials(
        ssid: 'AndroidShare_2841',
        passphrase: 'qwer1234asdf',
      );
      final payload = creds.qrPayload(channel: const ChannelId(0xA83F21));
      expectSafelyBranded(payload, size: 216, minPitch: 4.5);
      expect(
        QrBrandPlan.of(payload, size: 216).errorCorrectLevel,
        QrErrorCorrectLevel.Q,
      );
    });

    test('an unusually long SSID still clears the hotspot bar', () {
      const creds = HotspotCredentials(
        ssid: 'SomeVendorVeryLongHotspotName_92841',
        passphrase: 'correcthorsebatterystaple',
        security: 'SAE',
      );
      expectSafelyBranded(
        creds.qrPayload(channel: const ChannelId(0xA83F21)),
        size: 216,
        minPitch: 4,
      );
    });

    test('a two-seat Room invite riding a Wi-Fi code', () {
      final payload = _wifi(_invite(members: 2));
      final size = QrBrandPlan.sizeFor(payload, preferred: 270, max: phone);
      expectSafelyBranded(payload, size: size, minPitch: 2.4);
    });

    test(
      'the longest delegated invite: v4 chain, 80-character Persian name',
      () {
        final invite = _invite(
          members: 3,
          delegated: true,
          roomName: _persian(80),
        );
        expect(
          RoomDirectJoinBundle.decode(invite).certificate.issuerChain,
          hasLength(RoomMemberTransportCertificate.maxIssuerChain),
        );
        final payload = _wifi(invite);
        final size = QrBrandPlan.sizeFor(payload, preferred: 270, max: phone);
        expect(
          size,
          greaterThan(270),
          reason: 'a dense code gets a bigger tile',
        );
        expectSafelyBranded(payload, size: size, minPitch: 2);
        // A narrow phone has no room to grow into; still well clear of the
        // 1.5 px modules the v1 invite was reported unscannable at.
        expectSafelyBranded(payload, size: narrowPhone, minPitch: 1.8);
      },
    );

    test('even a full roster on a delegated invite with the longest name', () {
      final payload = _wifi(
        _invite(
          members: RoomAcceptedJoinSnapshot.maxMembers,
          delegated: true,
          roomName: _persian(RoomAcceptedJoinSnapshot.maxRoomNameLength),
        ),
      );
      final size = QrBrandPlan.sizeFor(payload, preferred: 270, max: phone);
      expectSafelyBranded(payload, size: size, minPitch: 1.6);
    });
  });

  testWidgets('the card draws the mark on a long code, centred and on-grid', (
    tester,
  ) async {
    final payload = _wifi(
      _invite(members: 3, delegated: true, roomName: _persian(80)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: GlowingQrCard(data: payload, size: 300)),
        ),
      ),
    );
    final plan = QrBrandPlan.of(payload, size: 300);
    final mark = find.byKey(const Key('qr-brand-mark'));
    expect(mark, findsOneWidget);
    expect(tester.getSize(mark).width, closeTo(plan.markExtent(300), 0.01));
    final view = tester.widget<QrImageView>(find.byType(QrImageView));
    expect(view.version, plan.version);
    expect(view.errorCorrectionLevel, plan.errorCorrectLevel);
    expect(
      tester.getCenter(mark),
      offsetMoreOrLessEquals(tester.getCenter(find.byType(QrImageView))),
    );
    // The code is drawn at exactly the plan's pitch.
    final drawn = tester.getSize(find.byType(QrImageView)).width;
    expect(drawn, closeTo(plan.moduleCount.toDouble(), 0.01));
    final scaled = tester.getRect(find.byType(FittedBox)).width;
    expect(scaled, closeTo(plan.codeExtent(300), 0.01));
  });
}

String _persian(int length) {
  const words = 'رکاب صبح جمعه با بچه‌های تهران تا دماوند ';
  final buffer = StringBuffer();
  while (buffer.length < length) {
    buffer.write(words);
  }
  return buffer.toString().substring(0, length).trim().padRight(length, 'ر');
}

String _wifi(String invite) => const HotspotCredentials(
  ssid: 'AndroidShare_2841',
  passphrase: 'qwer1234asdf',
).qrPayload(channel: const ChannelId(0xA83F21), roomInvite: invite);

/// A realistic invite for a Room of [members]: Persian display names, and —
/// when [delegated] — the invite right signed in, carried down the longest
/// chain a certificate may hold.
String _invite({
  required int members,
  bool delegated = false,
  String roomName = 'رکاب صبح جمعه',
}) {
  const roomId = RoomId('abababababababababababababababab');
  const joinerId = RoomMemberId('222222222222222222222222');
  final joinedAt = DateTime.utc(2026, 9, 2, 12, 30, 15, 250);
  List<int> bytes(int length, int seed) =>
      List<int>.generate(length, (i) => (i * 7 + seed) & 0xff);
  final keyPair = RoomMemberTransportKeyPair(
    privateKey: bytes(32, 3),
    publicKey: bytes(32, 11),
  );
  final root = bytes(32, 29);
  return RoomDirectJoinBundle(
    memberId: joinerId,
    snapshot: RoomAcceptedJoinSnapshot(
      roomId: roomId,
      roomName: roomName,
      roomCreatedAt: joinedAt,
      roomUpdatedAt: joinedAt,
      grantsInviteManagement: delegated,
      members: [
        for (var index = 0; index < members - 1; index += 1)
          RoomAcceptedJoinMember(
            memberId: RoomMemberId(
              '11111111111111111111111${index.toRadixString(16)}',
            ),
            displayName: 'همراه شماره $index',
            joinedAt: joinedAt,
            kind: RoomMemberKind.member,
          ),
        RoomAcceptedJoinMember(
          memberId: joinerId,
          displayName: 'جای خالی',
          joinedAt: joinedAt,
          kind: RoomMemberKind.member,
        ),
      ],
    ),
    memberKeyPair: keyPair,
    certificate: RoomMemberTransportCertificate(
      roomId: roomId,
      memberId: joinerId,
      memberPublicKey: keyPair.publicKey,
      issuerPublicKey: delegated ? bytes(32, 61) : root,
      issuerSignature: bytes(64, 47),
      inviteGrant: delegated ? bytes(64, 5) : null,
      issuerChain: [
        if (delegated)
          for (
            var link = 0;
            link < RoomMemberTransportCertificate.maxIssuerChain;
            link += 1
          )
            RoomInviteDelegation(
              memberId: RoomMemberId('33333333333333333333333$link'),
              memberPublicKey: bytes(32, 70 + link),
              issuerSignature: bytes(64, 90 + link),
              inviteGrant: bytes(64, 110 + link),
            ),
      ],
      chainRootPublicKey: delegated ? root : null,
    ),
    expiresAt: DateTime.utc(2099),
  ).encode();
}
